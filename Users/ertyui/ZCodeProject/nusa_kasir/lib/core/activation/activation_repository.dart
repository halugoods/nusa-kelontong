import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:nusa_kasir/core/cloud/cloud_gateway.dart';
import 'package:nusa_kasir/core/activation/activation_key.dart';
import 'package:nusa_kasir/core/activation/activation_public_key.dart';
import 'package:nusa_kasir/core/utils/secure_storage.dart';
import 'package:nusa_kasir/core/services/google_auth_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:nusa_kasir/core/config/nusa_config.dart';
import 'package:nusa_kasir/core/services/backup_crypto.dart';
import 'package:nusa_kasir/data/database/app_database.dart';

class ActivationResult {
  final bool ok;
  final String? error;
  ActivationResult(this.ok, [this.error]);
}

/// Status verifikasi backup cloud terhadap varian aplikasi ini — dipakai
/// activation_screen / RestoreBackupFlow untuk MENAMPILKAN pesan yang tepat
/// saat backup ada tapi isinya milik varian lain (folder tercemar), bukannya
/// diam-diam menganggap "tidak ada" lalu memaksa user setup ulang (v2.2.43).
enum BackupVariantStatus {
  /// Tidak ada backup di path varian ini (atau gagal unduh/decrypt).
  none,
  /// Backup ada dan isinya milik varian ini — layak ditawarkan untuk restore.
  matches,
  /// Backup ADA di path varian ini tapi isinya data varian LAIN (folder
  /// tercemar / setup keliru di perangkat lain). JANGAN restore diam-diam;
  /// beri tahu user dengan jelas.
  wrongVariant,
}

class ActivationRepository {
  ActivationRepository();

  Future<bool> get isActivated async =>
      (await SecureStore.getActivation()) != null;

  /// Get the Google user ID (used as encryption key for backups).
  ///
  /// v2.2.38: JANGAN fallback ke UID sesi anon Supabase untuk path/decrypt.
  /// Backup selalu dienkripsi + dipath dengan Google UID (`nusa_google_user_id`
  /// dari GoogleAuthService — angka 21 digit). UID anon (UUID format) ≠ Google
  /// UID → path berbeda → `hasBackup()` tak pernah menemukan backup + dekripsi
  /// gagal. Verifikasi 2026-08-20: SEMUA backup di bucket nusa-backups ada di
  /// path angka 21 digit, TIDAK ADA satu pun path UUID anon — fallback anon
  /// hanya menghasilkan path kosong → dialog "Data Ditemukan" tak muncul →
  /// user disuruh setup ulang padahal datanya ada. Kalau Google UID kosong →
  /// null (caller lanjut ke setup / minta login Google).
  ///
  /// v2.2.57+115 (Area I): unifikasi identitas — prefer `nusa_account_uid`
  /// (UUID email/password, jalur login terbaru) kalau ada, lalu Google
  /// 21-digit. Sebelumnya SELALU prioritas Google → kalau user pernah login
  /// email setelah Google, backup terpecah ke dua path → autosync "tidak
  /// sinkron" (laporan user 2026-08-28). Konsistenkan ke satu canonical UID.
  static Future<String?> _googleUserId() async {
    return SecureStore.resolveCanonicalUid();
  }

  /// Ensure a cloud session exists so background storage calls (auto-sync
  /// upload/download) work without forcing interactive auth.
  ///
  /// CloudGateway.init() sudah memuat JWT tersimpan / membuat sesi anon
  /// dengan legacy uid (path R2 = uid lama). Tidak ada langkah auth tambahan
  /// yang perlu dilakukan di sini — senggat jaringan ditangani gateway.
  Future<void> _ensureAnonAuth() async {
    if (!CloudGateway.shared.hasSession) {
      try {
        await CloudGateway.shared.init();
      } catch (_) {}
    }
  }

  /// Activate with Google ID (new flow).
  /// - Verifies Ed25519 signature locally
  /// - Sends key + googleUserId to register_activation edge function
  /// - Links license ↔ Google ID in cloud
  Future<ActivationResult> activate(String rawKey, String googleUserId) async {
    final key = rawKey.trim().toUpperCase();
    final valid = await ActivationKey.verify(key, nusaActivationPublicKey);
    if (!valid) return ActivationResult(false, 'Key tidak valid');

    await SecureStore.saveActivation(key);

    try {
      final ownerEmail = await GoogleAuthService.getStoredEmail();
      final res = await CloudGateway.shared.invoke(
        'register_activation',
        body: {
          'key': key,
          'googleUserId': googleUserId,
          'product': NusaConfig.productId,
          if (ownerEmail != null) 'ownerEmail': ownerEmail,
        },
      );
      if (res.status >= 400) {
        final data = res.data as Map<String, dynamic>?;
        final err = data?['error'] as String? ?? 'Aktivasi gagal';
        if (res.status == 403) {
          await SecureStore.clearActivation();
          return ActivationResult(false, 'Key dibatalkan atau tidak valid');
        }
        if (res.status == 409) {
          await SecureStore.clearActivation();
          return ActivationResult(
            false,
            data?['message'] as String? ??
                'Akun Google sudah dipakai untuk license lain',
          );
        }
        await SecureStore.clearActivation();
        return ActivationResult(false, err);
      }
    } catch (_) {
      // offline: keep local activation
    }
    return ActivationResult(true);
  }

  /// Lite activation (v2.2.57+130) — email + key only, tanpa Google Sign-In.
  /// Validasi email cocok dengan key di server. Tidak butuh Google auth.
  ///
  /// Alur:
  /// 1. Verify Ed25519 signature lokal (tetap pakai — admin issued key valid)
  /// 2. POST /api/license-manager/activate_lite {email, license_key, product, device_id}
  /// 3. Server cek: key valid? email cocok? status ok? → return Active
  /// 4. Save key + email (untuk backup encryption identity Lite)
  Future<ActivationResult> activateLite(String rawKey, String email, {String? deviceId}) async {
    final key = rawKey.trim().toUpperCase();
    final emailLower = email.trim().toLowerCase();

    // 1. Verify signature lokal
    final valid = await ActivationKey.verify(key, nusaActivationPublicKey);
    if (!valid) return ActivationResult(false, 'Format key tidak valid');

    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(emailLower)) {
      return ActivationResult(false, 'Format email tidak valid');
    }

    // 2. Panggil worker Lite activation
    try {
      final res = await CloudGateway.shared.invokeRaw(
        'license-manager',
        'activate_lite',
        body: {
          'license_key': key,
          'email': emailLower,
          'product': NusaConfig.productId,
          if (deviceId != null) 'device_id': deviceId,
        },
      );
      if (res.status >= 400) {
        final data = res.data as Map<String, dynamic>?;
        final err = data?['error'] as String? ?? 'Aktivasi gagal';
        return ActivationResult(false, err);
      }
    } catch (e) {
      return ActivationResult(false, 'Gagal terhubung ke server: $e');
    }

    // 3. Save locally
    await SecureStore.saveActivation(key);
    await SecureStore.saveLiteEmail(emailLower);

    return ActivationResult(true);
  }

  /// Build the backup path using the stored Google user ID + product ID.
  /// Namespaced per product to prevent cross-variant data leakage.
  static Future<String?> _backupPath() async {
    final uid = await _googleUserId();
    if (uid == null) return null;
    return '$uid/${NusaConfig.productId}/backup.sqlite.enc';
  }

  /// Check if an encrypted backup exists in Supabase Storage for the linked Google account.
  ///
  /// v2.2.38: JANGAN pakai `storage.list()` untuk deteksi — anon key TIDAK
  /// punya izin list folder (404 "Bucket not found" meski bucket terlihat di
  /// `/bucket` dan download langsung 200). Akibatnya `hasBackup()` selalu
  /// false → dialog "Data Ditemukan" tak muncul → SEMUA user disuruh setup
  /// ulang padahal datanya ada (verifikasi 2026-08-20: download path persis
  /// 200 untuk 11 UID / 21 backup). Fix: probe dengan download → 200 = ada.
  ///
  /// v2.2.42: verifikasi ISI backup — folder backup bisa tercemar data varian
  /// LAIN (mis. folder nusa-fnb berisi produk servis, kasus user 2026-08-20).
  /// Kalau isi backup bukan milik varian ini, `hasBackup()` menganggap TIDAK
  /// ADA supaya dialog "Data Ditemukan" TIDAK menawarkan data varian lain
  /// (restore data salah varian = data user hilang dari layar). Cek murah:
  /// PRAGMA user_version + nama tabel + kategori produk dari sqlite bytes.
  Future<bool> hasBackup() async {
    await _ensureAnonAuth();
    final uid = await _googleUserId();
    if (uid == null) return false;
    try {
      final path = '$uid/${NusaConfig.productId}/backup.sqlite.enc';
      final bytes = await CloudGateway.shared
          .storageDownload('nusa-backups', path);
      if (bytes == null || bytes.isEmpty) return false;
      // v2.2.42: verifikasi ISI backup (decrypt + unpack + cek varian) —
      // kalau isinya data varian lain, anggap TIDAK ADA (dialog Data
      // Ditemukan tak muncul → user setup dari nol untuk varian ini).
      // v2.2.57+130: decrypt+unpack di background isolate.
      final files = await decryptAndUnpackInIsolate(bytes, uid);
      final sqlite = files['nusa_kasir.sqlite'];
      if (sqlite == null) return false;
      return await _backupBelongsToVariant(sqlite, uid);
    } catch (_) {
      return false;
    }
  }

  /// Status backup cloud di path varian ini — membedakan "tidak ada" dari
  /// "ada tapi isinya varian lain". v2.2.43: dipakai UI untuk menampilkan
  /// pesan jelas (bukan diam-diam setup ulang) saat folder tercemar.
  Future<BackupVariantStatus> checkBackupVariant() async {
    await _ensureAnonAuth();
    final uid = await _googleUserId();
    if (uid == null) return BackupVariantStatus.none;
    try {
      final path = '$uid/${NusaConfig.productId}/backup.sqlite.enc';
      final bytes = await CloudGateway.shared
          .storageDownload('nusa-backups', path);
      if (bytes == null || bytes.isEmpty) return BackupVariantStatus.none;
      // v2.2.57+130: decrypt+unpack di background isolate.
      final files = await decryptAndUnpackInIsolate(bytes, uid);
      final sqlite = files['nusa_kasir.sqlite'];
      if (sqlite == null) return BackupVariantStatus.none;
      final ok = await _backupBelongsToVariant(sqlite, uid);
      return ok
          ? BackupVariantStatus.matches
          : BackupVariantStatus.wrongVariant;
    } catch (_) {
      return BackupVariantStatus.none;
    }
  }

  /// Cek apakah isi backup milik varian aplikasi ini. Backup dari varian lain
  /// (folder yang tercemar / setup keliru) TIDAK boleh di-restore — datanya
  /// bukan punya user untuk varian ini.
  ///
  /// Input [sqliteBytes] = bytes nusa_kasir.sqlite hasil decrypt+unpack
  /// (v2.2.57+130: pemanggil sudah menjalankan decryptAndUnpackInIsolate,
  /// fungsi ini tinggal inspeksi). Heuristik:
  /// 1. user_version < 20 → backup sangat lama / rusak → tolak.
  /// 2. Tabel kunci (products, transactions, employees) tidak ada → bukan
  ///    DB NUSA → tolak.
  /// 3. image_path produk menyebut paket aplikasi yang BUKAN paket varian ini
  ///    (mis. `/data/user/0/com.nusa.servis/...` di dalam folder nusa-fnb) →
  ///    pasti data varian lain → tolak. Ini sinyal PALING definitif (kasus
  ///    user 2026-08-20: folder nusa-fnb berisi produk servis, pkg
  ///    com.nusa.servis).
  /// 4. metadata.json `variantKey` (ditulis mulai v2.2.42) beda dari varian
  ///    ini → tolak. Backup baru selalu membawa identitas varian di metadata.
  Future<bool> _backupBelongsToVariant(
    List<int> sqliteBytes,
    String googleUserId,
  ) async {
    try {
      // Cek metadata variantKey dulu (kalau ada — backup versi baru).
      // v2.2.51: Jika metadata null (upload gagal / backup lama), JANGAN
      // langsung reject — fallback ke sqlite inspection. Backup valid tapi
      // tanpa metadata masih bisa diverifikasi lewat package name di image_path.
      // Kalau metadata ADA tapi variantKey beda → tetap reject.
      final meta = await getBackupMetadata();
      final metaVariant = meta?['variantKey'] as String?;
      if (metaVariant != null && metaVariant != NusaConfig.productId) {
        return false; // metadata says wrong variant → reject
      }
      // metaVariant == null → metadata missing, fall through to sqlite check
      // metaVariant == NusaConfig.productId → metadata matches, continue

      final sqlite = Uint8List.fromList(sqliteBytes);

      // Tulis bytes sqlite ke file temp di documents dir (relatif — pola sama
      // dengan _migrateSqliteBytes) lalu baca ringkasan schema.
      final tempName =
          'nusa_verify_${DateTime.now().millisecondsSinceEpoch}.sqlite';
      final dir = await getApplicationDocumentsDirectory();
      final tmp = File(p.join(dir.path, tempName));
      await tmp.writeAsBytes(sqlite, flush: true);
      try {
        final res = await _inspectSqlite(tempName);
        if (res == null) return false;
        return inspectMatchesVariant(
          res,
          expectedPackage:
              'com.nusa.${NusaConfig.productId.replaceFirst('nusa-', '')}',
        );
      } finally {
        try {
          await tmp.delete();
        } catch (_) {}
      }
    } catch (_) {
      // Gagal verifikasi → aman: anggap backup tidak valid (jangan restore
      // data yang tidak dikenal; lebih baik dialog tak muncul daripada
      // menimpa user dengan data varian lain).
      return false;
    }
  }

  /// Keputusan murni dari hasil [inspectSqliteResult] — apakah isi DB milik
  /// varian dengan paket [expectedPackage]. Dipisah supaya bisa di-unit-test
  /// (tanpa Supabase / network). [inspectSqliteResult] = output _inspectSqlite.
  /// Public (bukan private) supaya bisa dites dari test package.
  static bool inspectMatchesVariant(
    Map<String, dynamic> inspectSqliteResult, {
    required String expectedPackage,
  }) {
    final version = inspectSqliteResult['user_version'] as int? ?? 0;
    if (version < 20) return false; // backup terlalu lama/rusak
    if (inspectSqliteResult['has_products'] != true ||
        inspectSqliteResult['has_employees'] != true ||
        inspectSqliteResult['has_transactions'] != true) {
      return false; // bukan DB NUSA lengkap
    }
    // Cek paket aplikasi dari image_path produk (bila ada).
    final pkgs = (inspectSqliteResult['packages'] as List<dynamic>? ?? [])
        .cast<String>()
        .toSet();
    final foreignPkg =
        pkgs.any((p) => p != expectedPackage && p.startsWith('com.nusa.'));
    if (foreignPkg) return false;
    return true;
  }

  /// Baca ringkasan sqlite (user_version, tabel kunci, kategori, paket
  /// aplikasi) dari file temp via drift (AppDatabase.at — pola yang sama
  /// dengan _migrateSqliteBytes; beforeOpen repair jalan tapi hanya pada
  /// salinan temp). Return null kalau bukan sqlite valid.
  Future<Map<String, dynamic>?> _inspectSqlite(String tempName) async {
    try {
      final db = AppDatabase.at(tempName);
      await db.customSelect('SELECT 1').get(); // trigger open + migrasi
      final versionRow =
          await db.customSelect('PRAGMA user_version').getSingle();
      final v = versionRow.data['user_version'] as int? ?? 0;
      final tables = <String>{};
      final tableRows = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
          .get();
      for (final row in tableRows) {
        tables.add('${row.data['name']}');
      }
      final packages = <String>[];
      if (tables.contains('products')) {
        final imgs = await db.customSelect(
          "SELECT image_path FROM products WHERE image_path IS NOT NULL AND image_path != '' LIMIT 10",
        ).get();
        for (final row in imgs) {
          final m = RegExp(r'com\.nusa\.[a-z0-9_]+')
              .firstMatch('${row.data['image_path']}');
          if (m != null) packages.add(m.group(0)!);
        }
      }
      await db.close();
      return {
        'user_version': v,
        'has_products': tables.contains('products'),
        'has_employees': tables.contains('employees'),
        'has_transactions': tables.contains('transactions'),
        'packages': packages,
      };
    } catch (_) {
      return null;
    }
  }

  /// Get the cloud backup's last-modified timestamp.
  ///
  /// v2.2.57: uses embedded metadata (inside encrypted archive) — fallback
  /// to the plaintext sidecar metadata.json for backups written by older
  /// versions. NEVER falls back to `DateTime.now()` because that is what
  /// broke sync for percetakanrks@gmail.com (metadata upload silently
  /// failing → cloud timestamp looked always-newer than local → every
  /// autosync cycle hit conflict path → fresh uploads never propagated).
  /// If we cannot determine a real timestamp, return `null` and let the
  /// caller treat it as "cloud not proven newer than local" (safe path).
  /// v2.2.57+122 (Cached Egress fix): timestamp backup TANPA download full
  /// file. Sebelumnya `getBackupTimestamp()` download seluruh
  /// `backup.sqlite.enc` (beberapa MB) tiap kali dipanggil — padahal
  /// `_pullOnly()` memanggilnya tiap 30 detik → 8.640×/hari/device × MB =
  /// sumber utama pembengkakan Cached Egress (791%).
  ///
  /// Sekarang: `getBackupTimestamp` membaca sidecar `metadata.json` (~200 B,
  /// bukan full archive). Gateway tidak menyediakan HEAD/info() per objek;
  /// backup baru selalu menulis metadata.json (uploadBackupNow) — fallback
  /// `DateTime.now()` TETAP dihindari. Kalau sidecar gagal → null
  /// (caller anggap "cloud tidak terbukti lebih baru" = aman upload).
  Future<DateTime?> getBackupTimestamp() async {
    await _ensureAnonAuth();
    final uid = await _googleUserId();
    if (uid == null) return null;
    try {
      final bytes = await CloudGateway.shared
          .storageDownload(
            'nusa-backups',
            '$uid/${NusaConfig.productId}/metadata.json',
          )
          .timeout(const Duration(seconds: 8));
      if (bytes != null && bytes.isNotEmpty) {
        final m = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        final t = DateTime.tryParse(m['updated_at']?.toString() ?? '') ??
            DateTime.tryParse(m['backupTime']?.toString() ?? '');
        if (t != null) return t;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Upload current local DB + product images to cloud.
  /// Packed as a single archive (now includes metadata.json INSIDE the
  /// encrypted archive — v2.2.57). Encrypted with Google user ID.
  ///
  /// v2.2.57: metadata is no longer uploaded as a separate plaintext file.
  /// It is packed INSIDE the encrypted archive (`metadata.json` entry) so
  /// the timestamp + store/owner info can never get out-of-sync with the
  /// backup itself. This closes the failure mode where `getBackupTimestamp`
  /// would fall back to `DateTime.now()` and break sync silently because
  /// the sidecar metadata.json failed to upload (root cause of stuck-amber
  /// + always-conflict bug seen on percetakanrks@gmail.com 2026-08-26).
  Future<bool> uploadBackupNow({String? storeName, String? ownerName}) async {
    await _ensureAnonAuth();
    final uid = await _googleUserId();
    if (uid == null) return false;
    final path = '$uid/${NusaConfig.productId}/backup.sqlite.enc';
    try {
      final dir = await getApplicationDocumentsDirectory();
      final dbFile = File(p.join(dir.path, 'nusa_kasir.sqlite'));
      if (!await dbFile.exists()) return false;

      final now = DateTime.now();
      final meta = {
        'storeName': storeName ?? '',
        'ownerName': ownerName ?? '',
        'backupTime': now.toUtc().toIso8601String(),
        'updated_at': now.toUtc().toIso8601String(),
        'appVersion':
            '${NusaConfig.appVersion}+${NusaConfig.appBuildNumber}',
        'productId': NusaConfig.productId,
        'variantKey': NusaConfig.productId,
      };

      final files = <String, Uint8List>{};
      files['nusa_kasir.sqlite'] = await dbFile.readAsBytes();
      files['metadata.json'] = Uint8List.fromList(
        const JsonEncoder.withIndent('  ').convert(meta).codeUnits,
      );

      // v2.2.57+130: file gambar (product_*/photo_*/qris_*) TIDAK lagi ikut
      // arsip backup. Arsip gemuk (30+ MB) yang dikemas setiap kali autosync
      // jalan = bom egress + OOM (root cause force close user DB besar).
      // Gambar redundan: tersimpan di bucket nusa-images saat sync toko
      // online / syncAll, dan path fisiknya tetap ada di device. Setelah
      // restore di device baru, _relinkImagesFromCloud() (main.dart) +
      // syncAll menarik gambar dari bucket.

      // v2.2.57+130: pack + gzip + encrypt SEKALI jalan di background isolate
      // (encryptInIsolate menerima map file mentah, lalu pack → gzip → AES).
      final encrypted = await encryptInIsolate(files, uid);
      await CloudGateway.shared.storageUpload(
        'nusa-backups',
        path,
        encrypted,
        contentType: 'application/octet-stream',
        upsert: true,
      );

      await SecureStore.saveLastBackupTime(now);
      debugPrint(
        '[Backup] Uploaded DB (${encrypted.length} bytes encrypted, metadata-in-archive, no images)',
      );
      return true;
    } catch (e) {
      debugPrint('[Backup] uploadBackupNow error: $e');
      return false;
    }
  }

  /// Fetch the backup metadata (store name, owner, backup time).
  /// v2.2.57: prefers embedded metadata inside the encrypted archive. Falls
  /// back to the legacy plaintext `metadata.json` for backups written by
  /// older versions (graceful upgrade path — existing backups remain usable).
  Future<Map<String, dynamic>?> getBackupMetadata() async {
    final uid = await _googleUserId();
    if (uid == null) return null;
    try {
      final embedded = await _readEmbeddedMetadata();
      if (embedded != null) return embedded;
      final bytes = await CloudGateway.shared
          .storageDownload('nusa-backups', '$uid/${NusaConfig.productId}/metadata.json');
      if (bytes == null || bytes.isEmpty) return null;
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Read metadata.json from inside the encrypted archive. Returns null on
  /// legacy (unpacked) backups or on any error — caller will fall back to
  /// the plaintext sidecar.
  Future<Map<String, dynamic>?> _readEmbeddedMetadata() async {
    final uid = await _googleUserId();
    if (uid == null) return null;
    try {
      final bytes = await CloudGateway.shared
          .storageDownload('nusa-backups', '$uid/${NusaConfig.productId}/backup.sqlite.enc');
      if (bytes == null || bytes.isEmpty) return null;
      // v2.2.57+130: decrypt+unpack di background isolate.
      final packed = await decryptAndUnpackInIsolate(bytes, uid);
      final meta = packed['metadata.json'];
      if (meta == null) return null;
      return jsonDecode(utf8.decode(meta)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // ── v2.2.57+115 (Area J): kompatibilitas backup antar versi ────────

  /// Versi backup yang DITOLAK karena lebih baru dari app terpasang.
  /// Dipakai UI restore untuk menampilkan pesan yang jelas. null = tidak ada
  /// penolakan (atau backup tidak membawa appVersion).
  String? _lastBackupVersionError;

  /// Versi backup yang terakhir ditolak karena lebih baru (untuk pesan UI),
  /// atau null bila tidak ada.
  String? get lastBackupVersionError => _lastBackupVersionError;

  /// Parse build number dari string "2.2.57+115" → 115. Return null kalau
  /// format tidak dikenal (backup lama tanpa appVersion).
  static int? _parseBuildNumber(String appVersion) {
    final m = RegExp(r'\+(\d+)\s*$').firstMatch(appVersion.trim());
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// Download backup from cloud and write directly to the live DB + images.
  /// Restore berlaku IMMEDIATE — caller harus menutup koneksi drift dulu
  /// (lihat RestoreBackupFlow / _autoRestoreIfNeeded) supaya swap aman.
  /// Returns true on success.
  Future<bool> restoreDirect() async {
    await _ensureAnonAuth();
    final uid = await _googleUserId();
    if (uid == null) return false;
    final path = '$uid/${NusaConfig.productId}/backup.sqlite.enc';
    try {
      final bytes = await CloudGateway.shared.storageDownload('nusa-backups', path);
      if (bytes == null || bytes.isEmpty) return false;
      // v2.2.57+130: decrypt+unpack SEKALI di background isolate (arsip bisa
      // puluhan MB — sebelumnya decrypt di main isolate lalu unpack lagi).
      // _backupBelongsToVariant menerima plaintext sqlite langsung dari map.
      final packedFiles = await decryptAndUnpackInIsolate(bytes, uid);
      final decryptedSqlite = packedFiles['nusa_kasir.sqlite'];
      if (decryptedSqlite == null) return false;

      // ── v2.2.57+115 (Area J): tolak backup dari versi LEBIH BARU ──
      // Backup yang dibuat oleh build lebih baru bisa membawa schema/kolom
      // yang versi terpasang belum kenal → setelah restore, drift tidak bisa
      // migrasi (user_version > schemaVersion app) → query error / login PIN
      // gagal karena DB dianggap "corrupt". Cegah dengan pesan yang jelas:
      // "Update app dulu, lalu restore". Downgrade diam-diam tidak pernah aman.
      final meta = await _readEmbeddedMetadata();
      final backupApp = meta?['appVersion']?.toString() ?? '';
      final installedBuild = await SecureStore.installedBuildNumber();
      final backupBuild = _parseBuildNumber(backupApp);
      if (backupBuild != null && backupBuild > installedBuild) {
        debugPrint(
          '[RestoreDirect] tolak backup versi $backupApp (lebih baru dari '
          'terpasang +$installedBuild)',
        );
        _lastBackupVersionError = backupApp;
        return false;
      }
      _lastBackupVersionError = null;

      // v2.2.42: jangan pernah restore backup yang isinya data varian LAIN
      // (folder tercemar — mis. nusa-fnb berisi produk servis). Restore data
      // salah varian = data user hilang dari layar varian ini.
      if (!await _backupBelongsToVariant(decryptedSqlite, uid)) return false;
      final dir = await getApplicationDocumentsDirectory();

      // Write archive entries (DB + images) directly — no restart needed
      var imageCount = 0;
      final rootCanonical = p.normalize(Directory(dir.path).absolute.path);
      for (final entry in packedFiles.entries) {
        final destination = File(p.join(dir.path, entry.key));
        final destinationCanonical = p.normalize(destination.absolute.path);
        if (destinationCanonical != rootCanonical &&
            !p.isWithin(rootCanonical, destinationCanonical)) {
          throw FormatException(
            'Restore path escapes application directory: ${entry.key}',
          );
        }

        // ── v2.2.37: swap LANGSUNG ke live sqlite (bukan .pending) ──
        // Caller (RestoreBackupFlow / _autoRestoreIfNeeded) SUDAH menutup
        // koneksi drift (`ref.read(databaseProvider).close()` + invalidate)
        // sebelum memanggil restoreDirect(). Karena tidak ada koneksi drift
        // yang terbuka, menulis langsung ke nusa_kasir.sqlite AMAN dan restore
        // berlaku IMMEDIATE — tidak perlu restart, tidak ada .pending yang
        // menggantung, tidak ada jendela di mana app membaca DB lama yang
        // kosong (PIN gagal + produk kosong) setelah restart gagal.
        // v2.2.39: SEBELUM menulis file, jalankan migrasi drift schema
        // terhadap bytes hasil decrypt — backup lama (mis. varian lain yang
        // masih ver 26-30) bisa bawa kolom/tabel yang belum ada. Kalau dibiarkan,
        // drift tidak akan migrasi (user_version sudah dibaca & di-cache di
        // koneksi), query produk error "no such column" → loading abadi.
        // Jalankan eksplisit supaya DB hasil restore SELALU schema 44.
        if (entry.key == 'nusa_kasir.sqlite') {
          final migrated = await _migrateSqliteBytes(entry.value, uid);
          final live = File(p.join(dir.path, 'nusa_kasir.sqlite'));
          // Bersihkan sidecar WAL/SHM supaya SQLite tidak me-replay data lama
          // di atas file yang baru ditimpa.
          for (final sidecar in [
            '${live.path}-wal',
            '${live.path}-shm',
            '${live.path}-journal',
          ]) {
            final f = File(sidecar);
            if (await f.exists()) {
              try {
                await f.delete();
              } catch (_) {}
            }
          }
          await live.writeAsBytes(migrated, flush: true);
          await SecureStore.clearPendingRestore();
          continue;
        }
        await File(destinationCanonical).writeAsBytes(entry.value, flush: true);
        if (entry.key != 'nusa_kasir.sqlite') imageCount++;
      }

      // Pull backup timestamp from metadata if available
      final meta2 = await getBackupMetadata();
      final ts = meta2?['updated_at'] ?? meta2?['backupTime'];
      if (ts != null) {
        final parsed = DateTime.tryParse(ts.toString());
        if (parsed != null) {
          await SecureStore.saveLastBackupTime(parsed);
        }
      }

      debugPrint('[RestoreDirect] Restored DB${imageCount > 0 ? " + $imageCount images" : ""} (live swap, no restart needed)');
      return true;
    } catch (e) {
      debugPrint('[RestoreDirect] error: $e');
      return false;
    }
  }

  /// Download backup from cloud and stage it for restore on next launch.
  /// Uses Google user ID for decryption.
  ///
  /// v2.2.37: gunakan untuk jalur yang TIDAK bisa menutup drift — background
  /// AutoSyncService & settings manual. Stage .pending → di-swap oleh
  /// main.dart _applyPendingRestore() saat start berikutnya (tidak menabrak
  /// koneksi drift yang selalu terbuka). Untuk jalur user-facing (activation /
  /// RestoreBackupFlow) gunakan restoreDirect() (live swap setelah drift
  /// ditutup).
  Future<bool> restoreFromCloud() async {
    await _ensureAnonAuth();
    final uid = await _googleUserId();
    if (uid == null) return false;
    final path = '$uid/${NusaConfig.productId}/backup.sqlite.enc';
    try {
      final bytes = await CloudGateway.shared.storageDownload('nusa-backups', path);
      if (bytes == null || bytes.isEmpty) return false;
      // v2.2.57+130: decrypt+unpack di background isolate; ambil sqlite saja.
      final files = await decryptAndUnpackInIsolate(bytes, uid);
      final decryptedSqlite = files['nusa_kasir.sqlite'];
      if (decryptedSqlite == null) return false;
      // ── v2.2.57+115 (Area J): tolak backup versi lebih baru ──
      final meta = await _readEmbeddedMetadata();
      final backupApp = meta?['appVersion']?.toString() ?? '';
      final installedBuild = await SecureStore.installedBuildNumber();
      final backupBuild = _parseBuildNumber(backupApp);
      if (backupBuild != null && backupBuild > installedBuild) {
        _lastBackupVersionError = backupApp;
        return false;
      }
      _lastBackupVersionError = null;
      // v2.2.42: jangan pernah stage backup yang isinya data varian LAIN.
      if (!await _backupBelongsToVariant(decryptedSqlite, uid)) return false;
      final dir = await getApplicationDocumentsDirectory();

      // v2.2.39: migrasi schema eksplisit sebelum di-stage — backup lama
      // (ver 26-30 dari varian lain) butuh kolom/tabel baru; kalau tidak,
      // drift tidak akan migrasi saat koneksi baru dibuka (user_version sudah
      // di-cache) → query produk error → loading abadi (lihat restoreDirect).
      final migrated = await _migrateSqliteBytes(decryptedSqlite, uid);

      final pending = File(p.join(dir.path, 'nusa_kasir.sqlite.pending'));
      await pending.writeAsBytes(migrated, flush: true);
      await SecureStore.savePendingRestore();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Jalankan migrasi drift schema terhadap bytes SQLite hasil decrypt.
  /// Menulis bytes ke file temp, buka dengan AppDatabase (memicu `onUpgrade`
  /// sampai schemaVersion 44), lalu baca hasilnya kembali. Fallback: kalau
  /// migrasi gagal (DB rusak), kembalikan bytes asli — restore tetap jalan,
  /// query produk yang butuh kolom baru tinggal error, tapi app tidak crash.
  Future<List<int>> _migrateSqliteBytes(
    List<int> bytes,
    String googleUserId,
  ) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final temp = File(p.join(dir.path, 'nusa_kasir.sqlite.migrate'));
      await temp.writeAsBytes(bytes, flush: true);
      // AppDatabase.at() membuka FILE TEMP (bukan live) → migrasi onUpgrade
      // dijalankan terhadap bytes hasil decrypt. AppDatabase() normal selalu
      // buka nusa_kasir.sqlite (live) — salah sasaran kalau dipakai di sini.
      final db = AppDatabase.at('nusa_kasir.sqlite.migrate');
      // Buka + tutup → drift menjalankan onUpgrade (from=user_version → 44).
      // Tutup file secara manual supaya koneksi benar-benar release.
      await db.customSelect('SELECT 1').get();
      await db.close();
      // Hapus sidecar hasil migrasi (temp saja, bukan live).
      for (final sidecar in ['-wal', '-shm', '-journal']) {
        final f = File(temp.path + sidecar);
        if (await f.exists()) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
      final migrated = await temp.readAsBytes();
      await temp.delete();
      return migrated;
    } catch (e) {
      debugPrint('[Restore] _migrateSqliteBytes fallback (keep original): $e');
      return bytes;
    }
  }

  /// Auto-sync: check if cloud backup is newer than local state.
  /// If so, download and replace the local database directly (no restart needed).
  /// Returns true if sync was performed.
  ///
  /// NOTE: no longer a direct overwrite — the DB is staged to a .pending file
  /// that main.dart applies BEFORE the next database open. Overwriting the
  /// live sqlite file while drift has it open corrupts the session (empty
  /// reads → login fails, menu buttons dead). Sync here = stage for next
  /// launch; the pending swap is atomic.
  Future<bool> syncIfNewer() async {
    try {
      await _ensureAnonAuth();
      final uid = await _googleUserId();
      if (uid == null) return false;

      // Check if cloud backup exists and get its timestamp.
      // Probe download dulu; kalau ada, pakai metadata.json untuk timestamp
      // (upload selalu menulis updated_at). Fallback: anggap backup ada &
      // lebih baru (yang penting data user ketemu, bukan dilewati karena
      // takut menimpa).
      final cp = '$uid/${NusaConfig.productId}/backup.sqlite.enc';
      final probe = await CloudGateway.shared.storageDownload('nusa-backups', cp);
      if (probe == null || probe.isEmpty) return false;
      final meta = await getBackupMetadata();
      final cloudTime = meta != null
          ? DateTime.tryParse(meta['updated_at']?.toString() ?? '') ??
              DateTime.tryParse(meta['backupTime']?.toString() ?? '')
          : null;

      // Compare with local last-sync timestamp
      final localTime = await SecureStore.getLastBackupTime();
      if (localTime != null && cloudTime != null && !cloudTime.isAfter(localTime)) {
        return false;
      }

      debugPrint('[Sync] Cloud backup newer ($cloudTime), downloading...');

      // Download & decrypt (v2.2.57+130: di background isolate)
      final bytes = probe;
      if (bytes.isEmpty) return false;

      final packedFiles = await decryptAndUnpackInIsolate(bytes, uid);
      final decryptedSqlite = packedFiles['nusa_kasir.sqlite'];
      if (decryptedSqlite == null) return false;
      // v2.2.42: jangan pernah sync backup yang isinya data varian LAIN —
      // kalau cloud tercemar, cukup adopsi timestamp-nya tanpa menimpa lokal.
      if (!await _backupBelongsToVariant(decryptedSqlite, uid)) {
        if (cloudTime != null) await SecureStore.setLastCloudSeen(cloudTime);
        return false;
      }
      final dir = await getApplicationDocumentsDirectory();

      // Write archive entries (DB + images). The DB goes to .pending (applied
      // at next launch); images are written directly — safe, they're not open
      // by any connection.
      var imageCount = 0;
      final rootCanonical = p.normalize(Directory(dir.path).absolute.path);
      for (final entry in packedFiles.entries) {
        if (entry.key == 'nusa_kasir.sqlite') {
          final pending = File(p.join(dir.path, 'nusa_kasir.sqlite.pending'));
          await pending.writeAsBytes(entry.value, flush: true);
          await SecureStore.savePendingRestore();
          continue;
        }
        final destination = File(p.join(dir.path, entry.key));
        final destinationCanonical = p.normalize(destination.absolute.path);
        if (destinationCanonical != rootCanonical &&
            !p.isWithin(rootCanonical, destinationCanonical)) {
          throw FormatException(
            'Restore path escapes application directory: ${entry.key}',
          );
        }
        await File(destinationCanonical).writeAsBytes(entry.value, flush: true);
        imageCount++;
      }

      // v2.2.38: cloudTime bisa null (tanpa metadata) — tetap stage DB.
      // Kalau null, skip simpan lastBackupTime supaya next launch coba lagi.
      if (cloudTime != null) {
        await SecureStore.saveLastBackupTime(cloudTime);
      }
      debugPrint(
        '[Sync] Staged DB${imageCount > 0 ? " + $imageCount images" : ""} from cloud (applied next launch)',
      );
      return true;
    } catch (e) {
      debugPrint('[Sync] syncIfNewer error: $e');
      return false;
    }
  }

  // ── Legacy methods (kept for backward compatibility with old activation-key based backups) ──

  /// Upload using old activation-key encryption. Used for migration.
  @Deprecated('Use uploadBackupNow() which encrypts with Google ID')
  Future<bool> uploadBackup(String activationKey) async {
    final uid = await _googleUserId();
    if (uid == null) return false;
    final path = '$uid/${NusaConfig.productId}/backup.sqlite.enc';
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, 'nusa_kasir.sqlite'));
      if (!await file.exists()) return false;
      final raw = await file.readAsBytes();
      // v2.2.57+130: gzip+encrypt di background isolate.
      final encrypted = await Isolate.run(
        () => BackupCrypto.encrypt(raw, activationKey),
      );
      await CloudGateway.shared.storageUpload(
        'nusa-backups',
        path,
        encrypted,
        contentType: 'application/octet-stream',
        upsert: true,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  @Deprecated('Use restoreFromCloud() which decrypts with Google ID')
  Future<bool> downloadAndRestore(String activationKey) async {
    await _ensureAnonAuth();
    final path = await _backupPath();
    if (path == null) return false;
    try {
      final bytes = await CloudGateway.shared.storageDownload('nusa-backups', path);
      if (bytes == null || bytes.isEmpty) return false;
      final decrypted = await decryptInIsolate(bytes, activationKey);
      final dir = await getApplicationDocumentsDirectory();
      final pending = File(p.join(dir.path, 'nusa_kasir.sqlite.pending'));
      await pending.writeAsBytes(decrypted, flush: true);
      await SecureStore.savePendingRestore();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> deactivate() async => SecureStore.clearActivation();
}
