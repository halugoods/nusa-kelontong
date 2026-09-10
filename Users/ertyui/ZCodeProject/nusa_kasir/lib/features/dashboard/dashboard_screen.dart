import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nusa_kasir/core/config/nusa_config.dart';
import 'package:nusa_kasir/core/providers.dart';
import 'package:nusa_kasir/core/services/delta_sync_service.dart';
import 'package:nusa_kasir/core/services/google_auth_service.dart';
import 'package:nusa_kasir/core/services/call_service.dart';
import 'package:nusa_kasir/core/services/sound_service.dart';
import 'package:nusa_kasir/core/utils/format_rupiah.dart';
import 'package:nusa_kasir/core/utils/secure_storage.dart';
import 'package:nusa_kasir/core/services/image_storage_service.dart';
import 'package:nusa_kasir/data/repositories/attendance_repository.dart';
import 'package:nusa_kasir/data/repositories/cashier_session_repository.dart';
import 'package:nusa_kasir/data/repositories/report_repository.dart';
import 'package:nusa_kasir/data/repositories/branch_repository.dart';
import 'package:nusa_kasir/data/repositories/online_order_repository.dart';
import 'package:nusa_kasir/data/repositories/product_repository.dart';
import 'package:nusa_kasir/data/repositories/finance_repository.dart';
import 'package:nusa_kasir/data/repositories/laundry_order_repository.dart';
import 'package:nusa_kasir/data/repositories/print_order_repository.dart';import 'package:nusa_kasir/data/repositories/appointment_repository.dart';
import 'package:nusa_kasir/data/repositories/service_ticket_repository.dart';
import 'package:nusa_kasir/data/database/app_database.dart';
import 'package:nusa_kasir/features/auth/employee_session_provider.dart';
import 'package:nusa_kasir/features/auth/rbac.dart';
import 'package:nusa_kasir/shared/widgets/dashboard_header.dart';
import 'package:nusa_kasir/shared/widgets/pin_dialog.dart';
import 'package:nusa_kasir/shared/widgets/top_toast.dart';
import 'package:nusa_kasir/shared/widgets/profile_stats_card.dart';
import 'package:nusa_kasir/core/utils/icon_loader.dart';
import 'package:nusa_kasir/core/services/update_service.dart';
import 'package:nusa_kasir/core/services/force_update_dialog.dart';
import 'package:nusa_kasir/core/services/notification_service.dart';
import 'package:nusa_kasir/core/providers/update_progress_provider.dart';
import 'package:nusa_kasir/shared/services/biometric_service.dart';
import 'package:nusa_kasir/shared/services/nfc_tag_service.dart';
import 'package:nusa_kasir/shared/services/auth_methods.dart';
import 'package:nusa_kasir/core/utils/wa_phone.dart';
import 'package:url_launcher/url_launcher.dart';

// ignore_for_file: use_build_context_synchronously

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});
  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  String _storeName = 'NUSA';
  String _omzet = 'Rp 0';
  String _trxCount = '0';
  String _avg = 'Rp 0';
  String _shiftDuration = '0j 0m';
  final String _topProduct = '—';
  List<Branche> _branches = [];
  Branche? _activeBranch;

  // Current session info
  String _currentName = '';
  String _currentRole = '';
  String? _currentPhotoPath;

  // Attendance tracking
  bool _hasCheckedIn = false;
  String _checkInTime = '';

  // PIN pad kasir (opsional — dikendalikan dari Pengaturan)
  bool _pinPadEnabled = true;

  // In-app update: latest GitHub release + download state.
  // Download progress lives in the global [updateProgressProvider] so the
  // notification drawer shows realtime progress without closing/reopening.
  UpdateInfo? _updateInfo;
  String? _downloadError;

  // Notification Center: unread badge count.
  int _notifUnread = 0;

  // Last cashier session
  String? _lastCashierName;
  String _lastCashierRole = '';
  String _lastCashierTime = '';
  String? _lastCashierPhoto;
  List<Employee> _employees = [];
  int _onlinePending = 0;
  int _lowStockCount = 0;

  // Keuangan summary
  int _financeExpense = 0;
  int _financeIncome = 0;

  // Laundry stats
  int _laundryToday = 0;
  int _laundryPending = 0;
  int _laundryReady = 0;
  int _laundryDelivered = 0;
  bool _laundryStatsExpanded = false;

  // Salon stats
  int _salonToday = 0;
  int _salonConfirmed = 0;
  int _salonWaiting = 0;
  int _salonDone = 0;
  bool _salonStatsExpanded = false;

  // Bengkel stats
  int _bengkelToday = 0;
  int _bengkelQueue = 0;
  int _bengkelInProgress = 0;
  int _bengkelDone = 0;
  int _bengkelEstimate = 0;
  bool _bengkelStatsExpanded = false;

  // Fotocopy/Percetakan stats
  int _printToday = 0;
  int _printPending = 0;
  int _printDone = 0;
  int _printPicked = 0;
  bool _printStatsExpanded = false;

  // Flip card data
  EmployeeCardData? _cardData;
  int? _cardEmployeeId;

  // v2.2.44 (L3/L5): metadata lisensi untuk banner perpanjang di dashboard.
  ({DateTime? expiresAt, String tier, String status})? _licenseInfo;

  final List<Map<String, dynamic>> _items = const [
    {'id': 'produk', 'label': 'Produk', 'icon': 'product'},
    {'id': 'stok', 'label': 'Stok', 'icon': 'inventory'},
    {'id': 'transaksi', 'label': 'Transaksi', 'icon': 'transaction'},
    {'id': 'pelanggan', 'label': 'Pelanggan', 'icon': 'customer'},
    {'id': 'piutang', 'label': 'Piutang', 'icon': 'debt'},
    {'id': 'promo', 'label': 'Promo', 'icon': 'promotion'},
    {'id': 'pesanan_online', 'label': 'Online', 'icon': 'online'},
    {'id': 'laporan', 'label': 'Laporan', 'icon': 'report'},
    {'id': 'presensi', 'label': 'Presensi', 'icon': 'notification'},
    {'id': 'karyawan', 'label': 'Karyawan', 'icon': 'employee'},
    {'id': 'keuangan', 'label': 'Keuangan', 'icon': 'finance'},
    {'id': 'spreadsheet', 'label': 'Spreadsheet', 'icon': 'table'},
    {'id': 'supplier', 'label': 'Supplier', 'icon': 'supplier'},
    {'id': 'cabang', 'label': 'Cabang', 'icon': 'branch'},
    {'id': 'ai_chat', 'label': 'AI Chat', 'icon': 'ai'},
    {'id': 'pengaturan', 'label': 'Pengaturan', 'icon': 'settings'},
    // ── Domain-specific menus (hidden by default in irrelevant variants) ──
    {'id': 'meja', 'label': 'Meja', 'icon': 'table_bar'},
    {'id': 'laundry_status', 'label': 'Status Laundry', 'icon': 'laundry'},
    {'id': 'servis', 'label': 'Tiket Servis', 'icon': 'repair'},
    {'id': 'booking', 'label': 'Booking', 'icon': 'booking'},
    {'id': 'resep', 'label': 'Resep', 'icon': 'prescription'},
    {'id': 'print_order', 'label': 'Order Cetak', 'icon': 'print_order'},
  ];

  @override
  void initState() {
    super.initState();
    _init();
    // v2.2.57+136: refresh data (omzet/laba/stok notif) saat delta sync
    // mengubah DB — dulu dashboard cuma reload saat init/pull-route, trx
    // kasir dari device lain tak terlihat sampai reopen.
    try {
      DeltaSyncService.I.stream.listen((_) {
        if (mounted) _load();
      });
    } catch (_) {}
  }

  Future<void> _init() async {
    // Restore session
    await ref.read(employeeSessionProvider.notifier).restore();
    final session = ref.read(employeeSessionProvider);
    if (session != null) {
      ref.read(authProvider.notifier).state = session.role;
      _currentName = session.name;
      _currentRole = session.role;
      // Check attendance for today
      await _checkAttendance(session.employeeId);
      if (!_hasCheckedIn) {
        // Attendance reminder in the Notification Center (deduped per day).
        await NotificationService.add(
          id: 'attendance-${DateTime.now().year}-${DateTime.now().month}-${DateTime.now().day}',
          type: 'attendance',
          title: '⏰ Jangan lupa absen',
          body: 'Buka menu Kasir untuk absen otomatis hari ini.',
          route: '/presensi',
        );
      }
    }

    // ═══ Init providers from persisted storage (fixes BUG #5 + #11) ═══
    // These providers start empty by default — we must seed them from
    // SecureStore before the first Dashboard build so menu ordering,
    // feature toggles, and per-role access lists work on fresh launch.
    try {
      // Feature toggles
      final togglesRaw = await SecureStore.getFeatureToggles();
      if (togglesRaw != null) {
        final toggles = (jsonDecode(togglesRaw) as Map<String, dynamic>).map(
          (k, v) => MapEntry(k, v as bool),
        );
        ref.read(featureTogglesProvider.notifier).state = toggles;
      }
      // Menu order
      final orderRaw = await SecureStore.getMenuOrder();
      if (orderRaw != null) {
        final order = (jsonDecode(orderRaw) as List<dynamic>)
            .map((e) => e as String)
            .toList();
        ref.read(menuOrderProvider.notifier).state = order;
      }
      // RBAC dynamic role access — load custom roles from SQLite into the
      // reactive provider so Owner-defined access lists apply immediately
      // and stay in sync across devices (roles ride the DB backup).
      await loadRoleAccess(ref);
    } catch (_) {
      // Non-critical — defaults are safe fallbacks
    }

    await _load();

    // v2.2.57+115: versi APK asli (PackageInfo) — dipakai update check
    // supaya user versi lama dapat notif update yang benar.
    await SecureStore.loadInstalledVersion();

    // Check for app update silently (10-min cache inside UpdateService) —
    // if a new release exists, show a badge on the bell.
    _checkUpdateSilent();

    // v2.2.57: ping server — catat versi perangkat + cek force-update.
    // Kalau build < min_build → popup UPDATE WAJIB (blocking, download via
    // browser eksternal).
    _checkForceUpdate();

    // Refresh the bell badge with persisted unread count.
    _notifUnread = await NotificationService.unreadCount();
    if (mounted) setState(() {});

    // Fix: reload photoPath from DB (not stale session data)
    if (session != null && mounted) {
      try {
        final attRepo = AttendanceRepository(ref.read(databaseProvider));
        final emp = await attRepo.getEmployee(session.employeeId);
        if (emp != null && mounted) {
          final resolved = await _resolvePhoto(emp.photoPath);
          if (mounted) {
            setState(() => _currentPhotoPath = resolved ?? emp.photoPath);
          }
        }
      } catch (_) {}
    }

    // Biometric auto-unlock for Owner is handled by the GoRouter redirect guard
    // in app.dart — NOT here. The redirect guard invalidates remembered sessions
    // when fingerprint is disabled. If we reach here, the session is valid.

    // Auto-scope branch from session
    if (session?.branchId != null && mounted) {
      final branchRepo = BranchRepository(ref.read(databaseProvider));
      final branch = await branchRepo.byId(session!.branchId!);
      if (branch != null && mounted) {
        setState(() => _activeBranch = branch);
        ref.read(activeBranchProvider.notifier).state = branch;
        await _load();
      }
    }
  }

  Future<void> _checkAttendance(int employeeId) async {
    try {
      final attRepo = AttendanceRepository(ref.read(databaseProvider));
      final today = await attRepo.getToday(employeeId);
      if (mounted) {
        setState(() {
          _hasCheckedIn = today != null && today.checkIn != null;
          _checkInTime = today?.checkIn ?? '';
        });
      }
    } catch (_) {}
  }

  // ── In-app update (bell badge + download + install) ──────────

  /// Silent update check — caches for 10 min inside UpdateService so this
  /// never hammers GitHub. Non-critical: failures are ignored silently.
  Future<void> _checkUpdateSilent() async {
    if (!mounted) return;
    final info = await UpdateService.checkForUpdate();
    if (!mounted) return;
    setState(() => _updateInfo = info);
    if (info.hasUpdate) {
      // Record in Notification Center (deduped by id → single card).
      final sizeTxt = info.fileSizeBytes != null && info.fileSizeBytes! > 0
          ? ' • ${UpdateService.formatSize(info.fileSizeBytes)}'
          : '';
      await NotificationService.add(
        id: 'update',
        type: 'update',
        title: '🔄 Update Tersedia v${info.latestVersion}',
        body:
            'Versi baru NUSA tersedia$sizeTxt. Klik untuk download via browser.',
        route: 'update',
      );
    }
  }

  /// v2.2.57: ping server (version tracking + force-update). Popup blocking
  /// tampil kalau build app di bawah minimum produk. Gagal jaringan = diabaikan.
  Future<void> _checkForceUpdate() async {
    try {
      final fu = await UpdateService.pingAndCheck();
      if (!mounted || !fu.required) return;
      await ForceUpdateDialog.show(context, fu);
    } catch (_) {}
  }

  /// Bell tap: open the Notification Center modal (scrollable list of
  /// notifications). Tapping the update card closes the modal and starts the
  /// always-visible download popup.
  void _onBellTap() {
    _showNotificationCenter();
  }

  /// v2.2.57+112: setelah check-in berhasil, bersihkan notif "belum absen"
  /// hari ini supaya badge lonceng tidak nyala terus walau sudah absen &
  /// semua notif sudah dibaca. Notif yang sudah dibaca pengguna tetap
  /// dipertahankan (jangan dihapus paksa) — hanya notif absen yang dihapus.
  Future<void> _afterCheckIn() async {
    try {
      final id =
          'attendance-${DateTime.now().year}-${DateTime.now().month}-${DateTime.now().day}';
      await NotificationService.remove(id);
      final unread = await NotificationService.unreadCount();
      if (mounted) setState(() => _notifUnread = unread);
    } catch (_) {}
  }

  // ── Notification Center modal ────────────────────────────────────

  Future<void> _showNotificationCenter() async {
    final notifs = await NotificationService.getCenter();
    if (!mounted) return;

    final isDark = Theme.of(context).brightness == Brightness.dark;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? NusaConfig.darkSurface : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return FractionallySizedBox(
          heightFactor: 0.82,
          child: Column(
            children: [
              // Drag handle
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: isDark
                        ? NusaConfig.darkBorder
                        : NusaConfig.borderColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                child: Row(
                  children: [
                    const Text(
                      'Notifikasi',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    // v2.2.42: "Baca Semua" — tandai SEMUA notifikasi dibaca
                    // sekali (badge bell langsung mati). Service markRead(null)
                    // sudah mendukung mark-all; tinggal tombol + refresh badge.
                    if (notifs.isNotEmpty && notifs.any((n) => !n.read))
                      TextButton(
                        onPressed: () async {
                          await NotificationService.markRead(); // null = all
                          if (!ctx.mounted) return;
                          final unread = await NotificationService.unreadCount();
                          if (mounted) setState(() => _notifUnread = unread);
                          // Refresh list di dalam sheet (hapus dot merah).
                          Navigator.of(ctx).pop();
                          _showNotificationCenter();
                        },
                        child: Text(
                          'Baca Semua',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: NusaConfig.activePrimary,
                          ),
                        ),
                      ),
                    IconButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      icon: Icon(
                        Icons.close,
                        color: isDark
                            ? NusaConfig.darkTextSecondary
                            : NusaConfig.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: notifs.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.notifications_off_outlined,
                              size: 40,
                              color: isDark
                                  ? NusaConfig.darkTextTertiary
                                  : NusaConfig.textTertiary,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Tidak ada notifikasi',
                              style: TextStyle(
                                fontSize: 14,
                                color: isDark
                                    ? NusaConfig.darkTextSecondary
                                    : NusaConfig.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: notifs.length,
                        itemBuilder: (_, i) =>
                            _buildNotifCard(ctx, notifs[i], isDark),
                      ),
              ),
            ],
          ),
        );
      },
    );
    // Badge di-refresh setelah drawer ditutup — item baru yang belum dibaca
    // tetap menyala; yang sudah diketuk tandanya hilang (v2.2.35).
    if (mounted) {
      final unread = await NotificationService.unreadCount();
      if (mounted) setState(() => _notifUnread = unread);
    }
  }

  Widget _buildNotifCard(BuildContext ctx, AppNotification n, bool isDark) {
    final IconData icon = switch (n.type) {
      'update' => Icons.system_update_alt,
      'stock' => Icons.inventory_2_outlined,
      'online' => Icons.shopping_bag_outlined,
      'attendance' => Icons.access_time,
      _ => Icons.info_outline,
    };
    final Color color = switch (n.type) {
      'update' => Colors.orange,
      'stock' => Colors.redAccent,
      'online' => NusaConfig.accentPurple,
      'attendance' => Colors.teal,
      _ => NusaConfig.activePrimary,
    };
    // Live download progress for the update card — global provider so it
    // updates in realtime even while the drawer is open (no close/reopen).
    final upd = ref.watch(updateProgressProvider);
    return InkWell(
      onTap: () async {
        // Tool-calling (v2.2.35): tap notif → buka menu terkait.
        final route = n.route ?? switch (n.type) {
          'online' => '/pesanan_online',
          'stock' => '/stok',
          'attendance' => '/presensi',
          'update' => 'update',
          _ => null,
        };
        if (route == null) return;
        // Tandai dibaca saat item diketuk (bukan saat drawer dibuka).
        await NotificationService.markRead(id: n.id);
        if (ctx.mounted) {
          final unread = await NotificationService.unreadCount();
          if (mounted) setState(() => _notifUnread = unread);
        }
        if (route == 'update') {
          // v2.2.57: download via BROWSER eksternal (bukan in-app). URL
          // prioritas: min-version server → fallback asset GitHub release.
          final url = UpdateService.lastForceCheck?.downloadUrl ??
              _updateInfo?.downloadUrl;
          Navigator.of(ctx).pop();
          if (url != null && url.isNotEmpty) {
            try {
              await launchUrl(
                Uri.parse(url),
                mode: LaunchMode.externalApplication,
              );
            } catch (_) {}
          }
          return;
        }
        Navigator.of(ctx).pop();
        // /stok bisa dibuka dengan filter stok menipis (mimik menu dashboard).
        if (route == '/stok' && _lowStockCount > 0) {
          context.push('/stok?lowStock=true');
        } else {
          context.push(route);
        }
      },
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          n.title,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      // Dot merah = belum dibaca (v2.2.35).
                      if (!n.read)
                        Container(
                          width: 8,
                          height: 8,
                          margin: const EdgeInsets.only(top: 4, left: 6),
                          decoration: const BoxDecoration(
                            color: Colors.redAccent,
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    n.body,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: isDark
                          ? NusaConfig.darkTextSecondary
                          : NusaConfig.textSecondary,
                    ),
                  ),
                  // Realtime progress bar saat update sedang diunduh —
                  // tidak perlu buka-tutup drawer untuk refresh (fix bug).
                  if (n.type == 'update' && upd.downloading) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: upd.progress > 0 ? upd.progress : null,
                        minHeight: 6,
                        backgroundColor: isDark
                            ? NusaConfig.darkSurface2
                            : NusaConfig.backgroundColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Mengunduh… ${(upd.progress * 100).toStringAsFixed(0)}%',
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark
                            ? NusaConfig.darkTextTertiary
                            : NusaConfig.textTertiary,
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    _notifTime(n.createdAt),
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
          ],
        ),
      ),
    );
  }

  String _notifTime(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return 'Baru saja';
    if (diff.inMinutes < 60) return '${diff.inMinutes} mnt lalu';
    if (diff.inHours < 24) return '${diff.inHours} jam lalu';
    return '${t.day}/${t.month}/${t.year}';
  }

  /// Popup update. Bisa ditutup / diminimalkan kapan saja (tap luar, tombol
  /// back) — proses unduh tetap berjalan di latar belakang; buka lagi kapan
  /// saja untuk melihat progres.
  ///
  /// [autoStart] = langsung mulai unduh, popup langsung tampil progres
  /// (dipakai saat klik notif update — tanpa perlu klik tombol lagi).
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
              ? _buildDownloadProgress(isDark)
              : FutureBuilder<String>(
                  // v2.2.57+115: versi terpasang asli (PackageInfo).
                  future: SecureStore.installedVersionAndBuild(),
                  builder: (context, snap) {
                    final installed = snap.data ?? '';
                    final shown = installed.isNotEmpty
                        ? 'Saat ini: $installed'
                        : 'Saat ini: v${NusaConfig.appVersion}+${NusaConfig.appBuildNumber}';
                    return _buildUpdateInfo(info, isDark,
                        installedText: shown);
                  },
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

  Widget _buildUpdateInfo(UpdateInfo info, bool isDark,
      {String installedText = ''}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Versi ${info.latestVersion} (build ${info.latestBuildNumber})',
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
        const SizedBox(height: 4),
        Text(
          installedText,
          style: TextStyle(
            fontSize: 13,
            color: isDark
                ? NusaConfig.darkTextSecondary
                : NusaConfig.textSecondary,
          ),
        ),
        if (info.fileSizeBytes != null && info.fileSizeBytes! > 0) ...[
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
        if (info.changelog != null && info.changelog!.isNotEmpty) ...[
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
    );
  }

  /// Progres unduhan — baca dari provider global (realtime di notif drawer
  /// tanpa buka-tutup). Dipakai dashboard, settings, dan drawer notifikasi.
  bool get _downloadingUpdate => ref.read(updateProgressProvider).downloading;
  double get _downloadProgress => ref.read(updateProgressProvider).progress;

  Widget _buildDownloadProgress(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _downloadError != null
                ? 'Gagal mengunduh update'
                : 'Mengunduh update… ${(_downloadProgress * 100).toStringAsFixed(0)}%',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: _downloadError != null
                  ? null
                  : (_downloadProgress > 0 ? _downloadProgress : null),
              minHeight: 8,
              backgroundColor: isDark
                  ? NusaConfig.darkSurface2
                  : NusaConfig.backgroundColor,
            ),
          ),
          if (_downloadError != null) ...[
            const SizedBox(height: 12),
            Text(
              _downloadError!,
              style: TextStyle(
                fontSize: 13,
                color: Colors.redAccent,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            _downloadError != null
                ? 'Versi lama kamu tetap aman terpasang.'
                : 'Jangan tutup aplikasi selama proses berjalan.',
            style: TextStyle(
              fontSize: 12,
              color: isDark
                  ? NusaConfig.darkTextTertiary
                  : NusaConfig.textTertiary,
            ),
          ),
          if (_downloadError != null) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _startUpdateDownload,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Coba Lagi'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: NusaConfig.activePrimary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Download + install the APK with progress, then hand off to the system
  /// installer. The dialog stays OPEN until the whole flow finishes — on
  /// failure it shows "Coba Lagi" instead of closing.
  Future<void> _startUpdateDownload() async {
    final info = _updateInfo;
    if (info == null || info.downloadUrl == null) return;
    if (!mounted) return;
    final notifier = ref.read(updateProgressProvider.notifier);
    notifier.startDownload(
      'nusa-${NusaConfig.productId.replaceFirst('nusa-', '')}-v${info.latestVersion ?? 'latest'}.apk',
    );
    setState(() => _downloadError = null);

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
        // Keep showing "Update" until the next version is installed.
        TopToast.success(
          context,
          'Instalasi dibuka. Selesaikan di layar sistem.',
        );
      }
    } catch (e) {
      debugPrint('[Dashboard] update download error: $e');
      notifier.fail('Gagal mengunduh update. Cek koneksi, lalu coba lagi.');
      if (mounted) {
        setState(
          () => _downloadError =
              'Gagal mengunduh update. Cek koneksi, lalu coba lagi.',
        );
        TopToast.error(
          context,
          'Gagal mengunduh update. Cek koneksi, lalu coba lagi.',
        );
      }
    }
  }

  Future<void> _load() async {
    final name = await ref.read(settingsRepoProvider).getStoreName();
    _pinPadEnabled = await SecureStore.getPinPadEnabled();
    // v2.2.44 (L3): baca metadata lisensi dari SecureStore (diisi saat login).
    _licenseInfo = await SecureStore.getLicenseInfo();
    final db = ref.read(databaseProvider);
    final attRepo = AttendanceRepository(db);
    final emps = await attRepo.getEmployees();
    final branches = await BranchRepository(
      ref.read(databaseProvider),
    ).getAll();
    final session = ref.read(employeeSessionProvider);
    // A null branch keeps owner/global dashboards scoped to all branches.
    final branchId = _activeBranch?.id ?? session?.branchId;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final reportRepo = ReportRepository(ref.read(databaseProvider));
    // Sales scoping: Owner/Manager see the GLOBAL total (all cashiers);
    // other roles (Kasir/Gudang/Finance) see only THEIR OWN shift sales,
    // so switching cashier resets the dashboard to their own revenue.
    final role = session?.role ?? 'Owner';
    final isGlobalRole = role == 'Owner' || role == 'Manager';
    final sum = await reportRepo.summary(
      from: today,
      to: now,
      branchId: branchId,
      employeeId: isGlobalRole ? null : session?.employeeId,
    );

    final cashierRepo = CashierSessionRepository(ref.read(databaseProvider));
    final lastSession = await cashierRepo.getLast();

    String? lastCashierName;
    String lastCashierRole = '';
    String lastCashierTime = '';
    String? lastCashierPhoto;
    if (lastSession != null) {
      final emp = emps.cast<Employee?>().firstWhere(
        (e) => e!.id == lastSession.employeeId,
        orElse: () => null,
      );
      if (emp != null) {
        lastCashierName = emp.name;
        lastCashierRole = emp.role;
        lastCashierPhoto = emp.photoPath;
        final t = lastSession.openedAt;
        lastCashierTime =
            '${t.hour.toString().padLeft(2, '0')}:'
            '${t.minute.toString().padLeft(2, '0')}';
      }
    }

    // Check attendance for each employee — who hasn't checked in today?
    // (we'll use this to show badge on employee picker)
    // For now just reload the list

    // Load online pending count
    final onlineRepo = OnlineOrderRepository(ref.read(databaseProvider));
    final onlinePending = await onlineRepo.countPending();
    if (onlinePending > 0) {
      await NotificationService.add(
        id: 'online-pending',
        type: 'online',
        title: '🛒 Pesanan Online Menunggu',
        body: onlinePending == 1
            ? 'Ada 1 pesanan online baru yang belum diproses.'
            : 'Ada $onlinePending pesanan online baru yang belum diproses.',
        route: '/pesanan_online',
      );
    }

    // Load low stock count (stok menipis: stock < minStock && minStock > 0)
    int lowStockCount = 0;
    try {
      final allProducts = await ProductRepository(
        ref.read(databaseProvider),
      ).getProducts();
      lowStockCount = allProducts
          .where((p) => p.stock < p.minStock && p.minStock > 0)
          .length;
      // Record low-stock notification in the in-app center (deduped by count).
      if (lowStockCount > 0) {
        SoundService.I.play(NusaSound.lowStock);
        final lowNames = allProducts
            .where((p) => p.stock < p.minStock && p.minStock > 0)
            .take(3)
            .map((p) => p.name)
            .join(', ');
        await NotificationService.add(
          id: 'stock-low',
          type: 'stock',
          title: '⚠️ Stok Menipis',
          body: lowStockCount == 1
              ? 'Stok "$lowNames" menipis. Segera restock.'
              : '$lowStockCount produk stoknya menipis: $lowNames',
          route: '/stok',
        );
      }
    } catch (_) {}

    // Load keuangan summary
    final financeRepo = FinanceRepository(ref.read(databaseProvider));
    final finSummary = await financeRepo.getDashboardSummary(
      branchId: branchId,
    );

    // Load laundry stats
    int laundryToday = 0,
        laundryPending = 0,
        laundryReady = 0,
        laundryDelivered = 0;
    bool laundryStatsExpanded = false;
    if (NusaConfig.isLaundryVariant) {
      final laundryRepo = LaundryOrderRepository(db);
      laundryToday = await laundryRepo.countToday();
      laundryPending = await laundryRepo.countPending();
      laundryReady = await laundryRepo.countByStatus('Siap');
      laundryDelivered = await laundryRepo.countByStatus('Diambil');
      laundryStatsExpanded = await SecureStore.getLaundryStatsExpanded();
    }

    // Load salon stats
    int salonToday = 0, salonConfirmed = 0, salonWaiting = 0, salonDone = 0;
    bool salonStatsExpanded = false;
    if (NusaConfig.isSalonVariant) {
      final salonRepo = AppointmentRepository(db);
      salonToday = await salonRepo.getNextCounter(DateTime.now()) - 1;
      salonConfirmed = await salonRepo.countByStatus('Dikonfirmasi');
      salonWaiting = await salonRepo.countByStatus('Menunggu');
      salonDone = await salonRepo.countByStatus('Selesai');
      salonStatsExpanded = await SecureStore.getSalonStatsExpanded();
    }

    // Load bengkel stats
    int bengkelToday = 0,
        bengkelQueue = 0,
        bengkelInProgress = 0,
        bengkelDone = 0,
        bengkelEstimate = 0;
    bool bengkelStatsExpanded = false;
    if (NusaConfig.isBengkelVariant) {
      final bengkelRepo = ServiceTicketRepository(db);
      bengkelToday = await bengkelRepo.countToday();
      bengkelQueue =
          await bengkelRepo.countByStatus('Diagnosa') +
          await bengkelRepo.countByStatus('Estimasi');
      bengkelInProgress = await bengkelRepo.countByStatus('Perbaikan');
      bengkelDone = await bengkelRepo.countByStatus('Selesai');
      bengkelEstimate =
          await bengkelRepo.sumByStatus(
            'Perbaikan',
            costOf: (t) => t.sparepartCost + t.serviceCost,
          ) +
          await bengkelRepo.sumByStatus(
            'Estimasi',
            costOf: (t) => t.sparepartCost + t.serviceCost,
          );
      bengkelStatsExpanded = await SecureStore.getBengkelStatsExpanded();
    }

    // Load fotocopy/percetakan stats
    int printToday = 0, printPending = 0, printDone = 0, printPicked = 0;
    bool printStatsExpanded = false;
    if (NusaConfig.isFotocopyVariant) {
      final printRepo = PrintOrderRepository(db);
      printToday = await printRepo.countByDate(DateTime.now());
      printPending = await printRepo.countPending();
      printDone = await printRepo.countByStatus('Selesai');
      printPicked = await printRepo.countByStatus('Diambil');
      printStatsExpanded = await SecureStore.getFotocopyStatsExpanded();
    }

    // Load flip card data
    await _fetchCardData(ref.read(employeeSessionProvider)?.employeeId);

    // Foto kasir terakhir: jika file lokal hilang (restore/pindah device),
    // unduh ulang dari cloud (bucket nusa-images/employees/).
    String? resolvedLastPhoto = lastCashierPhoto;
    if (lastCashierPhoto != null && lastCashierPhoto.isNotEmpty) {
      resolvedLastPhoto = await _resolvePhoto(lastCashierPhoto);
    }

    // Resolve foto semua karyawan (untuk flip card / picker) — hanya yang
    // file lokalnya hilang; sisanya langsung.
    var resolvedEmps = emps;
    if (emps.any(
      (e) =>
          e.photoPath != null &&
          e.photoPath!.isNotEmpty &&
          !File(e.photoPath!).existsSync(),
    )) {
      resolvedEmps = [];
      for (final e in emps) {
        if (e.photoPath != null && e.photoPath!.isNotEmpty) {
          final r = await _resolvePhoto(e.photoPath);
          resolvedEmps.add(e.copyWith(photoPath: Value(r ?? e.photoPath)));
        } else {
          resolvedEmps.add(e);
        }
      }
    }

    // Refresh current user's card photo from the resolved employee list so a
    // photo change (or cloud restore) shows immediately on pull-to-refresh,
    // instead of keeping the stale path captured at initState.
    String? resolvedCurPhoto;
    if (session != null) {
      for (final e in resolvedEmps) {
        if (e.id == session.employeeId) {
          resolvedCurPhoto = e.photoPath;
          break;
        }
      }
    }

    if (mounted) {
      setState(() {
        if (session != null) _currentPhotoPath = resolvedCurPhoto;
        _storeName = name.isNotEmpty ? name : 'NUSA';
        _branches = branches;
        // Only auto-set first branch if session didn't already scope
        if (branches.isNotEmpty &&
            _activeBranch == null &&
            ref.read(employeeSessionProvider)?.branchId == null) {
          _activeBranch = branches.first;
          ref.read(activeBranchProvider.notifier).state = branches.first;
        }
        _omzet = formatRupiah(sum['omzet'] as int);
        _trxCount = '${sum['count']}';
        _avg = formatRupiah(sum['avg'] as int);
        _employees = resolvedEmps;
        _onlinePending = onlinePending;
        _lowStockCount = lowStockCount;
        _lastCashierName = lastCashierName;
        _lastCashierRole = lastCashierRole;
        _lastCashierTime = lastCashierTime;
        _lastCashierPhoto = resolvedLastPhoto;
        _financeExpense = finSummary['totalExpense'] ?? 0;
        _financeIncome = finSummary['totalIncome'] ?? 0;
        _laundryToday = laundryToday;
        _laundryPending = laundryPending;
        _laundryReady = laundryReady;
        _laundryDelivered = laundryDelivered;
        _laundryStatsExpanded = laundryStatsExpanded;
        _salonToday = salonToday;
        _salonConfirmed = salonConfirmed;
        _salonWaiting = salonWaiting;
        _salonDone = salonDone;
        _salonStatsExpanded = salonStatsExpanded;
        _bengkelToday = bengkelToday;
        _bengkelQueue = bengkelQueue;
        _bengkelInProgress = bengkelInProgress;
        _bengkelDone = bengkelDone;
        _bengkelEstimate = bengkelEstimate;
        _bengkelStatsExpanded = bengkelStatsExpanded;
        _printToday = printToday;
        _printPending = printPending;
        _printDone = printDone;
        _printPicked = printPicked;
        _printStatsExpanded = printStatsExpanded;
      });
    }
  }

  /// Pre-fetch flip card data for the profile card back side.
  Future<void> _fetchCardData(int? employeeId) async {
    if (employeeId == null) return;
    _cardEmployeeId = employeeId;
    try {
      final db = ref.read(databaseProvider);
      final reportRepo = ReportRepository(db);
      final attRepo = AttendanceRepository(db);
      final onlineRepo = OnlineOrderRepository(db);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final branchId =
          _activeBranch?.id ?? ref.read(employeeSessionProvider)?.branchId;

      // Today's sales summary
      final sum = await reportRepo.summary(
        from: today,
        to: now,
        branchId: branchId,
      );
      final penjualan = sum['omzet'] as int;
      final trxCount = sum['count'] as int;

      // Profit — use real P&L calculation (same as Laporan menu)
      final pl = await reportRepo.profitLoss(
        from: today,
        to: now,
        branchId: branchId,
      );
      final laba = (pl['labaBersih'] as int?) ?? 0;

      // Cash drawer — from today's attendance record
      final todayAtt = await attRepo.getToday(employeeId);
      final modalAwal = todayAtt?.pettyCash ?? 0;
      final totalLaci = todayAtt?.finalCash ?? modalAwal;
      final selisihLaci = totalLaci - modalAwal - penjualan;
      String? shiftHours;
      // Shift hours from today's attendance
      if (todayAtt?.checkIn != null) {
        final parts = todayAtt!.checkIn!.split(':');
        if (parts.length >= 2) {
          final h = int.tryParse(parts[0]) ?? 0;
          final m = int.tryParse(parts[1]) ?? 0;
          final diff = now.difference(
            DateTime(now.year, now.month, now.day, h, m),
          );
          if (diff.inMinutes > 0) {
            shiftHours = '${diff.inHours}j ${diff.inMinutes.remainder(60)}m';
          }
        }
      }

      // Monthly data
      final monthStart = DateTime(now.year, now.month, 1);
      final monthSum = await reportRepo.summary(
        from: monthStart,
        to: now,
        branchId: branchId,
      );
      final omzet = monthSum['omzet'] as int;
      final transaksiBulan = monthSum['count'] as int;

      // Attendance — count records this month
      final history = await attRepo.history(employeeId: employeeId);
      final hadirDays = history
          .where(
            (a) =>
                a.date.isAfter(monthStart.subtract(const Duration(days: 1))) &&
                a.checkIn != null,
          )
          .length;
      final totalDays = now.day;

      // Pending online orders
      final pendingItems = await onlineRepo.countPending();

      if (mounted) {
        setState(() {
          _shiftDuration = shiftHours ?? '0j 0m';
          _cardData = EmployeeCardData(
            penjualan: penjualan,
            laba: laba,
            trxCount: trxCount,
            modalAwal: modalAwal,
            totalLaci: totalLaci,
            selisihLaci: selisihLaci,
            shiftHours: shiftHours,
            omzet: omzet,
            transaksiBulan: transaksiBulan,
            hadirDays: hadirDays,
            totalDays: totalDays,
            pendingItems: pendingItems,
          );
        });
      }
    } catch (_) {}
  }

  // ── Branch Picker ──────────────────────────────────────────────

  /// Pastikan foto karyawan tersedia di device. Jika file lokal hilang
  /// (restore/pindah device), unduh ulang dari cloud ke cache lokal
  /// `{productId}_{filename}` — lalu kembalikan path yang valid.
  Future<String?> _resolvePhoto(String? photoPath) async {
    if (photoPath == null || photoPath.trim().isEmpty) return null;
    try {
      final f = File(photoPath);
      if (await f.exists()) return photoPath;
      // v2.2.38: path cloud pakai Google UID, bukan Supabase anon UID.
      // v2.2.57+115 (Area I): canonical UID — sama dengan path backup supaya
      // foto karyawan tidak pecah antara akun email vs Google.
      final uid = await SecureStore.resolveCanonicalUid();
      if (uid == null) return null;
      final filename = photoPath.split(RegExp(r'[\\/]')).last;
      final svc = ImageStorageService(uid);
      final cached = await svc.ensureLocal('employees', filename);
      if (cached != null && await File(cached).exists()) return cached;
    } catch (_) {}
    return null;
  }

  void _showBranchPicker() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Container(
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
            const SizedBox(height: 8),
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: NusaConfig.accentPurple.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.store,
                    color: NusaConfig.accentPurple,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                const Text(
                  'Pilih Cabang',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // "Semua Cabang" option
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: NusaConfig.accentGreen.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.layers,
                  color: NusaConfig.accentGreen,
                  size: 20,
                ),
              ),
              title: const Text(
                'Semua Cabang',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
              ),
              subtitle: const Text(
                'Lihat data dari seluruh cabang',
                style: TextStyle(fontSize: 12),
              ),
              trailing: _activeBranch == null
                  ? const Icon(
                      Icons.check_circle,
                      color: NusaConfig.accentGreen,
                      size: 22,
                    )
                  : null,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              onTap: () async {
                setState(() => _activeBranch = null);
                ref.read(activeBranchProvider.notifier).state = null;
                Navigator.pop(ctx);
                await _load();
              },
            ),
            const SizedBox(height: 4),
            // Branch list
            ..._branches.map((b) {
              final active = _activeBranch?.id == b.id;
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color:
                        (active
                                ? NusaConfig.accentPurple
                                : const Color(0xFF9CA3AF))
                            .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.storefront,
                    color: active
                        ? NusaConfig.accentPurple
                        : const Color(0xFF9CA3AF),
                    size: 20,
                  ),
                ),
                title: Text(
                  b.name,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    color: active ? NusaConfig.accentPurple : null,
                  ),
                ),
                subtitle: b.address != null && b.address!.isNotEmpty
                    ? Text(
                        b.address!,
                        style: const TextStyle(fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    : null,
                trailing: active
                    ? const Icon(
                        Icons.check_circle,
                        color: NusaConfig.accentPurple,
                        size: 22,
                      )
                    : null,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                onTap: () async {
                  setState(() => _activeBranch = b);
                  ref.read(activeBranchProvider.notifier).state = b;
                  Navigator.pop(ctx);
                  await _load();
                },
              );
            }),
            const SizedBox(height: 8),
            // Kelola Cabang button
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  context.push('/cabang');
                },
                icon: const Icon(Icons.add, size: 18),
                label: const Text(
                  'Kelola Cabang',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: NusaConfig.accentPurple,
                  side: const BorderSide(color: NusaConfig.accentPurple),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Menu navigation with RBAC guard ────────────────────────────────

  Future<void> _handleMenuTap(String route) async {
    final session = ref.read(employeeSessionProvider);

    // 1. Session must exist (GoRouter guard ensures this)
    if (session == null) return;

    final currentRole = ref.read(employeeSessionProvider)?.role ?? 'Kasir';

    // 2. Owner-only guard
    if (isOwnerOnly(route) &&
        currentRole != 'Owner' &&
        currentRole != 'Manager') {
      _showOwnerOnlyDialog(route);
      return;
    }

    // 3. RBAC access guard — block navigation for screens not in role's access list
    if (!hasAccess(ref, currentRole, route)) {
      _showOwnerOnlyDialog(route);
      return;
    }

    // 4. PIN guard for sensitive menus (kasir) — bisa dinonaktifkan di Pengaturan
    if (needsPinGuard(route) && await SecureStore.getPinPadEnabled()) {
      final pinOk = await _requirePinReentry();
      if (!pinOk) return;
    }

    // 5. Attendance check: if not checked in, check in now
    if (!_hasCheckedIn) {
      final attRepo = AttendanceRepository(ref.read(databaseProvider));
      await attRepo.checkIn(session.employeeId);
      if (mounted) setState(() => _hasCheckedIn = true);
      await _afterCheckIn();
    }

    // Navigate
    if (route == 'presensi') {
      await context.push('/$route');
      if (mounted) await _load();
    } else if (route == 'stok' && _lowStockCount > 0) {
      context.push('/stok?lowStock=true');
    } else {
      context.push('/$route');
    }
  }

  /// Show "Hanya owner" dialog with lock icon.
  void _showOwnerOnlyDialog(String route) {
    final label =
        _items.firstWhere(
              (i) => i['id'] == route,
              orElse: () => {'label': route},
            )['label']
            as String;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.lock_rounded, color: NusaConfig.activePrimary, size: 28),
            const SizedBox(width: 10),
            const Text('Akses Terbatas', style: TextStyle(fontSize: 17)),
          ],
        ),
        content: Text(
          'Menu "$label" hanya bisa diakses oleh Owner/Manager. '
          'Silakan minta Owner untuk login jika perlu mengakses menu ini.',
          style: const TextStyle(fontSize: 14, height: 1.5),
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: NusaConfig.activePrimary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Mengerti'),
          ),
        ],
      ),
    );
  }

  /// Force PIN re-entry for sensitive operations.
  Future<bool> _requirePinReentry() async {
    final session = ref.read(employeeSessionProvider);
    if (session == null) return false;

    final emp = _employees.cast<Employee?>().firstWhere(
      (e) => e!.id == session.employeeId,
      orElse: () => null,
    );
    if (emp == null) return false;

    final result = await PinDialog.show(
      context: context,
      employeeName: emp.name,
      employeeRole: emp.role,
      correctPin: emp.pin,
      showRemember: false,
      showFingerprint: true,
      showNfc: true,
      showBarcode: true,
      onFingerprint: () async => await _authFingerprint(),
      onNfc: () async {
        final id = await NfcTagService.readEmployeeTag();
        return id?.toString();
      },
      onBarcode: AuthMethods.barcode(ref, expectedEmployeeId: emp.id),
      // v2.2.50 (A5): "Lupa PIN?" → Google re-auth + set PIN baru (cloud-only)
      onForgotPin: NusaConfig.cloudEnabled
          ? () async {
              Navigator.of(context).pop(); // tutup dialog pin
              if (!mounted) return;
              final confirm = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  title: const Text('Lupa PIN?'),
                  content: const Text(
                    'Anda harus login ulang dengan akun Google pemilik toko '
                    'untuk mengatur PIN baru. Lanjutkan?',
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
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Akun Google berbeda. Gunakan akun pemilik toko.')),
                  );
                }
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
              await repo.updateEmployee(id: owner.id, name: owner.name, pin: newPin, role: owner.role, status: owner.status);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('PIN berhasil diubah')),
                );
              }
            }
          : null,
    );

    if (result == null || !result.success) {
      return false;
    }

    // Touch session on successful PIN
    ref.read(employeeSessionProvider.notifier).touch();
    return true;
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
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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

  // ── Logout / Ganti Pengguna ─────────────────────────────────────────

  /// Konfirmasi + logout. Kalau kasir masih BUKA, kasih peringatan dulu
  /// (tidak menutup paksa — user tutup kasir dulu di POS).
  Future<void> _confirmLogout() async {
    if (!mounted) return;

    // Block switch-user while a cashier shift is still OPEN: transactions
    // must stay attributed to the correct shift/session.
    final cashierRepo = CashierSessionRepository(ref.read(databaseProvider));
    final active = await cashierRepo.getActive();
    if (active != null) {
      if (mounted) {
        TopToast.error(
          context,
          'Tutup kasir dulu sebelum ganti pengguna. Shift kasir masih berjalan.',
        );
      }
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ganti Pengguna?'),
        content: Text(
          'Keluar dari ${ref.read(employeeSessionProvider)?.name ?? 'pengguna ini'} '
          'dan kembali ke layar login untuk memilih pengguna lain.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Keluar',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    // Clear session + role, back to login screen
    ref.read(employeeSessionProvider.notifier).logout();
    ref.read(authProvider.notifier).state = null;
    if (mounted) context.go('/login');
  }

  // ── Buka Kasir ─────────────────────────────────────────────────────

  Future<void> _bukaKasir() async {
    // Session must exist (GoRouter guard ensures this)
    final s = ref.read(employeeSessionProvider);
    if (s == null) return;

    // PIN re-entry for security (bisa dinonaktifkan di Pengaturan)
    if (await SecureStore.getPinPadEnabled()) {
      final pinOk = await _requirePinReentry();
      if (!pinOk) return;
      if (!mounted) return;
    }

    // Check if there's already an active cashier session
    final cashierRepo = CashierSessionRepository(ref.read(databaseProvider));
    final active = await cashierRepo.getActive();
    if (active != null) {
      if (mounted) {
        TopToast.info(
          context,
          'Kasir masih terbuka. Melanjutkan sesi sebelumnya.',
        );
        context.push('/kasir?sessionId=${active.id}');
      }
      return;
    }

    // Auto check-in if not yet
    if (!_hasCheckedIn) {
      try {
        final attRepo = AttendanceRepository(ref.read(databaseProvider));
        await attRepo.checkIn(s.employeeId);
        setState(() => _hasCheckedIn = true);
        await _afterCheckIn();
      } catch (_) {}
    }

    // Create cashier session with saldo = 0
    try {
      final sessionId = await cashierRepo.open(
        employeeId: s.employeeId,
        startingCash: 0,
      );
      if (mounted) {
        TopToast.success(context, 'Kasir dibuka — Halo, ${s.name}! 👋');
        context.push('/kasir?sessionId=$sessionId');
      }
    } catch (e) {
      if (mounted) {
        TopToast.error(context, 'Gagal membuka kasir: $e');
      }
    }
  }

  Future<void> _handlePresensiTap() async {
    await context.push('/presensi');
    if (mounted) {
      await _load();
    }
  }

  /// Show employee list with WhatsApp chat buttons (Owner quick access).
  /// v2.2.54: sheet "Hubungi Karyawan" diperbaiki total:
  ///  - SEMUA karyawan tampil (dulu cuma yang punya nomor WA → kosong).
  ///  - Sheet lebar penuh & scrollable setinggi ±70% layar (dulu nanggung).
  ///  - Tiap baris ada tombol WA (kalau ada nomor) + PANGGIL (Realtime
  ///    Broadcast → device yang login sebagai role/karyawan tsb berbunyi).
  void _showEmployeeWaList() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final list = [..._employees]..sort((a, b) => a.name.compareTo(b.name));
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.72,
        ),
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
            const SizedBox(height: 8),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Hubungi Karyawan',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  '${list.length} karyawan',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? NusaConfig.darkTextTertiary
                        : NusaConfig.textTertiary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Flexible(
              child: list.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.group_off_rounded,
                            size: 42,
                            color: isDark
                                ? NusaConfig.darkTextTertiary
                                : NusaConfig.textTertiary,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'Belum ada karyawan.\nTambahkan di menu Karyawan.',
                            textAlign: TextAlign.center,
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
                  : ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(top: 8),
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, i) {
                        final e = list[i];
                        final hasWa =
                            e.phone != null && e.phone!.trim().isNotEmpty;
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: isDark
                                ? NusaConfig.darkSurface2
                                : NusaConfig.backgroundColor,
                            borderRadius: BorderRadius.circular(
                              NusaConfig.radiusMD,
                            ),
                            border: Border.all(
                              color: isDark
                                  ? NusaConfig.darkBorder
                                  : NusaConfig.borderColor,
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: NusaConfig.activePrimary.withValues(
                                    alpha: 0.12,
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  e.name[0].toUpperCase(),
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: NusaConfig.activePrimary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      e.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 14,
                                      ),
                                    ),
                                    Text(
                                      e.role,
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
                              // Tombol WA — hanya kalau karyawan punya nomor.
                              if (hasWa)
                                _contactActionBtn(
                                  ctx,
                                  isDark: isDark,
                                  icon: Icons.chat_rounded,
                                  label: 'WA',
                                  color: NusaConfig.accentGreen,
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    _launchWa(e.phone!);
                                  },
                                ),
                              const SizedBox(width: 8),
                              // Tombol PANGGIL — cloud-only (butuh internet untuk
                              // broadcast ke device karyawan). Hidden di Lite.
                              if (NusaConfig.cloudEnabled)
                                _contactActionBtn(
                                  ctx,
                                  isDark: isDark,
                                  icon: Icons.notifications_active_rounded,
                                  label: 'Panggil',
                                  color: NusaConfig.info,
                                  keepOpen: true,
                                  onTap: () async {
                                    try {
                                      final session = ref.read(
                                        employeeSessionProvider,
                                      );
                                      final ok = await CallService.I.call(
                                        employeeId: e.id,
                                        employeeName: e.name,
                                        by: session?.name ?? 'Owner',
                                      );
                                      if (!ok) throw Exception();
                                      if (ctx.mounted) {
                                        TopToast.success(
                                          ctx,
                                          'Memanggil ${e.name}…',
                                        );
                                      }
                                    } catch (_) {
                                      if (ctx.mounted) {
                                        TopToast.error(
                                          ctx,
                                          'Gagal memanggil (butuh internet)',
                                        );
                                      }
                                    }
                                  },
                                ),
                            ],
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

  Widget _contactActionBtn(
    BuildContext ctx, {
    required bool isDark,
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
    bool keepOpen = false,
  }) {
    return GestureDetector(
      onTap: () {
        if (!keepOpen) Navigator.pop(ctx);
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(NusaConfig.radiusSM),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _launchWa(String phone) async {
    // Normalisasi via helper (v2.2.35): 0 di depan → 62.
    final uri = waLink(phone);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        TopToast.error(context, 'Gagal membuka WhatsApp');
      }
    }
  }

  /// v2.2.44 (L4): buka halaman perpanjang/beli lisensi /pay. Gateway
  /// pembayaran abstrak di web — app tidak perlu tahu midtrans/lainnya.
  Future<void> _openPayPage() async {
    final googleId = await GoogleAuthService.getStoredUserId();
    final uri = Uri.parse(
      googleId != null && googleId.isNotEmpty
          ? NusaConfig.paymentLink(googleId, 'lifetime')
          : '${NusaConfig.paymentUrl}?product=${NusaConfig.productId}',
    );
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        TopToast.error(context, 'Gagal membuka halaman pembayaran');
      }
    }
  }

  // ── Build ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(employeeSessionProvider);
    final role = session?.role ?? 'Owner';

    // Build menu items — only show menus this variant + role can access
    final featureToggles = ref.watch(featureTogglesProvider);
    final menuOrder = ref.watch(menuOrderProvider);
    // Cloud-dependent menus — hidden in NUSA Lite (offline-only) builds.
    const _cloudMenus = {'ai_chat', 'spreadsheet', 'pesanan_online'};
    final filteredItems = _items
        .where((item) {
          final id = item['id'] as String;
          // User override from Kelola Fitur takes priority
          if (featureToggles.containsKey(id)) return featureToggles[id]!;
          // Hide domain-inappropriate menus for this variant
          if (NusaConfig.hiddenMenus.contains(id)) return false;
          // Hide cloud-dependent menus in Lite (offline-only) builds
          if (_cloudMenus.contains(id) && !NusaConfig.cloudEnabled) return false;
          // Hide menus the employee's role cannot access (no lock gimmick)
          if (isOwnerOnly(id) && role != 'Owner' && role != 'Manager')
            return false;
          if (!hasAccess(ref, role, id)) return false;
          return true;
        })
        .map((item) {
          final id = item['id'] as String;
          final label = item['label'] as String;
          final icon = item['icon'] as String;

          // Only PIN-guarded menus need an indicator; everything else is accessible
          String accessType = '';
          if (needsPinGuard(id) && _pinPadEnabled) {
            accessType = '🔐';
          }

          return {'id': id, 'label': label, 'icon': icon, 'access': accessType};
        })
        .toList();

    // Apply user-defined menu order from Kelola Fitur drag-reorder
    if (menuOrder.isNotEmpty) {
      final orderMap = <String, int>{};
      for (var i = 0; i < menuOrder.length; i++) {
        orderMap[menuOrder[i]] = i;
      }
      filteredItems.sort((a, b) {
        final ai = orderMap[a['id'] as String] ?? 999;
        final bi = orderMap[b['id'] as String] ?? 999;
        return ai.compareTo(bi);
      });
    }
    final menuItems = filteredItems;

    // Build card props
    String initials, userName, roleText, attendanceText;
    String? cardPhoto;
    if (_currentName.isNotEmpty) {
      initials = _currentName[0].toUpperCase();
      userName = _currentName;
      roleText = _currentRole;
      cardPhoto = _currentPhotoPath;
      attendanceText = _hasCheckedIn
          ? 'Hadir • $_checkInTime'
          : '⚠️  Belum absen hari ini — buka kasir untuk absen otomatis';
    } else if (_lastCashierName != null) {
      initials = _lastCashierName!.isNotEmpty
          ? _lastCashierName![0].toUpperCase()
          : '?';
      userName = _lastCashierName!;
      roleText = _lastCashierRole;
      cardPhoto = _lastCashierPhoto;
      attendanceText = 'Kasir terakhir • $_lastCashierTime';
    } else {
      initials = '?';
      userName = 'Belum ada sesi kasir';
      roleText = '';
      cardPhoto = null;
      attendanceText = 'Buka Kasir untuk memulai';
    }

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            // Header (static)
            DashboardHeader(
              userName: userName,
              role: roleText,
              branch: _storeName,
              hasNotification:
                  // v2.2.36: dot lonceng = ADA NOTIF BELUM DIBACA saja.
                  // Sebelumnya ikut `_updateInfo.hasUpdate` → dot nyala terus
                  // walau notif sudah dibaca (release build number lama).
                  //
                  // v2.2.57+112: dot HANYA dari `_notifUnread`. Sebelumnya
                  // ada `|| (!_hasCheckedIn && _currentName.isNotEmpty)` yang
                  // bikin dot nyala terus selama belum absen, walau semua
                  // notif sudah dibaca. Notif "belum absen" kini di-remove
                  // saat check-in (lihat check-in handler), jadi badge bersih.
                  _notifUnread > 0,
              onBellTap: _onBellTap,
              onLogout: _confirmLogout,
              // Ikon cabang di header (ergonomis) — tap → bottom sheet.
              // Hanya Owner/Manager yang boleh pindah cabang; role lain
              // mendapat cabang saat login (lihat _load / login flow).
              showBranchIcon:
                  _branches.isNotEmpty &&
                  (role == 'Owner' || role == 'Manager'),
              branchName: _activeBranch?.name,
              onBranchTap:
                  (_branches.isNotEmpty &&
                      (role == 'Owner' || role == 'Manager'))
                  ? _showBranchPicker
                  : null,
            ),

            // Scrollable content: Profile card + Menu grid
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  await _load();
                },
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: Column(
                    children: [
                      // Profile card (now interactive — tap to flip)
                      ProfileStatsCard(
                        photoPath: cardPhoto,
                        initials: initials,
                        userName: userName,
                        role: roleText,
                        // v2.2.57+115: card stats menampilkan CABANG yang
                        // sedang dipilih (Owner/Manager bebas pindah cabang);
                        // null → "Semua Cabang". Sebelumnya selalu nama toko.
                        branch: _activeBranch?.name ?? 'Semua Cabang',
                        attendanceStatus: attendanceText,
                        salesValue: _omzet,
                        transactionCount: _trxCount,
                        shiftDuration: _shiftDuration,
                        avgValue: _avg,
                        topProduct: _topProduct,
                        // Flip card params
                        viewerRole: role,
                        viewerEmployeeId: session?.employeeId,
                        employeeId: _cardEmployeeId ?? session?.employeeId,
                        cardData: _cardData,
                        onAuthOwner: session?.role != 'Owner'
                            ? () async {
                                // Owner authenticating from non-Owner session
                                final attRepo = AttendanceRepository(
                                  ref.read(databaseProvider),
                                );
                                final emps = await attRepo.getEmployees();
                                final owner = emps.cast<Employee?>().firstWhere(
                                  (e) =>
                                      e!.role == 'Owner' &&
                                      e.status != 'Nonaktif',
                                  orElse: () => null,
                                );
                                if (owner == null) return false;
                                final result = await PinDialog.show(
                                  context: context,
                                  employeeName: owner.name,
                                  employeeRole: 'Owner',
                                  correctPin: owner.pin,
                                  showRemember: false,
                                  showFingerprint: true,
                                  showNfc: true,
                                  showBarcode: true,
                                  onFingerprint: () async =>
                                      await _authFingerprint(),
                                  onNfc: () async {
                                    final id =
                                        await NfcTagService.readEmployeeTag();
                                    return id?.toString();
                                  },
                                  onBarcode: AuthMethods.barcode(
                                    ref,
                                    expectedEmployeeId: owner.id,
                                  ),
                                  // v2.2.50 (A5): "Lupa PIN?" — cloud-only (needs Google re-auth)
                                  onForgotPin: NusaConfig.cloudEnabled
                                      ? () async {
                                          Navigator.of(context).pop();
                                          if (!mounted) return;
                                          final confirm = await showDialog<bool>(
                                            context: context,
                                            builder: (ctx) => AlertDialog(
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                              title: const Text('Lupa PIN?'),
                                              content: const Text(
                                                'Login ulang dengan akun Google pemilik toko untuk mengatur PIN baru. Lanjutkan?',
                                                style: TextStyle(fontSize: 14, height: 1.5),
                                              ),
                                              actions: [
                                                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
                                                FilledButton(
                                                  style: FilledButton.styleFrom(backgroundColor: NusaConfig.activePrimary, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
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
                                            if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Akun Google berbeda.')));
                                            return;
                                          }
                                          await GoogleAuthService.ensureStored(newUid);
                                          final db = ref.read(databaseProvider);
                                          final repo = AttendanceRepository(db);
                                          final emps = await repo.getEmployees();
                                          final o = emps.cast<Employee?>().firstWhere((Employee? e) => e!.role == 'Owner' || e.role == 'Manager', orElse: () => null);
                                          if (o == null) return;
                                          final newPin = await _promptNewPinDialog();
                                          if (!mounted || newPin == null) return;
                                          await repo.updateEmployee(id: o.id, name: o.name, pin: newPin, role: o.role, status: o.status);
                                          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN berhasil diubah')));
                                        }
                                      : null,
                                );
                                return result?.success ?? false;
                              }
                            : null,
                        onAbsenMasuk: () {
                          _handlePresensiTap();
                        },
                        onAbsenKeluar: () {
                          _handlePresensiTap();
                        },
                        onKontakWa: () {
                          // Show employee WA list for Owner
                          _showEmployeeWaList();
                        },
                        onLogout: () {
                          _confirmLogout();
                        },
                      ),

                      // v2.2.44 (L3): banner perpanjang lisensi (H-7 s/d habis).
                      if (_licenseInfo != null) ...[
                        _LicenseExpiryBanner(
                          info: _licenseInfo!,
                          onRenew: _openPayPage,
                        ),
                      ],

                      // Keuangan summary card
                      if (_financeExpense > 0 || _financeIncome > 0) ...[
                        const SizedBox(height: 12),
                        _KeuanganSummary(
                          expense: _financeExpense,
                          income: _financeIncome,
                        ),
                      ],

                      // Laundry stats
                      if (NusaConfig.isLaundryVariant &&
                          (_laundryToday > 0 || _laundryPending > 0)) ...[
                        const SizedBox(height: 12),
                        _LaundryStatsCard(
                          today: _laundryToday,
                          pending: _laundryPending,
                          ready: _laundryReady,
                          delivered: _laundryDelivered,
                          branch: _activeBranch?.name ?? 'Semua Cabang',
                          expanded: _laundryStatsExpanded,
                          onToggle: () {
                            setState(
                              () => _laundryStatsExpanded =
                                  !_laundryStatsExpanded,
                            );
                            SecureStore.setLaundryStatsExpanded(
                              !_laundryStatsExpanded,
                            );
                          },
                        ),
                      ],

                      // Salon stats
                      if (NusaConfig.isSalonVariant &&
                          (_salonToday > 0 || _salonConfirmed > 0)) ...[
                        const SizedBox(height: 12),
                        _SalonStatsCard(
                          today: _salonToday,
                          confirmed: _salonConfirmed,
                          waiting: _salonWaiting,
                          done: _salonDone,
                          branch: _activeBranch?.name ?? 'Semua Cabang',
                          expanded: _salonStatsExpanded,
                          onToggle: () {
                            setState(
                              () => _salonStatsExpanded = !_salonStatsExpanded,
                            );
                            SecureStore.setSalonStatsExpanded(
                              !_salonStatsExpanded,
                            );
                          },
                        ),
                      ],

                      // Bengkel stats
                      if (NusaConfig.isBengkelVariant &&
                          (_bengkelToday > 0 || _bengkelQueue > 0)) ...[
                        const SizedBox(height: 12),
                        _BengkelStatsCard(
                          today: _bengkelToday,
                          queue: _bengkelQueue,
                          inProgress: _bengkelInProgress,
                          done: _bengkelDone,
                          estimate: _bengkelEstimate,
                          branch: _activeBranch?.name ?? 'Semua Cabang',
                          expanded: _bengkelStatsExpanded,
                          onToggle: () {
                            setState(
                              () => _bengkelStatsExpanded =
                                  !_bengkelStatsExpanded,
                            );
                            SecureStore.setBengkelStatsExpanded(
                              !_bengkelStatsExpanded,
                            );
                          },
                        ),
                      ],

                      // Fotocopy/Percetakan stats
                      if (NusaConfig.isFotocopyVariant &&
                          (_printToday > 0 || _printPending > 0)) ...[
                        const SizedBox(height: 12),
                        _PrintOrderStatsCard(
                          today: _printToday,
                          pending: _printPending,
                          done: _printDone,
                          picked: _printPicked,
                          branch: _activeBranch?.name ?? 'Semua Cabang',
                          expanded: _printStatsExpanded,
                          onToggle: () {
                            setState(
                              () => _printStatsExpanded = !_printStatsExpanded,
                            );
                            SecureStore.setFotocopyStatsExpanded(
                              !_printStatsExpanded,
                            );
                          },
                        ),
                      ],

                      const SizedBox(height: 12),

                      // Menu grid with lock indicators (responsive columns)
                      LayoutBuilder(
                        builder: (_, constraints) {
                          final w = constraints.maxWidth;
                          final cols = w > 900 ? 5 : (w > 600 ? 4 : 3);
                          final spacing = w > 900 ? 24.0 : 20.0;
                          final pad = w > 900 ? 32.0 : 24.0;
                          return GridView.count(
                            crossAxisCount: cols,
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            padding: EdgeInsets.fromLTRB(pad, 0, pad, 12),
                            crossAxisSpacing: spacing,
                            mainAxisSpacing: spacing,
                            childAspectRatio: 0.72,
                            children: menuItems.map((item) {
                              final id = item['id'] as String;
                              return _MenuItem(
                                label: item['label'] as String,
                                icon: item['icon'] as String,
                                access: item['access'] as String,
                                onTap: () => _handleMenuTap(id),
                                badgeCount: id == 'pesanan_online'
                                    ? _onlinePending
                                    : (id == 'stok'
                                          ? _lowStockCount
                                          : null),
                                badgeColor: id == 'stok'
                                    ? NusaConfig.warning
                                    : null,
                              );
                            }).toList(),
                          );
                        },
                      ),

                      const SizedBox(height: 76), // space for FAB
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      // Big prominent floating Kasir button
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: SizedBox(
          width: double.infinity,
          height: 56,
          child: FloatingActionButton.extended(
            backgroundColor: NusaConfig.activePrimary,
            foregroundColor: Colors.white,
            icon: const Icon(Icons.point_of_sale_rounded, size: 24),
            label: const Text(
              'Kasir',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            elevation: 6,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            onPressed: () => _bukaKasir(),
          ),
        ),
      ),
    );
  }
}

/// Individual menu item with optional PIN-guard indicator.
class _MenuItem extends StatelessWidget {
  final String label;
  final String icon;
  final String access;
  final VoidCallback? onTap;
  final int? badgeCount;
  final Color? badgeColor;

  const _MenuItem({
    required this.label,
    required this.icon,
    required this.access,
    this.onTap,
    this.badgeCount,
    this.badgeColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Only PIN-guarded menus (kasir) show a 🔐 indicator; locked menus
    // are now hidden by the caller, so they never reach here.
    final isPinGuarded = access == '🔐';

    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Icon
          Stack(
            children: [
              Padding(
                padding: const EdgeInsets.all(4),
                child: MenuIcon(name: icon, size: 72),
              ),
              // PIN guard badge (kasir only)
              if (isPinGuarded)
                Positioned(
                  right: 0,
                  top: 0,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: NusaConfig.warning,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isDark
                            ? NusaConfig.darkBackground
                            : Colors.white,
                        width: 1.5,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.lock_rounded,
                      size: 10,
                      color: Colors.white,
                    ),
                  ),
                ),
              // Badge (count)
              if (badgeCount != null && badgeCount! > 0)
                Positioned(
                  right: 0,
                  top: 0,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: badgeColor ?? NusaConfig.activePrimary,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '$badgeCount',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            label,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: isPinGuarded
                  ? (isDark
                        ? NusaConfig.darkTextTertiary
                        : NusaConfig.textTertiary)
                  : (isDark
                        ? NusaConfig.darkTextPrimary
                        : NusaConfig.textPrimary),
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// v2.2.44 (L3): banner lisensi di dashboard — peringatan perpanjang H-7
/// sebelum habis. Lifetime / non-expliring tidak menampilkan apa-apa.
class _LicenseExpiryBanner extends StatelessWidget {
  final ({DateTime? expiresAt, String tier, String status}) info;
  final VoidCallback onRenew;
  const _LicenseExpiryBanner({required this.info, required this.onRenew});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final exp = info.expiresAt;
    final now = DateTime.now();

    // Status non-aktif (expired/cancelled) → banner merah wajib.
    final blocked = info.status == 'Expired' ||
        info.status == 'Cancelled';
    // Aktif tapi masa berlaku sudah lewat (expires_at < now) → harus segera
    // perpanjang; kalau lifetime (tanpa expires_at) → tidak perlu.
    final isExpired = !blocked && exp != null && exp.isBefore(now);
    // Aktif + belum habis → hitung H-7.
    final daysUntil = exp != null
        ? exp.difference(now).inDays
        : null;
    final approaching = !blocked && !isExpired && daysUntil != null && daysUntil <= 7;

    // Tidak ada yang perlu tampil → jangan render apapun.
    if (!blocked && !isExpired && !approaching) {
      return const SizedBox.shrink();
    }

    final urgent = blocked || isExpired;
    final accent = urgent ? Colors.red.shade600 : Colors.amber.shade800;
    final bg = urgent
        ? (isDark ? Colors.red.withValues(alpha: 0.12) : Colors.red.shade50)
        : (isDark ? Colors.amber.withValues(alpha: 0.12) : Colors.amber.shade50);

    String message;
    if (blocked) {
      message = info.status == 'Cancelled'
          ? 'Lisensi Anda dihentikan. Hubungi admin.'
          : 'Lisensi Anda telah kedaluwarsa. Perpanjang agar kasir aktif kembali.';
    } else if (isExpired) {
      message = 'Masa lisensi Anda telah berakhir. Perpanjang untuk melanjutkan.';
    } else if (daysUntil != null && daysUntil <= 0) {
      message = 'Lisensi berakhir hari ini. Perpanjang sekarang.';
    } else {
      message = daysUntil == 1
          ? 'Lisensi berlaku sampai ${_fmt(exp)} — tersisa 1 hari!'
          : 'Lisensi berakhir ${_fmt(exp)} — tersisa $daysUntil hari. Perpanjang agar tidak terputus.';
    }

    final expText = exp != null ? _fmt(exp) : null;
    final tierLabel = info.tier == 'trial'
        ? 'Trial'
        : info.tier == '1month'
            ? '1 Bulan'
            : 'Lifetime';

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: accent.withValues(alpha: 0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  urgent ? Icons.error_outline : Icons.event_outlined,
                  size: 18,
                  color: accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Lisensi ${urgent ? 'Perlu Perpanjangan' : 'Segera Berakhir'}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: accent,
                    ),
                  ),
                ),
                Text(
                  tierLabel,
                  style: TextStyle(fontSize: 11, color: accent, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              message,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary,
              ),
            ),
            if (expText != null) ...[
              const SizedBox(height: 2),
              Text(
                'Berlaku sampai: $expText',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: accent,
                ),
              ),
            ],
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: onRenew,
                style: ElevatedButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text('Perpanjang / Beli Lisensi'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _fmt(DateTime? d) =>
      d == null ? '—' : '${d.day}/${d.month}/${d.year}';
}

class _KeuanganSummary extends StatelessWidget {
  final int expense;
  final int income;
  const _KeuanganSummary({required this.expense, required this.income});
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final net = income - expense;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDark ? NusaConfig.darkBorder : NusaConfig.borderColor,
          ),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: NusaConfig.accentPurple.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.account_balance_wallet,
                    size: 16,
                    color: NusaConfig.accentPurple,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  'Keuangan Bulan Ini',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: isDark
                        ? NusaConfig.darkTextPrimary
                        : NusaConfig.textPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _finStat(
                  'Pengeluaran',
                  expense,
                  NusaConfig.activePrimary,
                  isDark,
                ),
                const SizedBox(width: 12),
                _finStat('Pemasukan', income, NusaConfig.accentGreen, isDark),
                const SizedBox(width: 12),
                _finStat(
                  'Selisih',
                  net,
                  net >= 0 ? NusaConfig.accentGreen : NusaConfig.activePrimary,
                  isDark,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _finStat(String label, int amount, Color color, bool isDark) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            formatRupiah(amount > 0 ? amount : 0),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: isDark
                  ? NusaConfig.darkTextSecondary
                  : NusaConfig.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Laundry mini stats — collapsible via a phone-style nav pill bar.
/// Collapsed: just a thin horizontal pill. Tap to expand the stats card.
class _LaundryStatsCard extends StatefulWidget {
  final int today, pending, ready, delivered;
  final String branch;
  final bool expanded;
  final VoidCallback onToggle;
  const _LaundryStatsCard({
    required this.today,
    required this.pending,
    required this.ready,
    required this.delivered,
    required this.branch,
    required this.expanded,
    required this.onToggle,
  });

  @override
  State<_LaundryStatsCard> createState() => _LaundryStatsCardState();
}

class _LaundryStatsCardState extends State<_LaundryStatsCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _slideCtrl;
  late Animation<double> _slideAnim;

  @override
  void initState() {
    super.initState();
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _slideAnim = CurvedAnimation(
      parent: _slideCtrl,
      curve: Curves.easeOutCubic,
    );
    if (widget.expanded) _slideCtrl.value = 1.0;
  }

  @override
  void didUpdateWidget(covariant _LaundryStatsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded != oldWidget.expanded) {
      if (widget.expanded) {
        _slideCtrl.forward();
      } else {
        _slideCtrl.reverse();
      }
    }
  }

  @override
  void dispose() {
    _slideCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = NusaConfig.primaryColor;
    final hintColor = isDark
        ? NusaConfig.darkTextTertiary
        : const Color(0xFFB0B0B0);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          // ── Pull pill bar (no card, no text, no animation — just the bar) ──
          GestureDetector(
            onTap: widget.onToggle,
            behavior: HitTestBehavior.opaque,
            child: AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: widget.expanded
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Container(
                        width: 48,
                        height: 5,
                        decoration: BoxDecoration(
                          color: hintColor.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
            ),
          ),

          // ── Expanded card (slide animation) ──
          SizeTransition(
            sizeFactor: _slideAnim,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isDark
                    ? NusaConfig.darkSurface
                    : NusaConfig.surfaceColor,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isDark
                      ? NusaConfig.darkBorder
                      : NusaConfig.borderColor,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.08 : 0.04),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: primaryColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          Icons.local_laundry_service_rounded,
                          size: 18,
                          color: primaryColor,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Laundry',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: isDark
                              ? NusaConfig.darkTextPrimary
                              : NusaConfig.textPrimary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // v2.2.57+115: keterangan cabang yang dipilih.
                      Expanded(
                        child: Text(
                          widget.branch,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: isDark
                                ? NusaConfig.darkTextTertiary
                                : NusaConfig.textTertiary,
                          ),
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: widget.onToggle,
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: primaryColor.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Icon(
                            Icons.keyboard_arrow_up_rounded,
                            size: 18,
                            color: isDark
                                ? NusaConfig.darkTextSecondary
                                : NusaConfig.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _laundryStat(
                        'Hari Ini',
                        widget.today,
                        NusaConfig.accentPurple,
                        isDark,
                      ),
                      _laundryStat(
                        'Diproses',
                        widget.pending,
                        NusaConfig.info,
                        isDark,
                      ),
                      _laundryStat(
                        'Siap',
                        widget.ready,
                        NusaConfig.success,
                        isDark,
                      ),
                      _laundryStat(
                        'Diambil',
                        widget.delivered,
                        NusaConfig.activePrimary,
                        isDark,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _laundryStat(String label, int count, Color color, bool isDark) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: isDark ? 0.10 : 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: color.withValues(alpha: isDark ? 0.15 : 0.12),
          ),
        ),
        child: Column(
          children: [
            Text(
              '$count',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: isDark
                    ? NusaConfig.darkTextTertiary
                    : NusaConfig.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Salon stats mini-card on dashboard.
class _SalonStatsCard extends StatefulWidget {
  final int today, confirmed, waiting, done;
  final String branch;
  final bool expanded;
  final VoidCallback onToggle;
  const _SalonStatsCard({
    required this.today,
    required this.confirmed,
    required this.waiting,
    required this.done,
    required this.branch,
    required this.expanded,
    required this.onToggle,
  });

  @override
  State<_SalonStatsCard> createState() => _SalonStatsCardState();
}

class _SalonStatsCardState extends State<_SalonStatsCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _slideCtrl;
  late Animation<double> _slideAnim;

  @override
  void initState() {
    super.initState();
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _slideAnim = CurvedAnimation(
      parent: _slideCtrl,
      curve: Curves.easeOutCubic,
    );
    if (widget.expanded) _slideCtrl.value = 1.0;
  }

  @override
  void didUpdateWidget(covariant _SalonStatsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded != oldWidget.expanded) {
      if (widget.expanded) {
        _slideCtrl.forward();
      } else {
        _slideCtrl.reverse();
      }
    }
  }

  @override
  void dispose() {
    _slideCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = NusaConfig.primaryColor;
    final hintColor = isDark
        ? NusaConfig.darkTextTertiary
        : const Color(0xFFB0B0B0);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          // ── Pull pill bar ──
          GestureDetector(
            onTap: widget.onToggle,
            behavior: HitTestBehavior.opaque,
            child: AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: widget.expanded
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Container(
                        width: 48,
                        height: 5,
                        decoration: BoxDecoration(
                          color: hintColor.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
            ),
          ),

          // ── Expanded card (slide animation) ──
          SizeTransition(
            sizeFactor: _slideAnim,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isDark
                    ? NusaConfig.darkSurface
                    : NusaConfig.surfaceColor,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isDark
                      ? NusaConfig.darkBorder
                      : NusaConfig.borderColor,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.08 : 0.04),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: primaryColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          Icons.content_cut_rounded,
                          size: 18,
                          color: primaryColor,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Salon',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: isDark
                              ? NusaConfig.darkTextPrimary
                              : NusaConfig.textPrimary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // v2.2.57+115: keterangan cabang yang dipilih.
                      Expanded(
                        child: Text(
                          widget.branch,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: isDark
                                ? NusaConfig.darkTextTertiary
                                : NusaConfig.textTertiary,
                          ),
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: widget.onToggle,
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: primaryColor.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Icon(
                            Icons.keyboard_arrow_up_rounded,
                            size: 18,
                            color: isDark
                                ? NusaConfig.darkTextSecondary
                                : NusaConfig.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _salonStat(
                        'Hari Ini',
                        widget.today,
                        NusaConfig.accentPurple,
                        isDark,
                      ),
                      _salonStat(
                        'Dikonfirmasi',
                        widget.confirmed,
                        NusaConfig.info,
                        isDark,
                      ),
                      _salonStat(
                        'Menunggu',
                        widget.waiting,
                        NusaConfig.warning,
                        isDark,
                      ),
                      _salonStat(
                        'Selesai',
                        widget.done,
                        NusaConfig.success,
                        isDark,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _salonStat(String label, int count, Color color, bool isDark) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: isDark ? 0.10 : 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: color.withValues(alpha: isDark ? 0.15 : 0.12),
          ),
        ),
        child: Column(
          children: [
            Text(
              '$count',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: isDark
                    ? NusaConfig.darkTextTertiary
                    : NusaConfig.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fotocopy/Percetakan dashboard stats card — expandable with slide animation.
class _PrintOrderStatsCard extends StatefulWidget {
  final int today, pending, done, picked;
  final String branch;
  final bool expanded;
  final VoidCallback onToggle;
  const _PrintOrderStatsCard({
    required this.today,
    required this.pending,
    required this.done,
    required this.picked,
    required this.branch,
    required this.expanded,
    required this.onToggle,
  });

  @override
  State<_PrintOrderStatsCard> createState() => _PrintOrderStatsCardState();
}

class _PrintOrderStatsCardState extends State<_PrintOrderStatsCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _slideCtrl;
  late Animation<double> _slideAnim;

  @override
  void initState() {
    super.initState();
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _slideAnim = CurvedAnimation(
      parent: _slideCtrl,
      curve: Curves.easeOutCubic,
    );
    if (widget.expanded) _slideCtrl.value = 1.0;
  }

  @override
  void didUpdateWidget(covariant _PrintOrderStatsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded != oldWidget.expanded) {
      if (widget.expanded) {
        _slideCtrl.forward();
      } else {
        _slideCtrl.reverse();
      }
    }
  }

  @override
  void dispose() {
    _slideCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = NusaConfig.primaryColor;
    final hintColor = isDark
        ? NusaConfig.darkTextTertiary
        : const Color(0xFFB0B0B0);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          GestureDetector(
            onTap: widget.onToggle,
            behavior: HitTestBehavior.opaque,
            child: AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: widget.expanded
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Container(
                        width: 48,
                        height: 5,
                        decoration: BoxDecoration(
                          color: hintColor.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
            ),
          ),

          // ── Expanded card (slide animation) ──
          SizeTransition(
            sizeFactor: _slideAnim,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isDark
                    ? NusaConfig.darkSurface
                    : NusaConfig.surfaceColor,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isDark
                      ? NusaConfig.darkBorder
                      : NusaConfig.borderColor,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.08 : 0.04),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: primaryColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          Icons.print_rounded,
                          size: 18,
                          color: primaryColor,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Order Cetak',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: isDark
                              ? NusaConfig.darkTextPrimary
                              : NusaConfig.textPrimary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // v2.2.57+115: keterangan cabang yang dipilih.
                      Expanded(
                        child: Text(
                          widget.branch,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: isDark
                                ? NusaConfig.darkTextTertiary
                                : NusaConfig.textTertiary,
                          ),
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: widget.onToggle,
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: primaryColor.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Icon(
                            Icons.keyboard_arrow_up_rounded,
                            size: 18,
                            color: isDark
                                ? NusaConfig.darkTextSecondary
                                : NusaConfig.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _printStat(
                        'Hari Ini',
                        widget.today,
                        NusaConfig.accentPurple,
                        isDark,
                      ),
                      _printStat(
                        'Diproses',
                        widget.pending,
                        NusaConfig.info,
                        isDark,
                      ),
                      _printStat(
                        'Selesai',
                        widget.done,
                        NusaConfig.success,
                        isDark,
                      ),
                      _printStat(
                        'Diambil',
                        widget.picked,
                        NusaConfig.activePrimary,
                        isDark,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _printStat(String label, int count, Color color, bool isDark) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: isDark ? 0.10 : 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: color.withValues(alpha: isDark ? 0.15 : 0.12),
          ),
        ),
        child: Column(
          children: [
            Text(
              '$count',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: isDark
                    ? NusaConfig.darkTextTertiary
                    : NusaConfig.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bengkel dashboard stats card — expandable with slide animation (mirror of salon).
class _BengkelStatsCard extends StatefulWidget {
  final int today, queue, inProgress, done, estimate;
  final String branch;
  final bool expanded;
  final VoidCallback onToggle;
  const _BengkelStatsCard({
    required this.today,
    required this.queue,
    required this.inProgress,
    required this.done,
    required this.estimate,
    required this.branch,
    required this.expanded,
    required this.onToggle,
  });

  @override
  State<_BengkelStatsCard> createState() => _BengkelStatsCardState();
}

class _BengkelStatsCardState extends State<_BengkelStatsCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _slideCtrl;
  late Animation<double> _slideAnim;

  @override
  void initState() {
    super.initState();
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _slideAnim = CurvedAnimation(
      parent: _slideCtrl,
      curve: Curves.easeOutCubic,
    );
    if (widget.expanded) _slideCtrl.value = 1.0;
  }

  @override
  void didUpdateWidget(covariant _BengkelStatsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded != oldWidget.expanded) {
      if (widget.expanded) {
        _slideCtrl.forward();
      } else {
        _slideCtrl.reverse();
      }
    }
  }

  @override
  void dispose() {
    _slideCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = NusaConfig.primaryColor;
    final hintColor = isDark
        ? NusaConfig.darkTextTertiary
        : const Color(0xFFB0B0B0);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          // ── Pull pill bar ──
          GestureDetector(
            onTap: widget.onToggle,
            behavior: HitTestBehavior.opaque,
            child: AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: widget.expanded
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Container(
                        width: 48,
                        height: 5,
                        decoration: BoxDecoration(
                          color: hintColor.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
            ),
          ),

          // ── Expanded card (slide animation) ──
          SizeTransition(
            sizeFactor: _slideAnim,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isDark
                    ? NusaConfig.darkSurface
                    : NusaConfig.surfaceColor,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isDark
                      ? NusaConfig.darkBorder
                      : NusaConfig.borderColor,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.08 : 0.04),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: primaryColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          Icons.directions_car_filled_outlined,
                          size: 18,
                          color: primaryColor,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Bengkel',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: isDark
                              ? NusaConfig.darkTextPrimary
                              : NusaConfig.textPrimary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // v2.2.57+115: keterangan cabang yang dipilih.
                      Expanded(
                        child: Text(
                          widget.branch,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: isDark
                                ? NusaConfig.darkTextTertiary
                                : NusaConfig.textTertiary,
                          ),
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: widget.onToggle,
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: primaryColor.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Icon(
                            Icons.keyboard_arrow_up_rounded,
                            size: 18,
                            color: isDark
                                ? NusaConfig.darkTextSecondary
                                : NusaConfig.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _bengkelStat(
                        'Hari Ini',
                        widget.today,
                        NusaConfig.warning,
                        isDark,
                      ),
                      _bengkelStat(
                        'Antrian',
                        widget.queue,
                        NusaConfig.info,
                        isDark,
                      ),
                      _bengkelStat(
                        'Dikerjakan',
                        widget.inProgress,
                        NusaConfig.accentPurple,
                        isDark,
                      ),
                      _bengkelStat(
                        'Selesai',
                        widget.done,
                        NusaConfig.success,
                        isDark,
                      ),
                    ],
                  ),
                  if (widget.estimate > 0) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: NusaConfig.accentGold.withValues(
                          alpha: isDark ? 0.12 : 0.10,
                        ),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: NusaConfig.accentGold.withValues(alpha: 0.2),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.receipt_long_outlined,
                            size: 16,
                            color: NusaConfig.accentGold,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Estimasi berjalan: ',
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark
                                  ? NusaConfig.darkTextSecondary
                                  : NusaConfig.textSecondary,
                            ),
                          ),
                          Text(
                            formatRupiah(widget.estimate),
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: NusaConfig.accentGold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bengkelStat(String label, int count, Color color, bool isDark) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: isDark ? 0.10 : 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: color.withValues(alpha: isDark ? 0.15 : 0.12),
          ),
        ),
        child: Column(
          children: [
            Text(
              '$count',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: isDark
                    ? NusaConfig.darkTextTertiary
                    : NusaConfig.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Menu icon — PNG icons from assets/icons/ (225px), resolved by [iconAssetPath].
class MenuIcon extends StatelessWidget {
  final String name;
  final double size;
  const MenuIcon({super.key, required this.name, this.size = 26});

  @override
  Widget build(BuildContext context) => Image.asset(
    iconAssetPath(name),
    width: size,
    height: size,
    fit: BoxFit.contain,
    errorBuilder: (_, __, ___) => Icon(
      Icons.grid_view_rounded,
      size: size,
      color: NusaConfig.activePrimary,
    ),
  );
}
