import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:restart_app/restart_app.dart';
import 'package:nusa_kasir/core/providers.dart';
import 'package:nusa_kasir/core/providers/restore_progress_provider.dart';
import 'package:nusa_kasir/shared/widgets/restore_progress_dialog.dart';
import 'package:nusa_kasir/data/database/app_database.dart';
import 'package:nusa_kasir/core/config/nusa_config.dart';
import 'package:nusa_kasir/core/services/google_auth_service.dart';
import 'package:nusa_kasir/core/receipt/receipt_config.dart';
import 'package:nusa_kasir/core/receipt/receipt_data.dart';
import 'package:nusa_kasir/core/receipt/receipt_preview_widget.dart';
import 'package:nusa_kasir/core/utils/image_utils.dart';
import 'package:nusa_kasir/core/utils/secure_storage.dart';
import 'package:nusa_kasir/core/services/call_service.dart';
import 'package:nusa_kasir/core/services/auto_sync_service.dart';
import 'package:nusa_kasir/core/services/realtime_sync_service.dart';
import 'package:nusa_kasir/core/utils/receipt_printer.dart';
import 'package:nusa_kasir/core/utils/receipt_header_renderer.dart'
    show receiptHeaderMinPx, receiptHeaderMaxPx;
import 'package:nusa_kasir/shared/widgets/nusa_card.dart';
import 'package:nusa_kasir/shared/widgets/nusa_input.dart';
import 'package:nusa_kasir/shared/widgets/nusa_button.dart';
import 'package:nusa_kasir/shared/widgets/screen_scaffold.dart';
import 'package:nusa_kasir/shared/widgets/top_toast.dart';
import 'package:nusa_kasir/shared/widgets/pin_dialog.dart';
import 'package:nusa_kasir/features/settings/backup_sheet.dart';
import 'package:nusa_kasir/features/settings/printer_settings_sheet.dart';
import 'package:nusa_kasir/features/settings/tutorial_screen.dart';
import 'package:nusa_kasir/core/services/update_service.dart';
import 'package:nusa_kasir/core/providers/update_progress_provider.dart';
import 'package:nusa_kasir/data/repositories/attendance_repository.dart';
import 'package:nusa_kasir/features/auth/employee_session_provider.dart';
import 'package:nusa_kasir/core/auth/employee_session.dart';
import 'package:nusa_kasir/shared/services/biometric_service.dart';
import 'package:nusa_kasir/shared/services/nfc_tag_service.dart';
import 'package:nusa_kasir/shared/services/auth_methods.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  String? _activationKey;
  String _themeMode = 'system';
  String? _printerName;
  bool _backingUp = false;
  UpdateInfo? _updateInfo;

  // Manual cloud sync
  bool _syncing = false;
  String? _cloudTimeStr;
  String? _localTimeStr;
  int _conflictCount = 0;

  // Fingerprint
  bool _fingerprintEnabled = false;

  // PIN pad kasir (opsional — login PIN tetap wajib)
  bool _pinPadEnabled = true;

  // FnB: alur pembayaran
  bool _fnbPayFirst = false;

  // Salon: estimasi & notifikasi
  int _salonDefaultDuration = 60;
  bool _salonNotifyBooking = true;

  // v2.2.54: suara aplikasi (transaksi berhasil, scan, dsb) + fitur Panggil
  // (Realtime Broadcast — owner bisa bunyikan device kasir/staf).
  bool _soundEnabled = true;
  bool _callFeatureEnabled = true;

  // Theme preset
  String _themePreset = NusaConfig.productId.replaceFirst('nusa-', '');

  // Feature toggles — all true by default
  Map<String, bool> _featureToggles = {};
  List<String> _menuOrder = []; // persistable menu order (drag-reorder)

  static const _allFeatures = [
    'produk', 'stok', 'transaksi', 'pelanggan', 'piutang', 'promo',
    'pesanan_online', 'laporan', 'presensi', 'karyawan',
    'keuangan', 'spreadsheet', 'supplier', 'cabang', 'ai_chat', 'pengaturan',
    // Domain features — hidden by default per variant via NusaConfig.hiddenMenus
    'meja', 'laundry_status', 'servis', 'booking', 'resep', 'print_order',
  ];

  static const _featureLabels = {
    'produk': 'Produk',
    'stok': 'Stok',
    'transaksi': 'Transaksi',
    'pelanggan': 'Pelanggan',
    'piutang': 'Piutang',
    'promo': 'Promo',
    'pesanan_online': 'Pesanan Online',
    'laporan': 'Laporan',
    'presensi': 'Presensi',
    'karyawan': 'Karyawan',
    'keuangan': 'Keuangan',
    'spreadsheet': 'Spreadsheet',
    'supplier': 'Supplier',
    'cabang': 'Cabang',
    'ai_chat': 'AI Chat',
    'pengaturan': 'Pengaturan',
    'meja': 'Meja',
    'laundry_status': 'Status Laundry',
    'servis': 'Tiket Servis',
    'booking': 'Booking',
    'resep': 'Resep',
    'print_order': 'Order Cetak',
  };

  static const _featureIcons = {
    'produk': Icons.inventory_2_outlined,
    'stok': Icons.view_module_outlined,
    'transaksi': Icons.receipt_long_outlined,
    'pelanggan': Icons.person_outline,
    'piutang': Icons.money_off_outlined,
    'promo': Icons.discount_outlined,
    'pesanan_online': Icons.shopping_cart_outlined,
    'laporan': Icons.paid_outlined,
    'presensi': Icons.fingerprint,
    'karyawan': Icons.people_outline,
    'keuangan': Icons.account_balance_wallet_outlined,
    'spreadsheet': Icons.table_chart_outlined,
    'supplier': Icons.local_shipping_outlined,
    'cabang': Icons.storefront_outlined,
    'ai_chat': Icons.smart_toy_outlined,
    'pengaturan': Icons.settings_outlined,
    'meja': Icons.table_bar_outlined,
    'laundry_status': Icons.local_laundry_service_outlined,
    'servis': Icons.build_outlined,
    'booking': Icons.calendar_month_outlined,
    'resep': Icons.medication_outlined,
    'print_order': Icons.print_outlined,
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(settingsRepoProvider);
    final key = await SecureStore.getActivation();
    final theme = await repo.getThemeMode();
    final printer = await repo.getPrinterAddress();

    // v2.2.57+115: versi APK asli (PackageInfo) — biar tampilan
    // "Terpasang" akurat, bukan konstanta build yang sudah naik duluan.
    await SecureStore.loadInstalledVersion();

    // Load theme preset
    final savedTheme = await SecureStore.getThemePreset();
    if (savedTheme != null && NusaConfig.themePresets.containsKey(savedTheme)) {
      _themePreset = savedTheme;
      NusaConfig.applyTheme(savedTheme);
    }

    // Load feature toggles
    final raw = await SecureStore.getFeatureToggles();
    Map<String, bool> toggles = {};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        for (final e in decoded.entries) {
          toggles[e.key] = e.value == true;
        }
      } catch (_) {}
    }
    // Fill in missing features conservatively: domain-specific menus stay hidden
    // unless explicitly enabled for this variant by the user.
    for (final f in _allFeatures) {
      toggles.putIfAbsent(f, () => !NusaConfig.hiddenMenus.contains(f));
    }

    // Load menu order
    final orderRaw = await SecureStore.getMenuOrder();
    List<String> order = [];
    if (orderRaw != null && orderRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(orderRaw) as List<dynamic>;
        order = decoded.cast<String>();
        // Filter to only valid feature IDs, add any new features at end
        final existing = order
            .where((id) => _allFeatures.contains(id))
            .toList();
        for (final f in _allFeatures) {
          if (!existing.contains(f)) existing.add(f);
        }
        order = existing;
      } catch (_) {
        order = List.from(_allFeatures);
      }
    } else {
      order = List.from(_allFeatures);
    }

    if (mounted) {
      _activationKey = key;
      _themeMode = theme ?? 'system';
      _printerName = printer;
      _featureToggles = toggles;
      _menuOrder = order;
      ref.read(themeModeProvider.notifier).state = _themeMode;
      // Sync feature toggles to provider (used by dashboard)
      ref.read(featureTogglesProvider.notifier).state = Map.from(toggles);
      // Sync menu order to provider (used by dashboard sort)
      ref.read(menuOrderProvider.notifier).state = List.from(order);

      // Load fingerprint state
      _fingerprintEnabled = await BiometricService.isEnabled();

      // Load PIN pad kasir toggle
      _pinPadEnabled = await SecureStore.getPinPadEnabled();

      // v2.2.54: suara aplikasi + fitur Panggil
      _soundEnabled = await SecureStore.getSoundEnabled();
      _callFeatureEnabled = await SecureStore.getCallFeatureEnabled();

      // Load FnB payment flow
      if (NusaConfig.isFnbVariant) {
        _fnbPayFirst = await SecureStore.getFnbPaymentFirst();
      }

      // Load Salon settings
      if (NusaConfig.isSalonVariant) {
        _salonDefaultDuration = await SecureStore.getSalonDefaultDuration();
        _salonNotifyBooking = await SecureStore.getSalonNotifyBooking();
      }

      // (Laundry global settings removed — now per-product)

      setState(() {});
    }
    // Silent update check — kalau ada update, baris "Riwayat Update"
    // berubah jadi "Update Tersedia!" (notif + popup saat diketuk).
    if (NusaConfig.isDevBuild == false) {
      final info = await UpdateService.checkForUpdate();
      if (mounted && info.hasUpdate) {
        setState(() => _updateInfo = info);
      }
    }
  }

  Future<void> _saveFeatureToggles() async {
    final json = jsonEncode(_featureToggles);
    await SecureStore.saveFeatureToggles(json);
    ref.read(featureTogglesProvider.notifier).state = Map.from(_featureToggles);
  }

  Future<void> _saveMenuOrder() async {
    final json = jsonEncode(_menuOrder);
    await SecureStore.saveMenuOrder(json);
    ref.read(menuOrderProvider.notifier).state = List.from(_menuOrder);
  }

  @override
  void dispose() {
    super.dispose();
  }

  // ── PIN Gate ──────────────────────────────────────────────

  Future<bool> _checkPin() async {
    final session = ref.read(employeeSessionProvider);
    String name;
    String correctPin;
    bool needOwner = false;

    if (session != null) {
      // Current session employee
      final repo = AttendanceRepository(ref.read(databaseProvider));
      final emp = await repo.getEmployee(session.employeeId);
      if (emp != null) {
        name = emp.name;
        correctPin = emp.pin;
      } else {
        // Stale session — employee was deleted or DB was replaced.
        // Clear the session and fall through to owner PIN below
        // instead of silently returning false (which shows misleading "PIN salah" toast).
        ref.read(employeeSessionProvider.notifier).logout();
        needOwner = true;
        name = '';
        correctPin = ''; // will be overwritten below
      }
    } else {
      needOwner = true;
      name = '';
      correctPin = ''; // will be overwritten below
    }

    if (needOwner) {
      // No valid session — ask for Owner PIN
      final repo = AttendanceRepository(ref.read(databaseProvider));
      final all = await repo.getEmployees();
      final ownerList = all.where((e) => e.role == 'Owner').toList();
      if (ownerList.isEmpty) return true;
      final owner = ownerList.first;
      name = owner.name;
      correctPin = owner.pin;
    }

    final result = await PinDialog.show(
      context: context,
      title: 'Verifikasi PIN',
      subtitle: 'Masukkan PIN $name untuk mengakses pengaturan keamanan',
      employeeName: name,
      correctPin: correctPin,
      showRemember: false,
      showFingerprint: true,
      showNfc: true,
      showBarcode: true,
      onFingerprint: () async => await _authFingerprint(),
      onNfc: () async {
        final id = await NfcTagService.readEmployeeTag();
        return id?.toString();
      },
      onBarcode: AuthMethods.barcode(ref),
      // v2.2.50 (A5): "Lupa PIN?" → Google re-auth + set PIN baru (cloud-only)
      onForgotPin: NusaConfig.cloudEnabled
          ? () async {
              Navigator.of(context).pop(); // tutup dialog pin
              if (!mounted) return;
              final confirm = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  title: const Text('Lupa PIN?'),
                  content: const Text(
                    'Login ulang dengan akun Google pemilik toko untuk mengatur PIN baru. Lanjutkan?',
                    style: TextStyle(fontSize: 14, height: 1.5),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Batal'),
                    ),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: NusaConfig.activePrimary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Lanjut'),
                    ),
                  ],
                ),
              );
              if (confirm != true || !mounted) return;
              final currentUid = await GoogleAuthService.getStoredUserId();
              final newUid = await GoogleAuthService().signIn();
              if (!mounted || newUid == null) return;
              if (currentUid != null && newUid != currentUid) {
                if (mounted)
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Akun Google berbeda.')),
                  );
                return;
              }
              await GoogleAuthService.ensureStored(newUid);
              final db = ref.read(databaseProvider);
              final repo = AttendanceRepository(db);
              final emps = await repo.getEmployees();
              final owner = emps.cast<Employee?>().firstWhere(
                (e) => e!.role == 'Owner' || e!.role == 'Manager',
                orElse: () => null,
              );
              if (owner == null) return;
              final newPin = await _promptNewPinDialog();
              if (!mounted || newPin == null) return;
              await repo.updateEmployee(
                id: owner.id,
                name: owner.name,
                pin: newPin,
                role: owner.role,
                status: owner.status,
              );
              if (mounted)
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('PIN berhasil diubah')));
            }
          : null,
    );

    return result?.success == true;
  }

  /// Prompt user for a new PIN (4–6 digits). Mirrors login_screen._promptNewPin.
  Future<String?> _promptNewPinDialog() {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('PIN Baru'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          maxLength: 6,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Masukkan PIN baru (4–6 digit)',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: NusaConfig.activePrimary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () {
              final v = ctrl.text.trim();
              if (v.length < 4 || !RegExp(r'^\d+$').hasMatch(v)) return;
              Navigator.pop(ctx, v);
            },
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
  }

  Future<bool> _authFingerprint() async {
    return BiometricService.authenticate(
      reason: 'Verifikasi biometrik untuk melanjutkan',
    );
  }

  Future<void> _pinGate(VoidCallback action) async {
    if (await _checkPin()) {
      action();
    } else {
      TopToast.error(context, 'PIN salah — akses ditolak');
    }
  }

  /// Toggle biometric login for Owner — direct, no PIN gate.
  /// ON → langsung muncul dialog biometric OS, sukses = enable, gagal = balik OFF.
  /// OFF → langsung disable.
  Future<void> _toggleFingerprint(EmployeeSession session) async {
    if (session.role != 'Owner') {
      TopToast.info(context, 'Hanya Owner yang bisa mengatur biometrik');
      return;
    }

    final enable = !_fingerprintEnabled;

    if (enable) {
      // Check hardware capabilities first — don't allow enable on devices
      // without biometric sensors (otherwise OS falls back to device PIN).
      final caps = await BiometricService.checkCapabilities();
      if (!caps.ok) {
        if (mounted) TopToast.error(context, caps.message);
        return;
      }

      // Validate via system biometric dialog directly
      final scanned = await BiometricService.authenticate(
        reason: 'Pindai biometrik untuk mengaktifkan Login Biometrik',
      );
      if (!scanned) {
        if (mounted) {
          final msg =
              BiometricService.lastResult.message ??
              'Pemindaian biometrik gagal atau dibatalkan';
          TopToast.error(context, msg);
        }
        return;
      }

      await BiometricService.enable();
    } else {
      await BiometricService.disable();
    }

    if (mounted) {
      setState(() => _fingerprintEnabled = enable);
      TopToast.success(
        context,
        enable ? 'Biometrik diaktifkan' : 'Biometrik dinonaktifkan',
      );
    }
  }

  // ── FnB: Alur Pembayaran ──────────────────────────────────

  Future<void> _toggleFnbPayFirst() async {
    final next = !_fnbPayFirst;
    await SecureStore.setFnbPaymentFirst(next);
    if (mounted) setState(() => _fnbPayFirst = next);
    if (mounted) {
      TopToast.success(
        context,
        next ? 'Alur: Bayar dulu di kasir' : 'Alur: Pesan dulu, bayar nanti',
      );
    }
  }

  // ── PIN Pad Kasir ────────────────────────────────────────

  Future<void> _togglePinPad() async {
    final next = !_pinPadEnabled;
    await SecureStore.setPinPadEnabled(next);
    if (mounted) setState(() => _pinPadEnabled = next);
    if (mounted) {
      TopToast.success(
        context,
        next
            ? 'PIN kasir aktif — fitur & kasir wajib PIN'
            : 'PIN kasir nonaktif — login tetap butuh PIN',
      );
    }
  }

  // ── Backups ───────────────────────────────────────────────

  Future<void> _backupNow() async {
    setState(() => _backingUp = true);
    final ok = await ref.read(activationRepoProvider).uploadBackupNow();
    // v2.2.55: ikon awan di dashboard ikut berubah sesuai hasil manual backup.
    AutoSyncService.status.value = AutoSyncStatus(
      ok ? AutoSyncPhase.ok : AutoSyncPhase.failed,
      lastOkAt: ok ? DateTime.now() : AutoSyncService.status.value.lastOkAt,
    );
    if (ok) {
      unawaited(RealtimeBackupNotifier.I.broadcastUpdated());
    }
    if (mounted) {
      setState(() => _backingUp = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? 'Backup berhasil disimpan ke cloud'
                : 'Gagal backup. Periksa koneksi internet.',
          ),
          backgroundColor: ok ? Colors.green.shade700 : Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
  }

  // ── Cloud Sync (manual) ──────────────────────────────────

  Future<void> _showCloudSync() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Fetch timestamps
    final repo = ref.read(activationRepoProvider);
    final cloudTime = await repo.getBackupTimestamp();
    final localTime = await SecureStore.getLastBackupTime();
    final conflictCount = await SecureStore.getConflictCount();

    if (mounted) {
      setState(() {
        _conflictCount = conflictCount;
        _cloudTimeStr = cloudTime != null
            ? '${cloudTime.day}/${cloudTime.month}/${cloudTime.year} ${cloudTime.hour.toString().padLeft(2, '0')}:${cloudTime.minute.toString().padLeft(2, '0')}'
            : null;
        _localTimeStr = localTime != null
            ? '${localTime.day}/${localTime.month}/${localTime.year} ${localTime.hour.toString().padLeft(2, '0')}:${localTime.minute.toString().padLeft(2, '0')}'
            : null;
      });
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      // v2.2.57+122 (Bug fix): isScrollControlled + maxHeight supaya konten
      // boleh lebih tinggi dari layar, lalu SingleChildScrollView membuat
      // tombol "Download dari Cloud" SELALU bisa dijangkau — sebelumnya
      // bottom sheet tidak bisa di-scroll sehingga tombol Download
      // tersembunyi dan "Upload ke Cloud" rawan tertekan tak sengaja
      // (menimpa database).
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.all(20),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.9,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark
                      ? NusaConfig.darkDivider
                      : NusaConfig.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 8),
              Icon(Icons.cloud_sync, size: 40, color: NusaConfig.activePrimary),
              const SizedBox(height: 12),
              const Text(
                'Sinkronisasi Cloud',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'Upload / Download data antar perangkat',
                style: TextStyle(
                  fontSize: 13,
                  color: isDark
                      ? NusaConfig.darkTextSecondary
                      : NusaConfig.textSecondary,
                ),
              ),
              const SizedBox(height: 16),
              // Timestamp comparison
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: isDark
                      ? NusaConfig.darkSurface2
                      : NusaConfig.backgroundColor,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    _syncInfoRow(
                      'Cloud (NUSA)',
                      _cloudTimeStr,
                      Icons.cloud,
                      isDark,
                    ),
                    const SizedBox(height: 8),
                    _syncInfoRow(
                      'Lokal (Perangkat ini)',
                      _localTimeStr,
                      Icons.phone_android,
                      isDark,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // Auto-sync info
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: NusaConfig.activePrimary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: NusaConfig.activePrimary.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.auto_awesome,
                      size: 18,
                      color: NusaConfig.activePrimary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Auto-sync aktif: perubahan dikirim ~1,2 dtk setelah '
                        'Anda berhenti mengetik, digabung dalam 10 dtk, dan '
                        'data ditarik dari cloud tiap 30 dtk (saat online). '
                        'Konflik otomatis memilih data terbaru — yang lama '
                        'disimpan sebagai snapshot, tanpa dialog.',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          color: isDark
                              ? NusaConfig.darkTextSecondary
                              : NusaConfig.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_conflictCount > 0) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: NusaConfig.warning.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: NusaConfig.warning.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 18,
                        color: NusaConfig.warning,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Ada $_conflictCount cadangan otomatis lama tersimpan di folder aplikasi (file conflict_*.sqlite). Aman dihapus dari tombol di atas jika tidak diperlukan.',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: isDark
                                ? NusaConfig.darkTextSecondary
                                : NusaConfig.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              // Upload
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _syncing
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          _doUpload();
                        },
                  icon: _syncing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_upload_outlined),
                  label: const Text('Upload ke Cloud (Simpan data lokal)'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: NusaConfig.activePrimary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              // Download
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _syncing
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          _confirmDownload();
                        },
                  icon: const Icon(Icons.cloud_download_outlined),
                  label: const Text('Download dari Cloud (Timpa data lokal)'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: NusaConfig.error,
                    side: const BorderSide(color: NusaConfig.error),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '⚠ Download akan menimpa SEMUA data lokal dengan data dari cloud.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  color: isDark
                      ? NusaConfig.darkTextTertiary
                      : NusaConfig.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _syncInfoRow(
    String label,
    String? time,
    IconData icon,
    bool isDark,
  ) => Row(
    children: [
      Icon(
        icon,
        size: 16,
        color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary,
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary,
          ),
        ),
      ),
      Text(
        time ?? 'Belum pernah',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: time != null
              ? (isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary)
              : (isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary)
                    .withValues(alpha: 0.8),
        ),
      ),
    ],
  );

  Future<void> _doUpload() async {
    setState(() => _syncing = true);
    final repo = ref.read(activationRepoProvider);
    final ok = await repo.uploadBackupNow();
    // v2.2.55: ikon awan di dashboard ikut berubah sesuai hasil upload manual.
    AutoSyncService.status.value = AutoSyncStatus(
      ok ? AutoSyncPhase.ok : AutoSyncPhase.failed,
      lastOkAt: ok ? DateTime.now() : AutoSyncService.status.value.lastOkAt,
    );
    if (ok) {
      unawaited(RealtimeBackupNotifier.I.broadcastUpdated());
    }
    if (mounted) {
      setState(() => _syncing = false);
      // Refresh timestamps so the next cloud sync dialog shows up-to-date values.
      if (ok) {
        final cloudTime = await repo.getBackupTimestamp();
        final localTime = await SecureStore.getLastBackupTime();
        setState(() {
          _cloudTimeStr = cloudTime != null
              ? '${cloudTime.day}/${cloudTime.month}/${cloudTime.year} ${cloudTime.hour.toString().padLeft(2, '0')}:${cloudTime.minute.toString().padLeft(2, '0')}'
              : null;
          _localTimeStr = localTime != null
              ? '${localTime.day}/${localTime.month}/${localTime.year} ${localTime.hour.toString().padLeft(2, '0')}:${localTime.minute.toString().padLeft(2, '0')}'
              : null;
        });
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? 'Data berhasil diupload ke cloud ☁️'
                : 'Gagal upload. Periksa koneksi internet.',
          ),
          backgroundColor: ok ? Colors.green.shade700 : Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
  }

  void _confirmDownload() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: NusaConfig.error,
              size: 28,
            ),
            SizedBox(width: 10),
            Text('Konfirmasi Download', style: TextStyle(fontSize: 17)),
          ],
        ),
        content: const Text(
          'Data lokal akan DITIMPA dengan data dari cloud.\n\n'
          'Pastikan tidak ada transaksi yang belum diupload.\n'
          'Disarankan upload dulu sebelum download.',
          style: TextStyle(fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: NusaConfig.error,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _doDownload();
            },
            child: const Text(
              'Ya, Timpa Data',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _doDownload() async {
    // v2.2.57+138: ganti spinner kecil di tombol dengan dialog progress.
    // restoreFromCloud() hanya download + stage .pending — gambar menyusul
    // dihidrasi otomatis oleh main() _applyPendingRestore() saat restart,
    // beri tahu user lewat label di dialog.
    final progress = ref.read(restoreProgressProvider.notifier);
    progress.start();
    showRestoreProgressDialog(context, showImages: false);

    final repo = ref.read(activationRepoProvider);
    final ok = await repo.restoreFromCloud(onPhase: (phase) {
      if (phase == 'unpack') progress.phase(RestorePhase.unpack);
    });
    if (mounted) {
      if (context.mounted) Navigator.of(context).pop(); // tutup dialog
      progress.done();
      if (ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Data dari cloud siap dipulihkan. Aplikasi akan restart...',
            ),
            backgroundColor: Colors.green.shade700,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
        // Restore from cloud stages the DB to .pending — applied by
        // main() _applyPendingRestore() BEFORE the DB opens. Without a real
        // restart the restored data (incl. PIN) never becomes visible, so
        // actually restart the app instead of just navigating home.
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) Restart.restartApp();
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Gagal download. Pastikan koneksi internet dan cloud backup tersedia.',
            ),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
      }
    }
  }

  // ── Section Header ────────────────────────────────────────
  // v2.2.57+112: label kategori — huruf kapital tebal, diberi jarak atas
  // lebih besar supaya tiap grup kartu terpisah jelas secara visual.

  Widget _sectionHeader(String title, bool isDark) => Padding(
    padding: const EdgeInsets.only(top: 28, bottom: 10),
    child: Text(
      title,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w800,
        color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary,
        letterSpacing: 1.4,
      ),
    ),
  );

  // ── Menu Tile (row tanpa card — dipakai di dalam _groupCard) ──
  // v2.2.57+112: baris-baris menu yang berelasi dibungkus 1 card group,
  // antar baris dipisah Divider tipis (pola Material 3).

  Widget _menuTile({
    required IconData icon,
    required String title,
    required String? subtitle,
    required VoidCallback? onTap,
    bool isDark = false,
    Widget? trailing,
    Widget?
    subtitleWidget, // v2.2.57+115: subtitle non-teks (mis. FutureBuilder)
  }) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Icon(icon, color: NusaConfig.activePrimary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 3),
                subtitleWidget ??
                    (subtitle == null
                        ? const SizedBox.shrink()
                        : Text(
                            subtitle,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                              color: isDark
                                  ? NusaConfig.darkTextTertiary
                                  : NusaConfig.textTertiary,
                            ),
                          )),
              ],
            ),
          ),
          if (trailing != null)
            trailing
          else
            Icon(
              Icons.chevron_right,
              size: 20,
              color: isDark
                  ? NusaConfig.darkTextTertiary
                  : NusaConfig.textTertiary,
            ),
        ],
      ),
    ),
  );

  // ── Group Card (Material 3) ───────────────────────────────
  // Satu card menampung baris-baris menu berelasi, dipisah divider tipis.
  // marginBottom diberi agar antar grup kartu renggang (brief: 24-28px).

  Widget _groupCard({required List<Widget> tiles, bool isDark = false}) {
    final divider = Divider(
      height: 1,
      thickness: 1,
      indent: 52,
      color: isDark ? NusaConfig.darkDivider : NusaConfig.dividerColor,
    );
    final children = <Widget>[];
    for (var i = 0; i < tiles.length; i++) {
      if (i > 0) children.add(divider);
      children.add(tiles[i]);
    }
    return NusaCard(
      Padding(
        padding: EdgeInsets.zero,
        child: Column(children: children),
      ),
    );
  }

  // ── Theme Chip ────────────────────────────────────────────

  Widget _themeChip(String label, String mode, IconData icon, bool isDark) {
    final selected = _themeMode == mode;
    return Expanded(
      child: GestureDetector(
        onTap: () async {
          await ref.read(settingsRepoProvider).setThemeMode(mode);
          ref.read(themeModeProvider.notifier).state = mode;
          setState(() => _themeMode = mode);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: selected ? NusaConfig.primarySoft : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? NusaConfig.activePrimary
                  : NusaConfig.dividerColor,
            ),
          ),
          child: Column(
            children: [
              Icon(
                icon,
                size: 20,
                color: selected
                    ? NusaConfig.activePrimary
                    : isDark
                    ? NusaConfig.darkTextSecondary
                    : NusaConfig.textSecondary,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: selected
                      ? NusaConfig.activePrimary
                      : isDark
                      ? NusaConfig.darkTextSecondary
                      : NusaConfig.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Theme Picker ──────────────────────────────────────────

  String _currentThemeLabel() {
    return NusaConfig.themeNames[_themePreset] ?? _themePreset;
  }

  void _showThemePicker() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => Container(
          decoration: BoxDecoration(
            color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark
                      ? NusaConfig.darkDivider
                      : NusaConfig.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: NusaConfig.activePrimary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.palette_outlined,
                        color: NusaConfig.activePrimary,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Tema Warna',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Pilih palet warna untuk aplikasi. Beberapa menu akan '
                'menyesuaikan warna tema yang dipilih.',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark
                      ? NusaConfig.darkTextTertiary
                      : NusaConfig.textTertiary,
                ),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: Wrap(
                  spacing: 20,
                  runSpacing: 20,
                  alignment: WrapAlignment.center,
                  children: NusaConfig.themePresets.entries.map((entry) {
                    final id = entry.key;
                    final preset = entry.value;
                    final selected = _themePreset == id;
                    return GestureDetector(
                      onTap: () async {
                        setSt(() {
                          _themePreset = id;
                          setState(() {});
                        });
                        NusaConfig.applyTheme(id);
                        ref.read(themePresetProvider.notifier).state = id;
                        await SecureStore.saveThemePreset(id);
                      },
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: preset['primary'],
                          border: Border.all(
                            color: selected
                                ? (isDark
                                      ? Colors.white
                                      : NusaConfig.textPrimary)
                                : Colors.transparent,
                            width: selected ? 3 : 0,
                          ),
                          boxShadow: selected
                              ? [
                                  BoxShadow(
                                    color: (preset['primary']!).withValues(
                                      alpha: 0.4,
                                    ),
                                    blurRadius: 12,
                                    spreadRadius: 2,
                                  ),
                                ]
                              : null,
                        ),
                        child: selected
                            ? const Icon(
                                Icons.check,
                                color: Colors.white,
                                size: 28,
                              )
                            : null,
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Feature Toggles Bottom Sheet ──────────────────────────

  void _showFeatureToggles() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Build ordered list respecting user's drag-reorder preference
    final hidden = NusaConfig.hiddenMenus;
    final ordered = List<String>.from(
      (_menuOrder.isNotEmpty ? _menuOrder : _allFeatures).where(
        (id) => !hidden.contains(id),
      ),
    );
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => Container(
          decoration: BoxDecoration(
            color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle
              Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark
                      ? NusaConfig.darkDivider
                      : NusaConfig.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Title
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: NusaConfig.activePrimary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.toggle_on_outlined,
                        color: NusaConfig.activePrimary,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Kelola Fitur',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Geser ikon ⠿ untuk atur ulang urutan menu di Home Screen.\n'
                'Matikan fitur yang tidak ingin ditampilkan.',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark
                      ? NusaConfig.darkTextTertiary
                      : NusaConfig.textTertiary,
                ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ReorderableListView.builder(
                  shrinkWrap: true,
                  itemCount: ordered.length,
                  onReorderItem: (oldIndex, newIndex) {
                    setSt(() {
                      if (newIndex > oldIndex) newIndex--;
                      final item = ordered.removeAt(oldIndex);
                      ordered.insert(newIndex, item);
                      _menuOrder = List.from(ordered);
                      setState(() {});
                    });
                    _saveMenuOrder();
                  },
                  proxyDecorator: (child, index, animation) {
                    return Material(
                      elevation: 4,
                      borderRadius: BorderRadius.circular(12),
                      shadowColor: NusaConfig.activePrimary.withValues(
                        alpha: 0.2,
                      ),
                      child: child,
                    );
                  },
                  itemBuilder: (context, index) {
                    final id = ordered[index];
                    final enabled = _featureToggles[id] ?? true;
                    return Container(
                      key: ValueKey(id),
                      margin: const EdgeInsets.symmetric(vertical: 2),
                      decoration: BoxDecoration(
                        color: isDark
                            ? NusaConfig.darkBackground
                            : NusaConfig.backgroundColor,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: SwitchListTile(
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                        ),
                        secondary: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Drag handle
                            Icon(
                              Icons.drag_indicator,
                              size: 20,
                              color: isDark
                                  ? NusaConfig.darkTextTertiary
                                  : NusaConfig.textTertiary,
                            ),
                            const SizedBox(width: 4),
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: enabled
                                    ? NusaConfig.activePrimary.withValues(
                                        alpha: 0.12,
                                      )
                                    : (isDark
                                          ? NusaConfig.darkSurface2
                                          : NusaConfig.backgroundColor),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                (_featureIcons[id] ?? Icons.circle),
                                size: 18,
                                color: enabled
                                    ? NusaConfig.activePrimary
                                    : isDark
                                    ? NusaConfig.darkTextTertiary
                                    : NusaConfig.textTertiary,
                              ),
                            ),
                          ],
                        ),
                        title: Text(
                          _featureLabels[id] ?? id,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: enabled
                                ? (isDark
                                      ? NusaConfig.darkTextPrimary
                                      : NusaConfig.textPrimary)
                                : (isDark
                                      ? NusaConfig.darkTextTertiary
                                      : NusaConfig.textTertiary),
                          ),
                        ),
                        subtitle: null,
                        value: enabled,
                        activeColor: NusaConfig.activePrimary,
                        onChanged: (v) {
                          setSt(() {
                            _featureToggles[id] = v;
                            setState(() {}); // sync parent
                          });
                          _saveFeatureToggles();
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── License Detail Bottom Sheet ───────────────────────────

  Future<void> _showLicense() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // v2.2.44 (L5): baca metadata lisensi nyata (diisi saat login) —
    // bukan hardcoded "Status: Aktif".
    final info = await SecureStore.getLicenseInfo();
    final exp = info?.expiresAt;
    final now = DateTime.now();
    final blocked =
        info == null || info.status == 'Expired' || info.status == 'Cancelled';
    final isExpired = !blocked && exp != null && exp.isBefore(now);
    final statusText = info == null
        ? 'Tidak Terdeteksi'
        : blocked
        ? (info.status == 'Cancelled' ? 'Dibatalkan' : 'Kedaluwarsa')
        : isExpired
        ? 'Kedaluwarsa'
        : 'Aktif';
    final statusColor = (blocked || isExpired)
        ? (isDark ? Colors.red.shade300 : Colors.red.shade600)
        : NusaConfig.accentGreen;
    final tierLabel = info?.tier == 'trial'
        ? 'Trial'
        : info?.tier == '1month'
        ? '1 Bulan'
        : 'Lifetime';
    final expText = exp != null
        ? '${exp.day}/${exp.month}/${exp.year}'
        : 'Seumur hidup';
    // v2.2.44 (L4/L5): tampilkan CTA perpanjang kalau status bermasalah
    // ATAU mendekati habis (H-7). Lifetime (exp null) tidak perlu.
    final needsRenew =
        blocked ||
        isExpired ||
        (exp != null && exp.isBefore(now.add(const Duration(days: 7))));

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark
                      ? NusaConfig.darkDivider
                      : NusaConfig.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.key, color: statusColor, size: 20),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Lisensi',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Activation key
              const Text(
                'Kode Aktivasi',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: isDark
                      ? NusaConfig.darkSurface2
                      : NusaConfig.backgroundColor,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isDark
                        ? NusaConfig.darkBorder
                        : NusaConfig.borderColor,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _activationKey ?? '-',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 14,
                        ),
                      ),
                    ),
                    if (_activationKey != null)
                      GestureDetector(
                        onTap: () {
                          Clipboard.setData(
                            ClipboardData(text: _activationKey!),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Kode aktivasi disalin'),
                              behavior: SnackBarBehavior.floating,
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                        child: Icon(
                          Icons.copy,
                          size: 18,
                          color: isDark
                              ? NusaConfig.darkTextSecondary
                              : NusaConfig.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // v2.2.44 (L5): status + tier + expiry nyata.
              Row(
                children: [
                  Icon(Icons.check_circle, size: 14, color: statusColor),
                  const SizedBox(width: 6),
                  Text(
                    'Status: $statusText',
                    style: TextStyle(
                      fontSize: 13,
                      color: statusColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.card_membership_outlined,
                    size: 14,
                    color: isDark
                        ? NusaConfig.darkTextSecondary
                        : NusaConfig.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Paket: $tierLabel',
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark
                          ? NusaConfig.darkTextSecondary
                          : NusaConfig.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.event_outlined,
                    size: 14,
                    color: isDark
                        ? NusaConfig.darkTextSecondary
                        : NusaConfig.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Berlaku sampai: $expText',
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark
                          ? NusaConfig.darkTextSecondary
                          : NusaConfig.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // v2.2.44 (L4/L5): CTA perpanjang/beli — buka /pay (lih. needsRenew).
              if (needsRenew)
                ElevatedButton.icon(
                  onPressed: () async {
                    final googleId = await GoogleAuthService.getStoredUserId();
                    final uri = Uri.parse(
                      googleId != null && googleId.isNotEmpty
                          ? NusaConfig.paymentLink(googleId, 'lifetime')
                          : '${NusaConfig.paymentUrl}?product=${NusaConfig.productId}',
                    );
                    if (await canLaunchUrl(uri)) {
                      await launchUrl(
                        uri,
                        mode: LaunchMode.externalApplication,
                      );
                    }
                  },
                  icon: const Icon(Icons.credit_card_outlined, size: 18),
                  label: Text(
                    (blocked || isExpired)
                        ? 'Perpanjang Lisensi'
                        : 'Perpanjang / Beli',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: NusaConfig.activePrimary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              const SizedBox(height: 12),

              // Backup button — cloud-only (upload ke Google Drive)
              if (NusaConfig.cloudEnabled)
                OutlinedButton.icon(
                  onPressed: _backingUp
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          _backupNow();
                        },
                  icon: _backingUp
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_upload_outlined, size: 18),
                  label: Text(_backingUp ? 'Menyimpan...' : 'Backup ke Cloud'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: NusaConfig.activePrimary,
                    side: BorderSide(color: NusaConfig.activePrimary),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              if (NusaConfig.cloudEnabled)
                const SizedBox(height: 6),
              if (NusaConfig.cloudEnabled)
                Text(
                  'Backup cloud tersimpan di akun Google Anda. Gunakan Sinkronisasi Cloud untuk upload/download manual.',
                style: TextStyle(
                  fontSize: 11,
                  color:
                      (isDark
                              ? NusaConfig.darkTextTertiary
                              : NusaConfig.textTertiary)
                          .withValues(alpha: 0.8),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  // ── Update Check ──────────────────────────────────────────

  /// Bottom-sheet riwayat update: sheet langsung terbuka (loading state),
  /// fetch GitHub berjalan di dalam sheet (initState) supaya tap terasa
  /// responsif. Tap kartu versi → changelog penuh expand. Offline/gagal →
  /// tampilkan versi lokal + pesan ramah.
  Future<void> _showUpdateHistory() async {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => const _UpdateHistorySheet(),
    );
  }

  /// Popup update. Bisa ditutup / diminimalkan kapan saja (tap luar, tombol
  /// back) — proses unduh tetap berjalan di latar belakang; buka lagi kapan
  /// saja untuk melihat progres.
  void _showUpdateDialog({bool autoStart = false}) {
    final info = _updateInfo;
    if (info == null || !info.hasUpdate) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.system_update,
                color: Colors.orange,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Update Tersedia',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: _downloadingUpdate
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Mengunduh update… ${(_updateDownloadProgress * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: _updateDownloadProgress > 0
                              ? _updateDownloadProgress
                              : null,
                          minHeight: 8,
                          backgroundColor: isDark
                              ? NusaConfig.darkSurface2
                              : NusaConfig.backgroundColor,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Jangan tutup aplikasi selama proses berjalan.',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? NusaConfig.darkTextTertiary
                              : NusaConfig.textTertiary,
                        ),
                      ),
                    ],
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Versi ${info.latestVersion} (build ${info.latestBuildNumber})',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    FutureBuilder<String>(
                      // v2.2.57+115: versi terpasang asli (PackageInfo).
                      future: SecureStore.installedVersionAndBuild(),
                      builder: (context, snap) {
                        final installed = snap.data ?? '';
                        return Text(
                          installed.isNotEmpty
                              ? 'Saat ini: $installed'
                              : 'Saat ini: v${NusaConfig.appVersion}+${NusaConfig.appBuildNumber}',
                          style: TextStyle(
                            fontSize: 13,
                            color: isDark
                                ? NusaConfig.darkTextSecondary
                                : NusaConfig.textSecondary,
                          ),
                        );
                      },
                    ),
                    if (info.fileSizeBytes != null &&
                        info.fileSizeBytes! > 0) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Ukuran: ${UpdateService.formatSize(info.fileSizeBytes)}',
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark
                              ? NusaConfig.darkTextSecondary
                              : NusaConfig.textSecondary,
                        ),
                      ),
                    ],
                    if (info.changelog != null &&
                        info.changelog!.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isDark
                              ? NusaConfig.darkSurface2
                              : NusaConfig.backgroundColor,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          info.changelog!,
                          style: TextStyle(
                            fontSize: 13,
                            color: isDark
                                ? NusaConfig.darkTextPrimary
                                : NusaConfig.textPrimary,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Text(
                      'Unduh APK langsung di aplikasi, lalu instal otomatis.',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark
                            ? NusaConfig.darkTextTertiary
                            : NusaConfig.textTertiary,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
        ),
        actions: _downloadingUpdate
            ? null
            : [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Nanti'),
                ),
                if (info.downloadUrl != null)
                  ElevatedButton.icon(
                    onPressed: () {
                      // Dialog TETAP terbuka selama unduh — berubah jadi
                      // tampilan progres langsung (tanpa tutup-buka lagi).
                      _startUpdateDownload();
                    },
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('Download & Update'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: NusaConfig.activePrimary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
              ],
      ),
    );
    if (autoStart) {
      _startUpdateDownload();
    }
  }

  /// Progres unduhan — baca dari provider global (satu sumber dengan
  /// dashboard & drawer notifikasi; realtime tanpa buka-tutup).
  bool get _downloadingUpdate => ref.read(updateProgressProvider).downloading;
  double get _updateDownloadProgress =>
      ref.read(updateProgressProvider).progress;

  /// Downloads the APK in-app with progress, then hands off to the system
  /// installer. On failure shows an error toast — the installed version is
  /// untouched (the partial file is deleted by downloadApk).
  Future<void> _startUpdateDownload() async {
    final info = _updateInfo;
    if (info == null || info.downloadUrl == null) return;
    if (!mounted) return;
    final notifier = ref.read(updateProgressProvider.notifier);
    notifier.startDownload(
      'nusa-${NusaConfig.productId.replaceFirst('nusa-', '')}-v${info.latestVersion ?? 'latest'}.apk',
    );
    try {
      final path = await UpdateService.downloadApk(
        url: info.downloadUrl!,
        variantId: NusaConfig.productId,
        version: info.latestVersion ?? 'latest',
        onProgress: (p) => notifier.updateProgress(p),
      );
      if (path == null) throw Exception('Gagal membuat file unduhan.');
      await UpdateService.installApk(path);
      notifier.done();
      if (mounted) {
        TopToast.success(
          context,
          'Instalasi dibuka. Selesaikan di layar sistem.',
        );
      }
    } catch (e) {
      debugPrint('[Settings] update download error: $e');
      notifier.fail('Gagal mengunduh update. Cek koneksi, lalu coba lagi.');
      if (mounted) {
        TopToast.error(
          context,
          'Gagal mengunduh update. Cek koneksi, lalu coba lagi.',
        );
      }
    }
  }

  // ── Receipt Settings ──────────────────────────────────────

  /// Dialog "Dalam Pengembangan" — dipakai fitur yang masih draft (v2.2.46:
  /// Kartu ID). Memberi tahu user fitur lagi dikerjakan, bukan hilang.
  void _showUnderDevelopment(BuildContext ctx, String featureName) {
    showDialog<void>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.construction, color: NusaConfig.accentGold, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                featureName,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        content: const Text(
          'Fitur ini masih dalam pengembangan.\n'
          'Desain sedang disiapkan — nantikan di update berikutnya.',
          style: TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: const Text('Oke'),
          ),
        ],
      ),
    );
  }

  Future<void> _showReceiptSettings() async {
    final db = ref.read(databaseProvider);
    final repo = ref.read(settingsRepoProvider);
    // SATU objek config — dibaca dari DB + SecureStore (satu sumber).
    final initial = await ReceiptConfig.load(db);
    final storeName = await repo.getStoreName();
    final headerCtrl = TextEditingController(text: initial.header);
    final subHeaderCtrl = TextEditingController(text: initial.subHeader);
    final footerCtrl = TextEditingController(text: initial.footer);
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        final setDark = Theme.of(ctx).brightness == Brightness.dark;
        // Draft config — setiap ubahan UI langsung update field di sini,
        // preview (ReceiptPreview) live-realtime dari draft ini.
        var draft = initial;
        // True saat ada ubahan yang belum disimpan (banner info).
        bool fontDirty = false;
        bool testPrinting = false;
        return StatefulBuilder(
          builder: (ctx, setSt) {
            // Preview data SAMPLE (spec W) — bukan mockup, dari renderer sama.
            final sample = ReceiptData.sample();
            return Container(
              decoration: BoxDecoration(
                color: setDark
                    ? NusaConfig.darkSurface
                    : NusaConfig.surfaceColor,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              padding: EdgeInsets.only(
                left: 24,
                right: 24,
                top: 16,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 40,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      margin: const EdgeInsets.symmetric(vertical: 8),
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: setDark
                            ? NusaConfig.darkDivider
                            : NusaConfig.dividerColor,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Title
                    Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: const Color(
                              0xFF10B981,
                            ).withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.receipt_long,
                            color: Color(0xFF10B981),
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'Pengaturan Struk',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: setDark
                                ? NusaConfig.darkTextPrimary
                                : NusaConfig.textPrimary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // ── Preview LIVE — dari SATU renderer (bukan mockup) ──
                    // v2.2.35: PREVIEW DI ATAS — user lihat hasil langsung
                    // sambil menggeser slider Header & Ukuran Logo.
                    Text(
                      'Preview',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: setDark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Preview = hasil cetak asli. Data contoh, ganti '
                      'pengaturan untuk melihat perubahannya langsung.',
                      style: TextStyle(
                        fontSize: 12,
                        color: setDark
                            ? NusaConfig.darkTextSecondary
                            : NusaConfig.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Preview 2 arah: lebar mengikuti ukuran kertas yang
                    // dipilih (58mm → ramping, 80mm → lebih lebar) — persis
                    // print asli. Boleh scroll vertikal (spec I).
                    Container(
                      alignment: Alignment.center,
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: setDark
                              ? NusaConfig.darkSurface2
                              : const Color(0xFFF3F4F6),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ReceiptPreview(
                          config: draft,
                          data: sample,
                          storeName: storeName.isNotEmpty
                              ? storeName
                              : 'NUSA MART',
                          dark: setDark,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Header — SLIDER 12–48px (image bit-image, preview = print).
                    Text(
                      'Header (px)',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: setDark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary,
                      ),
                    ),
                    Row(
                      children: [
                        Text(
                          '${receiptHeaderMinPx}',
                          style: TextStyle(
                            fontSize: 11,
                            color: setDark
                                ? NusaConfig.darkTextTertiary
                                : NusaConfig.textTertiary,
                          ),
                        ),
                        Expanded(
                          child: Slider(
                            value: draft.headerPx
                                .clamp(receiptHeaderMinPx, receiptHeaderMaxPx)
                                .toDouble(),
                            min: receiptHeaderMinPx.toDouble(),
                            max: receiptHeaderMaxPx.toDouble(),
                            divisions: receiptHeaderMaxPx - receiptHeaderMinPx,
                            activeColor: NusaConfig.activePrimary,
                            inactiveColor: setDark
                                ? NusaConfig.darkBorder
                                : NusaConfig.dividerColor,
                            label: '${draft.headerPx} px',
                            onChanged: (v) => setSt(() {
                              draft = draft.copyWith(headerPx: v.round());
                              fontDirty = true;
                            }),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: NusaConfig.primarySoft,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${draft.headerPx} px',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: NusaConfig.activePrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    const SizedBox(height: 14),

                    // ── Ukuran Logo (slider 1–100%) ──
                    Text(
                      'Ukuran Logo',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: setDark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary,
                      ),
                    ),
                    Row(
                      children: [
                        Text(
                          '1%',
                          style: TextStyle(
                            fontSize: 11,
                            color: setDark
                                ? NusaConfig.darkTextTertiary
                                : NusaConfig.textTertiary,
                          ),
                        ),
                        Expanded(
                          child: Slider(
                            value: draft.logoWidthPercent
                                .clamp(1, 100)
                                .toDouble(),
                            min: 1,
                            max: 100,
                            divisions: 99,
                            activeColor: NusaConfig.activePrimary,
                            inactiveColor: setDark
                                ? NusaConfig.darkBorder
                                : NusaConfig.dividerColor,
                            label: '${draft.logoWidthPercent}%',
                            onChanged: (v) => setSt(() {
                              draft = draft.copyWith(
                                logoWidthPercent: v.round(),
                              );
                              fontDirty = true;
                            }),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: NusaConfig.primarySoft,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${draft.logoWidthPercent}%',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: NusaConfig.activePrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    const SizedBox(height: 20),

                    // ── Ukuran Kertas ──
                    Text(
                      'Ukuran Kertas',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: setDark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _paperChip(
                          '58mm',
                          '${draft.paperWidth}mm',
                          setDark,
                          onTap: () => setSt(() {
                            draft = draft.copyWith(paperWidth: '58');
                            fontDirty = true;
                          }),
                        ),
                        const SizedBox(width: 10),
                        _paperChip(
                          '80mm',
                          '${draft.paperWidth}mm',
                          setDark,
                          onTap: () => setSt(() {
                            draft = draft.copyWith(paperWidth: '80');
                            fontDirty = true;
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // ── Jenis Font ──
                    Text(
                      'Jenis Font',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: setDark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Standar = huruf universal & paling kompatibel semua printer. '
                      'Ramping = huruf lebih ramping, muat lebih banyak per baris.',
                      style: TextStyle(
                        fontSize: 12,
                        color: setDark
                            ? NusaConfig.darkTextSecondary
                            : NusaConfig.textSecondary,
                      ),
                    ),
                    if (draft.fontType == 'kompak') ...[
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF4E5),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFF0B429)),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.warning_amber_rounded,
                              size: 16,
                              color: Color(0xFFB7791F),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Beberapa printer murah (klon VSC) mencetak '
                                'huruf Ramping KOSONG. Kalau hasilnya blank, '
                                'kembali ke Standar.',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: const Color(0xFF7C4A03),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _fontTypeChip(
                          'Standar',
                          Icons.text_fields,
                          draft.fontType,
                          setDark,
                          subtitle: 'Paling kompatibel',
                          onTap: () => setSt(() {
                            draft = draft.copyWith(fontType: 'standar');
                            fontDirty = true;
                          }),
                        ),
                        const SizedBox(width: 10),
                        _fontTypeChip(
                          'Ramping',
                          Icons.text_snippet_outlined,
                          draft.fontType,
                          setDark,
                          subtitle: 'Huruf ramping',
                          onTap: () => setSt(() {
                            draft = draft.copyWith(fontType: 'kompak');
                            fontDirty = true;
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // ── Ukuran Font ──
                    Text(
                      'Ukuran Font',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: setDark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Header dicetak sebagai GAMBAR (persis logo) — atur '
                      'tinggi huruf 12–48 piksel + ketebalan. Rincian & '
                      'Footer selalu ukuran Kecil (×1).',
                      style: TextStyle(
                        fontSize: 12,
                        color: setDark
                            ? NusaConfig.darkTextSecondary
                            : NusaConfig.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Header — KETEBALAN thin/medium/bold (v2.2.27).
                    Text(
                      'Ketebalan Header',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: setDark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        for (final w in const [
                          ('thin', 'Tipis'),
                          ('medium', 'Sedang'),
                          ('bold', 'Tebal'),
                        ]) ...[
                          Expanded(
                            child: GestureDetector(
                              onTap: () => setSt(() {
                                draft = draft.copyWith(headerWeight: w.$1);
                                fontDirty = true;
                              }),
                              child: Container(
                                margin: const EdgeInsets.only(right: 6),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: draft.headerWeight == w.$1
                                      ? NusaConfig.primarySoft
                                      : (setDark
                                            ? NusaConfig.darkSurface2
                                            : const Color(0xFFF3F4F6)),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: draft.headerWeight == w.$1
                                        ? NusaConfig.activePrimary
                                        : (setDark
                                              ? NusaConfig.darkBorder
                                              : NusaConfig.dividerColor),
                                  ),
                                ),
                                child: Center(
                                  child: Text(
                                    w.$2,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: draft.headerWeight == w.$1
                                          ? NusaConfig.activePrimary
                                          : (setDark
                                                ? NusaConfig.darkTextSecondary
                                                : NusaConfig.textSecondary),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 14),

                    // Rincian & Footer SELALU ukuran Kecil (×1) — v2.2.27.
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Rincian & Footer',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: NusaConfig.primarySoft,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            'Kecil (×1)',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: NusaConfig.activePrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // ── Logo Struk ──
                    Text(
                      'Logo Struk',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: setDark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: setDark
                                ? NusaConfig.darkSurface2
                                : const Color(0xFFF3F4F6),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: setDark
                                  ? NusaConfig.darkBorder
                                  : NusaConfig.dividerColor,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child:
                              draft.logoPath != null &&
                                  draft.logoPath!.isNotEmpty
                              ? Image.file(
                                  File(draft.logoPath!),
                                  fit: BoxFit.contain,
                                  cacheWidth: 200,
                                )
                              : Icon(
                                  Icons.image_outlined,
                                  color: setDark
                                      ? NusaConfig.darkTextTertiary
                                      : NusaConfig.textTertiary,
                                ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (draft.logoPath != null &&
                                  draft.logoPath!.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Text(
                                    'Logo tampil di atas struk',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: setDark
                                          ? NusaConfig.darkTextSecondary
                                          : NusaConfig.textSecondary,
                                    ),
                                  ),
                                ),
                              Row(
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: () async {
                                      final path = await pickAndSaveImage(
                                        maxSize: 512,
                                        prefix: 'store_logo_',
                                      );
                                      if (path != null) {
                                        setSt(() {
                                          draft = draft.copyWith(
                                            logoPath: path,
                                          );
                                          fontDirty = true;
                                        });
                                      }
                                    },
                                    icon: const Icon(
                                      Icons.photo_library_outlined,
                                      size: 18,
                                    ),
                                    label: Text(
                                      draft.logoPath != null &&
                                              draft.logoPath!.isNotEmpty
                                          ? 'Ganti'
                                          : 'Pilih Logo',
                                    ),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: NusaConfig.activePrimary,
                                      side: BorderSide(
                                        color: NusaConfig.activePrimary,
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 8,
                                      ),
                                      textStyle: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  if (draft.logoPath != null &&
                                      draft.logoPath!.isNotEmpty) ...[
                                    const SizedBox(width: 8),
                                    TextButton(
                                      onPressed: () => setSt(() {
                                        draft = draft.copyWith(logoPath: null);
                                        fontDirty = true;
                                      }),
                                      child: const Text(
                                        'Hapus',
                                        style: TextStyle(fontSize: 12),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // ── Posisi Logo (kiri/tengah/kanan) ──
                    Text(
                      'Posisi Logo',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: setDark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        for (final a in const [
                          ('left', Icons.format_align_left, 'Kiri'),
                          ('center', Icons.format_align_center, 'Tengah'),
                          ('right', Icons.format_align_right, 'Kanan'),
                        ]) ...[
                          Expanded(
                            child: GestureDetector(
                              onTap: () => setSt(() {
                                draft = draft.copyWith(logoAlign: a.$1);
                                fontDirty = true;
                              }),
                              child: Container(
                                margin: const EdgeInsets.only(right: 6),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: draft.logoAlign == a.$1
                                      ? NusaConfig.primarySoft
                                      : (setDark
                                            ? NusaConfig.darkSurface2
                                            : const Color(0xFFF3F4F6)),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: draft.logoAlign == a.$1
                                        ? NusaConfig.activePrimary
                                        : (setDark
                                              ? NusaConfig.darkBorder
                                              : NusaConfig.dividerColor),
                                  ),
                                ),
                                child: Column(
                                  children: [
                                    Icon(
                                      a.$2,
                                      size: 18,
                                      color: draft.logoAlign == a.$1
                                          ? NusaConfig.activePrimary
                                          : (setDark
                                                ? NusaConfig.darkTextSecondary
                                                : NusaConfig.textSecondary),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      a.$3,
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        color: draft.logoAlign == a.$1
                                            ? NusaConfig.activePrimary
                                            : (setDark
                                                  ? NusaConfig.darkTextSecondary
                                                  : NusaConfig.textSecondary),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 20),

                    // ── Header Struk ──
                    Text(
                      'Header Struk',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: setDark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    NusaInput(
                      'Header',
                      controller: headerCtrl,
                      hint: 'Cth: NUSA MART - Cabang Pusat',
                      onChanged: (v) => setSt(() {
                        draft = draft.copyWith(header: v);
                        fontDirty = true;
                      }),
                    ),
                    const SizedBox(height: 20),

                    // ── Sub-header Struk (alamat toko — v2.2.30) ──
                    Text(
                      'Sub-header (Alamat)',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: setDark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Baris teks kecil di bawah nama toko — biasanya alamat.',
                      style: TextStyle(
                        fontSize: 12,
                        color: setDark
                            ? NusaConfig.darkTextTertiary
                            : NusaConfig.textTertiary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: setDark
                            ? NusaConfig.darkInputFill
                            : NusaConfig.inputFill,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: setDark
                              ? NusaConfig.darkInputBorder
                              : NusaConfig.inputBorder,
                        ),
                      ),
                      child: TextField(
                        controller: subHeaderCtrl,
                        maxLines: 2,
                        onChanged: (v) => setSt(() {
                          draft = draft.copyWith(subHeader: v);
                          fontDirty = true;
                        }),
                        style: TextStyle(
                          color: setDark
                              ? NusaConfig.darkTextPrimary
                              : NusaConfig.textPrimary,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Cth: Jl. Merdeka No. 1, Jakarta',
                          hintStyle: TextStyle(
                            color: setDark
                                ? NusaConfig.darkTextTertiary
                                : NusaConfig.textTertiary,
                          ),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.all(14),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // ── Footer Struk ──
                    Text(
                      'Footer Struk',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: setDark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: setDark
                            ? NusaConfig.darkInputFill
                            : NusaConfig.inputFill,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: setDark
                              ? NusaConfig.darkInputBorder
                              : NusaConfig.inputBorder,
                        ),
                      ),
                      child: TextField(
                        controller: footerCtrl,
                        maxLines: 3,
                        onChanged: (v) => setSt(() {
                          draft = draft.copyWith(footer: v);
                          fontDirty = true;
                        }),
                        style: TextStyle(
                          color: setDark
                              ? NusaConfig.darkTextPrimary
                              : NusaConfig.textPrimary,
                        ),
                        decoration: InputDecoration(
                          hintText:
                              'Terima kasih, ditunggu pesanan selanjutnya!',
                          hintStyle: TextStyle(
                            color: setDark
                                ? NusaConfig.darkTextTertiary
                                : NusaConfig.textTertiary,
                          ),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.all(14),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Footer templates
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _footerChip(
                          '🙏 Terima kasih, ditunggu pesanan selanjutnya!',
                          footerCtrl,
                          setSt,
                        ),
                        _footerChip(
                          '🔄 Barang yang sudah dibeli tidak dapat ditukar.',
                          footerCtrl,
                          setSt,
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // ── Tampilkan di Struk ──
                    Text(
                      'Tampilkan di Struk',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: setDark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _toggleRow(
                      'Logo toko',
                      draft.showLogo,
                      setDark,
                      (v) => setSt(() {
                        draft = draft.copyWith(showLogo: v);
                        fontDirty = true;
                      }),
                    ),
                    _toggleRow(
                      'Nama kasir',
                      draft.showCashier,
                      setDark,
                      (v) => setSt(() {
                        draft = draft.copyWith(showCashier: v);
                        fontDirty = true;
                      }),
                    ),
                    _toggleRow(
                      'Nomor invoice',
                      draft.showInvoice,
                      setDark,
                      (v) => setSt(() {
                        draft = draft.copyWith(showInvoice: v);
                        fontDirty = true;
                      }),
                    ),
                    _toggleRow(
                      'Tanggal & jam',
                      draft.showDate,
                      setDark,
                      (v) => setSt(() {
                        draft = draft.copyWith(showDate: v);
                        fontDirty = true;
                      }),
                    ),
                    const SizedBox(height: 20),

                    // Banner: preview berubah tapi belum tersimpan.
                    if (fontDirty)
                      Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF4E5),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFF0B429)),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.info_outline,
                              size: 16,
                              color: Color(0xFFB7791F),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Preview berubah — tekan Simpan agar ukuran font tercetak.',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: const Color(0xFF7C4A03),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                    // ── Aksi: Tes Cetak (kiri) + Simpan (kanan) ──
                    // Tes Cetak memakai draft config SEKARANG (belum disimpan)
                    // supaya user verifikasi ukuran header yang benar-benar
                    // tercetak di kertas sebelum Simpan.
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(48),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              side: BorderSide(
                                color: NusaConfig.activePrimary.withValues(
                                  alpha: 0.5,
                                ),
                              ),
                              foregroundColor: NusaConfig.activePrimary,
                            ),
                            onPressed: testPrinting
                                ? null
                                : () async {
                                    setSt(() => testPrinting = true);
                                    final printer = ReceiptPrinter();
                                    try {
                                      if (!await ReceiptPrinter.ensureBluetoothReady()) {
                                        TopToast.error(
                                          ctx,
                                          'Bluetooth tidak siap. Periksa izin pengaturan.',
                                        );
                                        return;
                                      }
                                      final devices = await printer.discover();
                                      final savedAddr =
                                          await SecureStore.getPrinterAddress();
                                      final addr =
                                          savedAddr != null &&
                                              savedAddr.contains('|')
                                          ? savedAddr.split('|').last
                                          : null;
                                      final found = addr != null
                                          ? devices
                                                .where((d) => d.address == addr)
                                                .toList()
                                          : <dynamic>[];
                                      if (found.isEmpty) {
                                        TopToast.error(
                                          ctx,
                                          'Printer belum terhubung. Buka Pengaturan Printer untuk memindai.',
                                        );
                                        return;
                                      }
                                      await printer.connect(found.first);
                                      final ok = await printer.printTest(
                                        storeName,
                                        paperWidth: draft.paperWidth,
                                        config: draft,
                                      );
                                      if (ctx.mounted) {
                                        if (ok) {
                                          TopToast.success(
                                            ctx,
                                            'Tes cetak dikirim — cek hasil di kertas.',
                                          );
                                        } else {
                                          TopToast.error(
                                            ctx,
                                            'Gagal mengirim tes cetak',
                                          );
                                        }
                                      }
                                    } catch (_) {
                                      if (ctx.mounted) {
                                        TopToast.error(
                                          ctx,
                                          'Gagal mencetak: pastikan printer menyala dan terhubung',
                                        );
                                      }
                                    } finally {
                                      await printer.dispose();
                                      if (ctx.mounted) {
                                        setSt(() => testPrinting = false);
                                      }
                                    }
                                  },
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (testPrinting)
                                  SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: NusaConfig.activePrimary,
                                    ),
                                  )
                                else
                                  Icon(
                                    Icons.print_outlined,
                                    size: 18,
                                    color: NusaConfig.activePrimary,
                                  ),
                                const SizedBox(width: 8),
                                Text(
                                  testPrinting ? 'Mencetak…' : 'Tes Cetak',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: NusaConfig.activePrimary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: NusaButton(
                            'Simpan',
                            onPressed: () async {
                              // SATU titik tulis: simpan draft ke DB +
                              // SecureStore sekaligus (ganti mirror manual).
                              await draft
                                  .copyWith(
                                    header: headerCtrl.text,
                                    subHeader: subHeaderCtrl.text,
                                    footer: footerCtrl.text,
                                  )
                                  .save(db);
                              if (mounted) Navigator.pop(ctx);
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ── Receipt helpers ──────────────────────────────────────

  Widget _paperChip(
    String label,
    String current,
    bool isDark, {
    required VoidCallback onTap,
  }) {
    final selected = current == label;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: selected
                ? NusaConfig.primarySoft
                : (isDark ? NusaConfig.darkSurface2 : const Color(0xFFF3F4F6)),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? NusaConfig.activePrimary
                  : (isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor),
            ),
          ),
          child: Column(
            children: [
              Icon(
                selected ? Icons.check_circle : Icons.print,
                size: 20,
                color: selected
                    ? NusaConfig.activePrimary
                    : (isDark
                          ? NusaConfig.darkTextSecondary
                          : NusaConfig.textSecondary),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: selected
                      ? NusaConfig.activePrimary
                      : (isDark
                            ? NusaConfig.darkTextSecondary
                            : NusaConfig.textSecondary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toggleRow(
    String label,
    bool value,
    bool isDark,
    ValueChanged<bool> onChanged,
  ) {
    return SwitchListTile(
      title: Text(
        label,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
      value: value,
      dense: true,
      contentPadding: EdgeInsets.zero,
      activeColor: NusaConfig.activePrimary,
      onChanged: onChanged,
    );
  }

  /// Chip pilihan jenis font struk (Standar / Ramping).
  Widget _fontTypeChip(
    String label,
    IconData icon,
    String current,
    bool isDark, {
    String? subtitle,
    required VoidCallback onTap,
  }) {
    final selected = current == (label == 'Standar' ? 'standar' : 'kompak');
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
          decoration: BoxDecoration(
            color: selected
                ? NusaConfig.primarySoft
                : (isDark ? NusaConfig.darkSurface2 : const Color(0xFFF3F4F6)),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? NusaConfig.activePrimary
                  : (isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor),
            ),
          ),
          child: Column(
            children: [
              Icon(
                selected ? Icons.check_circle : icon,
                size: 20,
                color: selected
                    ? NusaConfig.activePrimary
                    : (isDark
                          ? NusaConfig.darkTextSecondary
                          : NusaConfig.textSecondary),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: selected
                      ? NusaConfig.activePrimary
                      : (isDark
                            ? NusaConfig.darkTextSecondary
                            : NusaConfig.textSecondary),
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10,
                    color: isDark
                        ? NusaConfig.darkTextTertiary
                        : NusaConfig.textTertiary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _footerChip(
    String text,
    TextEditingController ctrl,
    StateSetter setSt,
  ) {
    return GestureDetector(
      onTap: () {
        ctrl.text = text;
        setSt(() {});
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: NusaConfig.primarySoft,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          text,
          style: TextStyle(fontSize: 11, color: NusaConfig.activePrimary),
        ),
      ),
    );
  }

  // ── About Link ────────────────────────────────────────────

  Widget _aboutLink(String label, String url) {
    return GestureDetector(
      onTap: () {
        try {
          launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        } catch (_) {}
      },
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          color: NusaConfig.activePrimary,
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }

  // ── Feedback in-app (Laporkan / Saran) ──────────────────────

  void _showFeedbackSheet() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final appLabel =
        '${NusaConfig.appName} Kasir v${NusaConfig.appVersion}+${NusaConfig.appBuildNumber}';
    // Feedback dikirim ke WhatsApp (bukan GitHub) — pengguna NUSA kebanyakan
    // awam; generate link WA langsung ke 08976280303 sesuai teks yang diketik.
    final feedbackCtrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.fromLTRB(
          20,
          10,
          20,
          MediaQuery.of(ctx).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark
                      ? NusaConfig.darkBorder
                      : NusaConfig.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(Icons.feedback_outlined, color: NusaConfig.activePrimary),
                const SizedBox(width: 10),
                Text(
                  'Bantuan & Masukan',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Laporkan masalah atau usulkan fitur. Ketik di bawah, lalu kirim — '
              'langsung masuk ke WhatsApp kami ($appLabel).',
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: isDark
                    ? NusaConfig.darkTextSecondary
                    : NusaConfig.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            // ── Text input — isi otomatis teks WA sesuai yang diketik ──
            Container(
              decoration: BoxDecoration(
                color: isDark ? NusaConfig.darkInputFill : NusaConfig.inputFill,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isDark
                      ? NusaConfig.darkInputBorder
                      : NusaConfig.inputBorder,
                ),
              ),
              child: TextField(
                controller: feedbackCtrl,
                maxLines: 4,
                minLines: 3,
                style: TextStyle(
                  color: isDark
                      ? NusaConfig.darkTextPrimary
                      : NusaConfig.textPrimary,
                ),
                decoration: InputDecoration(
                  hintText:
                      'Contoh: Tombol kasir tidak merespons… / Ide: tambah mode malam…',
                  hintStyle: TextStyle(
                    fontSize: 13,
                    color: isDark
                        ? NusaConfig.darkTextTertiary
                        : NusaConfig.textTertiary,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.all(14),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // ── Tombol kirim — WA (bug/saran) + chat langsung ──
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: () {
                  final text = feedbackCtrl.text.trim();
                  if (text.isEmpty) {
                    TopToast.error(context, 'Tulis pesan dulu ya');
                    return;
                  }
                  final msg = '$text\n\n— $appLabel';
                  Navigator.pop(ctx);
                  _launch(
                    'https://wa.me/628976280303?text=${Uri.encodeComponent(msg)}',
                  );
                },
                icon: const Icon(Icons.send, size: 18),
                label: const Text(
                  'Kirim via WhatsApp',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF25D366),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  elevation: 0,
                ),
              ),
            ),
            const SizedBox(height: 10),
            _feedbackTile(
              ctx,
              icon: Icons.chat_outlined,
              color: const Color(0xFF25D366),
              title: 'Chat WhatsApp langsung',
              subtitle: 'Tanya apa saja ke tim NUSA',
              onTap: () {
                Navigator.pop(ctx);
                _launch(
                  'https://wa.me/628976280303?text=${Uri.encodeComponent('Halo, saya pengguna $appLabel. ')}',
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _feedbackTile(
    BuildContext ctx, {
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(ctx).brightness == Brightness.dark
                            ? NusaConfig.darkTextSecondary
                            : NusaConfig.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: Theme.of(ctx).brightness == Brightness.dark
                    ? NusaConfig.darkTextTertiary
                    : NusaConfig.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _launch(String url) {
    try {
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  // v2.2.53: buka daftar tutorial dari cloud (tabel `tutorials`, via dashboard).
  void _openTutorial() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const TutorialScreen()));
  }

  // ═══════════════════════════════════════════════════════════
  //  BUILD
  // ═══════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final session = ref.watch(employeeSessionProvider);

    return ScreenScaffold(
      'Pengaturan',
      SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ════════════════════════════════════════════════════════════════════════════════════════════════
            //  TOKO
            // ════════════════════════════════════════════════════════════════════════════════════════════════
            _sectionHeader('TOKO', isDark),
            // v2.2.57+112: baris menu dibungkus card group (Material 3).
            // "Informasi Toko" inline pindah ke layar Data Toko (/data_toko).
            _groupCard(
              isDark: isDark,
              tiles: [
                _menuTile(
                  icon: Icons.storefront_outlined,
                  title: 'Data Toko',
                  subtitle: 'Nama toko, alamat, no. HP, pemilik',
                  isDark: isDark,
                  onTap: () => context.push('/data_toko'),
                ),
                _menuTile(
                  icon: Icons.shopping_bag_outlined,
                  title: 'Toko Online',
                  subtitle: 'Aktifkan & atur toko online (Vercel)',
                  isDark: isDark,
                  onTap: () => context.push('/toko_online_setup'),
                ),
                _menuTile(
                  icon: Icons.badge_outlined,
                  title: 'Kartu ID',
                  subtitle: 'Cetak kartu member & karyawan (segera hadir)',
                  isDark: isDark,
                  onTap: () => _showUnderDevelopment(context, 'Kartu ID'),
                ),
                _menuTile(
                  icon: Icons.payment,
                  title: 'Pembayaran',
                  subtitle: 'Atur QRIS & rekening bank untuk transfer',
                  isDark: isDark,
                  onTap: () => context.push('/pengaturan_pembayaran'),
                ),
                _menuTile(
                  icon: Icons.receipt_long,
                  title: 'Pengaturan Struk',
                  subtitle: 'Atur footer struk & upload logo toko',
                  isDark: isDark,
                  onTap: _showReceiptSettings,
                ),
                // Alur Pembayaran — FnB only
                if (NusaConfig.isFnbVariant)
                  _menuTile(
                    icon: Icons.swap_horiz,
                    title: 'Alur Pembayaran',
                    subtitle: _fnbPayFirst
                        ? 'Bayar dulu di kasir, baru pilih meja'
                        : 'Pesan dulu, duduk di meja, bayar setelah selesai',
                    isDark: isDark,
                    onTap: null, // toggle handled by trailing switch
                    trailing: Switch(
                      value: _fnbPayFirst,
                      activeColor: NusaConfig.activePrimary,
                      onChanged: (_) => _toggleFnbPayFirst(),
                    ),
                  ),
              ],
            ),
            // ════════════════════════════════════════════════════════════════════════════════════════════════
            //  TAMPILAN
            // ════════════════════════════════════════════════════════════════════════════════════════════════
            _sectionHeader('TAMPILAN', isDark),
            _groupCard(
              isDark: isDark,
              tiles: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Tema',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          _themeChip(
                            'Terang',
                            'light',
                            Icons.light_mode,
                            isDark,
                          ),
                          const SizedBox(width: 8),
                          _themeChip('Gelap', 'dark', Icons.dark_mode, isDark),
                          const SizedBox(width: 8),
                          _themeChip(
                            'Sistem',
                            'system',
                            Icons.phone_android,
                            isDark,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Divider(
                  height: 1,
                  thickness: 1,
                  indent: 16,
                  endIndent: 16,
                  color: isDark
                      ? NusaConfig.darkDivider
                      : NusaConfig.dividerColor,
                ),
                _menuTile(
                  icon: Icons.palette_outlined,
                  title: 'Tema Warna',
                  subtitle: _currentThemeLabel(),
                  isDark: isDark,
                  onTap: _showThemePicker,
                ),
              ],
            ),

            // ════════════════════════════════════════════════════════════════════════════════════════════════
            //  KEAMANAN
            // ════════════════════════════════════════════════════════════════════════════════════════════════
            _sectionHeader('KEAMANAN', isDark),
            _groupCard(
              isDark: isDark,
              tiles: [
                _menuTile(
                  icon: Icons.toggle_on_outlined,
                  title: 'Kelola Fitur',
                  subtitle: 'Atur fitur yang tampil di Home Screen',
                  isDark: isDark,
                  onTap: () => _pinGate(_showFeatureToggles),
                  trailing: Icon(
                    Icons.lock_outline,
                    size: 16,
                    color: isDark
                        ? NusaConfig.darkTextSecondary
                        : NusaConfig.textSecondary,
                  ),
                ),
                _menuTile(
                  icon: Icons.pin_outlined,
                  title: 'PIN Kasir di Kasir',
                  subtitle: _pinPadEnabled
                      ? 'Kasir wajib PIN saat buka fitur & kasir'
                      : 'Kasir buka tanpa PIN (login tetap butuh PIN)',
                  isDark: isDark,
                  onTap: null, // toggle handled by trailing switch
                  trailing: Switch(
                    value: _pinPadEnabled,
                    activeColor: NusaConfig.activePrimary,
                    onChanged: (_) => _togglePinPad(),
                  ),
                ),
                // Dev: Pilih Varian (only in dev build)
                if (NusaConfig.isDevBuild)
                  _menuTile(
                    icon: Icons.apps_rounded,
                    title: 'Pilih Varian',
                    subtitle:
                        'Switch ke variant lain (${NusaConfig.productId.replaceFirst('nusa-', '')})',
                    isDark: isDark,
                    onTap: () => _pinGate(() => context.go('/variant-picker')),
                    trailing: Icon(
                      Icons.lock_outline,
                      size: 16,
                      color: isDark
                          ? NusaConfig.darkTextSecondary
                          : NusaConfig.textSecondary,
                    ),
                  ),
                _menuTile(
                  icon: Icons.key,
                  title: 'Lisensi',
                  subtitle: _activationKey != null
                      ? 'Terverifikasi'
                      : 'Belum diaktivasi',
                  isDark: isDark,
                  onTap: () => _pinGate(_showLicense),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_activationKey != null)
                        Icon(
                          Icons.check_circle,
                          size: 14,
                          color: NusaConfig.activePrimary,
                        ),
                      const SizedBox(width: 6),
                      Icon(
                        Icons.lock_outline,
                        size: 16,
                        color: isDark
                            ? NusaConfig.darkTextSecondary
                            : NusaConfig.textSecondary,
                      ),
                    ],
                  ),
                ),
              ],
            ),

            // ════════════════════════════════════════════════════════════════════════════════════════════════
            //  DATA
            // ════════════════════════════════════════════════════════════════════════════════════════════════
            _sectionHeader('DATA', isDark),
            _groupCard(
              isDark: isDark,
              tiles: [
                _menuTile(
                  icon: Icons.backup,
                  title: 'Backup & Restore',
                  subtitle: 'Simpan atau muat file database',
                  isDark: isDark,
                  onTap: () => showBackupSheet(context, ref),
                ),
                if (NusaConfig.cloudEnabled)
                  _menuTile(
                    icon: Icons.cloud_sync,
                    title: 'Sinkronisasi Cloud',
                    subtitle: 'Upload / Download antar perangkat via Google',
                    isDark: isDark,
                    onTap: () => _showCloudSync(),
                  ),
              ],
            ),

            // ════════════════════════════════════════════════════════════════════════════════════════════════
            //  NOTIFIKASI
            // ════════════════════════════════════════════════════════════════════════════════════════════════
            _sectionHeader('NOTIFIKASI', isDark),
            _groupCard(
              isDark: isDark,
              tiles: [
                _menuTile(
                  icon: Icons.volume_up_outlined,
                  title: 'Suara Aplikasi',
                  subtitle: _soundEnabled
                      ? 'Aktif — bunyi transaksi berhasil, scan, presensi, dll.'
                      : 'Dimatikan — app berjalan tanpa bunyi',
                  isDark: isDark,
                  onTap: null,
                  trailing: Switch(
                    value: _soundEnabled,
                    activeColor: NusaConfig.activePrimary,
                    onChanged: (v) async {
                      await SecureStore.setSoundEnabled(v);
                      setState(() => _soundEnabled = v);
                    },
                  ),
                ),
                _menuTile(
                  icon: Icons.notifications_active_outlined,
                  title: 'Fitur Panggil',
                  subtitle: _callFeatureEnabled
                      ? 'Aktif — owner bisa membunyikan device ini saat dibutuhkan'
                      : 'Dimatikan — device tidak menerima panggilan',
                  isDark: isDark,
                  onTap: null,
                  trailing: Switch(
                    value: _callFeatureEnabled,
                    activeColor: NusaConfig.activePrimary,
                    onChanged: (v) async {
                      await SecureStore.setCallFeatureEnabled(v);
                      setState(() => _callFeatureEnabled = v);
                      // Re-join / keluar channel Realtime sesuai toggle.
                      try {
                        if (v) {
                          await CallService.I.start();
                        } else {
                          await CallService.I.stop();
                        }
                      } catch (_) {}
                    },
                  ),
                ),
                // Login Biometrik — Owner only, direct toggle
                if (session?.role == 'Owner')
                  _menuTile(
                    icon: Icons.fingerprint,
                    title: 'Login Biometrik',
                    subtitle: _fingerprintEnabled
                        ? 'Aktif — akses cepat pakai sidik jari / Face ID'
                        : 'Aktifkan akses cepat Owner',
                    isDark: isDark,
                    onTap: () => _toggleFingerprint(session!),
                    trailing: Switch(
                      value: _fingerprintEnabled,
                      activeColor: NusaConfig.activePrimary,
                      onChanged: (v) => _toggleFingerprint(session!),
                    ),
                  ),
                // Salon settings
                if (NusaConfig.isSalonVariant) ...[
                  _menuTile(
                    icon: Icons.timer_outlined,
                    title: 'Estimasi Default',
                    subtitle:
                        '$_salonDefaultDuration menit — durasi estimasi standar per booking',
                    isDark: isDark,
                    onTap: () async {
                      final opts = [30, 45, 60, 90, 120];
                      final current = _salonDefaultDuration;
                      final sel = await showModalBottomSheet<String>(
                        context: context,
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.vertical(
                            top: Radius.circular(20),
                          ),
                        ),
                        builder: (ctx) => Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                'Estimasi Default',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 12),
                              ...opts.map(
                                (o) => ListTile(
                                  title: Text('$o menit'),
                                  trailing: o == current
                                      ? Icon(
                                          Icons.check,
                                          color: NusaConfig.activePrimary,
                                        )
                                      : null,
                                  onTap: () => Navigator.pop(ctx, '$o'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                      if (sel != null && mounted) {
                        final v = int.parse(sel);
                        await SecureStore.setSalonDefaultDuration(v);
                        setState(() => _salonDefaultDuration = v);
                      }
                    },
                  ),
                  _menuTile(
                    icon: Icons.notifications_outlined,
                    title: 'Notifikasi Booking',
                    subtitle: _salonNotifyBooking
                        ? 'Notif H-30 menit sebelum booking'
                        : 'Notifikasi dimatikan',
                    isDark: isDark,
                    onTap: null,
                    trailing: Switch(
                      value: _salonNotifyBooking,
                      activeColor: NusaConfig.activePrimary,
                      onChanged: (v) async {
                        await SecureStore.setSalonNotifyBooking(v);
                        setState(() => _salonNotifyBooking = v);
                      },
                    ),
                  ),
                ],
              ],
            ),

            // ════════════════════════════════════════════════════════════════════════════════════════════════
            //  PERANGKAT
            // ════════════════════════════════════════════════════════════════════════════════════════════════
            _sectionHeader('PERANGKAT', isDark),
            _groupCard(
              isDark: isDark,
              tiles: [
                _menuTile(
                  icon: Icons.print,
                  title: 'Printer',
                  subtitle: _printerName != null
                      ? _printerName!.split('|').first
                      : 'Atur printer thermal',
                  isDark: isDark,
                  onTap: () => PrinterSettingsSheet.show(
                    context: context,
                    currentAddress: _printerName,
                    onPrinterSelected: (d) async {
                      await ref
                          .read(settingsRepoProvider)
                          .setPrinterAddress('${d.name}|${d.address}');
                      // Mirror into SecureStore — single source of truth for
                      // receipt-sheet auto-print (printer_settings_sheet already
                      // writes it too; this covers older flows).
                      await SecureStore.setPrinterAddress(
                        '${d.name}|${d.address}',
                      );
                      setState(() => _printerName = '${d.name}|${d.address}');
                    },
                  ),
                ),
                _menuTile(
                  icon: _updateInfo?.hasUpdate == true
                      ? Icons.system_update
                      : Icons.update,
                  title: _updateInfo?.hasUpdate == true
                      ? 'Update Tersedia!'
                      : 'Riwayat Update',
                  subtitle: _updateInfo?.hasUpdate == true
                      ? 'Terpasang v${_updateInfo!.latestVersion} · Tersedia v${_updateInfo!.latestVersion}'
                      : null,
                  subtitleWidget: _updateInfo?.hasUpdate == true
                      ? null
                      : FutureBuilder<String>(
                          // v2.2.57+115: versi APK asli (PackageInfo).
                          future: SecureStore.installedVersionAndBuild(),
                          builder: (context, snap) {
                            final installed = snap.data ?? '';
                            return Text(
                              installed.isNotEmpty
                                  ? 'Terpasang $installed (terbaru)'
                                  : 'Terpasang v${NusaConfig.appVersion}+${NusaConfig.appBuildNumber} (terbaru)',
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark
                                    ? NusaConfig.darkTextSecondary
                                    : NusaConfig.textSecondary,
                              ),
                            );
                          },
                        ),
                  isDark: isDark,
                  onTap: _updateInfo?.hasUpdate == true
                      ? _showUpdateDialog
                      : _showUpdateHistory,
                  trailing: Icon(
                    _updateInfo?.hasUpdate == true
                        ? Icons.download
                        : Icons.history_rounded,
                    color: isDark
                        ? NusaConfig.darkTextSecondary
                        : NusaConfig.textSecondary,
                  ),
                ),
              ],
            ),

            // ════════════════════════════════════════════════════════════════════════════════════════════════
            //  BANTUAN
            // ════════════════════════════════════════════════════════════════════════════════════════════════
            _sectionHeader('BANTUAN', isDark),
            _groupCard(
              isDark: isDark,
              tiles: [
                // v2.2.53: Tutorial kini membuka daftar panduan dari cloud (tabel
                // `tutorials`) — dikelola via nusa-online /dashboard → tab Tutorial.
                _menuTile(
                  icon: Icons.school_outlined,
                  title: 'Tutorial',
                  subtitle: 'Panduan video cara pakai tiap menu',
                  isDark: isDark,
                  onTap: _openTutorial,
                ),
                _menuTile(
                  icon: Icons.feedback_outlined,
                  title: 'Bantuan & Masukan',
                  subtitle: 'Laporkan bug, usulkan fitur, atau chat tim',
                  isDark: isDark,
                  onTap: _showFeedbackSheet,
                ),
              ],
            ),

            // ════════════════════════════════════════════════════════════════════════════════════════════════
            //  TENTANG APLIKASI
            // ════════════════════════════════════════════════════════════════════════════════════════════════
            _sectionHeader('TENTANG APLIKASI', isDark),
            NusaCard(
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 20,
                          color: isDark
                              ? NusaConfig.darkTextSecondary
                              : NusaConfig.textSecondary,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Nusa Kasir',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Versi ${NusaConfig.appVersion} (build ${NusaConfig.appBuildNumber})',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: isDark
                                      ? NusaConfig.darkTextSecondary
                                      : NusaConfig.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Divider(),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Icon(
                          Icons.person_outline,
                          size: 18,
                          color: isDark
                              ? NusaConfig.darkTextSecondary
                              : NusaConfig.textSecondary,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Dibuat oleh Halu Goods',
                          style: TextStyle(
                            fontSize: 14,
                            color: isDark
                                ? NusaConfig.darkTextSecondary
                                : NusaConfig.textSecondary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        _aboutLink(
                          'Syarat & Ketentuan',
                          'https://halugoods.com/terms',
                        ),
                        const SizedBox(width: 16),
                        _aboutLink(
                          'Kebijakan Privasi',
                          'https://halugoods.com/privacy',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

// ── Riwayat Update sheet (fetch async di dalam sheet) ──
// Fetch GitHub di initState → sheet terbuka instan (loading dulu), data
// muncul setelah fetch selesai. Tap kartu versi → changelog penuh expand.
class _UpdateHistorySheet extends StatefulWidget {
  const _UpdateHistorySheet();

  @override
  State<_UpdateHistorySheet> createState() => _UpdateHistorySheetState();
}

class _UpdateHistorySheetState extends State<_UpdateHistorySheet> {
  List<ReleaseHistoryItem>? _releases; // null = masih loading
  int? _expandedIndex;
  int _installedBuild = NusaConfig.appBuildNumber; // v2.2.57+115: APK asli

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // v2.2.57+115: build yang TERPASANG dari PackageInfo, bukan konstanta
    // compile-time — biar badge "Terpasang" menandai release yang benar.
    _installedBuild = await SecureStore.installedBuildNumber();
    final releases = await UpdateService.getReleaseHistory();
    if (!mounted) return;
    setState(() {
      _releases = releases.isEmpty
          ? [
              ReleaseHistoryItem(
                version: NusaConfig.appVersion,
                buildNumber: NusaConfig.appBuildNumber,
                body: '',
              ),
            ]
          : releases;
    });
  }

  String _month(int m) {
    const months = [
      '',
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'Mei',
      'Jun',
      'Jul',
      'Agu',
      'Sep',
      'Okt',
      'Nov',
      'Des',
    ];
    return months[m];
  }

  /// Parse changelog (markdown ringan) menjadi daftar baris rapi:
  /// - "## " → judul section (ditebalkan saat render)
  /// - "- "/"* " → bullet list
  /// - lainnya → paragraf biasa
  List<String> _parseChangelog(String body) {
    return body.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).map(
      (l) {
        if (l.startsWith('## ')) return l.substring(3).trim();
        if (l.startsWith('# ')) return l.substring(2).trim();
        if (l.startsWith('- ')) return '• ${l.substring(2).trim()}';
        if (l.startsWith('* ') || l.startsWith('*')) {
          return '• ${l.replaceFirst('*', '').trim()}';
        }
        if (l.startsWith('### ')) return l.substring(4).trim();
        return l;
      },
    ).toList();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final loading = _releases == null;
    final releases = _releases ?? const <ReleaseHistoryItem>[];
    // Offline/gagal → hanya 1 item = versi lokal tanpa body.
    final localOnly =
        releases.length == 1 &&
        releases.first.buildNumber == NusaConfig.appBuildNumber &&
        releases.first.body.isEmpty;

    return FractionallySizedBox(
      heightFactor: 0.85,
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: isDark
                            ? NusaConfig.darkBorder
                            : NusaConfig.dividerColor,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Icon(
                        Icons.history_rounded,
                        color: NusaConfig.activePrimary,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Riwayat Update',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: isDark
                              ? NusaConfig.darkTextPrimary
                              : NusaConfig.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    loading
                        ? 'Memuat riwayat update…'
                        : localOnly
                        ? 'Tidak dapat mengambil riwayat dari internet. '
                              'Berikut versi yang terpasang di perangkat ini.'
                        : 'Versi terbaru ada di urutan paling atas. '
                              'Ketuk kartu untuk lihat changelog lengkap.',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: isDark
                          ? NusaConfig.darkTextSecondary
                          : NusaConfig.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Divider(
              height: 1,
              color: isDark ? NusaConfig.darkDivider : NusaConfig.dividerColor,
            ),
            Expanded(
              child: loading
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 12),
                          Text(
                            'Menghubungi GitHub…',
                            style: TextStyle(
                              fontSize: 13,
                              color: isDark
                                  ? NusaConfig.darkTextSecondary
                                  : NusaConfig.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                      itemCount: releases.length,
                      itemBuilder: (context, i) {
                        final r = releases[i];
                        final isCurrent = r.buildNumber == _installedBuild;
                        final expanded = _expandedIndex == i;
                        // Changelog di-render rapi: baris "- "/"* " → bullet
                        // list, "## " → judul section, sisanya paragraf.
                        final blocks = _parseChangelog(r.body);
                        final preview = blocks.take(4).join('\n');
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: NusaCard(
                            InkWell(
                              onTap: () => setState(() {
                                _expandedIndex = expanded ? null : i;
                              }),
                              borderRadius: BorderRadius.circular(16),
                              child: Padding(
                                padding: const EdgeInsets.all(14),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          'v${r.version}',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 15,
                                            color: isDark
                                                ? NusaConfig.darkTextPrimary
                                                : NusaConfig.textPrimary,
                                          ),
                                        ),
                                        if (r.buildNumber > 0) ...[
                                          const SizedBox(width: 6),
                                          Text(
                                            '(+${r.buildNumber})',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: isDark
                                                  ? NusaConfig.darkTextTertiary
                                                  : NusaConfig.textTertiary,
                                            ),
                                          ),
                                        ],
                                        const Spacer(),
                                        if (isCurrent)
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 3,
                                            ),
                                            decoration: BoxDecoration(
                                              color: NusaConfig.accentGreen
                                                  .withValues(alpha: 0.12),
                                              borderRadius:
                                                  BorderRadius.circular(20),
                                            ),
                                            child: Text(
                                              'Terpasang',
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w600,
                                                color: NusaConfig.accentGreen,
                                              ),
                                            ),
                                          ),
                                        Icon(
                                          expanded
                                              ? Icons.expand_less_rounded
                                              : Icons.expand_more_rounded,
                                          size: 20,
                                          color: isDark
                                              ? NusaConfig.darkTextSecondary
                                              : NusaConfig.textSecondary,
                                        ),
                                      ],
                                    ),
                                    if (r.publishedAt != null) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        '${_month(r.publishedAt!.month)} '
                                        '${r.publishedAt!.year}',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: isDark
                                              ? NusaConfig.darkTextTertiary
                                              : NusaConfig.textTertiary,
                                        ),
                                      ),
                                    ],
                                    if (preview.isNotEmpty) ...[
                                      const SizedBox(height: 8),
                                      if (expanded)
                                        _ChangelogBody(
                                          body: r.body,
                                          isDark: isDark,
                                        )
                                      else
                                        Text(
                                          preview,
                                          maxLines: 4,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 13,
                                            height: 1.5,
                                            color: isDark
                                                ? NusaConfig.darkTextSecondary
                                                : NusaConfig.textSecondary,
                                          ),
                                        ),
                                    ],
                                    if (r.body.isNotEmpty && !expanded)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 6),
                                        child: Text(
                                          'Ketuk untuk lihat changelog lengkap',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: NusaConfig.activePrimary,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Changelog body (riwayat update) ──
// Render markdown ringan changelog GitHub: "- " / "* " → bullet list,
// "## " → judul section tebal, baris lainnya → paragraf biasa.
class _ChangelogBody extends StatelessWidget {
  final String body;
  final bool isDark;
  const _ChangelogBody({required this.body, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final secondaryColor = isDark
        ? NusaConfig.darkTextSecondary
        : NusaConfig.textSecondary;
    final primaryColor = isDark
        ? NusaConfig.darkTextPrimary
        : NusaConfig.textPrimary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: body.split('\n').map((line) {
        final l = line.trim();
        if (l.isEmpty) return const SizedBox.shrink();

        final isSection = l.startsWith('## ') || l.startsWith('# ');
        final isBullet =
            l.startsWith('- ') || l.startsWith('* ') || l.startsWith('• ');
        final text = isSection
            ? l.replaceFirst(RegExp(r'^#+ '), '')
            : (isBullet ? l.replaceFirst(RegExp(r'^[-*•] '), '') : l);

        return Padding(
          padding: EdgeInsets.only(bottom: 4, left: isBullet ? 8 : 0),
          child: Text(
            (isBullet ? '•  ' : '') + text,
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              fontWeight: isSection ? FontWeight.w700 : FontWeight.w400,
              color: isSection ? primaryColor : secondaryColor,
            ),
          ),
        );
      }).toList(),
    );
  }
}
