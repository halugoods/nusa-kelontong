import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:nusa_kasir/core/constants/app_constants.dart';
import 'package:nusa_kasir/core/config/nusa_config.dart';
import 'package:nusa_kasir/core/label/label_renderer.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// DO NOT wipe the entire keystore on PlatformException.
/// A single key failure (e.g. after OS update) should NOT delete
/// unrelated keys like activation, Google ID, or employee session.
/// Instead, just return null for reads and retry writes on the specific key.
class SecureStore {
  const SecureStore._();
  static const _s = FlutterSecureStorage();

  // -- Generic key-value wrappers (catch PlatformException) --

  static Future<void> write({
    required String key,
    required String value,
  }) async {
    try {
      await _s.write(key: key, value: value);
    } on PlatformException {
      // Retry once after clearing just this key (corner case: key corruption)
      try {
        await _s.delete(key: key);
        await _s.write(key: key, value: value);
      } catch (_) {}
    }
  }

  static Future<String?> read({required String key}) async {
    try {
      return await _s.read(key: key);
    } on PlatformException {
      // Never wipe — just return null. Activation/auth state is sacred.
      return null;
    }
  }

  static Future<void> delete({required String key}) async {
    try {
      await _s.delete(key: key);
    } on PlatformException {
      // Already gone or inaccessible — don't cascade
    }
  }

  // -- Installed version (v2.2.57+115) ---------------------------------
  // Build APK ASLI dari PackageInfo (bukan konstanta compile-time).
  // Tanpa ini "Terpasang" salah tandai release yang belum diinstall:
  // konstanta sudah di-bump ke build berikutnya sebelum user meng-update.
  static int? _installedBuild;
  static String? _installedVersion;

  static Future<void> loadInstalledVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _installedVersion = info.version;
      _installedBuild = int.tryParse(info.buildNumber);
    } catch (_) {
      // Platform tidak mendukung / plugin gagal → fallback konstanta.
      _installedBuild = null;
    }
  }

  /// Build number APK yang TERPASANG (dari PackageInfo), fallback ke
  /// konstanta compile-time kalau plugin gagal di platform tertentu.
  static Future<int> installedBuildNumber() async {
    if (_installedBuild != null) return _installedBuild!;
    await loadInstalledVersion();
    return _installedBuild ?? NusaConfig.appBuildNumber;
  }

  /// Versi (mis. "2.2.57") dari PackageInfo, fallback konstanta.
  static Future<String> installedVersion() async {
    if (_installedVersion != null) return _installedVersion!;
    await loadInstalledVersion();
    return _installedVersion ?? NusaConfig.appVersion;
  }

  /// Gabungan "v2.2.57+115" dari PackageInfo (untuk label "Saat ini").
  static Future<String> installedVersionAndBuild() async {
    final v = await installedVersion();
    final b = await installedBuildNumber();
    return 'v$v+$b';
  }

  // -- Canonical backup identity (v2.2.57+115, Area I) -----------------
  // Identitas backup dipakai sebagai path + kunci enkripsi cloud
  // (lihat ActivationRepository._googleUserId). Ada 2 jalur login:
  //   - Google OAuth → `nusa_google_user_id` (angka 21 digit)
  //   - email/password → `nusa_account_uid` (UUID auth.users)
  // Kalau keduanya ada (user pernah login dua metode di perangkat sama),
  // backup terpecah ke dua path → autosync tampak "tidak sinkron".
  // Solusi: satu canonical UID = identitas yang PALING BARU dipakai.
  // TANPA migrasi/dedupe path otomatis (berisiko) — cukup konsistenkan
  // pilihan untuk jalur upload/download berikutnya.

  /// Pilih satu identitas backup yang konsisten:
  /// prefer account UUID (email/password — jalur login terbaru), lalu
  /// Google 21-digit. Hanya bila keduanya tidak ada → null.
  ///
  /// Lite mode (v2.2.57+130): kalau tidak ada akun Google/email-password
  /// (Lite tidak butuh login), fallback ke `nusa_lite_email` (email yg
  /// diinput saat aktivasi Lite). Email lowecased → deterministic, cocok
  /// sebagai identitas enkripsi backup (SHA-256(uid) → AES key).
  static Future<String?> resolveCanonicalUid() async {
    final account = await SecureStore.read(key: 'nusa_account_uid');
    if (account != null && account.isNotEmpty) return account;
    final google = await SecureStore.read(key: 'nusa_google_user_id');
    if (google != null && google.isNotEmpty) return google;
    // Lite mode: pakai email sebagai UID
    if (NusaConfig.isLite) {
      final lite = await SecureStore.read(key: 'nusa_lite_email');
      if (lite != null && lite.isNotEmpty) return lite;
    }
    return null;
  }

  /// Lite mode: simpan email aktivasi (untuk backup identity Lite).
  static Future<void> saveLiteEmail(String email) =>
      SecureStore.write(key: 'nusa_lite_email', value: email.toLowerCase());
  static Future<String?> getLiteEmail() async =>
      SecureStore.read(key: 'nusa_lite_email');

  // -- Activation (namespaced per product to prevent cross-variant license leaks) --
  static String get _activationKey => 'nusa_activation_${NusaConfig.productId}';
  static const String _legacyActivationKey = 'nusa_activation';

  static Future<void> saveActivation(String key) =>
      SecureStore.write(key: _activationKey, value: key);
  static Future<String?> getActivation() async {
    // Check namespaced key first
    final v = await SecureStore.read(key: _activationKey);
    if (v != null) return v;
    // Fall back to legacy un-namespaced key, then migrate
    final legacy = await SecureStore.read(key: _legacyActivationKey);
    if (legacy != null) {
      await SecureStore.write(key: _activationKey, value: legacy);
      await SecureStore.delete(key: _legacyActivationKey);
      return legacy;
    }
    // Migration: nusa-servicehp → nusa-servis (variant rename v1.6.9)
    if (NusaConfig.productId == 'nusa-servis') {
      final oldKey = await SecureStore.read(
        key: 'nusa_activation_nusa-servicehp',
      );
      if (oldKey != null) {
        await SecureStore.write(key: _activationKey, value: oldKey);
        await SecureStore.delete(key: 'nusa_activation_nusa-servicehp');
        return oldKey;
      }
    }
    return null;
  }

  static Future<void> clearActivation() async {
    await SecureStore.delete(key: _activationKey);
    await SecureStore.delete(key: _legacyActivationKey);
  }

  // -- License metadata (expires_at / tier / status) for dashboard banner + settings UI --
  // Namespaced per product. Dipisah dari key aktivasi supaya UI bisa menampilkan
  // status nyata (v2.2.44 L3/L5) tanpa perlu decrypt key.
  static String get _licenseInfoKey =>
      'nusa_license_info_${NusaConfig.productId}';

  static Future<void> saveLicenseInfo({
    required DateTime? expiresAt,
    required String tier,
    required String status,
  }) async {
    final json =
        '${expiresAt?.toIso8601String() ?? ''}|$tier|$status';
    await SecureStore.write(key: _licenseInfoKey, value: json);
  }

  static Future<({DateTime? expiresAt, String tier, String status})?>
      getLicenseInfo() async {
    final raw = await SecureStore.read(key: _licenseInfoKey);
    if (raw == null || raw.isEmpty) return null;
    final parts = raw.split('|');
    final expiresAt =
        parts.isNotEmpty && parts[0].isNotEmpty ? DateTime.tryParse(parts[0]) : null;
    return (
      expiresAt: expiresAt,
      tier: parts.length > 1 ? parts[1] : 'lifetime',
      status: parts.length > 2 ? parts[2] : 'Active',
    );
  }

  static Future<void> clearLicenseInfo() async {
    await SecureStore.delete(key: _licenseInfoKey);
  }

  // -- Pending DB restore (device migration) --
  static Future<void> savePendingRestore() =>
      SecureStore.write(key: 'nusa_pending_restore', value: '1');
  static Future<bool> hasPendingRestore() async =>
      (await SecureStore.read(key: 'nusa_pending_restore')) == '1';
  static Future<void> clearPendingRestore() =>
      SecureStore.delete(key: 'nusa_pending_restore');

  /// How many times has the current pending restore been attempted?
  /// Reset to 0 when a new pending file is staged.
  static Future<int> pendingRestoreAttempts() async {
    final v = await SecureStore.read(key: 'nusa_pending_restore_attempts');
    return int.tryParse(v ?? '0') ?? 0;
  }

  static Future<void> incrementPendingRestoreAttempts() async {
    final current = await pendingRestoreAttempts();
    await SecureStore.write(
      key: 'nusa_pending_restore_attempts',
      value: '${current + 1}',
    );
  }

  static Future<void> clearPendingRestoreAttempts() =>
      SecureStore.delete(key: 'nusa_pending_restore_attempts');

  // -- Cloud backup timestamp (for conflict resolution, namespaced per product) --
  static String get _backupTimeKey =>
      'nusa_last_backup_at_${NusaConfig.productId}';
  static Future<void> saveLastBackupTime(DateTime t) =>
      SecureStore.write(key: _backupTimeKey, value: t.toIso8601String());
  static Future<DateTime?> getLastBackupTime() async {
    final v = await SecureStore.read(key: _backupTimeKey);
    return v != null ? DateTime.tryParse(v) : null;
  }

  static Future<void> clearLastBackupTime() =>
      SecureStore.delete(key: _backupTimeKey);

  // -- Akun Google yang TERAKHIR login di perangkat ini (untuk deteksi
  //    ganti akun / fresh install di atas data lama). Kalau akun yang baru
  //    login berbeda dari yang tersimpan → data lokal belum tentu milik akun
  //    itu → dialog "Data Ditemukan" harus muncul SEBELUM PIN pad.
  static const String _linkedAccountKey = 'nusa_linked_account_id';
  static Future<String?> getLinkedAccountId() =>
      SecureStore.read(key: _linkedAccountKey);
  static Future<void> setLinkedAccountId(String uid) =>
      SecureStore.write(key: _linkedAccountKey, value: uid);
  static Future<void> clearLinkedAccountId() =>
      SecureStore.delete(key: _linkedAccountKey);

  // -- Sheets tokens --
  static Future<void> saveSheetsTokens(String json) =>
      SecureStore.write(key: AppConstants.sheetsTokenKey, value: json);
  static Future<String?> getSheetsTokens() =>
      SecureStore.read(key: AppConstants.sheetsTokenKey);
  static Future<void> clearSheetsTokens() =>
      SecureStore.delete(key: AppConstants.sheetsTokenKey);

  // -- Sheets email + spreadsheet ID per user --
  static Future<void> saveSheetsEmail(String email) =>
      SecureStore.write(key: 'nusa_sheets_email', value: email);
  static Future<String?> getSheetsEmail() =>
      SecureStore.read(key: 'nusa_sheets_email');
  static Future<void> clearSheetsEmail() =>
      SecureStore.delete(key: 'nusa_sheets_email');

  static Future<void> saveSheetsId(String id) =>
      SecureStore.write(key: 'nusa_sheets_id', value: id);
  static Future<String?> getSheetsId() =>
      SecureStore.read(key: 'nusa_sheets_id');
  static Future<void> clearSheetsId() =>
      SecureStore.delete(key: 'nusa_sheets_id');

  // -- Feature toggles (JSON, namespaced per product) --
  static String get _featureToggleKey =>
      'nusa_feature_toggles_${NusaConfig.productId}';
  static Future<void> saveFeatureToggles(String json) =>
      SecureStore.write(key: _featureToggleKey, value: json);
  static Future<String?> getFeatureToggles() =>
      SecureStore.read(key: _featureToggleKey);
  static Future<void> clearFeatureToggles() =>
      SecureStore.delete(key: _featureToggleKey);

  // -- Menu order (JSON array, namespaced per product) --
  static String get _menuOrderKey => 'nusa_menu_order_${NusaConfig.productId}';
  static Future<void> saveMenuOrder(String json) =>
      SecureStore.write(key: _menuOrderKey, value: json);
  static Future<String?> getMenuOrder() => SecureStore.read(key: _menuOrderKey);
  static Future<void> clearMenuOrder() =>
      SecureStore.delete(key: _menuOrderKey);

  // -- Theme preset (theme ID string, namespaced per product) --
  static String get _themePresetKey =>
      'nusa_theme_preset_${NusaConfig.productId}';
  static Future<void> saveThemePreset(String themeId) =>
      SecureStore.write(key: _themePresetKey, value: themeId);
  static Future<String?> getThemePreset() =>
      SecureStore.read(key: _themePresetKey);
  static Future<void> clearThemePreset() =>
      SecureStore.delete(key: _themePresetKey);

  // -- Printer settings --
  static Future<void> setAutoPrint(bool v) =>
      SecureStore.write(key: 'nusa_printer_auto_print', value: v.toString());
  static Future<bool> getAutoPrint() async =>
      (await SecureStore.read(key: 'nusa_printer_auto_print')) == 'true';
  static Future<void> setPaperSize(String v) =>
      SecureStore.write(key: 'nusa_printer_paper_size', value: v);
  static Future<String> getPaperSize() async =>
      (await SecureStore.read(key: 'nusa_printer_paper_size')) ?? '58';

  /// Selected printer address ("Name|MAC") — single source of truth for both
  /// the settings sheet and auto-print, so a printer picked on one device
  /// isn't lost when the receipt sheet runs on another screen/device.
  static const _printerAddressKey = 'nusa_printer_address';
  static Future<void> setPrinterAddress(String v) =>
      SecureStore.write(key: _printerAddressKey, value: v);
  static Future<String?> getPrinterAddress() =>
      SecureStore.read(key: _printerAddressKey);

  /// Label printer address ("Name|MAC") — TERPISAH dari printer struk.
  /// Dipakai fitur Cetak Label (Area B): jalur TSPL pakai printer label
  /// khusus (Rongta/HPRT/Godex/BluePrint), bukan printer struk.
  static const _labelPrinterAddressKey = 'nusa_label_printer_address';
  static Future<void> setLabelPrinterAddress(String v) =>
      SecureStore.write(key: _labelPrinterAddressKey, value: v);
  static Future<String?> getLabelPrinterAddress() =>
      SecureStore.read(key: _labelPrinterAddressKey);

  // -- Ukuran font label barcode (Area B, v2.2.57+116) --
  // Konfigurasi user untuk nama produk & harga di cetak label — berlaku ke
  // SEMUA jalur (TSPL / struk thermal / PDF A4) supaya preview = hasil cetak.
  // Tersimpan sebagai skala 1.0–3.0 (bitmap font 5×7 diskalakan; PDF pakai
  // fontSize = 7.5×skala). Default 1.0 = ukuran lama.
  static const _labelNameFontKey = 'nusa_label_name_font';
  static Future<void> setLabelNameFontScale(double v) =>
      SecureStore.write(key: _labelNameFontKey, value: v.toString());
  static Future<double> getLabelNameFontScale() async =>
      double.tryParse(
        await SecureStore.read(key: _labelNameFontKey) ?? '',
      ) ??
      1.0;
  static const _labelPriceFontKey = 'nusa_label_price_font';
  static Future<void> setLabelPriceFontScale(double v) =>
      SecureStore.write(key: _labelPriceFontKey, value: v.toString());
  static Future<double> getLabelPriceFontScale() async =>
      double.tryParse(
        await SecureStore.read(key: _labelPriceFontKey) ?? '',
      ) ??
      1.0;

  // -- Ukuran label fisik mm (Area B, v2.2.57+121) --
  // Width × height kertas label printer (default 40×30mm). Dipakai jalur
  // TSPL (SIZE) & PDF (grid); struk thermal selalu selebar kertas struk.
  static const _labelWidthMmKey = 'nusa_label_width_mm';
  static Future<void> setLabelWidthMm(double v) =>
      SecureStore.write(key: _labelWidthMmKey, value: v.toString());
  static Future<double> getLabelWidthMm() async =>
      double.tryParse(
        await SecureStore.read(key: _labelWidthMmKey) ?? '',
      ) ??
      LabelRenderer.defaultWidthMm;
  static const _labelHeightMmKey = 'nusa_label_height_mm';
  static Future<void> setLabelHeightMm(double v) =>
      SecureStore.write(key: _labelHeightMmKey, value: v.toString());
  static Future<double> getLabelHeightMm() async =>
      double.tryParse(
        await SecureStore.read(key: _labelHeightMmKey) ?? '',
      ) ??
      LabelRenderer.defaultHeightMm;

  // -- Cash drawer --
  static Future<void> setCashDrawerEnabled(bool v) =>
      SecureStore.write(key: 'nusa_cash_drawer_enabled', value: v.toString());
  static Future<bool> getCashDrawerEnabled() async =>
      (await SecureStore.read(key: 'nusa_cash_drawer_enabled')) == 'true';

  // -- Printer footer --
  static Future<void> setPrinterFooter(String v) =>
      SecureStore.write(key: 'nusa_printer_footer', value: v);
  static Future<String> getPrinterFooter() async =>
      (await SecureStore.read(key: 'nusa_printer_footer')) ?? '';

  // -- Teks Header struk (single source untuk printing) --
  // Disinkronkan dari DB (SettingsRepository.setReceiptHeader) saat
  // Pengaturan Struk disimpan; printer membaca ini supaya teks header
  // custom benar-benar tercetak (fallback: nama toko).
  static Future<void> setReceiptHeader(String v) =>
      SecureStore.write(key: 'nusa_receipt_header_text', value: v);
  static Future<String?> getReceiptHeader() =>
      SecureStore.read(key: 'nusa_receipt_header_text');

  // -- Sub-header struk (alamat toko, v2.2.30) — mirror DB settings untuk
  // jalur print tanpa DB (ReceiptConfig.loadFromStore) --
  static Future<void> setReceiptSubHeader(String v) =>
      SecureStore.write(key: 'nusa_receipt_sub_header', value: v);
  static Future<String> getReceiptSubHeader() async =>
      (await SecureStore.read(key: 'nusa_receipt_sub_header')) ?? '';

  // -- Receipt font settings (universal ESC/POS: Standar=Font A, Kompak=Font B) --
  // Jenis font GLOBAL: 'standar' (Font A, universal — direkomendasikan) | 'kompak' (Font B).
  static Future<void> setReceiptFontType(String v) =>
      SecureStore.write(key: 'nusa_receipt_font_type', value: v);
  static Future<String> getReceiptFontType() async =>
      (await SecureStore.read(key: 'nusa_receipt_font_type')) ?? 'standar';

  // Ukuran HEADER — PIXEL image (12–48px, default 24). Header dicetak sebagai
  // bit-image (renderReceiptHeaderPng), jadi ukuran ini adalah tinggi huruf
  // header dalam piksel kertas, bukan perbesaran ESC/POS.
  static Future<void> setReceiptHeaderPx(int v) =>
      SecureStore.write(key: 'nusa_receipt_header_px', value: v.toString());
  static Future<int> getReceiptHeaderPx() async =>
      int.tryParse(
        await SecureStore.read(key: 'nusa_receipt_header_px') ?? '',
      ) ??
      24;

  // Ketebalan HEADER image: 'thin' (w300) | 'medium' (w500) | 'bold' (w700).
  // Default 'medium' — kompromi tegas tapi tidak dominan di atas kertas.
  static Future<void> setReceiptHeaderWeight(String v) =>
      SecureStore.write(key: 'nusa_receipt_header_weight', value: v);
  static Future<String> getReceiptHeaderWeight() async =>
      (await SecureStore.read(key: 'nusa_receipt_header_weight')) ?? 'medium';

  // -- Printer logo path --
  static Future<void> setPrinterLogoPath(String? v) async {
    if (v == null) {
      await SecureStore.delete(key: 'nusa_printer_logo_path');
    } else {
      await SecureStore.write(key: 'nusa_printer_logo_path', value: v);
    }
  }

  static Future<String?> getPrinterLogoPath() async =>
      SecureStore.read(key: 'nusa_printer_logo_path');

  // -- Lebar logo struk saat PRINT (bit-image) —
  // PERSEN dari lebar kertas (1-100). Default 60.
  static Future<void> setReceiptLogoWidthPercent(int v) =>
      SecureStore.write(key: 'nusa_receipt_logo_width', value: v.toString());
  static Future<int> getReceiptLogoWidthPercent() async =>
      int.tryParse(
        await SecureStore.read(key: 'nusa_receipt_logo_width') ?? '',
      ) ??
      60;

  // -- Posisi logo struk: 'left' | 'center' | 'right' (default center) --
  static Future<void> setReceiptLogoAlign(String v) =>
      SecureStore.write(key: 'nusa_receipt_logo_align', value: v);
  static Future<String> getReceiptLogoAlign() async =>
      (await SecureStore.read(key: 'nusa_receipt_logo_align')) ?? 'center';

  // -- Toggle info di struk (mirror DB settings — dipakai jalur print tanpa DB) --
  static Future<void> setReceiptShowLogo(bool v) =>
      SecureStore.write(key: 'nusa_receipt_show_logo', value: v.toString());
  static Future<bool> getReceiptShowLogo() async =>
      (await SecureStore.read(key: 'nusa_receipt_show_logo')) != 'false';
  static Future<void> setReceiptShowCashier(bool v) =>
      SecureStore.write(key: 'nusa_receipt_show_cashier', value: v.toString());
  static Future<bool> getReceiptShowCashier() async =>
      (await SecureStore.read(key: 'nusa_receipt_show_cashier')) != 'false';
  static Future<void> setReceiptShowInvoice(bool v) =>
      SecureStore.write(key: 'nusa_receipt_show_invoice', value: v.toString());
  static Future<bool> getReceiptShowInvoice() async =>
      (await SecureStore.read(key: 'nusa_receipt_show_invoice')) != 'false';
  static Future<void> setReceiptShowDate(bool v) =>
      SecureStore.write(key: 'nusa_receipt_show_date', value: v.toString());
  static Future<bool> getReceiptShowDate() async =>
      (await SecureStore.read(key: 'nusa_receipt_show_date')) != 'false';

  // -- Kitchen printer (FnB) --
  static const _kitchenPrinterKey = 'nusa_kitchen_printer_address';

  static Future<String?> getKitchenPrinterAddress() =>
      SecureStore.read(key: _kitchenPrinterKey);

  static Future<void> setKitchenPrinterAddress(String? v) async {
    if (v == null) {
      await SecureStore.delete(key: _kitchenPrinterKey);
    } else {
      await SecureStore.write(key: _kitchenPrinterKey, value: v);
    }
  }

  static const _kitchenPrinterEnabledKey = 'nusa_kitchen_printer_enabled';

  static Future<bool> getKitchenPrinterEnabled() async =>
      (await SecureStore.read(key: _kitchenPrinterEnabledKey)) == 'true';

  static Future<void> setKitchenPrinterEnabled(bool v) =>
      SecureStore.write(key: _kitchenPrinterEnabledKey, value: v.toString());

  // ── FnB payment flow: true = bayar dulu (pay first, then table), false = pesan dulu (default) ──
  static Future<bool> getFnbPaymentFirst() async =>
      (await SecureStore.read(key: 'nusa_fnb_payment_first')) == 'true';
  static Future<void> setFnbPaymentFirst(bool v) =>
      SecureStore.write(key: 'nusa_fnb_payment_first', value: v.toString());

  // ── Laundry settings ──
  static Future<String> getLaundryDefaultPriceType() async =>
      (await SecureStore.read(key: 'nusa_laundry_default_price_type')) ?? 'pcs';
  static Future<void> setLaundryDefaultPriceType(String v) =>
      SecureStore.write(key: 'nusa_laundry_default_price_type', value: v);
  static Future<bool> getLaundryNotifyReady() async =>
      (await SecureStore.read(key: 'nusa_laundry_notify_ready')) == 'true';
  static Future<void> setLaundryNotifyReady(bool v) =>
      SecureStore.write(key: 'nusa_laundry_notify_ready', value: v.toString());
  static Future<bool> getLaundryStatsExpanded() async =>
      (await SecureStore.read(key: 'nusa_laundry_stats_expanded')) == 'true';
  static Future<void> setLaundryStatsExpanded(bool v) => SecureStore.write(
    key: 'nusa_laundry_stats_expanded',
    value: v.toString(),
  );

  // ── Salon settings ──
  static Future<int> getSalonDefaultDuration() async {
    final v = await SecureStore.read(key: 'nusa_salon_default_duration');
    return v != null ? int.tryParse(v) ?? 60 : 60;
  }

  static Future<void> setSalonDefaultDuration(int v) => SecureStore.write(
    key: 'nusa_salon_default_duration',
    value: v.toString(),
  );
  static Future<bool> getSalonNotifyBooking() async =>
      (await SecureStore.read(key: 'nusa_salon_notify_booking')) == 'true';
  static Future<void> setSalonNotifyBooking(bool v) =>
      SecureStore.write(key: 'nusa_salon_notify_booking', value: v.toString());
  static Future<bool> getSalonStatsExpanded() async =>
      (await SecureStore.read(key: 'nusa_salon_stats_expanded')) == 'true';
  static Future<void> setSalonStatsExpanded(bool v) =>
      SecureStore.write(key: 'nusa_salon_stats_expanded', value: v.toString());

  // ── Bengkel settings ──
  static Future<bool> getBengkelStatsExpanded() async =>
      (await SecureStore.read(key: 'nusa_bengkel_stats_expanded')) == 'true';
  static Future<void> setBengkelStatsExpanded(bool v) => SecureStore.write(
    key: 'nusa_bengkel_stats_expanded',
    value: v.toString(),
  );

  // ── Fotocopy/Percetakan settings ──
  static Future<bool> getFotocopyStatsExpanded() async =>
      (await SecureStore.read(key: 'nusa_fotocopy_stats_expanded')) == 'true';
  static Future<void> setFotocopyStatsExpanded(bool v) => SecureStore.write(
    key: 'nusa_fotocopy_stats_expanded',
    value: v.toString(),
  );

  // ── Image migration flag ──────────────────────────────────────────
  static Future<bool> getImagesMigrated() async =>
      (await SecureStore.read(key: 'nusa_images_migrated')) == 'true';
  static Future<void> setImagesMigrated(bool v) =>
      SecureStore.write(key: 'nusa_images_migrated', value: v.toString());

  // ── Image sync throttle ──
  /// Timestamp (ms since epoch) sinkronisasi gambar terakhir dari cloud.
  /// Dipakai untuk gate `syncAll()` — kalau baru sync <6 jam lalu & tidak ada
  /// perubahan lokal, skip download-probe yang menggandakan traffic egress
  /// (tiap start app nge-list+nge-download foto, padahal `nusa-images`
  /// CDN-cache 1 jam — sync berulang sebelum TTL hangus = pemborosan
  /// Cached Egress).
  static Future<int> getLastImageSyncMs() async {
    final v = await SecureStore.read(key: 'nusa_last_image_sync_ms');
    return int.tryParse(v ?? '') ?? 0;
  }

  static Future<void> setLastImageSyncMs(int ms) =>
      SecureStore.write(key: 'nusa_last_image_sync_ms', value: '$ms');

  /// Interval minimum antara syncAll gambar (default 6 jam).
  /// Bisa diturunkan via setLastImageSyncMs(0) untuk paksa sync.
  static const int imageSyncIntervalMs = 6 * 60 * 60 * 1000;

  // ── PIN pad kasir (default: aktif) ────────────────────────────────
  static Future<bool> getPinPadEnabled() async {
    final v = await SecureStore.read(key: 'nusa_pinpad_kasir_enabled');
    return v == null || v == 'true'; // default aktif
  }

  static Future<void> setPinPadEnabled(bool v) =>
      SecureStore.write(key: 'nusa_pinpad_kasir_enabled', value: v.toString());

  // ── Izin pertama kali (dialog sekali) ─────────────────────────────
  static Future<bool> getPermissionsAsked() async =>
      (await SecureStore.read(key: 'nusa_permissions_asked')) == 'true';
  static Future<void> setPermissionsAsked(bool v) =>
      SecureStore.write(key: 'nusa_permissions_asked', value: v.toString());

  // ── Suara aplikasi (v2.2.54): default AKTIF ────────────────────────
  static Future<bool> getSoundEnabled() async =>
      (await SecureStore.read(key: 'nusa_sound_enabled')) != 'false';
  static Future<void> setSoundEnabled(bool v) =>
      SecureStore.write(key: 'nusa_sound_enabled', value: v.toString());

  // ── Panggil karyawan (v2.2.54): default AKTIF ──────────────────────
  static Future<bool> getCallFeatureEnabled() async =>
      (await SecureStore.read(key: 'nusa_call_feature_enabled')) != 'false';
  static Future<void> setCallFeatureEnabled(bool v) =>
      SecureStore.write(
        key: 'nusa_call_feature_enabled',
        value: v.toString(),
      );

  // ── Auto cloud sync state (per device) ────────────────────────────
  static Future<DateTime?> getLastCloudSeen() async {
    final v = await SecureStore.read(key: 'nusa_last_cloud_seen');
    return v != null ? DateTime.tryParse(v) : null;
  }

  static Future<void> setLastCloudSeen(DateTime v) => SecureStore.write(
    key: 'nusa_last_cloud_seen',
    value: v.toUtc().toIso8601String(),
  );

  static Future<DateTime?> getLastLocalChange() async {
    final v = await SecureStore.read(key: 'nusa_last_local_change');
    return v != null ? DateTime.tryParse(v) : null;
  }

  static Future<void> setLastLocalChange(DateTime v) => SecureStore.write(
    key: 'nusa_last_local_change',
    value: v.toUtc().toIso8601String(),
  );

  static Future<int> getConflictCount() async {
    final v = await SecureStore.read(key: 'nusa_conflict_count');
    return v != null ? int.tryParse(v) ?? 0 : 0;
  }

  static Future<void> setConflictCount(int v) =>
      SecureStore.write(key: 'nusa_conflict_count', value: v.toString());
  static Future<void> bumpConflictCount() async {
    final c = await getConflictCount();
    await setConflictCount(c + 1);
  }

  // ── Delta sync (v2.2.57+131) ──────────────────────────────────────

  /// Timestamp of the last successful delta pull — sent to the cloud so
  /// the server can return only deltas newer than this.
  static Future<DateTime?> getLastDeltaPull() async {
    final s = await read(key: 'last_delta_pull');
    if (s == null) return null;
    return DateTime.tryParse(s);
  }

  static Future<void> setLastDeltaPull(DateTime t) async {
    await write(key: 'last_delta_pull', value: t.toIso8601String());
  }

  /// Stable per-device identifier for delta sync. Generated once and reused.
  static Future<String?> getDeviceId() async {
    var id = await read(key: 'device_id');
    if (id == null) {
      id =
          'dev-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(99999)}';
      await write(key: 'device_id', value: id);
    }
    return id;
  }
}
