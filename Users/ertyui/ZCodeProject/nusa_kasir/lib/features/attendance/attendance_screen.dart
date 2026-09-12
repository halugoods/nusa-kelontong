import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nusa_kasir/core/providers.dart';
import 'package:nusa_kasir/core/config/nusa_config.dart';
import 'package:nusa_kasir/core/services/sound_service.dart';
import 'package:nusa_kasir/core/utils/format_rupiah.dart';
import 'package:nusa_kasir/data/database/app_database.dart';
import 'package:nusa_kasir/data/repositories/attendance_repository.dart';
import 'package:nusa_kasir/features/auth/employee_session_provider.dart';
import 'package:nusa_kasir/shared/widgets/nusa_search_bar.dart';
import 'package:nusa_kasir/shared/widgets/screen_scaffold.dart';
import 'package:nusa_kasir/shared/widgets/empty_state.dart';
import 'package:nusa_kasir/shared/widgets/top_toast.dart';
import 'package:nusa_kasir/shared/widgets/pin_dialog.dart';
import 'package:nusa_kasir/shared/services/biometric_service.dart';
import 'package:nusa_kasir/shared/services/nfc_tag_service.dart';
import 'package:nusa_kasir/shared/services/auth_methods.dart';
import 'package:nusa_kasir/core/utils/wa_phone.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:go_router/go_router.dart';

const _avatarColors = [
  Color(0xFFE63946), Color(0xFF3B82F6), Color(0xFF10B981),
  Color(0xFF8B5CF6), Color(0xFFF59E0B), Color(0xFFEC4899),
  Color(0xFF14B8A6), Color(0xFFF97316),
];
Color _avatarCol(String name) => _avatarColors[name.runes.fold(0, (a, b) => a + b) % _avatarColors.length];

class AttendanceScreen extends ConsumerStatefulWidget {
  AttendanceScreen({super.key});
  @override
  ConsumerState<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends ConsumerState<AttendanceScreen>
    with TickerProviderStateMixin {
  int _tab = 0; // 0 = Hari Ini, 1 = Riwayat
  List<Employee> _employees = [];
  Map<int, AttendanceData?> _today = {};
  Map<String, int> _summary = {};
  bool _loading = true;
  List<String> monthNames = [];

  // Filter
  final _searchCtrl = TextEditingController();
  String _query = '';
  String _roleFilter = 'Semua';

  // History
  int _histYear = DateTime.now().year;
  int _histMonth = DateTime.now().month;
  Map<int, Map<String, dynamic>> _monthlySummary = {};
  Map<String, List<AttendanceData>> _historyGrouped = {};
  bool _histLoading = false;

  // Expanded employee in Riwayat
  final Set<String> _expandedEmployees = {};

  final _roleOptions = ['Semua', 'Owner', 'Manager', 'Kasir', 'Gudang', 'Finance'];

  // Hero animation controllers
  final Map<int, AnimationController> _pulseControllers = {};

  // v2.2.57: staf layanan yang login melihat kartu "Pendapatan Saya"
  // (salon only — omset & komisi pribadi).
  bool _showMyEarnings = false;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() => setState(() => _query = _searchCtrl.text.toLowerCase()));
    _load();
    _checkMyEarnings();
  }

  Future<void> _checkMyEarnings() async {
    try {
      if (!NusaConfig.isSalonVariant) return;
      final session = ref.read(employeeSessionProvider);
      if (session == null) return;
      final emps = await AttendanceRepository(
        ref.read(databaseProvider),
      ).getEmployees();
      Employee? me;
      for (final e in emps) {
        if (e.id == session.employeeId) me = e;
      }
      if (!mounted) return;
      setState(() => _showMyEarnings = me?.isServiceStaff ?? false);
    } catch (_) {}
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    for (final c in _pulseControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  List<Employee> get _filtered {
    var list = _employees;
    if (_query.isNotEmpty) {
      list = list.where((e) => e.name.toLowerCase().contains(_query)).toList();
    }
    if (_roleFilter != 'Semua') {
      list = list.where((e) => e.role == _roleFilter).toList();
    }
    return list;
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final repo = AttendanceRepository(ref.read(databaseProvider));
    final emps = await repo.getEmployees();
    final todayMap = <int, AttendanceData?>{};
    for (final e in emps) {
      todayMap[e.id] = await repo.getToday(e.id);
    }
    final sum = await repo.getTodaySummary();
    if (mounted) {
      setState(() {
        _employees = emps;
        _today = todayMap;
        _summary = sum;
        _loading = false;
      });
    }
  }

  Future<void> _loadHistory() async {
    setState(() => _histLoading = true);
    final repo = AttendanceRepository(ref.read(databaseProvider));
    final ms = await repo.getMonthlySummary(year: _histYear, month: _histMonth);
    final hg = await repo.getHistoryGrouped(year: _histYear, month: _histMonth);
    if (mounted) {
      setState(() {
        _monthlySummary = ms;
        _historyGrouped = hg;
        _histLoading = false;
      });
    }
  }

  // ── Status helper ──────────────────────────────────────────────────

  /// Returns true if the check-in time is past the late threshold
  /// (work start + 15 min). Defaults to 08:15 if no work hours set.
  bool _isLate(String checkIn, Employee? emp) {
    final parts = checkIn.split(':');
    final h = int.tryParse(parts.isNotEmpty ? parts[0] : '0') ?? 0;
    final m = parts.length >= 2 ? (int.tryParse(parts[1]) ?? 0) : 0;
    final checkInMin = h * 60 + m;

    // Use employee's work start + 15 min as late threshold
    final ws = emp?.workStart ?? '08:00';
    final wsParts = ws.split(':');
    final wsH = int.tryParse(wsParts.isNotEmpty ? wsParts[0] : '8') ?? 8;
    final wsM = wsParts.length >= 2 ? (int.tryParse(wsParts[1]) ?? 0) : 0;
    final lateThreshold = wsH * 60 + wsM + 15; // 15 min grace period

    return checkInMin > lateThreshold;
  }

  Color _statusColor(AttendanceData? att, Employee? emp) {
    if (att == null) return NusaConfig.activePrimary; // belum
    if (att.status == 'Izin' || att.status == 'Sakit') return Color(0xFF3B82F6);
    if (att.checkOut != null) return Color(0xFF9CA3AF); // selesai
    if (att.checkIn != null) {
      if (_isLate(att.checkIn!, emp)) return NusaConfig.accentGold;
      return NusaConfig.accentGreen;
    }
    return NusaConfig.activePrimary;
  }

  String _statusLabel(AttendanceData? att, Employee? emp) {
    if (att == null) return 'Belum Hadir';
    if (att.status == 'Izin' || att.status == 'Sakit') return 'Izin/Sakit';
    if (att.checkOut != null) return 'Hadir Lengkap';
    if (att.checkIn != null) {
      if (_isLate(att.checkIn!, emp)) return 'Terlambat';
      return 'Sedang Bekerja';
    }
    return 'Belum Hadir';
  }

  // ── Bottom sheet: Absen Masuk / Pulang (PIN popup on submit) ──────

  void _showAbsenSheet(Employee e, {required bool isCheckIn}) {
    final cashCtrl = TextEditingController();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final title = isCheckIn ? 'Absen Masuk' : 'Absen Pulang';
    final cashLabel = isCheckIn ? 'Kas Awal' : 'Kas Akhir';
    final iconData = isCheckIn ? Icons.login_rounded : Icons.logout_rounded;
    final accentColor = isCheckIn ? NusaConfig.accentGreen : Color(0xFFEF4444);
    // Only require cash input if employee has the flag enabled
    final showCash = isCheckIn ? (e.requiresCashOpen ?? false) : (e.requiresCashClose ?? false);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => Container(
          decoration: BoxDecoration(
            color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: EdgeInsets.fromLTRB(24, 10, 24, MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle
              Container(
                margin: EdgeInsets.symmetric(vertical: 8),
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: isDark ? NusaConfig.darkDivider : NusaConfig.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              SizedBox(height: 8),
              // Big icon card
              Container(
                width: 64, height: 64,
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Icon(iconData, size: 32, color: accentColor),
              ),
              SizedBox(height: 12),
              // Title
              Text(title,
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800,
                      color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary)),
              SizedBox(height: 2),
              Text('${e.name} • ${e.role}',
                  style: TextStyle(fontSize: 13,
                      color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary)),
              SizedBox(height: 4),
              // Show work hours
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.schedule, size: 13,
                      color: isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary),
                  SizedBox(width: 4),
                  Text('${e.workStart ?? '08:00'} - ${e.workEnd ?? '17:00'}',
                      style: TextStyle(fontSize: 12,
                          color: isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary)),
                ],
              ),
              SizedBox(height: 20),
              // Employee avatar header
              Row(children: [
                Container(
                  width: 48, height: 48,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    color: _avatarCol(e.name).withValues(alpha: 0.15),
                    image: e.photoPath != null && e.photoPath!.isNotEmpty
                        ? DecorationImage(
                            image: FileImage(File(e.photoPath!), scale: 1.0),
                            fit: BoxFit.cover,
                            filterQuality: FilterQuality.low,
                          )
                        : null,
                  ),
                  alignment: Alignment.center,
                  child: (e.photoPath == null || e.photoPath!.isEmpty)
                      ? Text(e.name[0].toUpperCase(),
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: _avatarCol(e.name)))
                      : null,
                ),
                SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(e.name,
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700,
                            color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary)),
                    Text(e.role,
                        style: TextStyle(fontSize: 13,
                            color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary)),
                  ]),
                ),
              ]),
              SizedBox(height: 20),
              // Cash input — only shown when employee requires cash on check-in/out
              if (showCash)
                _bsInput(
                  controller: cashCtrl,
                  label: cashLabel,
                  hint: 'Masukkan nominal $cashLabel',
                  keyboardType: TextInputType.number,
                  isDark: isDark,
                  prefixIcon: Icons.account_balance_wallet_outlined,
                )
              else ...[
                // Subtle info text when no cash needed
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.info_outline, size: 15,
                          color: isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary),
                      SizedBox(width: 6),
                      Text('Tidak perlu isi $cashLabel',
                          style: TextStyle(fontSize: 12,
                              color: isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary)),
                    ],
                  ),
                ),
              ],
              SizedBox(height: 24),
              // Action buttons
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      side: BorderSide(color: isDark ? NusaConfig.darkInputBorder : NusaConfig.inputBorder),
                    ),
                    child: Text('Batal',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600,
                            color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary)),
                  ),
                ),
                SizedBox(width: 14),
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    onPressed: () async {
                      final amountText = cashCtrl.text.trim();
                      final amount = int.tryParse(amountText);
                      // Cash validation only when showCash is true
                      if (showCash && (amount == null || amount <= 0)) {
                        TopToast.error(context, '$cashLabel wajib diisi');
                        return;
                      }
                      // Show PIN dialog before processing
                      Navigator.pop(ctx);
                      final pinOk = await PinDialog.show(
                        context: context,
                        title: title,
                        subtitle: 'Masukkan PIN ${e.name}',
                        employeeName: e.name,
                        employeeRole: e.role,
                        correctPin: e.pin,
                        showRemember: false,
                        showFingerprint: true,
                        showNfc: true,
                        showBarcode: true,
                        onFingerprint: () async => await _authFingerprint(),
                        onNfc: () async {
                          final id = await NfcTagService.readEmployeeTag();
                          return id?.toString();
                        },
                        onBarcode: AuthMethods.barcode(ref, expectedEmployeeId: e.id),
                      );
                      if (pinOk?.success != true) return;

                      final repo = AttendanceRepository(ref.read(databaseProvider));
                      if (isCheckIn) {
                        await repo.checkInWithCash(e.id, amount ?? 0);
                        SoundService.I.play(NusaSound.presence);
                        if (mounted) TopToast.success(context, '${e.name} absen masuk ✅');
                      } else {
                        await repo.checkOutWithCash(e.id, amount ?? 0);
                        SoundService.I.play(NusaSound.presence);
                        if (mounted) TopToast.success(context, '${e.name} absen pulang ✅');
                      }
                      _load();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: accentColor,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    child: Text(title,
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    ).then((_) {
      cashCtrl.dispose();
    });
  }

  Future<bool> _authFingerprint() async {
    return BiometricService.authenticate(
      reason: 'Verifikasi biometrik untuk melanjutkan',
    );
  }

  // ── Bottom sheet: Izin ──────────────────────────────────────────

  void _showIzinSheet(Employee e) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.fromLTRB(24, 10, 24, 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: EdgeInsets.symmetric(vertical: 8),
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: isDark ? NusaConfig.darkDivider : NusaConfig.dividerColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            SizedBox(height: 12),
            Container(
              width: 64, height: 64,
              decoration: BoxDecoration(
                color: Color(0xFF3B82F6).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(Icons.event_busy_rounded, size: 32, color: Color(0xFF3B82F6)),
            ),
            SizedBox(height: 14),
            Text('Tandai Izin',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700,
                    color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary)),
            SizedBox(height: 6),
            Text('${e.name} akan ditandai izin hari ini.',
                style: TextStyle(fontSize: 14,
                    color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary)),
            SizedBox(height: 24),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: OutlinedButton.styleFrom(
                    padding: EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    side: BorderSide(color: isDark ? NusaConfig.darkInputBorder : NusaConfig.inputBorder),
                  ),
                  child: Text('Batal',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600,
                          color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary)),
                ),
              ),
              SizedBox(width: 14),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    final repo = AttendanceRepository(ref.read(databaseProvider));
                    await repo.markTodayStatus(e.id, 'Izin');
                    if (mounted) TopToast.success(context, '${e.name} ditandai Izin');
                    _load();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Color(0xFF3B82F6),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: Text('Konfirmasi',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  // ── Bottom sheet: Tutup Shift (merged from Shift feature) ──────────

  void _showCloseShiftSheet(Employee e, AttendanceData att) {
    final actualCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pettyCash = att.pettyCash ?? 0;
    final expectedCash = att.expectedCash ?? pettyCash;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => Container(
          decoration: BoxDecoration(
            color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: EdgeInsets.fromLTRB(24, 10, 24, MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: EdgeInsets.symmetric(vertical: 8),
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: isDark ? NusaConfig.darkDivider : NusaConfig.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              SizedBox(height: 8),
              Container(
                width: 64, height: 64,
                decoration: BoxDecoration(
                  color: NusaConfig.activePrimary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(18),
                ),
                child:  Icon(Icons.point_of_sale_rounded, size: 32, color: NusaConfig.activePrimary),
              ),
              SizedBox(height: 12),
              Text('Tutup Shift & Hitung Kas',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800,
                      color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary)),
              SizedBox(height: 4),
              Text('${e.name} • Kas awal: ${formatRupiah(pettyCash)}',
                  style: TextStyle(fontSize: 13,
                      color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary)),
              SizedBox(height: 20),
              // Expected cash info
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: (isDark ? NusaConfig.darkInputFill : NusaConfig.inputFill),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: isDark ? NusaConfig.darkInputBorder : NusaConfig.inputBorder),
                ),
                child: Row(children: [
                  Icon(Icons.info_outline, size: 18, color: NusaConfig.info),
                  SizedBox(width: 10),
                  Text('Kas diharapkan: ${formatRupiah(expectedCash)}',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: NusaConfig.info)),
                ]),
              ),
              SizedBox(height: 14),
              _bsInput(
                controller: actualCtrl,
                label: 'Kas Dihitung (Rp)',
                hint: 'Hitung uang dan masukkan total',
                keyboardType: TextInputType.number,
                isDark: isDark,
                prefixIcon: Icons.monetization_on_outlined,
              ),
              SizedBox(height: 14),
              _bsInput(
                controller: notesCtrl,
                label: 'Catatan (opsional)',
                hint: 'Misal: ada selisih karena refund...',
                isDark: isDark,
                prefixIcon: Icons.notes_rounded,
              ),
              SizedBox(height: 24),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      side: BorderSide(color: isDark ? NusaConfig.darkInputBorder : NusaConfig.inputBorder),
                    ),
                    child: Text('Batal',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600,
                            color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary)),
                  ),
                ),
                SizedBox(width: 14),
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    onPressed: () async {
                      final actualText = actualCtrl.text.trim();
                      final actual = int.tryParse(actualText) ?? 0;
                      if (actualText.isEmpty) {
                        TopToast.error(context, 'Masukkan jumlah kas yang dihitung');
                        return;
                      }
                      Navigator.pop(ctx);
                      HapticFeedback.mediumImpact();
                      final repo = AttendanceRepository(ref.read(databaseProvider));
                      final diff = await repo.closeShift(
                        employeeId: e.id,
                        actualCash: actual,
                        notes: notesCtrl.text.trim().isNotEmpty ? notesCtrl.text.trim() : null,
                      );
                      if (mounted) {
                        _showShiftResultDialog(e.name, pettyCash, expectedCash, actual, diff);
                        await _load();
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: NusaConfig.activePrimary,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    child: Text('Tutup Shift',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    ).then((_) {
      actualCtrl.dispose();
      notesCtrl.dispose();
    });
  }

  void _showShiftResultDialog(String name, int starting, int expected, int actual, int diff) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selisihNeg = diff < 0;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: NusaConfig.success.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.check_circle_rounded, color: NusaConfig.success, size: 24),
          ),
          SizedBox(width: 12),
          Expanded(child: Text('Shift Ditutup', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
                color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary)),
            SizedBox(height: 12),
            _resultRow('Kas Awal', formatRupiah(starting), isDark),
            SizedBox(height: 6),
            _resultRow('Kas Diharapkan (Sistem)', formatRupiah(expected), isDark),
            SizedBox(height: 6),
            _resultRow('Kas Aktual (Dihitung)', formatRupiah(actual), isDark),
            Divider(height: 18),
            _resultRow('Selisih', formatRupiah(diff), isDark,
                valueColor: selisihNeg ? NusaConfig.activePrimary : NusaConfig.success),
          ],
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: NusaConfig.activePrimary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () => Navigator.pop(ctx),
            child: Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget _resultRow(String label, String value, bool isDark, {Color? valueColor}) {
    return Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Text(label, style: TextStyle(fontSize: 13,
          color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary)),
      Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
          color: valueColor ?? (isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary))),
    ]);
  }

  // ── WhatsApp Reminder ──────────────────────────────────────────────

  void _sendWAReminder(Employee e) async {
    if (e.phone == null || e.phone!.isEmpty) return;
    final msg =
        'Halo ${e.name}, ini dari NUSA Kasir.\n\n'
        'Kamu belum absen masuk hari ini. Mohon segera absen ya.\n\nTerima kasih 🙏';
    // Normalisasi via helper (v2.2.35): 08xx → 628xx biar wa.me valid.
    final uri = waLink(e.phone!, text: msg);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final session = ref.watch(employeeSessionProvider);
    final isOwner = session?.role == 'Owner' || session?.role == 'Manager';

    return ScreenScaffold(
      'Presensi',
      Column(children: [
        SizedBox(height: 6),
        // Tab switch
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Expanded(
              child: Container(
                height: 36,
                decoration: BoxDecoration(
                  color: isDark ? NusaConfig.darkSurface : NusaConfig.backgroundColor,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor),
                ),
                child: Row(children: [
                  _segBtn('Hari Ini', 0, isDark: isDark),
                  _segBtn('Riwayat', 1, isDark: isDark),
                ]),
              ),
            ),
            if (_tab == 0) ...[
              SizedBox(width: 8),
              SizedBox(width: 130, child: _roleDropdown(isDark)),
            ] else ...[
              SizedBox(width: 8),
              SizedBox(width: 130, child: _monthDropdown(isDark)),
            ],
          ]),
        ),
        SizedBox(height: 6),
        // v2.2.57: kartu Pendapatan Saya untuk stylist yang login.
        if (_showMyEarnings)
          Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => context.push('/pendapatan-saya'),
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: isDark ? NusaConfig.darkSurface2 : NusaConfig.surfaceColor,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor),
                ),
                child: Row(children: [
                  Icon(Icons.payments_rounded, size: 18, color: NusaConfig.activePrimary),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text('Pendapatan Saya',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                            color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary)),
                  ),
                  Icon(Icons.chevron_right_rounded, size: 18,
                      color: isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary),
                ]),
              ),
            ),
          ),
        if (_showMyEarnings) SizedBox(height: 6),
        Expanded(child: _tab == 0 ? _todayTab(isDark, isOwner) : _historyTab(isDark)),
      ]),
    );
  }

  Widget _segBtn(String label, int idx, {bool isDark = false}) {
    final sel = idx == _tab;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() {
          _tab = idx;
          if (idx == 1) _loadHistory();
        }),
        child: Container(
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: sel ? NusaConfig.activePrimary : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(label,
              style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600,
                color: sel ? Colors.white : (isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary),
              )),
        ),
      ),
    );
  }

  Widget _monthDropdown(bool isDark) {
    final now = DateTime.now();
    final monthOptions = <Map<String, int>>[];
    for (var y = now.year; y >= now.year - 2; y--) {
      final endM = y == now.year ? now.month : 12;
      for (var m = endM; m >= 1; m--) {
        monthOptions.add({'year': y, 'month': m});
      }
    }
    monthNames = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun', 'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des'];
    final textSec = isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary;
    final textTer = isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary;
    final textPri = isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary;

    return Container(
      height: 36,
      padding: EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<Map<String, int>>(
          value: monthOptions.firstWhere(
            (o) => o['year'] == _histYear && o['month'] == _histMonth,
            orElse: () => monthOptions.first,
          ),
          isExpanded: true,
          isDense: true,
          icon: Icon(Icons.expand_more_rounded, size: 16, color: textTer),
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: textSec),
          dropdownColor: isDark ? NusaConfig.darkSurface : Colors.white,
          borderRadius: BorderRadius.circular(10),
          underline: SizedBox.shrink(),
          items: monthOptions.map((o) => DropdownMenuItem(
            value: o,
            child: Text('${monthNames[o['month']!]} ${o['year']}',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: textPri)),
          )).toList(),
          onChanged: (v) {
            if (v == null) return;
            setState(() { _histYear = v['year']!; _histMonth = v['month']!; });
            _loadHistory();
          },
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  TAB: HARI INI (redesigned)
  // ═══════════════════════════════════════════════════════════════════

  Widget _todayTab(bool isDark, bool isOwner) {
    return Column(children: [
      // Summary cards
      Padding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: SizedBox(
          height: 64,
          child: Row(children: [
            Expanded(child: _sumCard('Hadir', '${_summary['hadir'] ?? 0}', NusaConfig.accentGreen, isDark)),
            SizedBox(width: 6),
            Expanded(child: _sumCard('Terlambat', '${_summary['terlambat'] ?? 0}', NusaConfig.accentGold, isDark)),
            SizedBox(width: 6),
            Expanded(child: _sumCard('Izin', '${_summary['izin'] ?? 0}', Color(0xFF3B82F6), isDark)),
            SizedBox(width: 6),
            Expanded(child: _sumCard('Belum', '${_summary['belum'] ?? 0}', NusaConfig.activePrimary, isDark)),
          ]),
        ),
      ),
      SizedBox(height: 8),
      // Search bar (search bar standar v2.2.54)
      Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 0),
        child: NusaSearchBar(
          controller: _searchCtrl,
          hint: 'Cari nama karyawan...',
        ),
      ),
      SizedBox(height: 8),
      // Employee list
      Expanded(
        child: _loading
            ? Center(child: CircularProgressIndicator())
            : _filtered.isEmpty
                ? EmptyState(icon: Icons.person_off_outlined, message: 'Tidak ada karyawan')
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView.separated(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 24),
                      itemCount: _filtered.length,
                      separatorBuilder: (_, _) => SizedBox(height: 12),
                      itemBuilder: (_, i) => _employeeCardRedesigned(_filtered[i], isDark, isOwner),
                    ),
                  ),
      ),
    ]);
  }

  // ── NEW: Employee Card (redesigned with avatar ring, horizontal strips) ──

  Widget _employeeCardRedesigned(Employee e, bool isDark, bool isOwner) {
    final att = _today[e.id];
    final inTime = att?.checkIn;
    final outTime = att?.checkOut;
    final pettyCash = att?.pettyCash;
    final finalCash = att?.finalCash;
    final expectedCash = att?.expectedCash;
    final isCheckedIn = inTime != null;
    final isCheckedOut = outTime != null;
    final isIzin = att?.status == 'Izin' || att?.status == 'Sakit';
    final hasPhone = e.phone != null && e.phone!.isNotEmpty;
    final isShiftActive = isCheckedIn && !isCheckedOut && !isIzin && expectedCash != null;
    final statusColor = _statusColor(att, e);
    final statusLabel = _statusLabel(att, e);
    final borderClr = isDark ? NusaConfig.darkBorder : NusaConfig.borderColor;
    final surf = isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor;
    final textPri = isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary;
    final textSec = isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary;
    final textTer = isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary;

    return Container(
      decoration: BoxDecoration(
        color: surf,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: borderClr),
        boxShadow: [
          BoxShadow(
            color: isDark ? Colors.transparent : Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      padding: EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── Row 1: Avatar ring + Name + Role info ──
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Avatar with colored ring
          Container(
            width: 52, height: 52,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: statusColor, width: 2.5),
            ),
            child: Container(
              margin: EdgeInsets.all(2.5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: _avatarCol(e.name).withValues(alpha: 0.15),
                image: e.photoPath != null && e.photoPath!.isNotEmpty
                    ? DecorationImage(
                        image: FileImage(File(e.photoPath!), scale: 1.0),
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.low,
                      )
                    : null,
              ),
              alignment: Alignment.center,
              child: (e.photoPath == null || e.photoPath!.isEmpty)
                  ? Text(e.name[0].toUpperCase(),
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _avatarCol(e.name)))
                  : null,
            ),
          ),
          SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(e.name, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: textPri)),
                ),
                // Status badge — right-aligned, next to name, won't overflow
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(statusLabel,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: statusColor)),
                ),
              ]),
              SizedBox(height: 4),
              Wrap(spacing: 6, runSpacing: 4, children: [
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: NusaConfig.activePrimary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(e.role, style:  TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: NusaConfig.activePrimary)),
                ),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.schedule, size: 10, color: textTer),
                  SizedBox(width: 2),
                  Text('${e.workStart ?? '08:00'} - ${e.workEnd ?? '17:00'}',
                      style: TextStyle(fontSize: 10, color: textTer)),
                ]),
                if (hasPhone)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.phone_android, size: 10, color: Color(0xFF10B981).withValues(alpha: 0.8)),
                    SizedBox(width: 2),
                    Flexible(child: Text(e.phone!, style: TextStyle(fontSize: 10, color: textTer), overflow: TextOverflow.ellipsis)),
                  ]),
              ]),
            ]),
          ),
        ]),
        SizedBox(height: 14),

        // ── Row 2: Horizontal info strip ──
        Container(
          padding: EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          decoration: BoxDecoration(
            color: isDark ? NusaConfig.darkInputFill : NusaConfig.inputFill,
            borderRadius: BorderRadius.circular(12),
          ),
          child: IntrinsicHeight(
            child: Row(children: [
              // Masuk
              Expanded(
                child: _infoStrip(Icons.login_rounded, 'Masuk', inTime ?? '—',
                    color: inTime != null ? NusaConfig.accentGreen : null, isDark: isDark),
              ),
              // Vertical divider
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Container(width: 1,
                    color: isDark ? NusaConfig.darkDivider : NusaConfig.dividerColor),
              ),
              // Pulang
              Expanded(
                child: _infoStrip(Icons.logout_rounded, 'Pulang', outTime ?? '—',
                    color: outTime != null ? NusaConfig.accentGreen : null, isDark: isDark),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Container(width: 1,
                    color: isDark ? NusaConfig.darkDivider : NusaConfig.dividerColor),
              ),
              // Kas Awal
              Expanded(
                child: _infoStrip(Icons.account_balance_wallet_outlined, 'Kas Awal',
                    pettyCash != null ? formatRupiah(pettyCash) : '—', isDark: isDark),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Container(width: 1,
                    color: isDark ? NusaConfig.darkDivider : NusaConfig.dividerColor),
              ),
              // Kas Akhir
              Expanded(
                child: _infoStrip(Icons.monetization_on_outlined, 'Kas Akhir',
                    finalCash != null ? formatRupiah(finalCash) : '—', isDark: isDark),
              ),
            ]),
          ),
        ),

        // ── Row 3: Shift Aktif section (conditional) ──
        if (isShiftActive) ...[
          SizedBox(height: 12),
          Container(
            padding: EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: NusaConfig.accentGreen.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: NusaConfig.accentGreen.withValues(alpha: 0.2)),
            ),
            child: Column(children: [
              Row(children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: NusaConfig.accentGreen.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.hub_outlined, size: 20, color: NusaConfig.accentGreen),
                ),
                SizedBox(width: 10),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Shift Aktif', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: NusaConfig.accentGreen)),
                  Text('Kas diharapkan: ${formatRupiah(expectedCash!)}',
                      style: TextStyle(fontSize: 11, color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary)),
                ]),
                Spacer(),
                // Close shift button
                SizedBox(
                  height: 36,
                  child: ElevatedButton.icon(
                    onPressed: () => _showCloseShiftSheet(e, att!),
                    icon: Icon(Icons.stop_rounded, size: 16),
                    label: Text('Tutup Shift',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: NusaConfig.activePrimary,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ]),
            ]),
          ),
        ],

        SizedBox(height: 14),

        // ── Row 4: Action buttons (Single Primary Smart Action + Quick Actions) ──
        Row(children: [
          Expanded(
            child: SizedBox(
              height: 42,
              child: ElevatedButton.icon(
                onPressed: isIzin
                    ? null
                    : (!isCheckedIn
                        ? () => _showAbsenSheet(e, isCheckIn: true)
                        : (!isCheckedOut
                            ? () => _showAbsenSheet(e, isCheckIn: false)
                            : null)),
                icon: Icon(
                  !isCheckedIn
                      ? Icons.login_rounded
                      : (!isCheckedOut ? Icons.logout_rounded : Icons.check_circle_rounded),
                  size: 18,
                ),
                label: Text(
                  !isCheckedIn
                      ? 'Absen Masuk'
                      : (!isCheckedOut ? 'Absen Pulang' : 'Hadir Lengkap'),
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: !isCheckedIn
                      ? NusaConfig.accentGreen
                      : (!isCheckedOut ? Color(0xFFEF4444) : (isDark ? NusaConfig.darkSurface2 : Color(0xFFE2E8F0))),
                  foregroundColor: (!isCheckedIn || !isCheckedOut)
                      ? Colors.white
                      : (isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary),
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ),
          if (isOwner && !isCheckedIn && !isIzin) ...[
            SizedBox(width: 8),
            _iconBtn(Icons.event_busy_rounded, 'Izin/Sakit', () => _showIzinSheet(e)),
          ],
          if (isOwner && hasPhone && !isCheckedIn && !isIzin) ...[
            SizedBox(width: 8),
            _iconBtn(Icons.chat_bubble_outline_rounded, 'Kirim WA', () => _sendWAReminder(e)),
          ],
        ]),
      ]),
    );
  }

  // ── Horizontal info strip widget ──

  Widget _infoStrip(IconData icon, String label, String value, {Color? color, bool isDark = false}) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 4),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14,
            color: color ?? (isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary)),
        SizedBox(height: 4),
        Text(label, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600,
            color: isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary)),
        SizedBox(height: 2),
        Flexible(
          child: Text(value,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                  color: color ?? (isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ),
      ]),
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  TAB: RIWAYAT (redesigned — heatmap strips + daily detail)
  // ═══════════════════════════════════════════════════════════════════

  Widget _historyTab(bool isDark) {
    final textPri = isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary;
    final textSec = isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary;
    final textTer = isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary;
    final surf = isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor;
    final border = isDark ? NusaConfig.darkBorder : NusaConfig.borderColor;

    if (_histLoading) return Center(child: CircularProgressIndicator());

    int totalHadir = 0, totalTerlambat = 0, totalIzin = 0, totalAlpha = 0;
    for (final v in _monthlySummary.values) {
      totalHadir += (v['hadir'] as int?) ?? 0;
      totalTerlambat += (v['terlambat'] as int?) ?? 0;
      totalIzin += (v['izin'] as int?) ?? 0;
      totalAlpha += (v['alpha'] as int?) ?? 0;
    }

    monthNames = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun', 'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des'];

    return RefreshIndicator(
      onRefresh: _loadHistory,
      child: SingleChildScrollView(
        physics: AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.all(16),
        child: Column(children: [
          // Month navigation
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            GestureDetector(
              onTap: () {
                if (_histMonth == 1) {
                  setState(() { _histMonth = 12; _histYear--; });
                } else {
                  setState(() => _histMonth--);
                }
                _loadHistory();
              },
              child: Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: isDark ? NusaConfig.darkBorder : NusaConfig.borderColor),
                ),
                child: Icon(Icons.chevron_left, size: 20),
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 18),
              child: Text('${monthNames[_histMonth]} $_histYear',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: textPri)),
            ),
            GestureDetector(
              onTap: () {
                final now = DateTime.now();
                if (_histMonth == 12) {
                  if (!(_histYear + 1 > now.year || (_histYear + 1 == now.year && 1 > now.month))) {
                    setState(() { _histMonth = 1; _histYear++; });
                    _loadHistory();
                  }
                } else if (!(_histYear > now.year || (_histYear == now.year && _histMonth + 1 > now.month))) {
                  setState(() => _histMonth++);
                  _loadHistory();
                }
              },
              child: Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: isDark ? NusaConfig.darkBorder : NusaConfig.borderColor),
                ),
                child: Icon(Icons.chevron_right, size: 20),
              ),
            ),
          ]),
          SizedBox(height: 16),

          // ── 4 big stat cards ──
          Row(children: [
            Expanded(child: _bigStatCard('HADIR', totalHadir, NusaConfig.accentGreen, Icons.check_circle_rounded, isDark)),
            SizedBox(width: 8),
            Expanded(child: _bigStatCard('TERLAMBAT', totalTerlambat, NusaConfig.accentGold, Icons.watch_later_rounded, isDark)),
            SizedBox(width: 8),
            Expanded(child: _bigStatCard('IZIN', totalIzin, Color(0xFF3B82F6), Icons.event_busy_rounded, isDark)),
            SizedBox(width: 8),
            Expanded(child: _bigStatCard('ALPHA', totalAlpha, NusaConfig.activePrimary, Icons.cancel_rounded, isDark)),
          ]),
          SizedBox(height: 20),

          // ── Employee heatmap cards ──
          if (_historyGrouped.isEmpty)
            EmptyState(icon: Icons.no_accounts_outlined, message: 'Belum ada data presensi bulan ini'),

          ..._historyGrouped.entries.map((entry) {
            final empName = entry.key;
            final atts = entry.value;
            final emp = _employees.cast<Employee?>().firstWhere((e) => e!.name == empName, orElse: () => null);
            final ms = emp != null ? (_monthlySummary[emp.id] ?? {}) : <String, dynamic>{};
            final hadir = (ms['hadir'] as int?) ?? 0;
            final terlambat = (ms['terlambat'] as int?) ?? 0;
            final izin = (ms['izin'] as int?) ?? 0;
            final alpha = (ms['alpha'] as int?) ?? 0;
            final totalHari = hadir + terlambat + izin + alpha;
            final ratio = totalHari > 0 ? (hadir + terlambat) / totalHari : 0.0;
            final empRole = emp?.role ?? '';
            final empPhone = emp?.phone;
            final isExpanded = _expandedEmployees.contains(empName);

            // Build day status map
            final dayStatus = <int, String>{};
            for (final a in atts) {
              if (a.status == 'Izin' || a.status == 'Sakit') {
                dayStatus[a.date.day] = 'izin';
              } else if (a.checkOut != null) {
                dayStatus[a.date.day] = 'hadir';
              } else if (a.checkIn != null) {
                final parts = a.checkIn!.split(':');
                final h = int.tryParse(parts.isNotEmpty ? parts[0] : '0') ?? 0;
                final m = parts.length >= 2 ? (int.tryParse(parts[1]) ?? 0) : 0;
                // Use per-employee workStart + 15 min grace
                final ws = emp?.workStart ?? '08:00';
                final wsParts = ws.split(':');
                final wsH = int.tryParse(wsParts.isNotEmpty ? wsParts[0] : '8') ?? 8;
                final wsM = wsParts.length >= 2 ? (int.tryParse(wsParts[1]) ?? 0) : 0;
                final threshold = wsH * 60 + wsM + 15;
                if ((h * 60 + m) > threshold) {
                  dayStatus[a.date.day] = 'terlambat';
                } else {
                  dayStatus[a.date.day] = 'hadir';
                }
              }
            }

            // Also add shift info to att-day map for detail view
            final attByDay = <int, AttendanceData>{};
            for (final a in atts) {
              attByDay[a.date.day] = a;
            }

            return Container(
              margin: EdgeInsets.only(bottom: 12),
              padding: EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: surf,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: border),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // ── Header: Avatar + Name + Role + Ratio badge ──
                Row(children: [
                  Container(
                    width: 42, height: 42,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: ratio >= 0.8 ? NusaConfig.accentGreen : ratio >= 0.5 ? NusaConfig.accentGold : NusaConfig.activePrimary,
                        width: 2,
                      ),
                    ),
                    child: Container(
                      margin: EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: _avatarCol(empName).withValues(alpha: 0.15),
                        image: emp?.photoPath != null && emp!.photoPath!.isNotEmpty
                            ? DecorationImage(
                                image: FileImage(File(emp.photoPath!), scale: 1.0),
                                fit: BoxFit.cover,
                                filterQuality: FilterQuality.low,
                              )
                            : null,
                      ),
                      alignment: Alignment.center,
                      child: (emp == null || emp.photoPath == null || emp.photoPath!.isEmpty)
                          ? Text(empName[0].toUpperCase(),
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _avatarCol(empName)))
                          : null,
                    ),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(empName, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: textPri)),
                      if (empRole.isNotEmpty)
                        Text(empRole, style: TextStyle(fontSize: 11, color: textTer)),
                    ]),
                  ),
                  // Ratio badge
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: (ratio >= 0.8 ? NusaConfig.accentGreen : ratio >= 0.5 ? NusaConfig.accentGold : NusaConfig.activePrimary).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text('${(ratio * 100).toStringAsFixed(0)}%',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800,
                            color: ratio >= 0.8 ? NusaConfig.accentGreen : ratio >= 0.5 ? NusaConfig.accentGold : NusaConfig.activePrimary)),
                  ),
                ]),
                SizedBox(height: 12),

                // ── Mini heatmap strip ──
                GestureDetector(
                  onTap: () => setState(() {
                    if (isExpanded) {
                      _expandedEmployees.remove(empName);
                    } else {
                      _expandedEmployees.add(empName);
                    }
                  }),
                  child: Column(children: [
                    // Heatmap grid of colored dots
                    Row(children: [
                      _heatmapCell('H:$hadir', NusaConfig.accentGreen, isDark),
                      SizedBox(width: 6),
                      _heatmapCell('T:$terlambat', NusaConfig.accentGold, isDark),
                      SizedBox(width: 6),
                      _heatmapCell('I:$izin', Color(0xFF3B82F6), isDark),
                      SizedBox(width: 6),
                      _heatmapCell('A:$alpha', NusaConfig.activePrimary, isDark),
                      Spacer(),
                      Icon(isExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                          size: 20, color: textTer),
                    ]),
                    SizedBox(height: 6),
                    // 31-day strip
                    SizedBox(
                      height: 28,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        shrinkWrap: true,
                        children: List.generate(
                          DateTime(_histYear, _histMonth + 1, 0).day,
                          (idx) {
                            final day = idx + 1;
                            final status = dayStatus[day];
                            Color cellColor;
                            if (status == 'hadir') {
                              cellColor = NusaConfig.accentGreen;
                            } else if (status == 'terlambat') {
                              cellColor = NusaConfig.accentGold;
                            } else if (status == 'izin') {
                              cellColor = Color(0xFF3B82F6);
                            } else {
                              cellColor = isDark ? NusaConfig.darkDivider : NusaConfig.dividerColor;
                            }
                            final isToday = _histYear == DateTime.now().year &&
                                _histMonth == DateTime.now().month &&
                                day == DateTime.now().day;
                            return Container(
                              width: 24, height: 24,
                              margin: EdgeInsets.symmetric(horizontal: 1.5),
                              decoration: BoxDecoration(
                                color: cellColor.withValues(alpha: status != null ? 0.85 : 1.0),
                                borderRadius: BorderRadius.circular(6),
                                border: isToday
                                    ? Border.all(color: NusaConfig.activePrimary, width: 2)
                                    : null,
                              ),
                              alignment: Alignment.center,
                              child: Text('$day',
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: isToday ? FontWeight.w700 : FontWeight.w500,
                                    color: status != null ? Colors.white : textTer,
                                  )),
                            );
                          },
                        ),
                      ),
                    ),
                  ]),
                ),

                // ── Expanded daily detail ──
                if (isExpanded && atts.isNotEmpty) ...[
                  SizedBox(height: 8),
                  Divider(height: 1),
                  SizedBox(height: 8),
                  ...atts.map((a) {
                    final day = a.date.day;
                    final dayName = ['Min', 'Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab'][a.date.weekday % 7];
                    final status = dayStatus[day] ?? 'alpha';
                    Color dotColor;
                    String dotLabel;
                    switch (status) {
                      case 'hadir':
                        dotColor = NusaConfig.accentGreen;
                        dotLabel = 'Hadir';
                        break;
                      case 'terlambat':
                        dotColor = NusaConfig.accentGold;
                        dotLabel = 'Terlambat';
                        break;
                      case 'izin':
                        dotColor = Color(0xFF3B82F6);
                        dotLabel = 'Izin';
                        break;
                      default:
                        dotColor = NusaConfig.activePrimary;
                        dotLabel = 'Alpha';
                    }

                    return Padding(
                      padding: EdgeInsets.symmetric(vertical: 5),
                      child: Row(children: [
                        // Day number
                        Container(
                          width: 36, height: 36,
                          decoration: BoxDecoration(
                            color: dotColor.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          alignment: Alignment.center,
                          child: Text('$day',
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: dotColor)),
                        ),
                        SizedBox(width: 10),
                        // Day name + status
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(dayName,
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: textPri)),
                            Text(dotLabel,
                                style: TextStyle(fontSize: 11, color: dotColor, fontWeight: FontWeight.w600)),
                          ]),
                        ),
                        // Times
                        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                          if (a.checkIn != null)
                            Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.login_rounded, size: 12, color: NusaConfig.accentGreen),
                              SizedBox(width: 4),
                              Text(a.checkIn!,
                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: textPri)),
                            ]),
                          if (a.checkOut != null) ...[
                            SizedBox(height: 2),
                            Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.logout_rounded, size: 12, color: Color(0xFFEF4444)),
                              SizedBox(width: 4),
                              Text(a.checkOut!,
                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: textPri)),
                            ]),
                          ],
                        ]),
                        // Cash info (if exists)
                        if (a.pettyCash != null || a.finalCash != null) ...[
                          SizedBox(width: 10),
                          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                            if (a.pettyCash != null)
                              Text(formatRupiah(a.pettyCash!),
                                  style: TextStyle(fontSize: 10, color: textTer)),
                            if (a.finalCash != null)
                              Text(formatRupiah(a.finalCash!),
                                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                                      color: NusaConfig.activePrimary)),
                          ]),
                        ],
                      ]),
                    );
                  }),
                ],
              ]),
            );
          }),
          SizedBox(height: 8),
        ]),
      ),
    );
  }

  Widget _bigStatCard(String label, int count, Color color, IconData icon, bool isDark) {
    return Container(
      padding: EdgeInsets.symmetric(vertical: 14, horizontal: 10),
      decoration: BoxDecoration(
        color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isDark ? NusaConfig.darkBorder : NusaConfig.borderColor),
      ),
      child: Column(children: [
        Container(
          width: 36, height: 36,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 18, color: color),
        ),
        SizedBox(height: 8),
        Text('$count',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: color, height: 1.1)),
        SizedBox(height: 2),
        Text(label,
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary)),
      ]),
    );
  }

  Widget _heatmapCell(String label, Color color, bool isDark) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 8, height: 8,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
      SizedBox(width: 4),
      Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
          color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary)),
    ]);
  }

  // ── Bottom sheet text input helper ──

  Widget _bsInput({
    required TextEditingController controller,
    required String label,
    required String hint,
    required bool isDark,
    IconData? prefixIcon,
    bool obscure = false,
    int? maxLength,
    TextInputType? keyboardType,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscure,
      maxLength: maxLength,
      style: TextStyle(fontSize: 15,
          color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
            color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary),
        hintText: hint,
        hintStyle: TextStyle(fontSize: 15,
            color: isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary),
        counterText: '',
        prefixIcon: prefixIcon != null
            ? Icon(prefixIcon, size: 20,
                color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary)
            : null,
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: isDark ? NusaConfig.darkInputBorder : NusaConfig.inputBorder)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: isDark ? NusaConfig.darkInputBorder : NusaConfig.inputBorder)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide:  BorderSide(color: NusaConfig.activePrimary, width: 1.5)),
        filled: true,
        fillColor: isDark ? NusaConfig.darkInputFill : NusaConfig.inputFill,
      ),
    );
  }

  // ── Helper Widgets ──────────────────────────────────────────────

  Widget _roleDropdown(bool isDark) {
    return Container(
      height: 36,
      constraints: BoxConstraints(maxWidth: 130),
      padding: EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: isDark ? NusaConfig.darkSurface : NusaConfig.backgroundColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _roleOptions.contains(_roleFilter) ? _roleFilter : 'Semua',
          isDense: true,
          icon: Icon(Icons.expand_more_rounded, size: 18,
              color: isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary),
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
              color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary),
          dropdownColor: isDark ? NusaConfig.darkSurface : Colors.white,
          borderRadius: BorderRadius.circular(12),
          underline: SizedBox.shrink(),
          items: _roleOptions.map((r) => DropdownMenuItem(
            value: r,
            child: Text(r, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary)),
          )).toList(),
          onChanged: (v) => setState(() => _roleFilter = v ?? 'Semua'),
        ),
      ),
    );
  }

  Widget _sumCard(String label, String value, Color color, bool isDark) {
    return Container(
      padding: EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      decoration: BoxDecoration(
        color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isDark ? NusaConfig.darkBorder : NusaConfig.borderColor),
      ),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
            color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary)),
        SizedBox(height: 2),
        Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color, height: 1.1)),
      ]),
    );
  }

  Widget _textBtn(String label, Color color, {required bool enabled, required VoidCallback onTap}) {
    return SizedBox(
      height: 38,
      child: ElevatedButton(
        onPressed: enabled ? onTap : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          disabledBackgroundColor: color.withValues(alpha: 0.25),
          disabledForegroundColor: Colors.white54,
          elevation: 0,
          padding: EdgeInsets.symmetric(horizontal: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          minimumSize: Size.zero,
          textStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
        child: Text(label),
      ),
    );
  }

  Widget _iconBtn(IconData icon, String tooltip, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Tooltip(
        message: tooltip,
        child: Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            color: NusaConfig.activePrimary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, size: 18, color: NusaConfig.activePrimary),
        ),
      ),
    );
  }
}
