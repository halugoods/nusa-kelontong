import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:ui';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nusa_kasir/core/cloud/cloud_gateway.dart';
import 'package:workmanager/workmanager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:nusa_kasir/app.dart';
import 'package:nusa_kasir/core/auth/employee_session.dart';
import 'package:nusa_kasir/core/config/nusa_config.dart';
import 'package:nusa_kasir/core/providers.dart';
import 'package:nusa_kasir/core/utils/secure_storage.dart';
import 'package:nusa_kasir/core/activation/activation_repository.dart';
import 'package:nusa_kasir/core/utils/receipt_printer.dart';
import 'package:nusa_kasir/core/services/notification_service.dart';
import 'package:nusa_kasir/core/services/stok_alert_worker.dart';
import 'package:nusa_kasir/core/services/ai_insight_worker.dart';
import 'package:nusa_kasir/core/services/backup_crypto.dart' show unpackInIsolate;
import 'package:nusa_kasir/core/services/update_service.dart';
import 'package:nusa_kasir/core/services/image_storage_service.dart';
import 'package:nusa_kasir/core/services/google_auth_service.dart';
import 'package:nusa_kasir/data/database/app_database.dart';
import 'package:nusa_kasir/data/repositories/settings_repository.dart';
import 'package:nusa_kasir/data/repositories/attendance_repository.dart';
import 'package:nusa_kasir/data/repositories/product_repository.dart';
import 'package:drift/drift.dart';

/// Ensure PIN length in the database is always 6 digits.
/// If the setting was changed to 4 (or corrupted), fix it.
/// If any employee PIN is not 6 digits, pad/truncate it.
Future<void> _repairPinLength() async {
  try {
    final db = AppDatabase();
    final settingsRepo = SettingsRepository(db);
    final pinLen = await settingsRepo.getPinLength();

    // Force setting back to 6
    if (pinLen != 6) {
      await settingsRepo.setPinLength(6);
    }

    // Fix any employee PINs that don't match 6 digits
    final attRepo = AttendanceRepository(db);
    final emps = await attRepo.getEmployees();
    for (final e in emps) {
      if (e.pin.length == 6) continue;
      String fixed;
      if (e.pin.length > 6) {
        fixed = e.pin.substring(0, 6);
      } else {
        fixed = e.pin.padRight(6, '0');
      }
      await (db.update(db.employees)..where((t) => t.id.equals(e.id))).write(
        EmployeesCompanion(pin: Value(fixed)),
      );
    }
    await db.close();
  } catch (_) {
    // Non-fatal — app continues even if repair fails
  }
}

/// Catch all unhandled Flutter errors and display them instead of blank screen.
void _setupErrorHandlers() {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    if (!details.silent) {
      final errorString =
          'FlutterError: ${details.exception}\n${details.stack?.toString().substring(0, 500) ?? ''}';
      debugPrint(errorString);
    }
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('PlatformDispatcher error: $error\n$stack');
    return true; // handled
  };
}

Future<void> _writeRestoreFile(
  String rootPath,
  String relativePath,
  List<int> bytes,
) async {
  final rootCanonical = p.normalize(Directory(rootPath).absolute.path);
  final destinationCanonical = p.normalize(
    File(p.join(rootPath, relativePath)).absolute.path,
  );
  if (destinationCanonical != rootCanonical &&
      !p.isWithin(rootCanonical, destinationCanonical)) {
    throw FormatException(
      'Restore path escapes application directory: $relativePath',
    );
  }
  await File(destinationCanonical).writeAsBytes(bytes, flush: true);
}

/// Swap a pending backup into place BEFORE the database opens.
///
/// Supports both legacy format (raw SQLite bytes) and new NUS1 archive format
/// (SQLite + product images packed together).
Future<void> _applyPendingRestore() async {
  if (!await SecureStore.hasPendingRestore()) return;
  try {
    final dir = await getApplicationDocumentsDirectory();
    final pending = File(p.join(dir.path, 'nusa_kasir.sqlite.pending'));
    if (!await pending.exists()) {
      await SecureStore.clearPendingRestore();
      return;
    }

    final bytes = await pending.readAsBytes();

    // Try NUS1 archive format first (new — includes images).
    // v2.2.57+130: unpack di background isolate (arsip bisa puluhan MB) —
    // jangan blok main thread saat startup.
    final files = await unpackInIsolate(bytes);

    // ── CRITICAL: clear stale SQLite sidecar files (-wal/-shm) first ──
    // If a previous session left a WAL/journal behind, SQLite would replay
    // it on top of the swapped-in database → mixed/empty tables → menu dead
    // + every PIN fails again. This is the same class of corruption as the
    // original restore bug, so clean all sidecars of the target file BEFORE
    // the swap. The database has NOT been opened yet at this point (we run
    // before AppDatabase() is constructed in main), so it's safe.
    final dbPath = p.join(dir.path, 'nusa_kasir.sqlite');
    for (final sidecar in ['$dbPath-wal', '$dbPath-shm', '$dbPath-journal']) {
      final f = File(sidecar);
      if (await f.exists()) {
        try {
          await f.delete();
          debugPrint('[Restore] Cleaned stale sidecar: ${p.basename(sidecar)}');
        } catch (_) {
          // Non-fatal: a locked sidecar just stays; SQLite handles it.
        }
      }
    }

    var imageCount = 0;
    for (final entry in files.entries) {
      await _writeRestoreFile(dir.path, entry.key, entry.value);
      if (entry.key != 'nusa_kasir.sqlite') imageCount++;
    }
    if (imageCount > 0) {
      debugPrint('[Restore] Extracted $imageCount product images');
    }

    await pending.delete();
    await SecureStore.clearPendingRestore();
  } catch (e) {
    // Keep the marker and pending file so the restore can be retried next launch.
    debugPrint('[Restore] _applyPendingRestore error (will retry): $e');
  }
}

/// Auto cloud sync — receive side. Runs at app launch (before the DB opens).
///
/// Rule: pull from cloud ONLY if the cloud backup is newer than what we last
/// saw AND we have no local changes that haven't been uploaded yet. This
/// never overwrites un-uploaded local work. Timeout 3s — offline starts fast.
Future<void> _receiveAtLaunch() async {
  try {
    if (await SecureStore.getActivation() == null) return;
    // v2.2.57+115 (Area I): canonical UID backup — prefer UID akun
    // email/password, lalu Google 21-digit. Sebelumnya hanya baca Google UID
    // → device email-only tidak pernah pull backup di launch.
    final uid = await SecureStore.resolveCanonicalUid();
    if (uid == null) return;

    final repo = ActivationRepository();
    final cloudTime = await repo.getBackupTimestamp().timeout(
      const Duration(seconds: 3),
      onTimeout: () => null,
    );
    if (cloudTime == null) return;

    final lastSeen = await SecureStore.getLastCloudSeen();
    final lastLocalChange = await SecureStore.getLastLocalChange();

    // ── v2.2.40: JANGAN restore diam-diam kalau device BELUM PERNAH sinkron
    // dengan cloud (lastSeen == null). Ini adalah fresh install / install di
    // atas data rusak. Restore DIAM-DIAM di sini akan menimpa DB lokal tanpa
    // dialog → user tidak pernah melihat "Data Ditemukan" dan kalau gagal,
    // data tidak keluar. Device yang belum pernah sinkron harus melewati
    // jalur user-facing (login Google → dialog Data Ditemukan) supaya user
    // TAHU data apa yang dipulihkan dan bisa memilih.
    if (lastSeen == null) return;

    // ── v2.2.40: JANGAN restore diam-diam kalau akun yang baru login BEDA
    // dari yang terakhir tersimpan (ganti akun). Restore akun baru harus lewat
    // dialog "Data Ditemukan" di activation screen (user harus TAHU + pilih),
    // bukan ditimpa diam-diam di sini.
    final prevLinked = await SecureStore.getLinkedAccountId();
    if (prevLinked != null && prevLinked != uid) return;

    // Cloud not newer than last seen → nothing to pull.
    if (!cloudTime.isAfter(lastSeen)) return;

    // Local un-uploaded changes → don't overwrite local; leave for upload.
    // lastSeen sudah non-null di sini (guard line 181).
    if (lastLocalChange != null && lastLocalChange.isAfter(lastSeen)) {
      return;
    }

    // ── PENTING: jangan pernah menimpa DB lokal yang sudah punya data ──
    // AutoSync di varian lain bisa menganggap backup kelontong (path
    // uid/nusa-kelontong) "lebih baru" dan men-download-nya ke varian ini.
    // Padahal path backup per-varian berbeda — yang bocor adalah saat UID
    // anon vs Google tidak konsisten, atau saat varian ini baru diinstall
    // dan lastSeen kosong → restore dari path sendiri yang KOSONG = DB
    // kosong (tidak ada owner/PIN) → "PIN salah" terus. Guard: kalau lokal
    // sudah punya karyawan, jangan sentuh DB dari cloud.
    try {
      final probe = AppDatabase();
      final empCount =
          await probe.select(probe.employees).get().then((r) => r.length);
      // v2.2.39: TUTUP koneksi probe SEBELUM restoreDirect — kalau tidak,
      // drift probe masih membuka file saat restore menulis live sqlite =
      // korupsi (login pertama setelah install selalu korup). Ini akar Bug A.
      await probe.close();
      if (empCount > 0) return;
    } catch (_) {
      // DB lokal tidak bisa dibaca (rusak) — data lokal sudah hilang, jadi
      // JANGAN bail: tetap restore dari cloud supaya data user pulih.
    }

    // No local pending changes → adopt cloud backup.
    // v2.2.37: pakai restoreDirect() (swap live) bukan restoreFromCloud()
    // (.pending). restoreFromCloud stage .pending yang baru di-swap saat start
    // BERIKUTNYA — tapi _applyPendingRestore() sudah lewat di urutan main, jadi
    // .pending tidak akan pernah di-swap → restore tidak berlaku → DB kosong →
    // PIN gagal + produk kosong. restoreDirect() menulis langsung ke sqlite
    // live (aman: drift belum dibuka di titik ini) → data langsung dipakai.
    //
    // v2.2.39: kalau ada .pending (dari AutoSyncService / settings manual),
    // _applyPendingRestore() di urutan main SUDAH swap DB-nya. Jangan
    // restoreDirect lagi di sini — itu menulis ulang live sqlite yang sudah
    // fresh, dan probe DB di atas sudah ditutup, jadi aman. Tapi kalau .pending
    // MASIH ada (baru dibuat oleh AutoSyncService saat app start), skip —
    // biar _applyPendingRestore() berikutnya yang swap (jangan dobel).
    if (await SecureStore.hasPendingRestore()) return;

    final ok = await repo.restoreDirect().timeout(
      const Duration(seconds: 15),
      onTimeout: () => false,
    );
    if (ok) {
      await SecureStore.setLastCloudSeen(cloudTime);
      debugPrint('[AutoSync] Received cloud backup ($cloudTime)');
    }
  } catch (e) {
    debugPrint('[AutoSync] receive-at-launch skip: $e');
  }
}

/// Sync images between local cache and Supabase Storage.
/// Runs once on startup — first-time migration uploads local images,
/// then downloads any cloud images missing from local cache.
void _syncImagesFromCloud() {
  Future.microtask(() async {
    try {
      // v2.2.38: pakai Google UID (bukan Supabase anon session UID).
      // Path images di bucket nusa-images memakai UID ({uid}/
      // {productId}/...). UID anon (UUID) beda → upload/download gambar
      // nyasar ke path kosong → foto produk hilang setelah reinstall.
      // v2.2.57+115 (Area I): canonical UID — SAMA dengan path backup supaya
      // restore foto tidak pecah antara akun email/password vs Google.
      final uid = await SecureStore.resolveCanonicalUid();
      if (uid == null) return;

      final svc = ImageStorageService(uid);

      // First-time: upload existing local images to cloud
      final migrated = await SecureStore.getImagesMigrated();
      if (!migrated) {
        final uploaded = await svc.uploadAllLocal();
        await SecureStore.setImagesMigrated(true);
        if (uploaded > 0) {
          debugPrint('[Sync] First-time migration: uploaded $uploaded images');
        }
      }

      // Download any cloud images we don't have locally
      final downloaded = await svc.syncAll();
      if (downloaded > 0) {
        debugPrint('[Sync] Downloaded $downloaded images from cloud');
      }
    } catch (e) {
      debugPrint('[Sync] Image sync error: $e');
    }
  });
}

/// B1 (v2.2.45): pulihkan file foto dari BASE64 yang tersimpan di kolom DB
/// (products.image_base64 + employees.photo_base64). Setelah restore cloud di
/// device baru, path file lokal hasil backup LAMA tidak ada — sini menulis
/// ulang ke disk lalu perbarui path di DB supaya UI langsung tampil.
Future<void> _hydrateImagesFromDb() async {
  try {
    final db = AppDatabase();
    final products = ProductRepository(db);
    final employees = AttendanceRepository(db);
    final p = await products.hydrateImages();
    final e = await employees.hydratePhotos();
    // v2.2.57+130 (A1.3): kompaksi BASE64 sekali per launch. Setelah hydrate
    // (foto base64 sudah ditulis ke disk), nolkan kolom image_base64 /
    // photo_base64 yang file fisiknya ADA — DB mengecil drastis (DB user
    // besar: 17 MB → ~0.3 MB) → arsip backup ringan, tidak OOM, tidak bom
    // egress. Idempoten & murah: hanya scan kolom, tanpa tulis kalau sudah
    // bersih. Kompaksi berjalan PALING BERAT di isolate via SQL UPDATE…
    // tidak perlu — drift utk SQLite jalan di background zone secara default.
    var compacted = 0;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final prods = await db.select(db.products).get();
      for (final pr in prods) {
        final b64 = pr.imageBase64;
        if (b64 == null || b64.isEmpty) continue;
        final path = pr.imagePath;
        final ok = path != null &&
            path.isNotEmpty &&
            await File(path).exists();
        if (!ok) continue; // file belum ada → biarkan hydrate device lain
        await (db.update(db.products)..where((t) => t.id.equals(pr.id)))
            .write(const ProductsCompanion(imageBase64: Value(null)));
        compacted++;
      }
      final emps = await db.select(db.employees).get();
      for (final em in emps) {
        final b64 = em.photoBase64;
        if (b64 == null || b64.isEmpty) continue;
        final path = em.photoPath;
        final ok = path != null &&
            path.isNotEmpty &&
            await File(path).exists();
        if (!ok) continue;
        await (db.update(db.employees)..where((t) => t.id.equals(em.id)))
            .write(const EmployeesCompanion(photoBase64: Value(null)));
        compacted++;
      }
      // VACUUM hanya sekali per launch & hanya bila ada yang dibersihkan —
      // reclaim ruang file DB sungguhan (tanpa ini file tetap gemuk).
      if (compacted > 0) {
        await db.customStatement('VACUUM');
        try {
          final f = File('${dir.path}/nusa_kasir.sqlite');
          if (await f.exists()) {
            debugPrint('[Compact] base64 cleared=$compacted, '
                'db=${(await f.length()) ~/ 1024} KB');
          }
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[Compact] skip: $e');
    }
    await db.close();
    if (p > 0 || e > 0 || compacted > 0) {
      debugPrint('[Hydrate] Restored product images=$p, employee photos=$e, '
          'compacted=$compacted');
    }
  } catch (err) {
    debugPrint('[Hydrate] error: $err');
  }
}

/// v2.2.57+130 (A1.2): relink foto produk & karyawan dari bucket setelah
/// restore. Arsip backup baru (+130) TIDAK mengemas file gambar — DB-only.
/// Di device baru / setelah clear data, `imagePath`/`photoPath` di DB menunjuk
/// v2.2.57+130 (FIX): upload semua base64 di DB ke R2. Mencegah data loss
/// saat user uninstall — tanpa ini gambar hilang permanen karena base64
/// di-clear saat kompaksi dan R2 kosong.
Future<void> _uploadBase64ImagesToR2() async {
  try {
    final uid = await SecureStore.resolveCanonicalUid();
    if (uid == null) return;
    final db = AppDatabase();
    var uploaded = 0;

    // Produk
    final prods = await db.select(db.products).get();
    for (final pr in prods) {
      final b64 = pr.imageBase64;
      if (b64 == null || b64.isEmpty) continue;
      final path = pr.imagePath;
      if (path == null || path.isEmpty) continue;
      final filename = p.basename(path);
      if (!filename.startsWith('product_')) continue;
      try {
        final bytes = base64Decode(b64);
        final remotePath = '$uid/${NusaConfig.productId}/products/$filename';
        final ok = await CloudGateway.shared.storageUpload(
          'nusa-images', remotePath, bytes,
          contentType: 'image/jpeg', upsert: true,
        );
        if (ok) uploaded++;
      } catch (_) {}
    }

    // Karyawan
    final emps = await db.select(db.employees).get();
    for (final em in emps) {
      final b64 = em.photoBase64;
      if (b64 == null || b64.isEmpty) continue;
      final path = em.photoPath;
      if (path == null || path.isEmpty) continue;
      final filename = p.basename(path);
      if (!filename.startsWith('photo_')) continue;
      try {
        final bytes = base64Decode(b64);
        final remotePath = '$uid/${NusaConfig.productId}/employees/$filename';
        final ok = await CloudGateway.shared.storageUpload(
          'nusa-images', remotePath, bytes,
          contentType: 'image/jpeg', upsert: true,
        );
        if (ok) uploaded++;
      } catch (_) {}
    }

    if (uploaded > 0) debugPrint('[ImageSync] uploaded $uploaded images to R2');
  } catch (_) {}
}

/// file lokal yang tidak ada, dan base64 sudah kosong (kompaksi A1.3) → tanpa
/// fungsi ini foto hilang. Sini tarik gambar dari `nusa-images/{uid}/
/// {productId}/{products|employees}/{basename}` dengan NAMA FILE ASLI (bucket
/// selalu diisi nama asli; prefix `{productId}_` hanya penamaan cache lokal
/// lama) lalu tulis ke documents dir + perbarui path di DB. Idempoten: yang
/// filenya sudah ada di-skip.
Future<void> _relinkImagesFromCloud() async {
  try {
    final uid = await SecureStore.resolveCanonicalUid();
    if (uid == null) return;

    final svc = ImageStorageService(uid);
    final db = AppDatabase();
    var relinkedProducts = 0;
    var relinkedEmployees = 0;
    try {
      // ── Produk ──
      final rows = await db.select(db.products).get();
      for (final pr in rows) {
        final path = pr.imagePath;
        final hasFile = path != null &&
            path.isNotEmpty &&
            await File(path).exists();
        if (hasFile) continue;
        final b64 = pr.imageBase64;
        if (b64 != null && b64.isNotEmpty) continue; // hydrate yang urus
        final name = p.basename(path ?? '');
        if (name.isEmpty || !name.startsWith('product_')) continue;
        final restored = await svc.downloadOriginal('products', name);
        if (restored == null) continue;
        await (db.update(db.products)..where((t) => t.id.equals(pr.id)))
            .write(ProductsCompanion(imagePath: Value(restored)));
        relinkedProducts++;
      }

      // ── Karyawan ──
      final emps = await db.select(db.employees).get();
      for (final em in emps) {
        final path = em.photoPath;
        final hasFile = path != null &&
            path.isNotEmpty &&
            await File(path).exists();
        if (hasFile) continue;
        final b64 = em.photoBase64;
        if (b64 != null && b64.isNotEmpty) continue; // hydrate yang urus
        final name = p.basename(path ?? '');
        if (name.isEmpty || !name.startsWith('photo_')) continue;
        final restored = await svc.downloadOriginal('employees', name);
        if (restored == null) continue;
        await (db.update(db.employees)..where((t) => t.id.equals(em.id)))
            .write(EmployeesCompanion(photoPath: Value(restored)));
        relinkedEmployees++;
      }
    } finally {
      await db.close();
    }
    if (relinkedProducts > 0 || relinkedEmployees > 0) {
      debugPrint('[Relink] Restored from bucket: '
          'products=$relinkedProducts, employees=$relinkedEmployees');
    }
  } catch (e) {
    debugPrint('[Relink] error: $e');
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _setupErrorHandlers();
  // v2.2.57+130 (A1.6): seed NusaConfig.appBuildNumber dari PackageInfo
  // SEBELUM UI mana pun membaca konstanta. Dulu const int — label "Terpasang"
  // dan force-update salah banding (konstanta sudah di-bump saat prep rilis
  // tapi APK terpasang masih build lama).
  try {
    await SecureStore.loadInstalledVersion();
    NusaConfig.seedBuildNumber(await SecureStore.installedBuildNumber());
  } catch (_) {}
  // DateFormat('...', 'id') dipakai di beberapa layar (mis. Tanggal Mulai
  // Kerja karyawan). Tanpa init ini, format locale id melempar dan layar
  // bisa blank — init sekali di awal (v2.2.35 fix blank tambah karyawan).
  try {
    await initializeDateFormatting('id');
  } catch (_) {}

  // Default fallback values in case any init step throws.
  // runApp() MUST be called — a white screen is worse than missing features.
  String persistedTheme = 'system';
  String initialLocation = '/activation';

  try {
    // Workmanager
    try {
      await Workmanager().initialize(
        stokCallbackDispatcher,
        isInDebugMode: false,
      );
    } catch (_) {}

    // Local notifications
    try {
      await NotificationService.init();
    } catch (_) {}

    // ── Cloud gateway init ─────────────────────────────────────────────
    // Muat JWT tersimpan / buat sesi anon (legacy uid) untuk REST + storage
    // + realtime. Tidak throw — app tetap jalan offline (fail-open).
    try {
      await CloudGateway.shared.init();
    } catch (_) {}

    // ── CRITICAL: apply pending device-migration backup FIRST ──
    // Kalau user baru selesai restore "Data Ditemukan" (restoreDirect →
    // .pending), swap DB-nya dulu sebelum auto-sync menyentuh apa pun.
    // Urutan lama (receiveAtLaunch dulu) membuat probe DB lama membuka
    // koneksi + menyisakan WAL, lalu restoreFromCloud menimpa .pending yang
    // sama → DB hasil restore korup → PIN tidak terbaca setelah restart.
    try {
      await _applyPendingRestore();
    } catch (_) {}

    // Auto-repair PIN length — SETELAH pending restore di-swap, supaya repair
    // membaca DB hasil restore (bukan DB lama yang masih kosong/parsial).
    // Sebelumnya repair jalan PALING AWAL → membuka koneksi ke DB lama +
    // menulis perubahan → bisa bentrok dengan swap .pending di atas.
    try {
      await _repairPinLength();
    } catch (_) {}

    // Auto cloud sync — receive-at-launch: pull the newest cloud backup
    // only when no pending restore exists (jangan timpa restore yang sudah
    // dijadwalkan) AND we have no un-uploaded local changes.
    try {
      if (!await SecureStore.hasPendingRestore()) {
        await _receiveAtLaunch();
      }
    } catch (_) {}

    // B1 (v2.2.45): hydrate foto produk + karyawan dari BASE64 (kolom DB)
    // ke disk. Setelah restore cloud di device baru, imagePath/photoPath
    // menunjuk ke file yang tidak ada — di sini ditulis ulang supaya SEMUA
    // UI langsung tampil. Idempoten: hanya yang file-nya hilang diproses.
    try {
      await _hydrateImagesFromDb();
    } catch (_) {}

    // v2.2.57+130 (FIX): upload base64 ke R2. Selama ini gambar TIDAK PERNAH
    // di-upload ke cloud — cuma base64 di DB. Kalau user uninstall, gambar
    // hilang permanen. Loop ini scan semua base64 dan upload ke R2 supaya
    // nanti bisa di-relink setelah restore.
    try {
      await _uploadBase64ImagesToR2();
    } catch (_) {}

    // v2.2.57+130 (A1.2): relink foto produk dari bucket nusa-images untuk
    // produk yang base64-nya sudah kosong (kompaksi) dan filenya tidak ada —
    // jalur pemulihan baru karena arsip backup tidak lagi mengemas gambar.
    try {
      await _relinkImagesFromCloud();
    } catch (_) {}

    // Register background tasks
    try {
      registerStokCheck();
    } catch (_) {}
    try {
      registerOnlineCheck();
    } catch (_) {}
    try {
      registerAiInsightCheck();
    } catch (_) {}

    // Load persisted theme mode and color preset before app starts.
    final db = AppDatabase();
    try {
      persistedTheme = await SettingsRepository(db).getThemeMode() ?? 'system';
    } catch (_) {}
    try {
      final preset = await SecureStore.getThemePreset();
      if (preset != null && NusaConfig.themePresets.containsKey(preset)) {
        NusaConfig.applyTheme(preset);
      }
    } catch (_) {}
    // Restore cash drawer auto-open flag so the setting survives app restarts
    // (ReceiptPrinter._cashDrawerEnabled is static and otherwise only set when
    // the printer settings sheet is opened).
    try {
      final drawer = await SecureStore.getCashDrawerEnabled();
      ReceiptPrinter.setCashDrawer(enabled: drawer);
    } catch (_) {}

    // Hapus APK update sisa (auto-cleanup) — user gaptek lupa menghapus,
    // memori penyimpanan penuh. File tidak bisa dihapus saat installer masih
    // memakainya, jadi dibersihkan saat app start berikutnya.
    try {
      await UpdateService.cleanupApk();
    } catch (_) {}

    // Determine initial route.
    try {
      final activated = (await SecureStore.getActivation()) != null;
      if (!activated) {
        // Dev mode: show variant picker first, then activation
        // Production: go directly to activation with build-time config
        initialLocation = NusaConfig.isDevBuild
            ? '/variant-picker'
            : '/activation';
      } else {
        final session = await EmployeeSession.restore();
        if (session != null && !session.isExpired) {
          initialLocation = '/home';
        } else {
          // Already activated. Jika DB belum punya owner/karyawan sama sekali
          // (mis. backup varian lain menimpa, atau setup gagal), langsung ke
          // /setup supaya user bisa buat Owner + PIN — bukan terjebak di pinpad.
          String? anyEmployee;
          try {
            final probe = AppDatabase();
            final rows = await probe.select(probe.employees).get();
            await probe.close();
            anyEmployee = rows.isEmpty ? null : 'x';
          } catch (_) {
            anyEmployee = null;
          }
          if (anyEmployee == null) {
            // ── v2.2.40: DB kosong ATAU rusak → jangan langsung /setup.
            // Kalau akun Google ini punya backup cloud, dialog "Data
            // Ditemukan" harus MUNCUL dulu (lewat login Google di layar
            // activation). /setup hanya jadi pilihan terakhir kalau memang
            // TIDAK ADA backup. Dengan /activation, user bisa ganti akun dan
            // backup akun lain ikut terdeteksi.
            initialLocation = '/activation';
          } else {
            initialLocation = '/login';
          }
        }
      }
    } catch (_) {
      initialLocation = '/activation';
    }

    // ── v2.2.54: STARTUP LICENSE GATE ────────────────────────────────────
    // Device yang sudah aktivasi tetap dicek ke cloud SETIAP buka app.
    // Lisensi yang di-revoke admin (Cancelled/Expired) → paksa
    // lewat layar aktivasi (blokir) meski key lokal masih valid. Ini menutup
    // celah: dulu activated device langsung masuk tanpa cek status terbaru.
    // Fail-open: offline / lambat (>4s) → jangan blokir user yang sah.
    if (initialLocation == '/home' || initialLocation == '/login') {
      try {
        final uid = await GoogleAuthService.getStoredUserId();
        if (uid != null && uid.isNotEmpty) {
          final res = await CloudGateway.shared
              .invoke(
                'register_activation',
                body: {
                  'googleUserId': uid,
                  'product': NusaConfig.productId,
                },
              )
              .timeout(const Duration(seconds: 4));
          final data = res.data as Map<String, dynamic>?;
          final status = data?['status'] as String?;
          final blocked = data != null &&
              data['has_license'] == false &&
              (data['is_expired'] == true ||
                  status == 'Cancelled' ||
                  status == 'Expired');
          if (blocked) initialLocation = '/activation';
        }
      } catch (_) {
        // Offline / timeout / error → fail-open, biarkan masuk app.
      }
    }

    // Background: sync images from cloud (first-time migration + download)
    _syncImagesFromCloud();

    try {
      await db.close();
    } catch (_) {}
  } catch (e) {
    debugPrint('[Main] Startup error: $e');
    // Fall through — runApp() always executes
  }

  runApp(
    ProviderScope(
      overrides: [
        themeModeProvider.overrideWith((ref) => persistedTheme),
        themePresetProvider.overrideWith((ref) {
          final preset = NusaConfig.themePresets.keys.firstWhere(
            (id) =>
                NusaConfig.activePrimary ==
                NusaConfig.themePresets[id]!['primary'],
            orElse: () => NusaConfig.productId.replaceFirst('nusa-', ''),
          );
          return preset;
        }),
      ],
      child: NusaApp(initialLocation: initialLocation),
    ),
  );
}
