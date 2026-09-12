import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:share_plus/share_plus.dart';
import 'package:nusa_kasir/core/providers.dart';
import 'package:nusa_kasir/core/config/nusa_config.dart';
import 'package:nusa_kasir/core/utils/format_rupiah.dart';
import 'package:nusa_kasir/core/utils/report_export.dart';
import 'package:nusa_kasir/core/utils/report_pdf.dart';
import 'package:nusa_kasir/data/database/app_database.dart';
import 'package:nusa_kasir/data/repositories/report_repository.dart';
import 'package:nusa_kasir/data/repositories/attendance_repository.dart';
import 'package:nusa_kasir/data/repositories/finance_repository.dart';
import 'package:nusa_kasir/features/auth/employee_session_provider.dart';
import 'package:nusa_kasir/shared/widgets/nusa_card.dart';
import 'package:nusa_kasir/shared/widgets/nusa_button.dart';
import "package:nusa_kasir/shared/widgets/top_toast.dart";
import 'package:nusa_kasir/shared/widgets/screen_scaffold.dart';
import 'package:nusa_kasir/shared/widgets/skeleton_list.dart';
import 'package:nusa_kasir/shared/widgets/empty_state.dart';
import 'package:go_router/go_router.dart';

class ReportsScreen extends ConsumerStatefulWidget {
  ReportsScreen({super.key});
  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  int _tab = 0; // 0 = Penjualan, 1 = Laba Rugi
  int _refreshKey = 0;
  bool _exporting = false;

  // v2.2.54: filter laporan per karyawan — owner bisa lihat penjualan kasir
  // tertentu (mis. kasir A saja). Null = semua karyawan.
  int? _employeeFilter;
  List<Employee> _employees = const [];

  /// v2.2.57+121 (keamanan): employeeId yang WAJIB dipakai di SEMUA query
  /// laporan — Owner/Manager = [_employeeFilter] (null = semua); karyawan
  /// lain = employeeId diri sendiri (HANYA laporan miliknya; mencegah intip
  /// omzet rekan kerja). Dropdown filter karyawan disembunyikan untuk
  /// non-owner di build.
  int? get _scopedEmployee {
    final session = ref.read(employeeSessionProvider);
    final role = session?.role ?? '';
    if (role == 'Owner' || role == 'Manager') return _employeeFilter;
    return session?.employeeId;
  }

  /// v2.2.57+121 (keamanan): boleh lihat laporan SEMUA karyawan — Owner &
  /// Manager saja (sama dengan kebijakan transaksi).
  bool get _canViewAllReports {
    final session = ref.read(employeeSessionProvider);
    final role = session?.role ?? '';
    return role == 'Owner' || role == 'Manager';
  }

  @override
  void initState() {
    super.initState();
    _loadEmployees();
  }

  Future<void> _loadEmployees() async {
    try {
      final emps = await AttendanceRepository(
        ref.read(databaseProvider),
      ).getEmployees();
      if (!mounted) return;
      setState(() => _employees = emps);
    } catch (_) {}
  }

  /// F: "Ringkas dulu, detail on-demand" — grafik & detail di balik tombol
  /// "Lihat Detail" supaya layar pertama selalu ringkas & cepat.
  bool _detailOpen = false;

  // Period state
  String _period = 'Hari ini';
  DateTimeRange? _dateRange;

  /// Label ringkas rupiah ("Rp 12,3 jt") untuk kartu ringkasan.
  String _formatJt(int value) {
    if (value >= 1000000000) {
      final v = value / 1000000000;
      return 'Rp ${v.toStringAsFixed(v >= 10 ? 0 : 1)} M';
    }
    if (value >= 1000000) {
      final v = value / 1000000;
      return 'Rp ${v.toStringAsFixed(v >= 10 ? 0 : 1)} jt';
    }
    if (value >= 1000) {
      final v = value / 1000;
      return 'Rp ${v.toStringAsFixed(v >= 10 ? 0 : 1)} rb';
    }
    return formatRupiah(value);
  }

  (DateTime?, DateTime?) _range() {
    if (_period == 'custom' && _dateRange != null) {
      return (_dateRange!.start, _dateRange!.end);
    }
    final now = DateTime.now();
    switch (_period) {
      case 'Hari ini':
        return (DateTime(now.year, now.month, now.day), now);
      case 'Kemarin':
        final yesterday = DateTime(now.year, now.month, now.day - 1);
        return (yesterday, yesterday.add(Duration(days: 1)));
      case 'Minggu ini':
        return (now.subtract(Duration(days: 7)), now);
      case 'Bulan ini':
        return (now.subtract(Duration(days: 30)), now);
      case 'Tahun ini':
        return (DateTime(now.year, 1, 1), now);
      default:
        return (null, null);
    }
  }

  String _periodLabel() {
    if (_period == 'custom' && _dateRange != null) {
      return '${_dateRange!.start.day}/${_dateRange!.start.month} \u2013 ${_dateRange!.end.day}/${_dateRange!.end.month}/${_dateRange!.end.year}';
    }
    return _period;
  }

  Future<void> _pickDateRange() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      initialDateRange: _dateRange,
      helpText: 'Pilih Rentang Tanggal',
      cancelText: 'BATAL',
      confirmText: 'PILIH',
    );
    if (range != null) {
      setState(() {
        _dateRange = range;
        _period = 'custom';
        _refreshKey++;
      });
    }
  }

  // ── Export ─────────────────────────────────────────────────────────

  Future<String?> _pickFormat() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: isDark
                      ? NusaConfig.darkBorder
                      : NusaConfig.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Title
            Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                'Export Laporan',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: isDark
                      ? NusaConfig.darkTextPrimary
                      : NusaConfig.textPrimary,
                ),
              ),
            ),
            _exportOption(
              icon: Icons.table_chart,
              title: 'Export Excel (.xlsx)',
              desc: 'Spreadsheet lengkap dengan semua kolom transaksi',
              color: NusaConfig.accentGreen,
              isDark: isDark,
              onTap: () => Navigator.of(ctx).pop('excel'),
            ),
            SizedBox(height: 8),
            _exportOption(
              icon: Icons.description,
              title: 'Export CSV (.csv)',
              desc: 'File CSV ringan untuk import ke aplikasi lain',
              color: NusaConfig.info,
              isDark: isDark,
              onTap: () => Navigator.of(ctx).pop('csv'),
            ),
            SizedBox(height: 8),
            _exportOption(
              icon: Icons.picture_as_pdf,
              title: 'Export PDF Lengkap (.pdf)',
              desc: 'Laporan komprehensif dengan Laba/Rugi, grafik & analisis',
              color: NusaConfig.activePrimary,
              isDark: isDark,
              onTap: () => Navigator.of(ctx).pop('pdf'),
            ),
            SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _exportOption({
    required IconData icon,
    required String title,
    required String desc,
    required Color color,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkSurface2 : NusaConfig.backgroundColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDark ? NusaConfig.darkBorder : NusaConfig.borderColor,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? NusaConfig.darkTextPrimary
                          : NusaConfig.textPrimary,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    desc,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark
                          ? NusaConfig.darkTextTertiary
                          : NusaConfig.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: isDark
                  ? NusaConfig.darkTextTertiary
                  : NusaConfig.textTertiary,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _doExport(
    List<Transaction> items,
    Map<String, dynamic> sum,
    List<Map<String, dynamic>> top,
    List<Map<String, dynamic>> cats,
    Map<String, int> pays,
  ) async {
    final format = await _pickFormat();
    if (format == null) return;
    setState(() => _exporting = true);
    try {
      final stamp =
          '${DateTime.now().year}${DateTime.now().month}${DateTime.now().day}_${DateTime.now().hour}${DateTime.now().minute}';
      final name =
          'laporan_${_periodLabel().replaceAll(' ', '').toLowerCase()}_$stamp';
      if (format == 'pdf') {
        // Full comprehensive PDF with profit/loss
        final (from, to) = _range();
        final repo = ReportRepository(ref.read(databaseProvider));

        // Fetch additional data for full PDF
        Map<String, dynamic>? pl;
        try {
          pl = await repo.profitLoss(from: from, to: to);
        } catch (_) {
          // Profit/loss is optional for the PDF
        }

        final file = await exportFullReportPdf(
          period: _periodLabel(),
          summary: sum,
          profitLossData: pl,
          topProducts: top,
          categories: cats,
          payments: pays,
        );

        if (!mounted) return;
        TopToast.success(context, 'PDF berhasil dibuat');

        // Offer share
        final share = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Laporan Siap'),
            content: Text(
              'Laporan PDF lengkap telah dibuat. Bagikan sekarang?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text('Nanti'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text('Bagikan'),
              ),
            ],
          ),
        );

        if (share == true) {
          await SharePlus.instance.share(
            ShareParams(
              files: [XFile(file.path)],
              subject: 'Laporan NUSA Kasir',
              text: 'Laporan lengkap NUSA Kasir (${_periodLabel()})',
            ),
          );
        }
      } else {
        final file = format == 'excel'
            ? await exportExcel(items, name)
            : await exportCsv(items, name);
        if (!mounted) return;
        TopToast.success(context, 'Laporan berhasil diexport');
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path)],
            subject: 'Laporan NUSA Kasir',
            text: 'Laporan penjualan NUSA Kasir (${_periodLabel()})',
          ),
        );
      }
    } catch (e) {
      if (mounted) TopToast.error(context, 'Gagal ekspor: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// Quick share: directly generates and shares PDF without picking format.
  Future<void> _quickSharePdf() async {
    setState(() => _exporting = true);
    try {
      final (from, to) = _range();
      final repo = ReportRepository(ref.read(databaseProvider));

      // v2.2.57+121 (keamanan): export laporan ikut dibatasi ke scope
      // karyawan — kasir hanya bisa share laporan miliknya sendiri.
      final scope = _scopedEmployee;
      final data = await repo.summary(from: from, to: to, onlyEmployee: scope);
      final top = await repo.topProducts(
          from: from, to: to, onlyEmployee: scope);
      final cats = await repo.salesByCategory(
          from: from, to: to, onlyEmployee: scope);
      final pays = await repo.salesByPaymentMethod(
          from: from, to: to, onlyEmployee: scope);

      Map<String, dynamic>? pl;
      try {
        pl = await repo.profitLoss(from: from, to: to, onlyEmployee: scope);
      } catch (_) {}

      final file = await exportFullReportPdf(
        period: _periodLabel(),
        summary: data,
        profitLossData: pl,
        topProducts: top,
        categories: cats,
        payments: pays,
      );

      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: 'Laporan NUSA Kasir',
          text: 'Laporan lengkap NUSA Kasir (${_periodLabel()})',
        ),
      );
    } catch (e) {
      if (mounted) TopToast.error(context, 'Gagal membagikan: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// Export daftar pengeluaran (CSV/Excel) sesuai periode filter.
  Future<void> _exportExpenses() async {
    final format = await _pickFormat();
    if (format == null) return;
    if (format == 'pdf') {
      // PDF lengkap laporan periode juga mencakup ringkasan pengeluaran.
      await _quickSharePdf();
      return;
    }
    setState(() => _exporting = true);
    try {
      final (from, to) = _range();
      final financeRepo = FinanceRepository(ref.read(databaseProvider));
      final all = await financeRepo.getExpenses();
      final list = all.where((e) {
        if (from != null &&
            e.date.isBefore(DateTime(from.year, from.month, from.day))) {
          return false;
        }
        if (to != null &&
            e.date.isAfter(DateTime(to.year, to.month, to.day, 23, 59, 59))) {
          return false;
        }
        return true;
      }).toList();
      if (list.isEmpty) {
        if (mounted)
          TopToast.info(context, 'Tidak ada pengeluaran pada periode ini');
        return;
      }
      final stamp =
          '${DateTime.now().year}${DateTime.now().month}${DateTime.now().day}_${DateTime.now().hour}${DateTime.now().minute}';
      final name =
          'pengeluaran_${_periodLabel().replaceAll(' ', '').toLowerCase()}_$stamp';
      final file = format == 'excel'
          ? await exportExpenseExcel(list, name)
          : await exportExpenseCsv(list, name);
      if (!mounted) return;
      TopToast.success(context, 'Pengeluaran berhasil diexport');
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: 'Pengeluaran NUSA Kasir',
          text: 'Laporan pengeluaran NUSA Kasir (${_periodLabel()})',
        ),
      );
    } catch (e) {
      if (mounted) TopToast.error(context, 'Gagal ekspor pengeluaran: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ── PENJUALAN TAB ──────────────────────────────────────────────────

  Widget _penjualanTab() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final (from, to) = _range();
    final repo = ReportRepository(ref.read(databaseProvider));
    final labelClr = isDark
        ? NusaConfig.darkTextPrimary
        : NusaConfig.textPrimary;
    final textSec = isDark
        ? NusaConfig.darkTextSecondary
        : NusaConfig.textSecondary;
    final textTer = isDark
        ? NusaConfig.darkTextTertiary
        : NusaConfig.textTertiary;
    final surf = isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor;
    final border = isDark ? NusaConfig.darkBorder : NusaConfig.borderColor;

    return RefreshIndicator(
      onRefresh: () async => setState(() => _refreshKey++),
      child: SingleChildScrollView(
        physics: AlwaysScrollableScrollPhysics(),
        child: Column(
          children: [
            SizedBox(height: 8),
            // ── Comparison cards ──
            FutureBuilder<Map<String, dynamic>>(
              key: ValueKey('comp_$_refreshKey'),
              future: repo.summaryWithPrevious(
                from,
                to,
                onlyEmployee: _scopedEmployee,
              ),
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return Padding(
                    padding: EdgeInsets.all(20),
                    child: SkeletonList(),
                  );
                }
                final d = snap.data ?? {};
                final omzet = d['omzet'] as int? ?? 0;
                final count = d['count'] as int? ?? 0;
                final avg = d['avg'] as int? ?? 0;
                final hasPrev = d['hasPrevious'] as bool? ?? false;
                final omzetG = d['omzetGrowth'] as double? ?? 0;
                final countG = d['countGrowth'] as double? ?? 0;
                return Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _StatCard(
                              'Omzet',
                              _formatJt(omzet),
                              isDark: isDark,
                            ),
                          ),
                          SizedBox(width: 10),
                          Expanded(
                            child: _StatCard(
                              'Transaksi',
                              count.toString(),
                              isDark: isDark,
                            ),
                          ),
                          SizedBox(width: 10),
                          Expanded(
                            child: _StatCard(
                              'Rata-rata',
                              _formatJt(avg),
                              isDark: isDark,
                            ),
                          ),
                        ],
                      ),
                      if (hasPrev) ...[
                        SizedBox(height: 10),
                        Row(
                          children: [
                            _GrowthBadge('Omzet', omzetG, isDark: isDark),
                            SizedBox(width: 10),
                            _GrowthBadge('Transaksi', countG, isDark: isDark),
                          ],
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
            SizedBox(height: 12),
            // ── Bar Chart ──
            FutureBuilder<Map<String, int>>(
              key: ValueKey('chart_$_refreshKey'),
              future: repo.dailyRevenue(
                from: from,
                to: to,
                onlyEmployee: _scopedEmployee,
              ),
              builder: (ctx, snap) {
                final daily = snap.data ?? {};
                if (daily.isEmpty) return SizedBox.shrink();
                final entries = daily.entries.toList()
                  ..sort((a, b) => a.key.compareTo(b.key));
                final maxVal = entries.fold<int>(
                  0,
                  (m, e) => e.value > m ? e.value : m,
                );
                final show7 = entries.length > 7;
                final bars = show7
                    ? _buildDailyBars(entries, maxVal)
                    : _buildDayBars(entries, maxVal);
                return Container(
                  height: 220,
                  margin: EdgeInsets.fromLTRB(16, 0, 16, 16),
                  padding: EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: surf,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Pendapatan Harian',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: labelClr,
                        ),
                      ),
                      SizedBox(height: 16),
                      Expanded(
                        child: BarChart(
                          BarChartData(
                            barGroups: bars,
                            gridData: FlGridData(
                              show: true,
                              drawVerticalLine: false,
                              horizontalInterval: maxVal > 0
                                  ? (maxVal / 4).ceilToDouble()
                                  : 50000,
                            ),
                            titlesData: FlTitlesData(
                              show: true,
                              bottomTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  getTitlesWidget: (v, meta) {
                                    final idx = v.toInt();
                                    if (idx < 0 || idx >= entries.length) {
                                      return SizedBox.shrink();
                                    }
                                    return _barLabel(
                                      idx,
                                      entries,
                                      isDark: isDark,
                                    );
                                  },
                                  reservedSize: 28,
                                ),
                              ),
                              leftTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  reservedSize: 52,
                                  getTitlesWidget: (v, meta) => Text(
                                    formatRupiah(v.toInt()),
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: textTer,
                                    ),
                                  ),
                                ),
                              ),
                              topTitles: AxisTitles(
                                sideTitles: SideTitles(showTitles: false),
                              ),
                              rightTitles: AxisTitles(
                                sideTitles: SideTitles(showTitles: false),
                              ),
                            ),
                            borderData: FlBorderData(show: false),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            // ── "Lihat Detail" toggle: grafik & detail on-demand (F) ──
            Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: _detailToggle(isDark),
            ),
            if (_detailOpen) ...[
              // ── Best-Seller ──
              FutureBuilder<List<Map<String, dynamic>>>(
                key: ValueKey('top_$_refreshKey'),
                future: repo.topProducts(
                  from: from,
                  to: to,
                  limit: 5,
                  onlyEmployee: _scopedEmployee,
                ),
                builder: (ctx, snap) {
                  final list = snap.data ?? [];
                  if (list.isEmpty) return SizedBox.shrink();
                  return Container(
                    margin: EdgeInsets.fromLTRB(16, 0, 16, 16),
                    padding: EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: surf,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Produk Terlaris',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: labelClr,
                          ),
                        ),
                        SizedBox(height: 12),
                        ...list.asMap().entries.map((e) {
                          final p = e.value;
                          final qty = (p['qty'] as int?) ?? 0;
                          final rev = (p['revenue'] as int?) ?? 0;
                          final maxQty = list.isNotEmpty
                              ? (list.first['qty'] as int?) ?? 1
                              : 1;
                          final ratio = maxQty > 0 ? qty / maxQty : 0.0;
                          return Padding(
                            padding: EdgeInsets.only(bottom: 10),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              '${p['name']}',
                                              style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                                color: labelClr,
                                              ),
                                            ),
                                          ),
                                          Text(
                                            formatRupiah(rev),
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w700,
                                              color: NusaConfig.primaryColor,
                                            ),
                                          ),
                                        ],
                                      ),
                                      SizedBox(height: 4),
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(3),
                                        child: LinearProgressIndicator(
                                          value: ratio.clamp(0.0, 1.0),
                                          backgroundColor: NusaConfig
                                              .primaryColor
                                              .withValues(alpha: 0.12),
                                          valueColor: AlwaysStoppedAnimation(
                                            NusaConfig.activePrimary,
                                          ),
                                          minHeight: 4,
                                        ),
                                      ),
                                      SizedBox(height: 2),
                                      Text(
                                        '${qty}x terjual',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: textTer,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        }),
                      ],
                    ),
                  );
                },
              ),
              // ── Pie: Kategori ──
              FutureBuilder<List<Map<String, dynamic>>>(
                key: ValueKey('cat_$_refreshKey'),
                future: repo.salesByCategory(
                  from: from,
                  to: to,
                  onlyEmployee: _scopedEmployee,
                ),
                builder: (ctx, snap) {
                  final list = snap.data ?? [];
                  if (list.isEmpty) return SizedBox.shrink();
                  final totalRev = list.fold<int>(
                    0,
                    (s, c) => s + ((c['revenue'] as int?) ?? 0),
                  );
                  return Container(
                    margin: EdgeInsets.fromLTRB(16, 0, 16, 16),
                    padding: EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: surf,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Penjualan per Kategori',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: labelClr,
                          ),
                        ),
                        SizedBox(height: 12),
                        Row(
                          children: [
                            SizedBox(
                              width: 130,
                              height: 130,
                              child: PieChart(
                                PieChartData(
                                  sections: list.asMap().entries.map((e) {
                                    final cat = e.value;
                                    final pct = totalRev > 0
                                        ? ((cat['revenue'] as int) / totalRev) *
                                              100
                                        : 0.0;
                                    return PieChartSectionData(
                                      value: (cat['revenue'] as int).toDouble(),
                                      title: '${pct.toStringAsFixed(0)}%',
                                      titleStyle: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.white,
                                      ),
                                      color:
                                          _catColors[e.key % _catColors.length],
                                      radius: 55,
                                    );
                                  }).toList(),
                                  sectionsSpace: 2,
                                  centerSpaceRadius: 0,
                                ),
                              ),
                            ),
                            SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                children: list.take(6).map((c) {
                                  final pct = totalRev > 0
                                      ? ((c['revenue'] as int) / totalRev) * 100
                                      : 0.0;
                                  return Padding(
                                    padding: EdgeInsets.only(bottom: 6),
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 10,
                                          height: 10,
                                          margin: EdgeInsets.only(right: 8),
                                          decoration: BoxDecoration(
                                            color:
                                                _catColors[list.indexOf(c) %
                                                    _catColors.length],
                                            borderRadius: BorderRadius.circular(
                                              2,
                                            ),
                                          ),
                                        ),
                                        Expanded(
                                          child: Text(
                                            '${c['category']}',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: textSec,
                                            ),
                                          ),
                                        ),
                                        Text(
                                          '${pct.toStringAsFixed(0)}%',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                            color: labelClr,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
              // ── Pie: Metode Pembayaran ──
              FutureBuilder<Map<String, int>>(
                key: ValueKey('pay_$_refreshKey'),
                future: repo.salesByPaymentMethod(
                  from: from,
                  to: to,
                  onlyEmployee: _scopedEmployee,
                ),
                builder: (ctx, snap) {
                  final pays = snap.data ?? {};
                  if (pays.isEmpty || pays.values.every((v) => v == 0)) {
                    return SizedBox.shrink();
                  }
                  final totalPay = pays.values.fold(0, (s, v) => s + v);
                  final sorted = pays.entries.toList()
                    ..sort((a, b) => b.value.compareTo(a.value));
                  return Container(
                    margin: EdgeInsets.fromLTRB(16, 0, 16, 16),
                    padding: EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: surf,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Metode Pembayaran',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: labelClr,
                          ),
                        ),
                        SizedBox(height: 12),
                        Row(
                          children: [
                            SizedBox(
                              width: 130,
                              height: 130,
                              child: PieChart(
                                PieChartData(
                                  sections: sorted.asMap().entries.map((e) {
                                    final method = e.value.key;
                                    final amt = e.value.value;
                                    final pct = totalPay > 0
                                        ? (amt / totalPay) * 100
                                        : 0.0;
                                    return PieChartSectionData(
                                      value: amt.toDouble(),
                                      title: '${pct.toStringAsFixed(0)}%',
                                      titleStyle: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.white,
                                      ),
                                      color: _payColor(method),
                                      radius: 55,
                                    );
                                  }).toList(),
                                  sectionsSpace: 2,
                                  centerSpaceRadius: 0,
                                ),
                              ),
                            ),
                            SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                children: sorted.map((e) {
                                  final pct = totalPay > 0
                                      ? (e.value / totalPay) * 100
                                      : 0.0;
                                  return Padding(
                                    padding: EdgeInsets.only(bottom: 6),
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 10,
                                          height: 10,
                                          margin: EdgeInsets.only(right: 8),
                                          decoration: BoxDecoration(
                                            color: _payColor(e.key),
                                            borderRadius: BorderRadius.circular(
                                              2,
                                            ),
                                          ),
                                        ),
                                        Expanded(
                                          child: Text(
                                            e.key,
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: textSec,
                                            ),
                                          ),
                                        ),
                                        Text(
                                          '${pct.toStringAsFixed(0)}%',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                            color: labelClr,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 6),
                        Text(
                          '${formatRupiah(totalPay)} total',
                          style: TextStyle(fontSize: 11, color: textTer),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ], // end _detailOpen (Penjualan)
            // ── Export + Share buttons ──
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: NusaButton(
                      _exporting ? 'Memproses...' : 'Export Laporan',
                      fullWidth: true,
                      onPressed: _exporting
                          ? null
                          : () async {
                              final data = await repo.summary(
                                from: from,
                                to: to,
                              );
                              final items =
                                  (data['items'] as List<Transaction>?) ?? [];
                              final top = await repo.topProducts(
                                from: from,
                                to: to,
                              );
                              final cats = await repo.salesByCategory(
                                from: from,
                                to: to,
                              );
                              final pays = await repo.salesByPaymentMethod(
                                from: from,
                                to: to,
                              );
                              await _doExport(items, data, top, cats, pays);
                            },
                    ),
                  ),
                  SizedBox(width: 10),
                  _iconButton(
                    icon: Icons.share_rounded,
                    label: 'Bagikan',
                    color: NusaConfig.activePrimary,
                    isDark: isDark,
                    onPressed: _exporting ? null : _quickSharePdf,
                    loading: _exporting,
                  ),
                ],
              ),
            ),
            SizedBox(height: 12),
            // ── Transaction list ──
            FutureBuilder<List<Transaction>>(
              key: ValueKey('list_$_refreshKey'),
              future: repo.getTransactions(
                from: from,
                to: to,
                onlyEmployee: _scopedEmployee,
              ),
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return Padding(
                    padding: EdgeInsets.all(16),
                    child: SkeletonList(),
                  );
                }
                if (snap.hasError) {
                  return Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(
                      child: Text(
                        'Gagal memuat: ${snap.error}',
                        style: TextStyle(color: textSec),
                      ),
                    ),
                  );
                }
                final list = snap.data ?? [];
                if (list.isEmpty) {
                  return Padding(
                    padding: EdgeInsets.all(16),
                    child: EmptyState(
                      icon: Icons.bar_chart_outlined,
                      message: 'Belum ada transaksi',
                    ),
                  );
                }
                return ListView.separated(
                  shrinkWrap: true,
                  physics: NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: list.length,
                  separatorBuilder: (_, __) => SizedBox(height: 10),
                  itemBuilder: (_, i) => _TxCard(tx: list[i], isDark: isDark),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// F: tombol "Lihat Detail" — buka/tutup grafik tambahan (best-seller,
  /// pie kategori, metode bayar, daftar transaksi). Ringkas dulu.
  Widget _detailToggle(bool isDark) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: () => setState(() => _detailOpen = !_detailOpen),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: _detailOpen
                ? NusaConfig.activePrimary.withValues(alpha: 0.12)
                : (isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _detailOpen
                  ? NusaConfig.activePrimary.withValues(alpha: 0.5)
                  : (isDark ? NusaConfig.darkBorder : NusaConfig.borderColor),
            ),
          ),
          child: Row(
            children: [
              Icon(
                _detailOpen
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
                size: 20,
                color: NusaConfig.activePrimary,
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  _detailOpen ? 'Sembunyikan Detail' : 'Lihat Detail',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: NusaConfig.activePrimary,
                  ),
                ),
              ),
              if (!_detailOpen)
                Text(
                  'Best seller · kategori · metode bayar',
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

  Widget _iconButton({
    required IconData icon,
    required String label,
    required Color color,
    required bool isDark,
    required VoidCallback? onPressed,
    bool loading = false,
  }) {
    // Tinggi 40 konsisten dengan NusaButton 'Export Laporan' di Row yang
    // sama — supaya sejajar atas-bawah.
    return SizedBox(
      height: 40,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: isDark ? 0.15 : 0.1),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: color.withValues(alpha: 0.25)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                loading
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: color,
                        ),
                      )
                    : Icon(icon, size: 18, color: color),
                SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static const _catColors = [
    Color(0xFFE63946),
    Color(0xFF3B82F6),
    Color(0xFF10B981),
    Color(0xFF8B5CF6),
    Color(0xFFF59E0B),
    Color(0xFFEC4899),
  ];

  Color _payColor(String method) {
    switch (method) {
      case 'Tunai':
        return NusaConfig.payCash;
      case 'QRIS':
        return NusaConfig.payQris;
      case 'Transfer':
        return NusaConfig.payTransfer;
      default:
        return NusaConfig.textSecondary;
    }
  }

  List<BarChartGroupData> _buildDailyBars(
    List<MapEntry<String, int>> entries,
    int maxVal,
  ) {
    return List.generate(entries.length, (i) {
      return BarChartGroupData(
        x: i,
        barRods: [
          BarChartRodData(
            toY: entries[i].value.toDouble(),
            gradient: LinearGradient(
              colors: [
                NusaConfig.activePrimary.withValues(alpha: 0.65),
                NusaConfig.activePrimary,
              ],
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
            ),
            width: entries.length > 15 ? 8 : 14,
            borderRadius: BorderRadius.circular(6),
          ),
        ],
      );
    });
  }

  List<BarChartGroupData> _buildDayBars(
    List<MapEntry<String, int>> entries,
    int maxVal,
  ) {
    return List.generate(entries.length, (i) {
      return BarChartGroupData(
        x: i,
        barRods: [
          BarChartRodData(
            toY: entries[i].value.toDouble(),
            gradient: LinearGradient(
              colors: [
                NusaConfig.activePrimary.withValues(alpha: 0.65),
                NusaConfig.activePrimary,
              ],
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
            ),
            width: 22,
            borderRadius: BorderRadius.circular(8),
          ),
        ],
      );
    });
  }

  Widget _barLabel(
    int idx,
    List<MapEntry<String, int>> entries, {
    bool isDark = false,
  }) {
    final key = entries[idx].key;
    final parts = key.split('-');
    if (parts.length == 3) {
      if (entries.length <= 7) {
        final dt = DateTime.tryParse(key);
        if (dt != null) {
          final names = ['Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'];
          final wd = dt.weekday - 1;
          if (wd >= 0 && wd < 7) {
            return Text(
              names[wd],
              style: TextStyle(
                fontSize: 11,
                color: isDark
                    ? NusaConfig.darkTextTertiary
                    : NusaConfig.textTertiary,
              ),
            );
          }
        }
      }
      return Text(
        '${parts[2]}/${parts[1]}',
        style: TextStyle(
          fontSize: 11,
          color: isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary,
        ),
      );
    }
    return SizedBox.shrink();
  }

  // ── LABA RUGI TAB ──────────────────────────────────────────────────

  Widget _labaRugiTab() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final (from, to) = _range();
    final repo = ReportRepository(ref.read(databaseProvider));
    final textSec = isDark
        ? NusaConfig.darkTextSecondary
        : NusaConfig.textSecondary;
    final textTer = isDark
        ? NusaConfig.darkTextTertiary
        : NusaConfig.textTertiary;

    return FutureBuilder<Map<String, dynamic>>(
      key: ValueKey('pl_$_refreshKey'),
      future: repo.profitLoss(from: from, to: to),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return SkeletonList();
        }
        if (snap.hasError) {
          return Center(
            child: Text(
              'Gagal memuat: ${snap.error}',
              style: TextStyle(color: textSec),
            ),
          );
        }
        final d = snap.data ?? {};
        final pendapatan = d['pendapatan'] as int? ?? 0;
        final hpp = d['hpp'] as int? ?? 0;
        final retur = d['retur'] as int? ?? 0;
        final hppRetur = d['hppRetur'] as int? ?? 0;
        final labaKotor = d['labaKotor'] as int? ?? 0;
        final expenses = d['expenses'] as int? ?? 0;
        final payroll = d['payroll'] as int? ?? 0;
        final waste = d['waste'] as int? ?? 0;
        final liqIn = d['liquidityIn'] as int? ?? 0;
        final liqOut = d['liquidityOut'] as int? ?? 0;
        final totalBeban = d['totalBeban'] as int? ?? 0;
        final labaBersih = d['labaBersih'] as int? ?? 0;
        final txCount = d['txCount'] as int? ?? 0;

        return RefreshIndicator(
          onRefresh: () async => setState(() => _refreshKey++),
          child: ListView(
            padding: EdgeInsets.all(16),
            children: [
              // Header card
              NusaCard(
                Column(
                  children: [
                    Text(
                      labaBersih >= 0 ? 'Laba Bersih' : 'Rugi Bersih',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: textSec,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      formatRupiah(labaBersih.abs()),
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w800,
                        color: labaBersih >= 0
                            ? NusaConfig.accentGreenDark
                            : NusaConfig.activePrimary,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      '$txCount transaksi',
                      style: TextStyle(fontSize: 12, color: textTer),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 16),
              // ── Export + Share buttons in Laba Rugi tab too ──
              Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: NusaButton(
                        _exporting ? 'Memproses...' : 'Export Laporan',
                        fullWidth: true,
                        onPressed: _exporting
                            ? null
                            : () async {
                                final data = await repo.summary(
                                  from: from,
                                  to: to,
                                );
                                final items =
                                    (data['items'] as List<Transaction>?) ?? [];
                                final top = await repo.topProducts(
                                  from: from,
                                  to: to,
                                );
                                final cats = await repo.salesByCategory(
                                  from: from,
                                  to: to,
                                );
                                final pays = await repo.salesByPaymentMethod(
                                  from: from,
                                  to: to,
                                );
                                await _doExport(items, data, top, cats, pays);
                              },
                      ),
                    ),
                    SizedBox(width: 10),
                    _iconButton(
                      icon: Icons.share_rounded,
                      label: 'Bagikan',
                      color: NusaConfig.activePrimary,
                      isDark: isDark,
                      onPressed: _exporting ? null : _quickSharePdf,
                      loading: _exporting,
                    ),
                  ],
                ),
              ),
              _plSection('Pendapatan', [
                _plRow(
                  'Pendapatan Penjualan',
                  formatRupiah(pendapatan),
                  isHighlight: true,
                  isDark: isDark,
                ),
                if (retur > 0)
                  _plRow(
                    'Retur / Refund',
                    formatRupiah(retur),
                    isDeduct: true,
                    isDark: isDark,
                  ),
                _plRow(
                  'HPP (Harga Pokok Penjualan)',
                  '${formatRupiah(hpp)}',
                  isDeduct: true,
                  isDark: isDark,
                ),
                if (hppRetur > 0)
                  _plRow(
                    'HPP Barang Retur',
                    formatRupiah(hppRetur),
                    isAdd: true,
                    isDark: isDark,
                  ),
                _plDivider(isDark: isDark),
                _plRow(
                  'Laba Kotor',
                  formatRupiah(labaKotor),
                  isBold: true,
                  color: labaKotor >= 0
                      ? NusaConfig.accentGreenDark
                      : NusaConfig.activePrimary,
                  isDark: isDark,
                ),
              ], isDark: isDark),
              SizedBox(height: 12),
              _plSection('Beban', [
                _plRow(
                  'Pengeluaran Operasional',
                  formatRupiah(expenses),
                  isDeduct: true,
                  isDark: isDark,
                ),
                _plRow(
                  'Payroll / Gaji',
                  formatRupiah(payroll),
                  isDeduct: true,
                  isDark: isDark,
                ),
                _plRow(
                  'Waste / Barang Rusak',
                  formatRupiah(waste),
                  isDeduct: true,
                  isDark: isDark,
                ),
                _plRow(
                  'Likuiditas Keluar',
                  formatRupiah(liqOut),
                  isDeduct: true,
                  isDark: isDark,
                ),
                _plRow(
                  'Likuiditas Masuk',
                  formatRupiah(liqIn),
                  isAdd: true,
                  isDark: isDark,
                ),
                _plDivider(isDark: isDark),
                _plRow(
                  'Total Beban',
                  formatRupiah(totalBeban),
                  isBold: true,
                  isDeduct: true,
                  isDark: isDark,
                ),
              ], isDark: isDark),
              SizedBox(height: 12),
              NusaCard(
                Column(
                  children: [
                    _plRow(
                      'Laba / Rugi Bersih',
                      formatRupiah(labaBersih.abs()),
                      isBold: true,
                      isHighlight: true,
                      color: labaBersih >= 0
                          ? NusaConfig.accentGreenDark
                          : NusaConfig.activePrimary,
                      isDark: isDark,
                    ),
                    SizedBox(height: 4),
                    Text(
                      labaBersih >= 0 ? 'Untung' : 'Rugi',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: labaBersih >= 0
                            ? NusaConfig.accentGreenDark
                            : NusaConfig.activePrimary,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 16),
              Text(
                '* Perhitungan berdasarkan data yang tersedia. HPP dari harga beli produk; item manual memakai harga modal yang diisi saat transaksi.',
                style: TextStyle(
                  fontSize: 11,
                  color: textTer,
                  fontStyle: FontStyle.italic,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        );
      },
    );
  }

  /// Tab Laporan Pengeluaran: total, per kategori (pie + bar), dan daftar.
  Widget _pengeluaranTab() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final (from, to) = _range();
    final repo = ReportRepository(ref.read(databaseProvider));
    final financeRepo = FinanceRepository(ref.read(databaseProvider));
    final textSec = isDark
        ? NusaConfig.darkTextSecondary
        : NusaConfig.textSecondary;
    final textTer = isDark
        ? NusaConfig.darkTextTertiary
        : NusaConfig.textTertiary;
    final surf = isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor;
    final border = isDark ? NusaConfig.darkBorder : NusaConfig.borderColor;

    return RefreshIndicator(
      onRefresh: () async => setState(() => _refreshKey++),
      child: FutureBuilder<List<Map<String, dynamic>>>(
        key: ValueKey('expcat_$_refreshKey'),
        future: repo.expensesByCategory(from: from, to: to),
        builder: (ctx, snapCat) {
          final cats = snapCat.data ?? <Map<String, dynamic>>[];
          final totalCat = cats.fold<int>(
            0,
            (s, c) => s + (c['amount'] as int? ?? 0),
          );
          return FutureBuilder<List<Expense>>(
            key: ValueKey('exp_$_refreshKey'),
            future: financeRepo.getExpenses(),
            builder: (ctx, snapList) {
              final all = snapList.data ?? <Expense>[];
              final (fltFrom, fltTo) = (from, to);
              final list = all.where((e) {
                if (fltFrom != null &&
                    e.date.isBefore(
                      DateTime(fltFrom.year, fltFrom.month, fltFrom.day),
                    )) {
                  return false;
                }
                if (fltTo != null &&
                    e.date.isAfter(
                      DateTime(fltTo.year, fltTo.month, fltTo.day, 23, 59, 59),
                    )) {
                  return false;
                }
                return true;
              }).toList();
              final totalList = list.fold<int>(0, (s, e) => s + e.amount);

              if (snapList.connectionState != ConnectionState.done &&
                  snapCat.connectionState != ConnectionState.done) {
                return SkeletonList();
              }

              return ListView(
                padding: EdgeInsets.all(16),
                children: [
                  // ── Total pengeluaran periode ──
                  NusaCard(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.money_off_csred_outlined,
                              size: 18,
                              color: Colors.red.shade400,
                            ),
                            SizedBox(width: 6),
                            Text(
                              'Total Pengeluaran',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: textSec,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 8),
                        Text(
                          _formatJt(totalCat),
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                            color: Colors.red.shade400,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          '$list.length pengeluaran',
                          style: TextStyle(fontSize: 12, color: textTer),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: 16),
                  // ── Export Pengeluaran ──
                  Row(
                    children: [
                      Expanded(
                        child: NusaButton(
                          _exporting ? 'Memproses...' : 'Export Laporan',
                          fullWidth: true,
                          onPressed: _exporting ? null : _exportExpenses,
                        ),
                      ),
                      SizedBox(width: 10),
                      _iconButton(
                        icon: Icons.share_rounded,
                        label: 'Bagikan',
                        color: NusaConfig.activePrimary,
                        isDark: isDark,
                        onPressed: _exporting ? null : _quickSharePdf,
                        loading: _exporting,
                      ),
                    ],
                  ),
                  SizedBox(height: 12),
                  // F: ringkas dulu — detail grafik di balik toggle
                  Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: _detailToggle(isDark),
                  ),
                  if (_detailOpen && cats.isNotEmpty) ...[
                    // ── Pie chart per kategori ──
                    Container(
                      padding: EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: surf,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Pengeluaran per Kategori',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: isDark
                                  ? NusaConfig.darkTextPrimary
                                  : NusaConfig.textPrimary,
                            ),
                          ),
                          SizedBox(height: 12),
                          Row(
                            children: [
                              SizedBox(
                                width: 130,
                                height: 130,
                                child: PieChart(
                                  PieChartData(
                                    sections: cats.asMap().entries.map((e) {
                                      final cat = e.value;
                                      final pct = totalCat > 0
                                          ? ((cat['amount'] as int) /
                                                    totalCat) *
                                                100
                                          : 0.0;
                                      return PieChartSectionData(
                                        value: (cat['amount'] as int)
                                            .toDouble(),
                                        title: '${pct.toStringAsFixed(0)}%',
                                        titleStyle: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: Colors.white,
                                        ),
                                        color:
                                            _catColors[e.key %
                                                _catColors.length],
                                        radius: 55,
                                      );
                                    }).toList(),
                                    sectionsSpace: 2,
                                    centerSpaceRadius: 0,
                                  ),
                                ),
                              ),
                              SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  children: cats.take(6).map((c) {
                                    return Padding(
                                      padding: EdgeInsets.only(bottom: 6),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 10,
                                            height: 10,
                                            margin: EdgeInsets.only(right: 8),
                                            decoration: BoxDecoration(
                                              color:
                                                  _catColors[cats.indexOf(c) %
                                                      _catColors.length],
                                              borderRadius:
                                                  BorderRadius.circular(2),
                                            ),
                                          ),
                                          Expanded(
                                            child: Text(
                                              '${c['category']}',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: textSec,
                                              ),
                                            ),
                                          ),
                                          Text(
                                            formatRupiah(c['amount'] as int),
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                              color: isDark
                                                  ? NusaConfig.darkTextPrimary
                                                  : NusaConfig.textPrimary,
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  }).toList(),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: 16),
                    // ── Bar per kategori ──
                    Container(
                      padding: EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: surf,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Perbandingan Kategori',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: isDark
                                  ? NusaConfig.darkTextPrimary
                                  : NusaConfig.textPrimary,
                            ),
                          ),
                          SizedBox(height: 14),
                          ...cats.take(6).map((c) {
                            final amount = c['amount'] as int;
                            final pct = totalCat > 0
                                ? (amount / totalCat) * 100
                                : 0.0;
                            return Padding(
                              padding: EdgeInsets.only(bottom: 10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        '${c['category']}',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: textSec,
                                        ),
                                      ),
                                      Text(
                                        '${pct.toStringAsFixed(0)}% · ${formatRupiah(amount)}',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: textTer,
                                        ),
                                      ),
                                    ],
                                  ),
                                  SizedBox(height: 4),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: LinearProgressIndicator(
                                      value: pct / 100,
                                      minHeight: 8,
                                      backgroundColor: isDark
                                          ? NusaConfig.darkSurface2
                                          : NusaConfig.backgroundColor,
                                      valueColor: AlwaysStoppedAnimation(
                                        _catColors[cats.indexOf(c) %
                                            _catColors.length],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                        ],
                      ),
                    ),
                    SizedBox(height: 16),
                  ] else if (!_detailOpen && cats.isNotEmpty)
                    // Detail tersembunyi — toggle di atas menunjukkan ringkas.
                    SizedBox.shrink()
                  else
                    // Empty state when no expenses in period
                    EmptyState(
                      icon: Icons.receipt_long_outlined,
                      message:
                          'Belum ada pengeluaran — catat lewat menu Keuangan untuk periode ini',
                    ),
                  // ── Daftar pengeluaran ──
                  if (list.isNotEmpty) ...[
                    Text(
                      'Daftar Pengeluaran',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary,
                      ),
                    ),
                    SizedBox(height: 10),
                    ...list.map(
                      (e) => Container(
                        margin: EdgeInsets.only(bottom: 8),
                        padding: EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: surf,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: border),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: Colors.red.shade50,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                Icons.shopping_cart_outlined,
                                size: 18,
                                color: Colors.red.shade400,
                              ),
                            ),
                            SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${e.category}'
                                    '${e.description.isNotEmpty ? ' — ${e.description}' : ''}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: isDark
                                          ? NusaConfig.darkTextPrimary
                                          : NusaConfig.textPrimary,
                                    ),
                                  ),
                                  SizedBox(height: 2),
                                  Text(
                                    '${e.date.day.toString().padLeft(2, '0')}/${e.date.month.toString().padLeft(2, '0')}/${e.date.year}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: textTer,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              formatRupiah(e.amount),
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: Colors.red.shade400,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 8),
                    Center(
                      child: Text(
                        'Total: ${formatRupiah(totalList)}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: isDark
                              ? NusaConfig.darkTextPrimary
                              : NusaConfig.textPrimary,
                        ),
                      ),
                    ),
                  ],
                  SizedBox(height: 16),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _plSection(String title, List<Widget> rows, {bool isDark = false}) =>
      NusaCard(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: isDark
                    ? NusaConfig.darkTextPrimary
                    : NusaConfig.textPrimary,
              ),
            ),
            SizedBox(height: 12),
            ...rows,
          ],
        ),
      );

  Widget _plRow(
    String label,
    String value, {
    bool isBold = false,
    bool isDeduct = false,
    bool isAdd = false,
    bool isHighlight = false,
    Color? color,
    bool isDark = false,
  }) {
    final prefix = isDeduct ? '\u2212 ' : (isAdd ? '+ ' : '');
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: isHighlight ? FontWeight.w700 : FontWeight.w500,
              color: isHighlight
                  ? (isDark
                        ? NusaConfig.darkTextPrimary
                        : NusaConfig.textPrimary)
                  : (isDark
                        ? NusaConfig.darkTextSecondary
                        : NusaConfig.textSecondary),
            ),
          ),
          Text(
            '$prefix$value',
            style: TextStyle(
              fontSize: 14,
              fontWeight: isBold || isHighlight
                  ? FontWeight.w700
                  : FontWeight.w600,
              color:
                  color ??
                  (isDeduct
                      ? Colors.red.shade400
                      : isAdd
                      ? Colors.green
                      : (isDark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _plDivider({bool isDark = false}) => Divider(
    height: 16,
    thickness: 1,
    color: isDark ? NusaConfig.darkDivider : NusaConfig.dividerColor,
  );

  // ── Ringkasan Harian ───────────────────────────────────────────────

  Widget _ringkasanHarianCard() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final repo = ReportRepository(ref.read(databaseProvider));

    return FutureBuilder<Map<String, dynamic>>(
      key: ValueKey('daily_$_refreshKey'),
      future: _fetchDailySummary(repo),
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SkeletonList(),
          );
        }
        final d = snap.data ?? {};
        final omzet = d['omzet'] as int? ?? 0;
        final count = d['count'] as int? ?? 0;
        final avg = d['avg'] as int? ?? 0;
        final hasPrev = d['hasPrevious'] as bool? ?? false;
        final omzetG = d['omzetGrowth'] as double? ?? 0;

        return Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: NusaCard(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.today_rounded,
                      size: 18,
                      color: isDark
                          ? NusaConfig.darkTextSecondary
                          : NusaConfig.textSecondary,
                    ),
                    SizedBox(width: 6),
                    Text(
                      'Ringkasan Hari Ini',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary,
                      ),
                    ),
                    Spacer(),
                    if (hasPrev)
                      _miniGrowth(omzetG, label: 'vs kemarin', isDark: isDark),
                  ],
                ),
                SizedBox(height: 12),
                Row(
                  children: [
                    _dailyStat('Omzet', formatRupiah(omzet), isDark: isDark),
                    _dailyDivider(),
                    _dailyStat('Transaksi', count.toString(), isDark: isDark),
                    _dailyDivider(),
                    _dailyStat('Rata-rata', formatRupiah(avg), isDark: isDark),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<Map<String, dynamic>> _fetchDailySummary(ReportRepository repo) async {
    final now = DateTime.now();
    final todayFrom = DateTime(now.year, now.month, now.day);
    return repo.summaryWithPrevious(todayFrom, now);
  }

  Widget _dailyStat(String label, String value, {bool isDark = false}) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: NusaConfig.activePrimary,
            ),
          ),
          SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: isDark
                  ? NusaConfig.darkTextTertiary
                  : NusaConfig.textTertiary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _dailyDivider() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: 1,
      height: 36,
      color: isDark ? NusaConfig.darkBorder : NusaConfig.borderColor,
    );
  }

  Widget _miniGrowth(double pct, {String label = '', bool isDark = false}) {
    final up = pct >= 0;
    final color = up ? NusaConfig.accentGreenDark : NusaConfig.activePrimary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          up ? Icons.trending_up : Icons.trending_down,
          size: 14,
          color: color,
        ),
        SizedBox(width: 3),
        Text(
          '${up ? "+" : ""}${pct.toStringAsFixed(1)}% $label',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }

  // ── MAIN BUILD ─────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ScreenScaffold(
      'Laporan',
      Column(
        children: [
          SizedBox(height: 6),
          // Row: Tabs (left, in 1 card) + period dropdown (right, card style)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                // Segmented toggle in 1 card
                Expanded(
                  child: Container(
                    height: 36,
                    decoration: BoxDecoration(
                      color: isDark
                          ? NusaConfig.darkSurface
                          : NusaConfig.backgroundColor,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isDark
                            ? NusaConfig.darkBorder
                            : NusaConfig.dividerColor,
                      ),
                    ),
                    child: Row(
                      children: [
                        _segBtn('Penjualan', 0, isDark: isDark),
                        _segBtn('Laba Rugi', 1, isDark: isDark),
                        _segBtn('Pengeluaran', 2, isDark: isDark),
                      ],
                    ),
                  ),
                ),
                SizedBox(width: 8),
                // Period dropdown card-style
                _periodDropdown(isDark),
              ],
            ),
          ),
          SizedBox(height: 2),
          // v2.2.55: filter per karyawan (Penjualan tab) — kartu full-width di
          // bawah tab & periode. v2.2.57+121 (keamanan): hanya Owner/Manager
          // yang bisa pilih karyawan; kasir lain otomatis laporan miliknya.
          if (_tab == 0 && _canViewAllReports)
            Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: _employeeFilterDropdown(isDark),
            ),
          // v2.2.57: Kinerja Stylist (salon) — omset & komisi per stylist.
          if (_tab == 0 && NusaConfig.isSalonVariant)
            Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: _stylistEntryCard(isDark),
            ),
          SizedBox(height: 2),
          // Ringkasan Harian card (only for Penjualan tab)
          if (_tab == 0) _ringkasanHarianCard(),
          Expanded(
            child: _tab == 0
                ? _penjualanTab()
                : _tab == 1
                ? _labaRugiTab()
                : _pengeluaranTab(),
          ),
        ],
      ),
    );
  }

  /// v2.2.57: pipih — tipis sejajar switch card (~48px). v2.2.55 terlalu
  /// tebal karena padding bertumpuk + shadow; diringkas jadi selaras.
  Widget _employeeFilterDropdown(bool isDark) {
    final selectedEmp = _employees.where((e) => e.id == _employeeFilter).firstOrNull;
    final label = selectedEmp != null ? '${selectedEmp.name} (${selectedEmp.role})' : 'Semua Kasir';

    return InkWell(
      onTap: () => _showEmployeeFilterSheet(isDark),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkSurface2 : NusaConfig.surfaceColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.person_outline_rounded,
              size: 18,
              color: NusaConfig.activePrimary,
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
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 18,
              color: isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary,
            ),
          ],
        ),
      ),
    );
  }

  void _showEmployeeFilterSheet(bool isDark) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark ? Colors.white24 : Colors.black12,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Filter Laporan Kasir / Staf',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              leading: CircleAvatar(
                radius: 18,
                backgroundColor: NusaConfig.activePrimary.withValues(alpha: 0.15),
                child: Icon(Icons.people_outline_rounded, size: 20, color: NusaConfig.activePrimary),
              ),
              title: const Text('Semua Kasir', style: TextStyle(fontWeight: FontWeight.w600)),
              trailing: _employeeFilter == null
                  ? Icon(Icons.check_circle_rounded, color: NusaConfig.activePrimary)
                  : null,
              onTap: () {
                setState(() {
                  _employeeFilter = null;
                  _refreshKey++;
                });
                Navigator.pop(ctx);
              },
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _employees.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, idx) {
                  final e = _employees[idx];
                  final isSelected = _employeeFilter == e.id;
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    leading: CircleAvatar(
                      radius: 18,
                      backgroundColor: NusaConfig.activePrimary.withValues(alpha: 0.12),
                      child: Text(
                        e.name.isNotEmpty ? e.name[0].toUpperCase() : '?',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: NusaConfig.activePrimary,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    title: Text(e.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(e.role, style: TextStyle(fontSize: 12, color: isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary)),
                    trailing: isSelected
                        ? Icon(Icons.check_circle_rounded, color: NusaConfig.activePrimary)
                        : null,
                    onTap: () {
                      setState(() {
                        _employeeFilter = e.id;
                        _refreshKey++;
                      });
                      Navigator.pop(ctx);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// v2.2.57: kartu pintasan laporan Kinerja Stylist (khusus varian salon) —
  /// pipih sejajar dropdown filter di atasnya.
  Widget _stylistEntryCard(bool isDark) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => context.push('/laporan/Stylist'),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkSurface2 : NusaConfig.surfaceColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor,
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.workspace_premium_rounded,
                size: 18, color: NusaConfig.activePrimary),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Kinerja Stylist — Omset & Komisi',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isDark
                      ? NusaConfig.darkTextPrimary
                      : NusaConfig.textPrimary,
                ),
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: 18,
                color: isDark
                    ? NusaConfig.darkTextTertiary
                    : NusaConfig.textTertiary),
          ],
        ),
      ),
    );
  }

  Widget _periodDropdown(bool isDark) {
    return Container(
      height: 36,
      padding: EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: isDark ? NusaConfig.darkSurface : NusaConfig.backgroundColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor,
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _period == 'custom' ? 'custom' : _period,
          isDense: true,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: isDark
                ? NusaConfig.darkTextSecondary
                : NusaConfig.textSecondary,
          ),
          borderRadius: BorderRadius.circular(12),
          underline: SizedBox.shrink(),
          icon: Icon(
            Icons.expand_more_rounded,
            size: 18,
            color: isDark
                ? NusaConfig.darkTextTertiary
                : NusaConfig.textTertiary,
          ),
          items: [
            _ddItem('Hari ini'),
            _ddItem('Kemarin'),
            _ddItem('Minggu ini'),
            _ddItem('Bulan ini'),
            _ddItem('Tahun ini'),
            _ddItem('Semua'),
            if (_period == 'custom' && _dateRange != null)
              DropdownMenuItem(
                value: 'custom',
                enabled: false,
                child: Text(
                  _periodLabel(),
                  style: TextStyle(
                    fontSize: 11,
                    color: NusaConfig.activePrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            _ddItem('Pilih Periode'),
          ],
          onChanged: (v) {
            if (v == 'Pilih Periode') {
              _pickDateRange();
            } else {
              setState(() {
                _period = v!;
                _dateRange = null;
                _refreshKey++;
              });
            }
          },
        ),
      ),
    );
  }

  DropdownMenuItem<String> _ddItem(String label) =>
      DropdownMenuItem(value: label, child: Text(label));

  Widget _segBtn(String label, int idx, {bool isDark = false}) {
    final sel = idx == _tab;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _tab = idx),
        child: Container(
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: sel ? NusaConfig.activePrimary : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: sel
                  ? Colors.white
                  : (isDark
                        ? NusaConfig.darkTextSecondary
                        : NusaConfig.textSecondary),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Helper widgets ────────────────────────────────────────────────────

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final bool isDark;
  _StatCard(this.title, this.value, {required this.isDark});

  @override
  Widget build(BuildContext context) => NusaCard(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 12,
            color: isDark
                ? NusaConfig.darkTextSecondary
                : NusaConfig.textSecondary,
          ),
        ),
        SizedBox(height: 6),
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: NusaConfig.activePrimary,
          ),
        ),
      ],
    ),
  );
}

class _GrowthBadge extends StatelessWidget {
  final String label;
  final double pct;
  final bool isDark;
  _GrowthBadge(this.label, this.pct, {required this.isDark});

  @override
  Widget build(BuildContext context) {
    final up = pct >= 0;
    final color = up ? NusaConfig.accentGreenDark : NusaConfig.activePrimary;
    return Expanded(
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: up
              ? NusaConfig.successSoft.withValues(alpha: 0.5)
              : NusaConfig.errorSoft.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              up ? Icons.trending_up : Icons.trending_down,
              size: 18,
              color: color,
            ),
            SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark
                          ? NusaConfig.darkTextSecondary
                          : NusaConfig.textSecondary,
                    ),
                  ),
                  Text(
                    '${up ? "+" : ""}${pct.toStringAsFixed(1)}%',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: color,
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
}

class _TxCard extends StatelessWidget {
  final Transaction tx;
  final bool isDark;
  _TxCard({required this.tx, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final dateStr =
        '${tx.date.day}/${tx.date.month}/${tx.date.year} ${tx.date.hour.toString().padLeft(2, '0')}:${tx.date.minute.toString().padLeft(2, '0')}';
    final isVoided = tx.status == 'Void';
    final textPri = isDark
        ? NusaConfig.darkTextPrimary
        : NusaConfig.textPrimary;
    final textSec = isDark
        ? NusaConfig.darkTextSecondary
        : NusaConfig.textSecondary;

    return NusaCard(
      Opacity(
        opacity: isVoided ? 0.55 : 1.0,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        tx.invoice,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: textPri,
                        ),
                      ),
                      if (isVoided) ...[
                        SizedBox(width: 8),
                        Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: NusaConfig.activePrimary.withValues(
                              alpha: 0.12,
                            ),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'VOID',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: NusaConfig.activePrimary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  SizedBox(height: 4),
                  Text(
                    '$dateStr \u2022 ${tx.paymentMethod}',
                    style: TextStyle(fontSize: 13, color: textSec),
                  ),
                  // v2.2.54: nama karyawan/kasir yang melakukan transaksi.
                  if ((tx.cashierName ?? '').isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          Icon(
                            Icons.person_rounded,
                            size: 12,
                            color: textSec,
                          ),
                          SizedBox(width: 3),
                          Text(
                            tx.cashierName ?? '',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: textSec,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            Text(
              formatRupiah(tx.total),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: NusaConfig.activePrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
