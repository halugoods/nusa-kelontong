import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:nusa_kasir/core/providers.dart';
import 'package:nusa_kasir/core/services/delta_sync_service.dart';
import 'package:nusa_kasir/core/config/nusa_config.dart';
import 'package:nusa_kasir/core/receipt/receipt_config.dart';
import 'package:nusa_kasir/core/receipt/receipt_data.dart';
import 'package:nusa_kasir/core/receipt/receipt_preview_widget.dart';
import 'package:nusa_kasir/core/receipt/receipt_renderer.dart';
import 'package:nusa_kasir/core/utils/format_rupiah.dart';
import 'package:nusa_kasir/data/database/app_database.dart';
import 'package:nusa_kasir/data/repositories/attendance_repository.dart';
import 'package:nusa_kasir/data/repositories/customer_repository.dart';
import 'package:nusa_kasir/data/repositories/debt_repository.dart';
import 'package:nusa_kasir/data/repositories/settings_repository.dart';
import 'package:nusa_kasir/features/auth/employee_session_provider.dart';
import 'package:nusa_kasir/core/auth/employee_session.dart';
import 'package:nusa_kasir/features/checkout/receipt_sheet.dart';
import 'package:nusa_kasir/shared/widgets/nusa_button.dart';
import 'package:nusa_kasir/shared/widgets/nusa_search_bar.dart';
import 'package:nusa_kasir/shared/widgets/pin_dialog.dart';
import 'package:nusa_kasir/shared/services/biometric_service.dart';
import 'package:nusa_kasir/shared/services/nfc_tag_service.dart';
import 'package:nusa_kasir/shared/services/auth_methods.dart';
import 'package:nusa_kasir/shared/widgets/screen_scaffold.dart';
import 'package:nusa_kasir/shared/widgets/skeleton_list.dart';
import 'package:nusa_kasir/shared/widgets/empty_state.dart';
import 'package:nusa_kasir/shared/widgets/top_toast.dart';
import 'package:nusa_kasir/core/utils/wa_phone.dart';

/// v2.2.43: tampilkan nama item + varian ("Nama — Varian") bila tersimpan.
String _itemDisplayName(Map<String, dynamic> it) {
  final base = (it['name'] as String?) ?? 'Item';
  final v = it['variantName'] as String?;
  if (v != null && v.isNotEmpty && base.isNotEmpty && base != 'Item') {
    return '$base — $v';
  }
  return base;
}

/// Label qty item di riwayat: "x 3" polos, atau "x 3 dus" bila transaksi
/// memakai satuan jual dinamis (v2.2.43).
String _itemQtyLabel(Map<String, dynamic> it) {
  final qty = (it['qty'] as num?)?.toInt() ?? 0;
  final unit = it['unitName'] as String?;
  if (unit == null || unit.isEmpty || qty <= 0) return '$qty';
  return '$qty $unit';
}

class TransactionsScreen extends ConsumerStatefulWidget {
  TransactionsScreen({super.key});
  @override
  ConsumerState<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends ConsumerState<TransactionsScreen> {
  String _timeFilter = 'Hari ini';
  String _payFilter = 'Semua';
  DateTimeRange? _dateRange;
  int _refreshKey = 0;
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';
  // v2.2.54: filter transaksi per karyawan (null = semua).
  int? _employeeFilter;
  List<Employee> _employees = const [];

  /// v2.2.57+121 (keamanan): boleh lihat SEMUA transaksi = Owner + role yang
  /// punya akses menu "transaksi" TETAPI dengan privilege penuh. Default:
  /// Owner & Manager lihat semua; kasir/gudang/custom role lain hanya transaksi
  /// miliknya sendiri (cek di bawah memakai session).
  ///
  /// [session] null (belum login PIN) → otomatis restricted ke diri sendiri
  /// (paling aman).
  bool _canViewAll(EmployeeSession? session) {
    if (session == null) return false;
    final role = session.role;
    // Owner & Manager: akses penuh bawaan (tidak mungkin dinonaktifkan).
    if (role == 'Owner' || role == 'Manager') return true;
    // Role lain: hanya lihat transaksi miliknya sendiri, KECUALI role tsb
    // secara eksplisit punya hak (future: kolom "lihat semua transaksi" —
    // sementara default karyawan = lihat punya sendiri).
    return false;
  }

  @override
  void initState() {
    super.initState();
    _loadEmployees();
    // v2.2.57+136: refresh saat delta sync mengubah DB — dulu layar ini
    // load-once via FutureBuilder, transaksi dari device lain tak pernah
    // muncul sampai user buka-tutup layar manual.
    try {
      DeltaSyncService.I.stream.listen((_) {
        if (mounted) setState(() {});
      });
    } catch (_) {}
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

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<Transaction> _filter(List<Transaction> all) {
    final now = DateTime.now();
    var filtered = switch (_timeFilter) {
      'Hari ini' =>
        all
            .where(
              (t) => !t.date.isBefore(DateTime(now.year, now.month, now.day)),
            )
            .toList(),
      'Kemarin' =>
        all
            .where(
              (t) =>
                  !t.date.isBefore(
                    DateTime(now.year, now.month, now.day - 1),
                  ) &&
                  t.date.isBefore(DateTime(now.year, now.month, now.day)),
            )
            .toList(),
      'Minggu ini' =>
        all
            .where((t) => t.date.isAfter(now.subtract(Duration(days: 7))))
            .toList(),
      'Bulan ini' =>
        all
            .where((t) => t.date.isAfter(now.subtract(Duration(days: 30))))
            .toList(),
      'Tahun ini' =>
        all.where((t) => !t.date.isBefore(DateTime(now.year, 1, 1))).toList(),
      'Semua' => all,
      'custom' =>
        _dateRange == null
            ? all
            : all
                  .where(
                    (t) =>
                        !t.date.isBefore(_dateRange!.start) &&
                        !t.date.isAfter(_dateRange!.end.add(Duration(days: 1))),
                  )
                  .toList(),
      _ => all,
    };
    if (_payFilter != 'Semua') {
      filtered = filtered.where((t) => t.paymentMethod == _payFilter).toList();
    }
    // ── v2.2.57+121 (keamanan): batasi default karyawan ──
    // Owner/Manager boleh lihat semua (dengan dropdown filter karyawan).
    // Karyawan lain (Kasir/custom role) WAJIB hanya lihat transaksinya
    // sendiri — mencegah karyawan mengintip omzet & transaksi rekan kerja.
    final session = ref.read(employeeSessionProvider);
    if (!_canViewAll(session)) {
      final myId = session?.employeeId;
      // Session null (belum login PIN) → tidak ada transaksi yang boleh
      // ditampilkan (paling aman).
      filtered = myId == null
          ? const []
          : filtered.where((t) => t.employeeId == myId).toList();
      // Force filter karyawan ke diri sendiri (dropdown disembunyikan di
      // build untuk non-owner).
      _employeeFilter = myId;
    } else if (_employeeFilter != null) {
      // v2.2.54: filter per karyawan — hanya transaksi yang dibuat karyawan tsb.
      filtered = filtered
          .where((t) => t.employeeId == _employeeFilter)
          .toList();
    }
    if (_searchQuery.isNotEmpty) {
      filtered = filtered
          .where((t) => t.invoice.toLowerCase().contains(_searchQuery))
          .toList();
    }
    return filtered;
  }

  Future<void> _voidTransaction(Transaction tx) async {
    // ── Access control (keputusan user 2026-08-12): void hanya Owner/Manager ──
    // Kasir/Finance/custom role TIDAK boleh membatalkan transaksi siapa pun.
    final session = ref.read(employeeSessionProvider);
    final role = session?.role ?? 'Kasir';
    if (role != 'Owner' && role != 'Manager') {
      _showVoidRestrictedDialog();
      return;
    }

    // PIN re-entry — bukti fisik bahwa Owner/Manager yang mengeksekusi void.
    final pinOk = await _requireVoidPin();
    if (!pinOk) return;

    final reasonCtrl = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Void Transaksi'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Invoice: ${tx.invoice}',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 4),
            Text(
              'Total: ${formatRupiah(tx.total)}',
              style: TextStyle(
                color: NusaConfig.activePrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 16),
            TextField(
              controller: reasonCtrl,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Alasan void *',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                ),
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Batal'),
          ),
          NusaButton(
            'Void',
            fullWidth: false,
            onPressed: () {
              final r = reasonCtrl.text.trim();
              if (r.isEmpty) {
                TopToast.error(context, 'Alasan void wajib diisi');
                return;
              }
              Navigator.pop(context, r);
            },
          ),
        ],
      ),
    );

    reasonCtrl.dispose();
    if (reason == null || reason.isEmpty) return;

    final repo = ref.read(transactionRepoProvider);
    final err = await repo.voidTransaction(tx.id, reason);
    if (mounted) {
      if (err != null) {
        TopToast.error(context, err);
      } else {
        TopToast.success(context, 'Transaksi #${tx.invoice} berhasil di-void');
        setState(() => _refreshKey++);
      }
    }
  }

  /// Retur / refund parsial untuk transaksi ini.
  ///
  /// Access control sama dengan void: hanya Owner/Manager + PIN re-entry.
  /// User memilih item & qty yang dikembalikan → stok balik + uang balik
  /// dicatat di tabel refunds (laporan omzet/HPP/kas otomatis berkurang).
  Future<void> _showReturSheet(Transaction tx) async {
    final session = ref.read(employeeSessionProvider);
    final role = session?.role ?? 'Kasir';
    if (role != 'Owner' && role != 'Manager') {
      _showVoidRestrictedDialog();
      return;
    }
    final pinOk = await _requireVoidPin();
    if (!pinOk) return;

    if (!mounted) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final items = _parseItems(
      tx.items,
    ).where((it) => ((it['qty'] as num?) ?? 0) > 0).toList();
    if (items.isEmpty) {
      TopToast.error(context, 'Tidak ada item untuk di-retur');
      return;
    }
    final selected = <int, int>{}; // index → qty retur
    for (var i = 0; i < items.length; i++) {
      selected[i] = 0;
    }
    final reasonCtrl = TextEditingController();

    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          int totalRetur() {
            var s = 0;
            items.asMap().forEach((i, it) {
              s += (selected[i] ?? 0) * ((it['price'] as num?)?.toInt() ?? 0);
            });
            return s;
          }

          return Container(
            decoration: BoxDecoration(
              color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
            ),
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 12,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
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
                    Icon(
                      Icons.assignment_return_rounded,
                      color: NusaConfig.activePrimary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Retur / Refund',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Invoice: ${tx.invoice}',
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark
                        ? NusaConfig.darkTextSecondary
                        : NusaConfig.textSecondary,
                  ),
                ),
                const SizedBox(height: 16),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      ...items.asMap().entries.map((e) {
                        final i = e.key;
                        final it = e.value;
                        final name = _itemDisplayName(it);
                        final qty = (it['qty'] as num?)?.toInt() ?? 0;
                        final price = (it['price'] as num?)?.toInt() ?? 0;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      name,
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      '$qty x ${formatRupiah(price)}',
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
                              Text(
                                'Retur: ${selected[i] ?? 0}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: NusaConfig.activePrimary,
                                ),
                              ),
                              _qtyStepper(
                                ctx,
                                setSheet,
                                selected,
                                isDark,
                                i,
                                selected[i] ?? 0,
                                qty,
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: reasonCtrl,
                  decoration: InputDecoration(
                    labelText: 'Alasan retur (mis. barang expired)',
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Text(
                      'Total Refund',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      formatRupiah(totalRetur()),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: NusaConfig.activePrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: NusaButton(
                    totalRetur() <= 0
                        ? 'Pilih item terlebih dahulu'
                        : 'Proses Retur ${formatRupiah(totalRetur())}',
                    onPressed: totalRetur() <= 0
                        ? null
                        : () => Navigator.pop(ctx, {
                            'selected': Map<int, int>.from(selected),
                            'reason': reasonCtrl.text.trim(),
                          }),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );

    reasonCtrl.dispose();
    if (!mounted || result == null) return;
    final sel = result['selected'] as Map<int, int>;
    final reason = result['reason'] as String? ?? '';
    final returns = <Map<String, dynamic>>[];
    sel.forEach((i, q) {
      if (q <= 0) return;
      final it = items[i];
      returns.add({
        'productId': it['productId'] as int?,
        'name': it['name'] as String? ?? 'Item',
        'qty': q,
        'unitPrice': (it['price'] as num?)?.toInt() ?? 0,
      });
    });
    if (returns.isEmpty) return;

    final refundRepo = ref.read(refundRepoProvider);
    final branchId = session?.branchId;
    final employeeId = session?.employeeId;
    final res = await refundRepo.refund(
      transactionId: tx.id,
      returns: returns,
      reason: reason,
      branchId: branchId,
      employeeId: employeeId,
    );
    if (!mounted) return;
    if (res.refundAmount <= 0) {
      TopToast.error(context, 'Retur gagal: tidak ada jumlah yang valid');
      return;
    }
    TopToast.success(
      context,
      'Retur ${formatRupiah(res.refundAmount)} berhasil — stok & uang '
      'sudah dikembalikan',
    );
    setState(() => _refreshKey++);
  }

  Widget _qtyStepper(
    BuildContext ctx,
    StateSetter setSheet,
    Map<int, int> selected,
    bool isDark,
    int index,
    int current,
    int maxQty,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: current > 0
              ? () => setSheet(() => selected[index] = current - 1)
              : null,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color:
                  (isDark ? NusaConfig.darkSurface : NusaConfig.backgroundColor)
                      .withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.remove_rounded,
              size: 18,
              color: current > 0
                  ? NusaConfig.activePrimary
                  : (isDark
                        ? NusaConfig.darkTextTertiary
                        : NusaConfig.textTertiary),
            ),
          ),
        ),
        const SizedBox(width: 8),
        InkWell(
          onTap: current < maxQty
              ? () => setSheet(() => selected[index] = current + 1)
              : null,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: NusaConfig.activePrimary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.add_rounded,
              size: 18,
              color: current < maxQty
                  ? NusaConfig.activePrimary
                  : (isDark
                        ? NusaConfig.darkTextTertiary
                        : NusaConfig.textTertiary),
            ),
          ),
        ),
      ],
    );
  }

  /// Void hanya untuk Owner/Manager — dialog peringatan untuk role lain.
  void _showVoidRestrictedDialog() {
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
        content: const Text(
          'Void transaksi hanya bisa dilakukan oleh Owner/Manager. '
          'Silakan minta Owner/Manager yang login untuk membatalkan transaksi ini.',
          style: TextStyle(fontSize: 14, height: 1.5),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Mengerti'),
          ),
        ],
      ),
    );
  }

  /// PIN re-entry sebelum void/retur — mencegah void/retur tidak sengaja /
  /// oleh yang bukan pemilik akun. Memakai PIN karyawan yang sedang login,
  /// plus opsi biometrik (FP) dan NFC — sama seperti pin pad di Pengaturan.
  Future<bool> _requireVoidPin() async {
    final session = ref.read(employeeSessionProvider);
    if (session == null) return false;
    final db = ref.read(databaseProvider);
    final emp = await AttendanceRepository(db).getEmployee(session.employeeId);
    if (emp == null || emp.pin.isEmpty) return false;

    final result = await PinDialog.show(
      context: context,
      title: 'Konfirmasi Void',
      subtitle: 'Masukkan PIN untuk membatalkan transaksi',
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
    );
    return result?.success ?? false;
  }

  Future<bool> _authFingerprint() async {
    return BiometricService.authenticate(
      reason: 'Verifikasi biometrik untuk melanjutkan',
    );
  }

  Future<void> _reprintTransaction(Transaction tx) async {
    String? custName;
    String? custPhone;
    if (tx.customerId != null) {
      final custRepo = CustomerRepository(ref.read(databaseProvider));
      final cust = await custRepo.byId(tx.customerId!);
      if (cust != null) {
        custName = cust.name;
        custPhone = cust.phone;
      }
    }

    final rawItems = _parseItems(tx.items);
    final dateStr =
        '${tx.date.day.toString().padLeft(2, '0')}/${tx.date.month.toString().padLeft(2, '0')}/${tx.date.year} '
        '${tx.date.hour.toString().padLeft(2, '0')}:${tx.date.minute.toString().padLeft(2, '0')}';

    if (mounted) {
      // Deteksi DP (uang muka) saat reprint: Tunai dengan cashGiven < total
      // berarti transaksi DP — uang muka = cashGiven, sisanya piutang.
      final isDpReprint =
          tx.paymentMethod.toLowerCase().contains('tunai') &&
          tx.cashGiven != null &&
          tx.cashGiven! > 0 &&
          tx.cashGiven! < tx.total;
      await ReceiptSheet.show(
        context,
        sheet: ReceiptSheet.fromMaps(
          rawItems: rawItems,
          total: tx.total,
          discount: tx.discount,
          paymentMethod: tx.paymentMethod,
          cashGiven: tx.cashGiven,
          cashReturn: tx.cashReturn,
          downPayment: isDpReprint ? (tx.cashGiven ?? 0) : 0,
          remainingDue: isDpReprint ? tx.total - (tx.cashGiven ?? 0) : 0,
          cashierName: tx.cashierName,
          customerName: custName,
          customerPhone: custPhone,
          invoice: tx.invoice,
          dateStr: dateStr,
          orderType: tx.orderType,
          tableName: null, // table name not stored in transaction, only tableId
        ),
      );
    }
  }

  /// v2.2.54: dropdown filter karyawan — "Semua Kasir" default; pilih
  /// karyawan → daftar transaksi hanya menampilkan trx karyawan tsb.
  /// v2.2.57: pipih — tipis sejajar switch card (~48px).
  Widget _employeeDropdown(bool isDark) {
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
                style: GoogleFonts.plusJakartaSans(
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
              'Filter Kasir / Staf',
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
                setState(() => _employeeFilter = null);
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
                      setState(() => _employeeFilter = e.id);
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

  Widget _timeDropdown(bool isDark) {
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
          value: _timeFilter == 'custom' ? 'custom' : _timeFilter,
          isDense: true,
          style: GoogleFonts.plusJakartaSans(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: isDark
                ? NusaConfig.darkTextSecondary
                : isDark
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
                : isDark
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
            if (_timeFilter == 'custom' && _dateRange != null)
              DropdownMenuItem(
                value: 'custom',
                enabled: false,
                child: Text(
                  '${_dateRange!.start.day}/${_dateRange!.start.month} - ${_dateRange!.end.day}/${_dateRange!.end.month}',
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
                _timeFilter = v!;
                _dateRange = null;
              });
            }
          },
        ),
      ),
    );
  }

  DropdownMenuItem<String> _ddItem(String label) =>
      DropdownMenuItem(value: label, child: Text(label));

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(Duration(days: 1)),
      initialDateRange:
          _dateRange ??
          DateTimeRange(start: DateTime.now(), end: DateTime.now()),
    );
    if (picked != null && mounted) {
      setState(() {
        _timeFilter = 'custom';
        _dateRange = picked;
      });
    }
  }

  Widget _paymentSegmented(bool isDark) {
    final opts = ['Semua', 'Tunai', 'QRIS', 'Transfer'];
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: isDark ? NusaConfig.darkSurface : NusaConfig.backgroundColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor,
        ),
      ),
      child: Row(
        children: opts.map((opt) {
          final active = _payFilter == opt;
          final Color activeColor;
          if (opt == 'QRIS') {
            activeColor = NusaConfig.payQris;
          } else if (opt == 'Transfer') {
            activeColor = NusaConfig.payTransfer;
          } else {
            activeColor = NusaConfig.activePrimary;
          }
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _payFilter = opt),
              child: Container(
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: active ? activeColor : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  opt,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: active
                        ? Colors.white
                        : (isDark
                              ? NusaConfig.darkTextSecondary
                              : isDark
                              ? NusaConfig.darkTextSecondary
                              : NusaConfig.textSecondary),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── Share / bagikan dengan preview gambar ──

  Future<File?> _captureReceipt(GlobalKey key, Transaction tx) async {
    try {
      final boundary =
          key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return null;
      final image = await boundary.toImage(pixelRatio: 3);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return null;
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/struk_${tx.invoice.replaceAll('/', '_')}.png',
      );
      await file.writeAsBytes(byteData.buffer.asUint8List());
      return file;
    } catch (_) {
      return null;
    }
  }

  /// Preview struk transaksi lama — dari SATU ReceiptPreview (renderer SAMA
  /// dengan print/settings). Config TERBARU (spec AA: reprint pakai config
  /// terbaru), data = transaksi lama. Fix v2.2.29: bug paperWidth '58'
  /// hardcoded + header 230px hilang — sekarang ikut ReceiptConfig.
  Widget _buildReceiptPreview(
    Transaction tx,
    List<Map<String, dynamic>> rawItems,
    String dateStr,
    String? custName, {
    bool isDark = false,
    String storeName = 'NUSA Kasir',
    ReceiptConfig? config,
  }) {
    final data = ReceiptData.fromMaps(
      rawItems: rawItems,
      total: tx.total,
      discount: tx.discount,
      paymentMethod: tx.paymentMethod,
      cashGiven: tx.cashGiven,
      cashReturn: tx.cashReturn,
      cashierName: tx.cashierName,
      customerName: custName,
      invoiceNumber: tx.invoice,
      dateStr: dateStr,
      orderType: tx.orderType,
    );
    return ReceiptPreview(
      config: config ?? ReceiptConfig.sample(),
      data: data,
      storeName: storeName.isNotEmpty ? storeName : 'NUSA Kasir',
      dark: isDark,
    );
  }

  Future<void> _showShareSheet(
    Transaction tx,
    String? custName,
    String? custPhone,
  ) async {
    final rawItems = _parseItems(tx.items);
    final dateStr =
        '${tx.date.day.toString().padLeft(2, '0')}/${tx.date.month.toString().padLeft(2, '0')}/${tx.date.year} '
        '${tx.date.hour.toString().padLeft(2, '0')}:${tx.date.minute.toString().padLeft(2, '0')}';

    // Config TERBARU (spec AA) — preview/share/unduh pakai renderer sama.
    final db = ref.read(databaseProvider);
    final storeName = (await SettingsRepository(db).getStoreName()).trim();
    final config = await ReceiptConfig.load(db);
    final data = ReceiptData.fromMaps(
      rawItems: rawItems,
      total: tx.total,
      discount: tx.discount,
      paymentMethod: tx.paymentMethod,
      cashGiven: tx.cashGiven,
      cashReturn: tx.cashReturn,
      cashierName: tx.cashierName,
      customerName: custName,
      invoiceNumber: tx.invoice,
      dateStr: dateStr,
      orderType: tx.orderType,
    );

    final receiptKey = GlobalKey();
    bool capturing = false;

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        final shareDark = Theme.of(ctx).brightness == Brightness.dark;
        return StatefulBuilder(
          builder: (ctx, setSt) => Container(
            decoration: BoxDecoration(
              color: shareDark
                  ? NusaConfig.darkSurface
                  : NusaConfig.surfaceColor,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            padding: EdgeInsets.fromLTRB(24, 16, 24, 40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: EdgeInsets.symmetric(vertical: 8),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: NusaConfig.dividerColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                SizedBox(height: 12),
                Text(
                  'Bagikan Struk ${tx.invoice}',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: shareDark
                        ? NusaConfig.darkTextPrimary
                        : NusaConfig.textPrimary,
                  ),
                ),
                SizedBox(height: 16),
                // ── Receipt preview image ──
                RepaintBoundary(
                  key: receiptKey,
                  child: Container(
                    // Lebar ikut ukuran kertas (58/80mm) dari ReceiptConfig
                    // — ditangani ReceiptPreview (renderer yang sama).
                    padding: EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: shareDark ? NusaConfig.darkSurface2 : Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: shareDark
                            ? NusaConfig.darkBorder
                            : Colors.grey.shade200,
                      ),
                    ),
                    child: _buildReceiptPreview(
                      tx,
                      rawItems,
                      dateStr,
                      custName,
                      isDark: shareDark,
                      storeName: storeName.isNotEmpty
                          ? storeName
                          : 'NUSA Kasir',
                      config: config,
                    ),
                  ),
                ),
                SizedBox(height: 20),
                if (capturing)
                  Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Center(
                      child: CircularProgressIndicator(strokeWidth: 3),
                    ),
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () async {
                            setSt(() => capturing = true);
                            final file = await _captureReceipt(receiptKey, tx);
                            setSt(() => capturing = false);
                            if (file != null && mounted) {
                              Navigator.pop(ctx);
                              // Kirim via WA — text dari SATU renderer
                              // (renderText) supaya isi = preview = print.
                              if (custPhone != null && custPhone.isNotEmpty) {
                                final text = renderText(
                                  config: config,
                                  data: data,
                                  storeName: storeName,
                                );
                                final waUrl = waLink(
                                  custPhone,
                                  text: text,
                                ).toString();
                                launchUrl(Uri.parse(waUrl));
                              } else {
                                SharePlus.instance.share(
                                  ShareParams(files: [XFile(file.path)]),
                                );
                              }
                            }
                          },
                          child: Container(
                            padding: EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Color(0xFF25D366).withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.chat_rounded,
                                  size: 32,
                                  color: Color(0xFF25D366),
                                ),
                                SizedBox(height: 8),
                                Text(
                                  custPhone != null && custPhone.isNotEmpty
                                      ? 'Kirim WA'
                                      : 'Share',
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF25D366),
                                  ),
                                ),
                                if (custPhone != null && custPhone.isNotEmpty)
                                  Text(
                                    custPhone,
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: shareDark
                                          ? NusaConfig.darkTextTertiary
                                          : Colors.grey,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      SizedBox(width: 16),
                      Expanded(
                        child: GestureDetector(
                          onTap: () async {
                            // Unduh struk — PDF ASLI dari SATU renderer
                            // (renderPdf), bukan gambar/teks.
                            setSt(() => capturing = true);
                            try {
                              final pdfFile = await renderPdf(
                                config: config,
                                data: data,
                                storeName: storeName,
                                invoice: tx.invoice,
                              );
                              setSt(() => capturing = false);
                              if (!mounted) return;
                              Navigator.pop(ctx);
                              SharePlus.instance.share(
                                ShareParams(
                                  files: [XFile(pdfFile.path)],
                                  subject: 'Struk $storeName',
                                ),
                              );
                            } catch (_) {
                              setSt(() => capturing = false);
                              if (mounted) {
                                TopToast.error(ctx, 'Gagal membuat PDF struk');
                              }
                            }
                          },
                          child: Container(
                            padding: EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: NusaConfig.activePrimary.withValues(
                                alpha: 0.1,
                              ),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.download_rounded,
                                  size: 32,
                                  color: NusaConfig.activePrimary,
                                ),
                                SizedBox(height: 8),
                                Text(
                                  'Unduh Struk',
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: NusaConfig.activePrimary,
                                  ),
                                ),
                                Text(
                                  'PDF',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: shareDark
                                        ? NusaConfig.darkTextTertiary
                                        : NusaConfig.textTertiary,
                                  ),
                                ),
                              ],
                            ),
                          ),
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
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ScreenScaffold(
      'Transaksi',
      Column(
        children: [
          SizedBox(height: 8),
          // ── Search by invoice ──
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: NusaSearchBar(
              controller: _searchCtrl,
              hint: 'Cari nomor invoice…',
              onChanged: (v) =>
                  setState(() => _searchQuery = v.toLowerCase()),
            ),
          ),
          SizedBox(height: 18),
          // ── Payment segmented + time dropdown inline ──
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(child: _paymentSegmented(isDark)),
                SizedBox(width: 8),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: 150),
                  child: _timeDropdown(isDark),
                ),
              ],
            ),
          ),
          SizedBox(height: 8),
          // ── Filter karyawan (v2.2.54) ──
          // v2.2.57+121 (keamanan): dropdown HANYA tampil untuk Owner/Manager
          // (yang bisa lihat semua transaksi). Karyawan lain otomatis hanya
          // melihat transaksi miliknya — tidak bisa pilih karyawan lain.
          if (_canViewAll(ref.read(employeeSessionProvider)))
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: _employeeDropdown(isDark),
            ),
          SizedBox(height: 8),
          Expanded(
            child: FutureBuilder<List<Transaction>>(
              key: ValueKey(_refreshKey),
              future: ref.watch(transactionRepoProvider).getTransactions(),
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return SkeletonList();
                }
                if (snap.hasError) {
                  return Center(
                    child: Text(
                      'Gagal memuat: ${snap.error}',
                      style: TextStyle(
                        color: isDark
                            ? NusaConfig.darkTextSecondary
                            : Colors.grey,
                      ),
                    ),
                  );
                }
                final list = _filter(snap.data ?? []);
                if (list.isEmpty) {
                  return EmptyState(
                    icon: Icons.receipt_long_outlined,
                    message: 'Belum ada transaksi',
                  );
                }
                final totalRevenue = list.fold<int>(
                  0,
                  (sum, t) => sum + t.total,
                );
                final avg = list.isNotEmpty
                    ? (totalRevenue / list.length).round()
                    : 0;
                return RefreshIndicator(
                  onRefresh: () async {
                    setState(() => _refreshKey++);
                  },
                  child: Column(
                    children: [
                      // ── Summary ──
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Container(
                          width: double.infinity,
                          padding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          decoration: BoxDecoration(
                            color: NusaConfig.activePrimary.withValues(
                              alpha: 0.08,
                            ),
                            borderRadius: BorderRadius.circular(
                              NusaConfig.radiusMD,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.summarize_rounded,
                                size: 18,
                                color: NusaConfig.activePrimary,
                              ),
                              SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${list.length} transaksi',
                                      style: GoogleFonts.plusJakartaSans(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        color: isDark
                                            ? NusaConfig.darkTextPrimary
                                            : isDark
                                            ? NusaConfig.darkTextPrimary
                                            : NusaConfig.textPrimary,
                                      ),
                                    ),
                                    SizedBox(height: 2),
                                    Text(
                                      'Rata-rata ${formatRupiah(avg)}',
                                      style: GoogleFonts.plusJakartaSans(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500,
                                        color: isDark
                                            ? NusaConfig.darkTextTertiary
                                            : isDark
                                            ? NusaConfig.darkTextTertiary
                                            : NusaConfig.textTertiary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Text(
                                formatRupiah(totalRevenue),
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  color: NusaConfig.activePrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      SizedBox(height: 12),
                      Expanded(
                        child: ListView.separated(
                          padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                          itemCount: list.length,
                          separatorBuilder: (_, __) => SizedBox(height: 12),
                          itemBuilder: (_, i) => _TransactionCard(
                            tx: list[i],
                            onVoid: () => _voidTransaction(list[i]),
                            onRetur: () => _showReturSheet(list[i]),
                            onReprint: () => _reprintTransaction(list[i]),
                            onShare: () async {
                              String? custName;
                              String? custPhone;
                              if (list[i].customerId != null) {
                                final custRepo = CustomerRepository(
                                  ref.read(databaseProvider),
                                );
                                final cust = await custRepo.byId(
                                  list[i].customerId!,
                                );
                                if (cust != null) {
                                  custName = cust.name;
                                  custPhone = cust.phone;
                                }
                              }
                              _showShareSheet(list[i], custName, custPhone);
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TransactionCard extends ConsumerStatefulWidget {
  final Transaction tx;
  final VoidCallback onVoid;
  final VoidCallback onRetur;
  final VoidCallback onReprint;
  final VoidCallback onShare;
  _TransactionCard({
    required this.tx,
    required this.onVoid,
    required this.onRetur,
    required this.onReprint,
    required this.onShare,
  });

  @override
  ConsumerState<_TransactionCard> createState() => _TransactionCardState();
}

class _TransactionCardState extends ConsumerState<_TransactionCard> {
  bool _expanded = false;
  Future<List<Refund>>? _refundFuture;

  // ── Status piutang (v2.2.34): dibaca dari debt yang terhubung via
  // tx.debtId, supaya riwayat transaksi sinkron dengan menu Piutang
  // (berubah saat DP/hutang dibayar progres atau lunas).
  Widget? _debtStatus;

  static const _payColors = {
    'Tunai': NusaConfig.payCash,
    'QRIS': NusaConfig.payQris,
    'Transfer': NusaConfig.payTransfer,
  };
  static const _payIcons = {
    'Tunai': Icons.money_rounded,
    'QRIS': Icons.qr_code_rounded,
    'Transfer': Icons.account_balance_rounded,
  };

  Color _payColor(bool isDark) =>
      _payColors[widget.tx.paymentMethod] ??
      (isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary);
  IconData _payIcon() =>
      _payIcons[widget.tx.paymentMethod] ?? Icons.payment_rounded;

  @override
  void initState() {
    super.initState();
    _loadDebtStatus();
  }

  Future<void> _loadDebtStatus() async {
    final debtId = widget.tx.debtId;
    if (debtId == null) return;
    try {
      final debt = await DebtRepository(
        ref.read(databaseProvider),
      ).byId(debtId);
      if (debt == null || !mounted) return;
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final lunas = debt.status == 'Lunas';
      final isCredit = (widget.tx.dpAmount ?? 0) == 0 &&
          (widget.tx.cashGiven ?? 0) == 0 &&
          debt.amount == widget.tx.total;
      // Status cicilan (v2.2.35): x/N bila debt ber-cicilan & belum lunas.
      String? installmentLabel;
      if (!lunas && debt.installmentMonths != null && debt.installmentMonths! > 0) {
        final months = debt.installmentMonths!;
        final perMonth = (debt.amount / months).ceil();
        final paidCount =
            ((debt.amount - debt.remainingAmount) / perMonth).ceil();
        installmentLabel =
            '${paidCount.clamp(1, months)}/$months';
      }
      setState(() {
        _debtStatus = Row(
          children: [
            Icon(
              lunas
                  ? Icons.check_circle_rounded
                  : Icons.pending_actions_rounded,
              size: 13,
              color: lunas
                  ? NusaConfig.accentGreen
                  : (isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary),
            ),
            SizedBox(width: 4),
            Flexible(
              child: Text(
                lunas
                    ? 'Piutang Lunas ✓'
                    : installmentLabel != null
                        ? 'Cicilan $installmentLabel · sisa ${formatRupiah(debt.remainingAmount)}'
                        : isCredit
                            ? 'Piutang — sisa ${formatRupiah(debt.remainingAmount)}'
                            : 'Sisa piutang ${formatRupiah(debt.remainingAmount)}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: lunas
                      ? NusaConfig.accentGreen
                      : (isDark
                            ? NusaConfig.darkTextTertiary
                            : const Color(0xFFB45309)),
                ),
              ),
            ),
          ],
        );
      });
    } catch (_) {}
  }

  static String _relDate(DateTime date) {
    final now = DateTime.now();
    if (date.year == now.year &&
        date.month == now.month &&
        date.day == now.day) {
      return 'Hari ini, ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    } else if (date.year == now.year &&
        date.month == now.month &&
        date.day == now.day - 1) {
      return 'Kemarin';
    }
    return '${date.day}/${date.month}/${date.year}';
  }

  Widget _actionIcon(IconData icon, Color color, VoidCallback onTap) =>
      Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 18, color: color),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tx = widget.tx;
    final items = _parseItems(tx.items);
    final isVoided = tx.status == 'Void';
    final accent = isVoided
        ? isDark
              ? NusaConfig.darkTextTertiary
              : NusaConfig.textTertiary
        : _payColor(isDark);
    final relDate = _relDate(tx.date);

    return Opacity(
      opacity: isVoided ? 0.6 : 1.0,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(NusaConfig.radiusLG),
        child: InkWell(
          onTap: () => setState(() {
            _expanded = !_expanded;
            if (_expanded && _refundFuture == null) {
              _refundFuture = ref
                  .read(refundRepoProvider)
                  .getByTransaction(widget.tx.id);
            }
          }),
          borderRadius: BorderRadius.circular(NusaConfig.radiusLG),
          child: Container(
            decoration: BoxDecoration(
              color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
              borderRadius: BorderRadius.circular(NusaConfig.radiusLG),
              border: Border.all(
                color: isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.06),
                  blurRadius: 10,
                  offset: Offset(0, 3),
                ),
              ],
            ),
            child: Padding(
              padding: EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Header ──
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  tx.invoice,
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    decoration: isVoided
                                        ? TextDecoration.lineThrough
                                        : null,
                                    color: isDark
                                        ? NusaConfig.darkTextPrimary
                                        : isDark
                                        ? NusaConfig.darkTextPrimary
                                        : NusaConfig.textPrimary,
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
                                      color: NusaConfig.activePrimary
                                          .withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      'VOID',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w800,
                                        color: NusaConfig.activePrimary,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            SizedBox(height: 4),
                            Row(
                              children: [
                                Icon(
                                  _payIcon(),
                                  size: 14,
                                  color: isVoided
                                      ? isDark
                                            ? NusaConfig.darkTextTertiary
                                            : NusaConfig.textTertiary
                                      : accent,
                                ),
                                SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    // v2.2.57+115: kasir dipindah ke baris
                                    // sendiri di bawah tanggal (sebelumnya
                                    // sejajar metode → ketutupan icon aksi).
                                    '$relDate • ${tx.paymentMethod}',
                                    overflow: TextOverflow.ellipsis,
                                    style: GoogleFonts.plusJakartaSans(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: isVoided
                                          ? isDark
                                                ? NusaConfig.darkTextTertiary
                                                : NusaConfig.textTertiary
                                          : (isDark
                                                ? NusaConfig.darkTextTertiary
                                                : NusaConfig.textTertiary),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            // v2.2.54: nama karyawan yang melakukan trx.
                            if ((tx.cashierName ?? '').isNotEmpty) ...[
                              SizedBox(height: 3),
                              Row(
                                children: [
                                  Icon(
                                    Icons.person_rounded,
                                    size: 13,
                                    color: isDark
                                        ? NusaConfig.darkTextTertiary
                                        : NusaConfig.textTertiary,
                                  ),
                                  SizedBox(width: 3),
                                  Flexible(
                                    child: Text(
                                      tx.cashierName ?? '',
                                      overflow: TextOverflow.ellipsis,
                                      style: GoogleFonts.plusJakartaSans(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: isDark
                                            ? NusaConfig.darkTextSecondary
                                            : NusaConfig.textSecondary,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                            // ── Status piutang (v2.2.34): sinkron dengan
                            // menu Piutang — "Lunas ✓" / "Sisa RpX" / "Piutang".
                            if (!isVoided && _debtStatus != null) ...[
                              SizedBox(height: 6),
                              _debtStatus!,
                            ],
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            formatRupiah(tx.total),
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: isVoided
                                  ? isDark
                                        ? NusaConfig.darkTextTertiary
                                        : NusaConfig.textTertiary
                                  : NusaConfig.activePrimary,
                            ),
                          ),
                          SizedBox(height: 6),
                          Row(
                            children: [
                              _actionIcon(
                                Icons.print_rounded,
                                NusaConfig.info,
                                widget.onReprint,
                              ),
                              SizedBox(width: 6),
                              _actionIcon(
                                Icons.share_rounded,
                                NusaConfig.accentGreen,
                                widget.onShare,
                              ),
                              if (!isVoided) ...[
                                SizedBox(width: 6),
                                _actionIcon(
                                  Icons.assignment_return_rounded,
                                  NusaConfig.info,
                                  widget.onRetur,
                                ),
                                SizedBox(width: 6),
                                _actionIcon(
                                  Icons.undo_rounded,
                                  NusaConfig.activePrimary,
                                  widget.onVoid,
                                ),
                              ],
                              SizedBox(width: 2),
                              _actionIcon(
                                _expanded
                                    ? Icons.expand_less_rounded
                                    : Icons.expand_more_rounded,
                                isDark
                                    ? NusaConfig.darkTextTertiary
                                    : NusaConfig.textTertiary,
                                () => setState(() {
                                  _expanded = !_expanded;
                                  if (_expanded && _refundFuture == null) {
                                    _refundFuture = ref
                                        .read(refundRepoProvider)
                                        .getByTransaction(widget.tx.id);
                                  }
                                }),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                  // ── Expanded detail ──
                  if (_expanded) ...[
                    SizedBox(height: 12),
                    Divider(
                      height: 1,
                      color: isDark
                          ? NusaConfig.darkDivider
                          : NusaConfig.dividerColor,
                    ),
                    SizedBox(height: 10),
                    ...items.map(
                      (it) => Padding(
                        padding: EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                '${_itemDisplayName(it)} x ${_itemQtyLabel(it)}',
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 13,
                                  color: isDark
                                      ? NusaConfig.darkTextSecondary
                                      : isDark
                                      ? NusaConfig.darkTextSecondary
                                      : NusaConfig.textSecondary,
                                ),
                              ),
                            ),
                            Text(
                              formatRupiah(
                                (it['qty'] as int) * (it['price'] as int),
                              ),
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: isDark
                                    ? NusaConfig.darkTextPrimary
                                    : isDark
                                    ? NusaConfig.darkTextPrimary
                                    : NusaConfig.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 8),
                    Divider(
                      height: 1,
                      color: isDark
                          ? NusaConfig.darkDivider
                          : NusaConfig.dividerColor,
                    ),
                    SizedBox(height: 8),
                    FutureBuilder<List<Refund>>(
                      future: _refundFuture,
                      builder: (context, snap) {
                        final refunds = snap.data ?? const [];
                        if (refunds.isEmpty) {
                          return const SizedBox.shrink();
                        }
                        final total = refunds.fold(
                          0,
                          (int s, r) => s + r.refundAmount,
                        );
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ...refunds.map(
                              (r) => Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 3,
                                ),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Expanded(
                                      child: Text(
                                        '↩ ${r.productName} x ${r.qty}',
                                        style: GoogleFonts.plusJakartaSans(
                                          fontSize: 13,
                                          color: NusaConfig.info,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      formatRupiah(r.refundAmount),
                                      style: GoogleFonts.plusJakartaSans(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: NusaConfig.info,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Divider(
                              height: 1,
                              color: isDark
                                  ? NusaConfig.darkDivider
                                  : NusaConfig.dividerColor,
                            ),
                            _row(
                              'Sudah di-retur',
                              formatRupiah(total),
                              isDark: isDark,
                            ),
                          ],
                        );
                      },
                    ),
                    _row(
                      'Subtotal',
                      formatRupiah(tx.total + tx.discount),
                      isDark: isDark,
                    ),
                    _row('Diskon', formatRupiah(tx.discount), isDark: isDark),
                    _row('Total', formatRupiah(tx.total), isDark: isDark),
                    _row(
                      'Bayar',
                      tx.cashGiven != null ? formatRupiah(tx.cashGiven!) : '-',
                      isDark: isDark,
                    ),
                    _row(
                      'Kembali',
                      tx.cashReturn != null
                          ? formatRupiah(tx.cashReturn!)
                          : '-',
                      isDark: isDark,
                    ),
                    if (isVoided && tx.voidReason != null) ...[
                      SizedBox(height: 8),
                      Text(
                        'Alasan void: ${tx.voidReason}',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                          color: NusaConfig.activePrimary,
                        ),
                      ),
                    ],
                    if (!isVoided) ...[
                      SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: widget.onVoid,
                          icon: Icon(Icons.undo_rounded, size: 18),
                          label: Text(
                            'Void Transaksi',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: NusaConfig.activePrimary,
                            side: BorderSide(color: NusaConfig.activePrimary),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            padding: EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                      SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: widget.onRetur,
                          icon: Icon(Icons.assignment_return_rounded, size: 18),
                          label: Text(
                            'Retur / Refund Parsial',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: NusaConfig.info,
                            side: BorderSide(color: NusaConfig.info),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            padding: EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                    ], // close if(!isVoided)
                  ], // close if(_expanded)
                ], // close Column children
              ), // close Column
            ), // close Padding
          ), // close Container
        ), // close InkWell
      ), // close Material
    ); // close Opacity
  }

  Widget _row(String label, String value, {bool isDark = false}) => Padding(
    padding: EdgeInsets.symmetric(vertical: 3),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: GoogleFonts.plusJakartaSans(
            fontSize: 13,
            color: isDark
                ? NusaConfig.darkTextSecondary
                : isDark
                ? NusaConfig.darkTextSecondary
                : NusaConfig.textSecondary,
          ),
        ),
        Text(
          value,
          style: GoogleFonts.plusJakartaSans(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isDark
                ? NusaConfig.darkTextPrimary
                : isDark
                ? NusaConfig.darkTextPrimary
                : NusaConfig.textPrimary,
          ),
        ),
      ],
    ),
  );
}

List<Map<String, dynamic>> _parseItems(String json) {
  try {
    final decoded = jsonDecode(json);
    if (decoded is List) {
      return decoded.map((e) => Map<String, dynamic>.from(e)).toList();
    }
  } catch (_) {
    // ignore malformed items
  }
  return [];
}
