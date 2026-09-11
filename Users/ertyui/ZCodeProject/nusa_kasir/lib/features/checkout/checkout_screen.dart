import 'dart:convert';
import 'dart:io';
import 'dart:async' show unawaited;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:intl/intl.dart';
import 'package:nusa_kasir/core/providers.dart';
import 'package:nusa_kasir/core/config/nusa_config.dart';
import 'package:nusa_kasir/core/utils/format_rupiah.dart';
import 'package:nusa_kasir/core/utils/secure_storage.dart';
import 'package:nusa_kasir/core/utils/receipt_printer.dart';
import 'package:drift/drift.dart' show Value;
import 'package:nusa_kasir/data/database/app_database.dart';
import 'package:nusa_kasir/data/repositories/cashier_session_repository.dart';
import 'package:nusa_kasir/data/repositories/customer_repository.dart';
import 'package:nusa_kasir/data/repositories/debt_repository.dart';
import 'package:nusa_kasir/data/repositories/installment_option_repository.dart';
import 'package:nusa_kasir/data/repositories/dining_table_repository.dart';
import 'package:nusa_kasir/data/repositories/laundry_order_repository.dart';
import 'package:nusa_kasir/data/repositories/appointment_repository.dart';
import 'package:nusa_kasir/data/repositories/attendance_repository.dart';
import 'package:nusa_kasir/core/services/sound_service.dart';
import 'package:nusa_kasir/core/services/realtime_sync_service.dart';
import 'package:nusa_kasir/core/services/delta_sync_service.dart';
import 'package:nusa_kasir/data/repositories/print_order_repository.dart';
import 'package:nusa_kasir/data/repositories/print_service_type_repository.dart';
import 'package:nusa_kasir/data/repositories/product_repository.dart';
import 'package:nusa_kasir/data/repositories/recipe_repository.dart';
import 'package:nusa_kasir/data/repositories/promo_repository.dart';
import 'package:nusa_kasir/data/repositories/settings_repository.dart';
import 'package:nusa_kasir/data/repositories/tab_repository.dart';
import 'package:nusa_kasir/features/auth/employee_session_provider.dart';
import 'package:nusa_kasir/features/pos/cart.dart';
import 'package:nusa_kasir/shared/widgets/top_toast.dart';
import 'package:nusa_kasir/shared/widgets/screen_scaffold.dart';
import 'package:nusa_kasir/shared/widgets/hid_barcode_listener.dart';
import 'package:nusa_kasir/shared/widgets/nusa_search_bar.dart';
import 'package:nusa_kasir/shared/widgets/animated_scanner_overlay.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:nusa_kasir/features/checkout/receipt_sheet.dart';

/// Shared section card style used across all checkout cards.
BoxDecoration _sectionCard(bool isDark) => BoxDecoration(
  color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
  borderRadius: BorderRadius.circular(18),
  border: Border.all(
    color: isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor,
  ),
  boxShadow: [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.03),
      blurRadius: 8,
      offset: Offset(0, 2),
    ),
  ],
);

class CheckoutScreen extends ConsumerStatefulWidget {
  final int? sessionId;
  CheckoutScreen({super.key, this.sessionId});
  @override
  ConsumerState<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends ConsumerState<CheckoutScreen> {
  static const _customDenomsKey = 'nusa_checkout_custom_denoms';
  final _discountCtrl = TextEditingController();
  final _cashCtrl = TextEditingController();
  final _promoCtrl = TextEditingController();
  String _paymentMethod = 'Tunai';
  bool _loading = false;
  List<int> denoms = [];
  // ── Uang Pas + template nominal custom (K8) ──
  List<int> _customDenoms = [];
  int? _cashGiven;
  String? _qrisString;
  String? _qrisImagePath;
  String? _bankName;
  String? _bankAccount;
  String? _bankHolder;
  Customer? _selectedCustomer;
  Promo? _appliedPromo;
  int _pointsUsed = 0; // poin yang ditukar (1 poin = Rp 1)
  bool _promoLoading = false; // untuk tombol pilih diskon
  bool _hasBebasPromos =
      false; // ada promo mode 'bebas' yang bisa dipilih di kasir

  // Split bill
  bool _splitBill = false;
  int _splitCount = 2;

  // DP (uang muka): bayar sebagian sekarang, sisanya dicatat sebagai piutang.
  // Lazim di servis/bengkel/salon (biasanya 50%), tapi bisa untuk semua varian.
  bool _dpEnabled = false;
  final _dpCtrl = TextEditingController();

  // ── DP v2.2.34: mode nominal / persen + cicilan ──
  // Persen: DP = ceil(total × %/100), sisa dibagi rata sesuai opsi cicilan.
  bool _dpIsPercent = false;
  final _dpPercentCtrl = TextEditingController();
  bool _installmentEnabled = false;
  int? _installmentMonths;
  List<InstallmentOption> _installmentOptions = [];

  /// Mode HUTANG: bayar 0 sekarang, SELURUH total dicatat sebagai hutang
  /// pelanggan (masuk menu Piutang). Berlaku untuk semua metode bayar.
  bool _creditMode = false;

  /// Jatuh tempo piutang (v2.2.35) — default +7 hari saat DP/Hutang aktif.
  DateTime? _dueDate;

  // FnB params
  String? _orderType;
  int? _tableId;
  String? _tableName;
  int? _activeTabId;

  // Salon booking params
  DateTime _salonDate = DateTime.now();
  final _salonTimeCtrl = TextEditingController(text: '09:00');
  final _salonStylistCtrl = TextEditingController();
  int _salonDuration = 60;
  // v2.2.54: stylist = dropdown karyawan ber-flag isServiceStaff (bukan teks
  // bebas) — id tersimpan ke appointments.stylist_id untuk laporan per staf.
  List<Employee> _salonStaff = [];
  int? _selectedStylistId;

  Future<void> _loadSalonStaff() async {
    try {
      final emps = await AttendanceRepository(
        ref.read(databaseProvider),
      ).getEmployees();
      if (!mounted) return;
      setState(() {
        _salonStaff = emps
            .where((e) => e.isServiceStaff && (e.status ?? 'Aktif') != 'Nonaktif')
            .toList();
        // Validasi pilihan lama (mis. setelah restore data).
        if (_selectedStylistId != null &&
            !_salonStaff.any((e) => e.id == _selectedStylistId)) {
          _selectedStylistId = null;
        }
        // v2.2.57: default stylist = staf layanan yang sedang login —
        // Stylist yang melayani langsung tercatat tanpa pilih manual.
        if (_selectedStylistId == null) {
          final session = ref.read(employeeSessionProvider);
          if (session != null &&
              _salonStaff.any((e) => e.id == session.employeeId)) {
            _selectedStylistId = session.employeeId;
          }
        }
      });
    } catch (_) {}
  }

  Future<void> _completeTab(AppDatabase db, {bool freeTable = true}) async {
    try {
      final tabRepo = TabRepository(db);
      await tabRepo.complete(_activeTabId!);
      if (freeTable && _tableId != null) {
        await DiningTableRepository(db).updateStatus(_tableId!, 'Kosong');
      }
    } catch (_) {}
  }

  /// Trigger kitchen printer (FnB only). Fire-and-forget — never blocks user.
  void _triggerKitchenPrint(
    List<CartItem> cart,
    String? orderType,
    String? tableName,
  ) {
    Future.microtask(() async {
      try {
        // Pre-flight: check Bluetooth permissions & state
        if (!await ReceiptPrinter.ensureBluetoothReady()) return;

        final enabled = await SecureStore.getKitchenPrinterEnabled();
        if (!enabled) return;
        final addr = await SecureStore.getKitchenPrinterAddress();
        if (addr == null || addr.isEmpty) return;

        final printer = ReceiptPrinter();
        final lines = cart
            .map((c) => ReceiptLine(name: c.name, qty: c.qty, price: c.price))
            .toList();
        // Kitchen order tidak menampilkan harga — qty & nama saja. price
        // tidak dipakai di render kitchen (printKitchenOrder).
        final notes = cart.map((c) => c.note).toList();

        await printer.printKitchenOrder(
          orderType: orderType ?? 'Dine In',
          lines: lines,
          itemNotes: notes,
          tableName: tableName,
        );
      } catch (_) {
        // Silent fail — kitchen print is best-effort
      }
    });
  }

  // v2.2.57+127: subtotal = Σ (harga sementara/unit × qty) MINUS diskon
  // MANUAL per satuan (itemDiscountTotal). Diskon produk/menu sudah tercermin
  // di price — TIDAK dikurang lagi (fix dobel diskon: 87.500 → 12.500).
  int get _subtotal {
    final cart = ref.watch(cartProvider);
    return cart.fold(
      0,
      (s, e) => s + e.subtotal - e.itemDiscountTotal,
    );
  }
  // v2.2.55: true bila keranjang berisi minimal satu item LAYANAN. Item
  // manual/timbang default isService=false jadi aman. read (bukan watch)
  // supaya boleh dipanggil dari _confirmPayment; reaktivitas build tetap
  // terjaga oleh ref.watch(cartProvider) di build().
  bool get _cartHasService => ref.read(cartProvider).any((e) => e.isService);
  int get _manualDiscount => int.tryParse(_discountCtrl.text) ?? 0;
  int get _tierDiscount {
    if (_selectedCustomer == null) return 0;
    final pct = CustomerRepository.tierDiscountPercent(
      _selectedCustomer!.level,
    );
    return (_subtotal * pct / 100).round();
  }

  /// Diskon promo dihitung ULANG dari subtotal saat itu (bukan beku di apply).
  /// - persen  → proporsional terhadap subtotal (otomatis mengikuti perubahan keranjang)
  /// - nominal → tetap, tapi tidak boleh melebihi subtotal
  /// - Jika subtotal turun di bawah min. belanja → 0 (promo tetap terpasang).
  int get _promoDiscount {
    final p = _appliedPromo;
    if (p == null) return 0;
    if (_subtotal < p.minBelanja) return 0;
    final d = p.type == 'persen'
        ? (_subtotal * p.value / 100).round()
        : p.value;
    return d.clamp(0, _subtotal);
  }

  int get _totalDiscount =>
      (_manualDiscount + _promoDiscount + _tierDiscount + _pointsUsed).clamp(
        0,
        _subtotal,
      );
  int get _total => (_subtotal - _totalDiscount).clamp(0, _subtotal);
  int? get _kembalian =>
      _cashGiven != null && _cashGiven! >= _total ? _cashGiven! - _total : null;

  /// Nominal DP yang dipakai transaksi ini (0 jika DP mati).
  /// Saat DP aktif: nominal langsung (mode Rp) atau ceil(total × %) (mode %).
  int get _downPayment {
    if (!_dpEnabled) return 0;
    if (_dpIsPercent) {
      final pct = int.tryParse(_dpPercentCtrl.text) ?? 0;
      if (pct <= 0 || pct >= 100) return 0;
      return (_total * pct / 100).ceil();
    }
    return int.tryParse(_dpCtrl.text) ?? 0;
  }

  /// Cicilan per bulan (sisa dibagi rata, dibulatkan ke atas).
  int get _installmentPerMonth {
    final months = _installmentEnabled && _installmentMonths != null
        ? _installmentMonths!
        : 0;
    if (months <= 0) return 0;
    return (_remainingDue / months).ceil();
  }

  /// Sisa yang belum dibayar (piutang) — hanya saat DP aktif.
  /// Saat mode HUTANG aktif, seluruh total menjadi sisa (piutang penuh).
  int get _remainingDue {
    if (_creditMode) return _total;
    return _downPayment > 0 ? (_total - _downPayment).clamp(0, _total) : 0;
  }

  @override
  void initState() {
    super.initState();
    _loadPaymentSettings();
    _checkBebasPromos();
    _loadInstallmentOptions();
    if (NusaConfig.isSalonVariant) _loadSalonStaff();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeAutoApplyPromo();
      final extra = GoRouterState.of(context).uri.queryParameters;
      if (extra['orderType'] != null) {
        _orderType = extra['orderType'];
        _tableId = int.tryParse(extra['tableId'] ?? '');
        _tableName = extra['tableName'] != null
            ? Uri.decodeComponent(extra['tableName']!)
            : null;
        _activeTabId = int.tryParse(extra['activeTabId'] ?? '');
        if (mounted) setState(() {});
      }
      // ── Route customer (dari servis/booking: "Kasir" trigger) ──
      final customer = extra['customer'];
      final customerPhone = extra['customerPhone'];
      if ((customer != null && customer.isNotEmpty) ||
          (customerPhone != null && customerPhone.isNotEmpty)) {
        _preselectCustomer(
          name: customer != null ? Uri.decodeComponent(customer) : null,
          phone: customerPhone != null
              ? Uri.decodeComponent(customerPhone)
              : null,
        );
      }
    });
  }

  /// Auto-select the customer passed via route params (servis/booking →
  /// POS → checkout). If a customer with that phone exists, use it; otherwise
  /// create a lightweight record so the transaction still records the name.
  Future<void> _preselectCustomer({String? name, String? phone}) async {
    final repo = CustomerRepository(ref.read(databaseProvider));
    Customer? found;
    final cleanPhone = phone != null && phone.isNotEmpty ? phone : null;
    if (cleanPhone != null) {
      found = await repo.byPhone(cleanPhone);
    }
    if (found == null && name != null && name.isNotEmpty) {
      final all = await repo.getCustomers();
      found = all.cast<Customer?>().firstWhere(
        (c) => c!.name.toLowerCase() == name.toLowerCase(),
        orElse: () => null,
      );
    }
    if (found == null && name != null && name.isNotEmpty) {
      final id = await repo.addCustomer(name: name, phone: cleanPhone);
      found = await repo.byId(id);
    }
    if (found != null && mounted) {
      setState(() {
        _selectedCustomer = found;
        _pointsUsed = 0;
      });
    }
  }

  Future<void> _loadPaymentSettings() async {
    final repo = ref.read(settingsRepoProvider);
    final qris = await repo.getQris();
    final qrisImg = await repo.getQrisImagePath();
    final bankName = await repo.getBankName();
    final bankAccount = await repo.getBankAccount();
    final bankHolder = await repo.getBankHolder();
    // Template nominal custom (Uang Pas / nominal cepat) — tersimpan di
    // SecureStore JSON, ikut backup cloud lewat nusa_config? Tidak — SecureStore
    // lokal per device. Nominal cepat tidak perlu sinkron antar device.
    List<int> customs = [];
    try {
      final raw = await SecureStore.read(key: _customDenomsKey);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List;
        customs = list
            .map((e) => int.tryParse('$e') ?? 0)
            .where((v) => v > 0)
            .toList();
      }
    } catch (_) {}
    if (mounted)
      setState(() {
        _qrisString = qris;
        _qrisImagePath = qrisImg;
        _bankName = bankName;
        _bankAccount = bankAccount;
        _bankHolder = bankHolder;
        _customDenoms = customs;
      });
  }

  /// "Uang Pas": isi nominal pembayaran = total tagihan tepat (kembalian 0).
  void _applyExactCash() {
    final t = _total;
    _cashCtrl.text = t.toString();
    setState(() => _cashGiven = t);
  }

  /// Simpan template nominal custom ke SecureStore (JSON array int).
  Future<void> _saveCustomDenoms() async {
    try {
      await SecureStore.write(
        key: _customDenomsKey,
        value: jsonEncode(_customDenoms),
      );
    } catch (_) {}
  }

  /// Sheet kelola template nominal: tambah, hapus. Akses lewat ikon pensil
  /// di sebelah chip nominal cepat.
  Future<void> _manageCustomDenoms() async {
    final ctrl = TextEditingController();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPri = isDark
        ? NusaConfig.darkTextPrimary
        : NusaConfig.textPrimary;
    final textSec = isDark
        ? NusaConfig.darkTextSecondary
        : NusaConfig.textSecondary;
    final textTer = isDark
        ? NusaConfig.darkTextTertiary
        : NusaConfig.textTertiary;
    final surface = isDark ? NusaConfig.darkSurface : Colors.white;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Container(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: NusaConfig.accentGreen.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.tune,
                      size: 20,
                      color: NusaConfig.accentGreen,
                    ),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Nominal Cepat',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: textPri,
                          ),
                        ),
                        Text(
                          'Chip tambahan di samping pecahan uang',
                          style: TextStyle(fontSize: 12, color: textTer),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(ctx),
                    icon: Icon(Icons.close, color: textSec),
                  ),
                ],
              ),
              SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: ctrl,
                      keyboardType: TextInputType.number,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: textPri,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Contoh: 15000',
                        hintStyle: TextStyle(fontSize: 14, color: textTer),
                        filled: true,
                        fillColor: isDark
                            ? NusaConfig.darkSurface2
                            : Color(0xFFF9FAFB),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: 10),
                  ElevatedButton(
                    onPressed: () {
                      final v = int.tryParse(ctrl.text.trim());
                      if (v == null || v <= 0) return;
                      if (_customDenoms.contains(v)) {
                        TopToast.info(ctx, 'Nominal $v sudah ada');
                        return;
                      }
                      setSheet(
                        () => _customDenoms = [..._customDenoms, v]..sort(),
                      );
                      ctrl.clear();
                      _saveCustomDenoms();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: NusaConfig.activePrimary,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      'Tambah',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 12),
              if (_customDenoms.isEmpty)
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'Belum ada nominal custom. Tambahkan, misal 15000 untuk voucher/saldo.',
                    style: TextStyle(fontSize: 12.5, color: textTer),
                  ),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final v in _customDenoms)
                      Chip(
                        label: Text(
                          formatRupiah(v),
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 12.5,
                          ),
                        ),
                        backgroundColor: isDark
                            ? NusaConfig.darkSurface2
                            : Color(0xFFF0FDF4),
                        side: BorderSide(
                          color: isDark
                              ? NusaConfig.darkBorder
                              : Color(0xFFBBF7D0),
                        ),
                        deleteIcon: Icon(
                          Icons.close,
                          size: 16,
                          color: Color(0xFFDC2626),
                        ),
                        onDeleted: () {
                          setSheet(
                            () => _customDenoms = _customDenoms
                                .where((e) => e != v)
                                .toList(),
                          );
                          _saveCustomDenoms();
                        },
                      ),
                  ],
                ),
              SizedBox(height: 8),
              if (_customDenoms.isNotEmpty)
                TextButton.icon(
                  onPressed: () {
                    setSheet(() => _customDenoms = []);
                    _saveCustomDenoms();
                  },
                  icon: Icon(Icons.delete_outline, size: 16),
                  label: Text('Hapus semua', style: TextStyle(fontSize: 12.5)),
                  style: TextButton.styleFrom(
                    foregroundColor: Color(0xFFDC2626),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    ctrl.dispose();
  }

  /// Render chip nominal cepat (pecahan + custom). Custom punya ikon kelola.
  Widget _buildDenomChips(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final d in denoms)
              _denomChip(isDark, d, () {
                final prev = int.tryParse(_cashCtrl.text) ?? 0;
                final newVal = prev + d;
                _cashCtrl.text = newVal.toString();
                setState(() => _cashGiven = newVal);
              }),
            for (final d in _customDenoms)
              _denomChip(isDark, d, () {
                final prev = int.tryParse(_cashCtrl.text) ?? 0;
                final newVal = prev + d;
                _cashCtrl.text = newVal.toString();
                setState(() => _cashGiven = newVal);
              }),
            // Reset button
            GestureDetector(
              onTap: () {
                _cashCtrl.clear();
                setState(() => _cashGiven = null);
              },
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Color(0xFFFEF2F2),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Color(0xFFFECACA)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.refresh, size: 12, color: Color(0xFFDC2626)),
                    SizedBox(width: 4),
                    Text(
                      'Reset',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFDC2626),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: 8),
        // Uang Pas + kelola nominal custom — kompak seperti chip nominal lain
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _denomChip(
              isDark,
              _total,
              _applyExactCash,
              label: 'Uang Pas',
              accent: NusaConfig.activePrimary,
            ),
            SizedBox(width: 6),
            IconButton(
              onPressed: _manageCustomDenoms,
              tooltip: 'Atur nominal cepat',
              icon: Icon(Icons.tune, size: 18),
              color: isDark
                  ? NusaConfig.darkTextSecondary
                  : NusaConfig.textSecondary,
              style: IconButton.styleFrom(
                backgroundColor: isDark
                    ? NusaConfig.darkSurface2
                    : Color(0xFFF1F5F9),
                minimumSize: Size(36, 36),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _denomChip(
    bool isDark,
    int value,
    VoidCallback onTap, {
    String? label,
    Color? accent,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkSurface2 : Color(0xFFF0FDF4),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color:
                accent ?? (isDark ? NusaConfig.darkBorder : Color(0xFFBBF7D0)),
          ),
        ),
        child: Text(
          label ?? formatRupiah(value),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: accent ?? Color(0xFF166534),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _discountCtrl.dispose();
    _cashCtrl.dispose();
    _promoCtrl.dispose();
    _dpCtrl.dispose();
    _salonTimeCtrl.dispose();
    _salonStylistCtrl.dispose();
    super.dispose();
  }

  Future<void> _applyPromo() async {
    final code = _promoCtrl.text.trim();
    if (code.isEmpty) {
      TopToast.error(context, 'Masukkan kode promo');
      return;
    }
    final repo = PromoRepository(ref.read(databaseProvider));
    final promos = await repo.getPromos();
    final match = promos.cast<Promo?>().firstWhere(
      (p) =>
          p!.code.toUpperCase() == code.toUpperCase() &&
          p.status == 'Aktif' &&
          p.mode != 'otomatis', // otomatis tidak pakai kode
      orElse: () => null,
    );
    if (match == null) {
      TopToast.error(context, 'Kode promo tidak valid atau tidak aktif');
      return;
    }

    // Check min belanja
    if (_subtotal < match.minBelanja) {
      TopToast.error(context, 'Min. belanja ${formatRupiah(match.minBelanja)}');
      return;
    }

    // Check kuota
    if (match.maxUses != null && match.usedCount >= match.maxUses!) {
      TopToast.error(context, 'Kuota promo sudah habis');
      return;
    }

    // Calculate discount (percent promo follows the live subtotal via getter)
    final discount =
        (match.type == 'persen'
                ? (_subtotal * match.value / 100).round()
                : match.value)
            .clamp(0, _subtotal);

    setState(() {
      _appliedPromo = match;
    });
    TopToast.success(
      context,
      'Promo "${match.name}" diterapkan! '
      'Diskon ${formatRupiah(discount)}',
    );
  }

  void _clearPromo() {
    setState(() {
      _appliedPromo = null;
      _promoCtrl.clear();
    });
  }

  /// Promo aktif & valid secara umum (status, tanggal, kuota).
  bool _isPromoUsable(Promo p, {required bool checkMin}) {
    if (p.status != 'Aktif') return false;
    final now = DateTime.now();
    if (p.startDate != null && p.startDate!.isAfter(now)) return false;
    if (p.endDate != null && p.endDate!.isBefore(now)) return false;
    if (p.maxUses != null && p.usedCount >= p.maxUses!) return false;
    if (checkMin && _subtotal < p.minBelanja) return false;
    return true;
  }

  /// Promo yang BISA dipilih manual di kasir (mode 'bebas').
  Future<List<Promo>> _getSelectablePromos() async {
    final repo = PromoRepository(ref.read(databaseProvider));
    final promos = await repo.getPromos();
    return promos
        .where((p) => p.mode == 'bebas' && _isPromoUsable(p, checkMin: true))
        .toList();
  }

  /// Refresh flag: apakah ada promo mode 'bebas' (tombol "Pilih diskon dari
  /// daftar" disembunyikan kalau tidak ada — hindari tombol yang selalu kosong).
  Future<void> _checkBebasPromos() async {
    try {
      final repo = PromoRepository(ref.read(databaseProvider));
      final promos = await repo.getPromos();
      final has = promos.any(
        (p) => p.mode == 'bebas' && _isPromoUsable(p, checkMin: false),
      );
      if (mounted && has != _hasBebasPromos) {
        setState(() => _hasBebasPromos = has);
      }
    } catch (_) {}
  }

  /// Auto-apply promo mode 'otomatis' (diskon terbesar yang memenuhi syarat).
  /// Tidak menimpa promo yang sudah dipasang manual (kode/bebas).
  Future<void> _maybeAutoApplyPromo() async {
    if (_appliedPromo != null) return;
    final repo = PromoRepository(ref.read(databaseProvider));
    final promos = await repo.getPromos();
    Promo? best;
    int bestDisc = 0;
    for (final p in promos) {
      if (p.mode != 'otomatis') continue;
      if (!_isPromoUsable(p, checkMin: true)) continue;
      final d = p.type == 'persen'
          ? (_subtotal * p.value / 100).round()
          : p.value;
      if (d > bestDisc) {
        best = p;
        bestDisc = d;
      }
    }
    if (best != null && bestDisc > 0 && mounted) {
      setState(() => _appliedPromo = best);
    }
  }

  /// Bottom sheet daftar diskon yang bisa dipilih (mode 'bebas').
  Future<void> _showPickDiscountSheet() async {
    if (_promoLoading) return;
    setState(() => _promoLoading = true);
    try {
      final list = await _getSelectablePromos();
      if (!mounted) return;
      final selected = await showModalBottomSheet<Promo>(
        context: context,
        useRootNavigator: true,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (ctx) {
          final isDark = Theme.of(ctx).brightness == Brightness.dark;
          return Container(
            decoration: BoxDecoration(
              color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: NusaConfig.dividerColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                  child: Row(
                    children: [
                      Icon(
                        Icons.local_offer_outlined,
                        size: 20,
                        color: NusaConfig.activePrimary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Pilih Diskon',
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
                ),
                if (list.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'Belum ada diskon yang bisa dipilih.\nBuat promo dengan mode "Pilih di Kasir".',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark
                            ? NusaConfig.darkTextTertiary
                            : NusaConfig.textTertiary,
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: list.length,
                      itemBuilder: (_, i) {
                        final p = list[i];
                        return ListTile(
                          leading: Icon(
                            Icons.discount_outlined,
                            color: NusaConfig.activePrimary,
                          ),
                          title: Text(
                            p.name,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            '${p.type == 'persen' ? '${p.value}%' : formatRupiah(p.value)}'
                            '${p.minBelanja > 0 ? ' • Min. ${formatRupiah(p.minBelanja)}' : ''}',
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark
                                  ? NusaConfig.darkTextSecondary
                                  : NusaConfig.textSecondary,
                            ),
                          ),
                          trailing: _appliedPromo?.id == p.id
                              ? Icon(
                                  Icons.check_circle,
                                  color: NusaConfig.accentGreen,
                                )
                              : Icon(
                                  Icons.chevron_right,
                                  color: isDark
                                      ? NusaConfig.darkTextTertiary
                                      : NusaConfig.textTertiary,
                                ),
                          onTap: () => Navigator.of(ctx).pop(p),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      );
      if (selected != null && mounted) {
        setState(() {
          _appliedPromo = selected;
          _promoCtrl.clear();
        });
        final d = selected.type == 'persen'
            ? (_subtotal * selected.value / 100).round()
            : selected.value;
        TopToast.success(
          context,
          'Diskon "${selected.name}" diterapkan! '
          'Potongan ${formatRupiah(d.clamp(0, _subtotal))}',
        );
      }
    } finally {
      if (mounted) setState(() => _promoLoading = false);
    }
  }

  Future<void> _pickCustomer() async {
    final repo = CustomerRepository(ref.read(databaseProvider));
    final customers = await repo.getCustomers();
    if (!mounted) return;

    final result = await showDialog<Customer?>(
      context: context,
      builder: (ctx) => _CustomerPickerDialog(
        customers: customers,
        onAddNew: () async {
          Navigator.pop(ctx); // close picker first
          final created = await _showAddCustomerSheet();
          if (created != null) {
            setState(() {
              _selectedCustomer = created;
              _pointsUsed = 0;
              _dpEnabled = false;
              _dpCtrl.clear();
            });
            if (mounted)
              TopToast.success(context, 'Pelanggan: ${created.name}');
          }
        },
        byBarcode: (code) => repo.byBarcode(code),
        scanBarcode: (onResult) => _scanMemberBarcode(ctx, onResult),
      ),
    );

    if (result != null && mounted) {
      setState(() {
        _selectedCustomer = result;
        _pointsUsed = 0;
        _dpEnabled = false;
        _dpCtrl.clear();
      });
      TopToast.success(context, 'Pelanggan: ${result.name}');
    }
  }

  /// Scan barcode member via kamera (pola sama customer_screen B11) —
  /// hasil diteruskan ke callback untuk dicari & auto-pilih.
  Future<void> _scanMemberBarcode(
    BuildContext ctx,
    ValueChanged<String> onResult,
  ) async {
    String? scannedCode;
    final controller = MobileScannerController(
      formats: const [
        BarcodeFormat.ean13,
        BarcodeFormat.ean8,
        BarcodeFormat.upcA,
        BarcodeFormat.upcE,
        BarcodeFormat.code128,
        BarcodeFormat.code39,
        BarcodeFormat.qrCode,
      ],
    );
    String? errorMsg;
    await showDialog(
      context: ctx,
      barrierDismissible: false,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, dSet) => AlertDialog(
          title: Row(
            children: [
              Icon(
                Icons.qr_code_scanner,
                size: 22,
                color: NusaConfig.activePrimary,
              ),
              const SizedBox(width: 8),
              const Text('Pindai Barcode Member'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedScannerOverlay(
                size: 280,
                child: MobileScanner(
                  controller: controller,
                  onDetect: (capture) {
                    if (scannedCode != null) return;
                    final raw = capture.barcodes.isNotEmpty
                        ? capture.barcodes.first.rawValue
                        : null;
                    if (raw == null || raw.isEmpty) return;
                    scannedCode = raw;
                    Navigator.pop(dctx);
                  },
                  errorBuilder: (context, error, child) {
                    debugPrint('[Checkout] scanner error: $error');
                    if (errorMsg == null) {
                      errorMsg =
                          'Kamera tidak tersedia atau izin kamera ditolak.';
                      dSet(() {});
                    }
                    return Container(
                      height: 280,
                      width: 280,
                      color: Colors.black12,
                      alignment: Alignment.center,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.no_photography_outlined,
                              size: 36,
                              color: Colors.grey,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Kamera tidak tersedia.\nBarcode diisi manual atau scan HID.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (errorMsg != null) ...[
                const SizedBox(height: 8),
                Text(
                  errorMsg!,
                  style: TextStyle(fontSize: 11, color: Colors.orange.shade800),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx),
              child: const Text('Batal'),
            ),
          ],
        ),
      ),
    );
    await controller.dispose();
    if (scannedCode == null || !ctx.mounted) return;
    final norm = scannedCode!.replaceAll(RegExp(r'[\s\-]'), '').trim();
    if (norm.isEmpty) return;
    onResult(norm);
  }

  /// v2.2.57+137: flush delta outbox SEKARANG lalu broadcast "ada data baru"
  /// — urutannya penting: broadcast yang sampai lebih dulu dari datanya bikin
  /// owner pull ke server yang masih kosong (kesan tidak realtime).
  Future<void> _pushAndAnnounce() async {
    try {
      await DeltaSyncService.I.flushNow();
    } catch (_) {}
    try {
      await RealtimeBackupNotifier.I.broadcastUpdated();
    } catch (_) {}
  }

  Future<void> _confirmPayment() async {
    final cart = ref.read(cartProvider);
    if (cart.isEmpty) {
      TopToast.error(context, 'Keranjang kosong');
      return;
    }

    // Validasi jumlah bayar sebelum proses.
    //  - Tunai tanpa DP: jumlah dibayar (cashGiven) harus ≥ total.
    //  - Tunai dengan DP: DP harus > 0 dan < total (sisa dicatat piutang).
    //  - EDC / QRIS / Transfer: lunas dianggap dibayar penuh.
    //  - HUTANG: bayar 0 sekarang, seluruh total dicatat piutang (wajib pelanggan).
    if (_creditMode) {
      if (_selectedCustomer == null) {
        TopToast.error(context, 'Pilih pelanggan dulu untuk mencatat hutang');
        return;
      }
    } else if (_paymentMethod == 'Tunai' && _dpEnabled) {
      final dp = _downPayment;
      if (dp <= 0) {
        TopToast.error(
          context,
          _dpIsPercent
              ? 'Isi persen uang muka (DP) 1-99'
              : 'Isi nominal uang muka (DP)',
        );
        return;
      }
      if (dp >= _total) {
        TopToast.error(context, 'DP harus kurang dari total (sisanya piutang)');
        return;
      }
      if (_selectedCustomer == null) {
        TopToast.error(
          context,
          'Pilih pelanggan dulu untuk mencatat sisa piutang',
        );
        return;
      }
    } else if (_paymentMethod == 'Tunai') {
      final given = int.tryParse(_cashCtrl.text) ?? 0;
      if (given < _total) {
        TopToast.error(context, 'Jumlah dibayarkan kurang');
        return;
      }
    }

    // Validate stock before deducting (item manual — productId negatif —
    // dilewati; layanan isService — tidak dilacak stoknya, dilewati juga).
    final db = ref.read(databaseProvider);
    final productRepo = ProductRepository(db);
    for (final item in cart) {
      if (item.isManual) continue;
      if (item.isService) continue;
      final product = await productRepo.byId(item.productId);
      if (product == null || product.stock < item.qty) {
        final name = product?.name ?? item.name;
        if (mounted) {
          TopToast.error(
            context,
            'Stok "$name" tidak cukup (tersedia: ${product?.stock ?? 0})',
          );
        }
        return;
      }
    }

    setState(() => _loading = true);

    try {
      final transactionRepo = ref.read(transactionRepoProvider);
      final session = ref.read(employeeSessionProvider);
      final cashierName = session?.name;
      // Saat DP aktif, total = harga penuh; yang dibayar di kasir hanya DP.
      // Sisa otomatis dicatat sebagai piutang pelanggan (lihat di bawah).
      // Mode HUTANG: tidak ada pembayaran di kasir, seluruh total jadi piutang.
      final dp = _creditMode
          ? 0
          : (_paymentMethod == 'Tunai' && _dpEnabled ? _downPayment : 0);
      final isDownPayment = dp > 0;
      // cashGiven=0 saat HUTANG → transaksi tercatat tanpa pembayaran tunai.
      final cashGiven = _creditMode ? 0 : (int.tryParse(_cashCtrl.text));
      final cashReturn = _creditMode
          ? null
          : (cashGiven != null && cashGiven >= _total
                ? cashGiven - _total
                : null);
      // Cicilan (hanya saat DP aktif): jumlah bulan dari opsi terpilih.
      final months = _installmentEnabled && _installmentMonths != null
          ? _installmentMonths!
          : 0;
      final perMonth = months > 0 ? _installmentPerMonth : 0;

      // Wrap all DB writes (stock, transaction, loyalty, promo) in a single transaction.
      // If any step fails, it all rolls back — no partial state.
      int pointsEarned = 0;
      // v2.2.43 (F&B): bahan baku yang stoknya menipis setelah checkout —
      // ditampilkan sebagai PERINGATAN (transaksi tetap jalan).
      final materialWarnings = <String>[];
      final recipeRepo = NusaConfig.isFnbVariant
          ? RecipeRepository(db)
          : null;
      // v2.2.57: id transaksi dibawa keluar blok transaction — dipakai link
      // appointment → transaksi (atribusi omset/komisi Stylist).
      int bookingTxId = 0;
      await db.transaction(() async {
        // Deduct stock for each item (item manual tidak punya stok).
        // Stok selalu dalam satuan dasar → pakai qtyInBase (qty × qtyPerBase).
        // B10: LAYANAN (isService) tidak dilacak stoknya → skip decrement.
        for (final item in cart) {
          if (item.isManual) continue;
          if (item.isService) continue;
          await productRepo.adjustStock(item.productId, -item.qtyInBase);
          // Varian (v2.2.43): kurangi stok varian spesifik bila item memilih varian.
          if (item.variantName != null && item.variantName!.isNotEmpty) {
            await productRepo.adjustVariantStock(
                item.productId, item.variantName, -item.qtyInBase);
          }
          // F&B: produk ber-resep → kurangi stok bahan. Kurang = PERINGATAN saja.
          if (recipeRepo != null && item.productId >= 0) {
            materialWarnings.addAll(
              await recipeRepo.consumeRecipe(item.productId, item.qtyInBase),
            );
          }
        }

        // Save transaction
        // employeeId = logged-in employee; sessionId = active cashier shift
        // (so each cashier's dashboard shows only their own shift's sales).
        final activeShift = await CashierSessionRepository(db).getActive();
        final savedTxId = await transactionRepo.saveTransaction(
          items: cart,
          total: _total,
          discount: _totalDiscount,
          paymentMethod: _paymentMethod,
          cashGiven: isDownPayment ? dp : cashGiven,
          cashReturn: isDownPayment ? null : cashReturn,
          cashierName: cashierName,
          customerId: _selectedCustomer?.id,
          branchId: ref.read(activeBranchProvider)?.id,
          orderType: _orderType,
          tableId: _tableId,
          employeeId: session?.employeeId,
          sessionId: activeShift?.id,
          dpAmount: isDownPayment ? dp : null,
          installmentMonths: months > 0 ? months : null,
          installmentPerMonth: perMonth > 0 ? perMonth : null,
        );
        bookingTxId = savedTxId;

        // v2.2.57+131: announce transaction immediately so owner's device
        // knows to pull within ~1s instead of waiting for the 5-min
        // debounce upload cycle. Upload itself stays debounced (egress),
        // but the lightweight WS broadcast is near-zero cost.
        // v2.2.57+137: urutan PENTING — trigger SQLite sudah menulis outbox
        // saat saveTransaction; flush SEKARANG (bypass debounce 500ms)
        // supaya delta benar-benar SUDAH di server saat broadcast sampai ke
        // owner. Dulu broadcast jalan duluan → owner pull → delta belum ada →
        // dapat datanya belakangan lewat tick 20/30 dtk (kesan "tidak realtime").
        unawaited(_pushAndAnnounce());

        // v2.2.57+131: announce transaction via delta sync so other devices
        // can apply the row-level change without a full backup pull.
        // v2.2.57+137: shim pushDelta tidak lagi mengirim payload manual —
        // trigger SQLite sudah menulis baris lengkap (snapshot DB saat flush)
        // ke outbox; cukup minta flush sekarang (lihat _pushAndAnnounce).
        try {
          DeltaSyncService.I.pushDelta(
            table: 'transactions',
            recordId: savedTxId.toString(),
            operation: 'INSERT',
          );
        } catch (_) {}

        // ── HUTANG / DP: catat sisa sebagai hutang pelanggan (menu Piutang) ──
        // Total transaksi tetap utuh (laporan omzet benar); uang muka tercatat
        // di transaksi (cashGiven = dp), sisa tercatat di Piutang (menu Utang)
        // sampai pelanggan melunasi lewat menu tersebut.
        // Mode HUTANG penuh: seluruh total dicatat sebagai hutang.
        if ((isDownPayment || _creditMode) && _selectedCustomer != null) {
          final debtRepo = DebtRepository(db);
          final due = _total - (_creditMode ? 0 : dp);
          final desc = _creditMode
              ? 'Hutang transaksi INV $savedTxId (bayar di belakang)'
              : 'Sisa bayar transaksi INV $savedTxId (DP ${formatRupiah(dp)})'
                  '${months > 0 ? ', cicil $months× ${formatRupiah(perMonth)}/bulan' : ''}';
          final debtId = await debtRepo.addDebt(
            customerId: _selectedCustomer!.id,
            customerName: _selectedCustomer!.name,
            amount: due,
            description: desc,
            installmentMonths: months > 0 ? months : null,
            dueDate: _dueDate,
          );
          // Link transaksi → debt (status bayar di riwayat sinkron dengan
          // menu Piutang; void transaksi ikut menghapus piutang yatim).
          if (debtId > 0) {
            await (db.update(db.transactions)..where((t) => t.id.equals(savedTxId)))
                .write(TransactionsCompanion(debtId: Value(debtId)));
          }
        }

        // Update customer loyalty
        if (_selectedCustomer != null) {
          final pointConfig = await SettingsRepository(db).getPointConfig();
          final cust = await CustomerRepository(db).byId(_selectedCustomer!.id);
          final beforePoints = cust?.points ?? 0;
          await CustomerRepository(db).addSpent(
            _selectedCustomer!.id,
            _total,
            pointsPerRupiah: pointConfig['pointsPerRupiah']!,
            goldThreshold: pointConfig['goldThreshold']!,
            platinumThreshold: pointConfig['platinumThreshold']!,
            transactionId: savedTxId,
          );
          // Poin yang didapat transaksi ini: (total belanja / poin per rupiah).
          // Saldo poin dihitung kumulatif dari totalSpent, jadi hitung delta.
          final after = await CustomerRepository(
            db,
          ).byId(_selectedCustomer!.id);
          pointsEarned = ((after?.points ?? 0) - beforePoints).clamp(
            0,
            1 << 30,
          );
        }

        // Increment promo usage
        if (_appliedPromo != null) {
          await PromoRepository(db).incrementUsed(_appliedPromo!.id);
        }

        // Redeem loyalty points
        if (_selectedCustomer != null && _pointsUsed > 0) {
          await CustomerRepository(db).redeemPoints(
            _selectedCustomer!.id,
            _pointsUsed,
            transactionId: savedTxId,
          );
        }
      });

      // Clear cart
      // Capture total & discount before clearing — getters depend on cartProvider
      final savedTotal = _total;
      final savedDiscount = _totalDiscount;
      final savedOrderType = _orderType;
      final savedTableName = _tableName;

      // ── Laundry: auto-create LaundryOrder after successful transaction ──
      int? _laundryOrderId;
      if (NusaConfig.isLaundryVariant && cart.isNotEmpty) {
        try {
          final laundryRepo = LaundryOrderRepository(db);
          final itemsJson = jsonEncode(
            cart
                .map(
                  (c) => {
                    'name': c.name,
                    'qty': c.isPerKg ? 1 : c.qty,
                    'price': c.price,
                    if (c.originalPrice != null)
                      'originalPrice': c.originalPrice,
                    if (c.costPrice != null) 'costPrice': c.costPrice,
                    if (c.isPerKg) 'weightKg': c.weightKg,
                  },
                )
                .toList(),
          );
          _laundryOrderId = await laundryRepo.add(
            customerName: _selectedCustomer?.name ?? 'Umum',
            customerPhone: _selectedCustomer?.phone,
            itemsJson: itemsJson,
            total: savedTotal,
            notes: cart
                .where((c) => c.note != null && c.note!.isNotEmpty)
                .map((c) => '${c.name}: ${c.note}')
                .join('; '),
          );
        } catch (_) {}
      }

      // ── Salon: auto-create Appointment after successful transaction ──
      int? _bookingId;
      // v2.2.55: gate sama dengan tampil kartu booking — transaksi murni
      // barang tidak boleh membuat appointment saat kartu disembunyikan.
      if (NusaConfig.isSalonVariant &&
          cart.isNotEmpty &&
          _cartHasService) {
        try {
          final aptRepo = AppointmentRepository(db);
          final services = cart.map((c) => c.name).join(', ');
          _bookingId = await aptRepo.add(
            customerName: _selectedCustomer?.name ?? 'Umum',
            customerPhone: _selectedCustomer?.phone,
            service: services,
            stylist: _salonStylistCtrl.text.trim().isEmpty
                ? null
                : _salonStylistCtrl.text.trim(),
            stylistId: _selectedStylistId,
            // v2.2.57: link ke transaksi — dasar atribusi omset & komisi
            // Stylist di laporan Kinerja Stylist.
            transactionId: bookingTxId > 0 ? bookingTxId : null,
            date: _salonDate,
            timeSlot: _salonTimeCtrl.text,
            estimatedDuration: _salonDuration,
            notes: cart
                .where((c) => c.note != null && c.note!.isNotEmpty)
                .map((c) => '${c.name}: ${c.note}')
                .join('; '),
          );
        } catch (_) {}
      }

      // ── Fotocopy: auto-create PrintOrder for percetakan categories ──
      if (NusaConfig.isFotocopyVariant && cart.isNotEmpty) {
        try {
          final productRepo = ProductRepository(db);
          final printServiceTypes =
              await PrintServiceTypeRepository(db).getAll();
          String serviceType = printServiceTypes.isNotEmpty
              ? printServiceTypes.first.name
              : 'Print';
          final printItems = <String>[];
          int totalPages = 0;
          int totalCopies = 0;
          final String? estimateReady = null;
          // Ambil nama kategori percetakan dari config (semua kategori
          // fotocopy adalah kategori cetak). serviceType = NAMA KATEGORI
          // produk pertama (bukan selalu 'Fotocopy').
          for (final c in cart) {
            if (c.isManual) continue;
            final p = await productRepo.byId(c.productId);
            if (p != null && p.category != 'Lainnya') {
              if (printItems.isEmpty) serviceType = p.category;
              printItems.add('${c.qty}× ${c.name}');
              totalPages += c.qty;
              totalCopies += 1;
            }
          }
          if (printItems.isNotEmpty) {
            await PrintOrderRepository(db).add(
              customerName: _selectedCustomer?.name ?? 'Umum',
              customerPhone: _selectedCustomer?.phone,
              serviceType: serviceType,
              pages: totalPages > 0 ? totalPages : 0,
              copies: totalCopies > 0 ? totalCopies : 1,
              paperSize: 'A4',
              estimateReady: estimateReady,
              total: savedTotal,
              notes: printItems.join(', '),
            );
          }
        } catch (_) {}
      }

      ref.read(cartProvider.notifier).clear();

      // ── F&B: peringatan stok bahan menipis (transaksi tetap jalan) ──
      if (materialWarnings.isNotEmpty && mounted) {
        TopToast.warning(
          context,
          'Stok bahan menipis: ${materialWarnings.join(', ')}',
        );
      }

      if (!mounted) return;

      // Build receipt data
      final now = DateTime.now();
      final dateStr =
          '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year} '
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
      final invoice =
          'INV${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
          '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';

      // Show receipt as centered dialog (GAS thermal style)
      if (mounted) {
        SoundService.I.play(NusaSound.success);
        final autoPrint = await SecureStore.getAutoPrint();
        if (!mounted) return;
        await ReceiptSheet.show(
          context,
          sheet: ReceiptSheet.fromCart(
            cartItems: cart,
            total: savedTotal,
            discount: savedDiscount,
            paymentMethod: _paymentMethod,
            cashGiven: cashGiven,
            cashReturn: cashReturn,
            downPayment: isDownPayment ? dp : 0,
            // Struk menampilkan sisa hutang saat DP / mode HUTANG penuh.
            remainingDue: _creditMode
                ? savedTotal
                : (isDownPayment ? savedTotal - dp : 0),
            cashierName: cashierName,
            customerName: _selectedCustomer?.name,
            customerPhone: _selectedCustomer?.phone,
            invoice: invoice,
            dateStr: dateStr,
            pointsUsed: _pointsUsed,
            pointsEarned: pointsEarned,
            autoPrint: autoPrint && !_splitBill, // split bill prints separately
            orderType: savedOrderType,
            tableName: savedTableName,
            laundryOrderId: _laundryOrderId,
            salonBookingId: _bookingId,
          ),
          onDismiss: () async {
            // ── Split bill: print splits after receipt shown ──
            if (_splitBill) {
              final perPerson = (savedTotal / _splitCount).ceil();
              await _printSplitBills(_splitCount, perPerson, cart);
            }

            // ── FnB: complete open tab (if any) + manage table ──
            if (NusaConfig.isFnbVariant) {
              final payFirst = await SecureStore.getFnbPaymentFirst();
              if (_activeTabId != null) {
                // Complete tab; in Bayar Dulu mode don't free table yet
                _completeTab(db, freeTable: !payFirst);
              } else if (_tableId != null) {
                if (payFirst) {
                  // Bayar Dulu: mark table as Dipesan (occupied after payment)
                  DiningTableRepository(db).updateStatus(_tableId!, 'Dipesan');
                } else {
                  // Pesan Dulu: direct payment → free table immediately
                  DiningTableRepository(db).updateStatus(_tableId!, 'Kosong');
                }
              }
              // ── Kitchen print (fire-and-forget) ──
              _triggerKitchenPrint(cart, savedOrderType, savedTableName);
            }
            // Return to POS screen after receipt is dismissed
            if (mounted && widget.sessionId != null) {
              context.go('/kasir?sessionId=${widget.sessionId}');
            } else if (mounted) {
              context.go('/home');
            }
          },
        );
      } else {
        // Return to POS screen if not mounted
        if (widget.sessionId != null) {
          context.go('/kasir?sessionId=${widget.sessionId}');
        } else {
          context.go('/home');
        }
      }
    } catch (e) {
      SoundService.I.play(NusaSound.error);
      if (mounted) {
        TopToast.error(context, 'Gagal memproses pembayaran: $e');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(cartProvider);
    // Auto-apply promo otomatis saat keranjang berubah (tanpa timpa promo manual).
    ref.listen(cartProvider, (_, __) => _maybeAutoApplyPromo());
    final subtotal = _subtotal;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ScreenScaffold(
      'Pembayaran',
      ListView(
        padding: EdgeInsets.all(16),
        children: [
          // ── Customer Card ──
          _buildCustomerCard(isDark),
          SizedBox(height: 14),

          // ── Salon Booking Card (salon variant with jasa items) ──
          // v2.2.55: sembunyikan bila keranjang murni barang (tanpa layanan).
          if (NusaConfig.isSalonVariant &&
              _cartHasService &&
              _subtotal > 0) ...[
            _buildSalonBookingCard(isDark),
            SizedBox(height: 14),
          ],

          // ── Ringkasan Belanja Card ──
          _buildSummaryCard(isDark, subtotal),
          SizedBox(height: 14),

          // ── Split Bill Toggle (above payment method) ──
          _buildSplitToggle(isDark),
          SizedBox(height: 14),

          // ── Metode Pembayaran Card ──
          _buildPaymentMethodCard(isDark),
          SizedBox(height: 14),

          // ── Detail Pembayaran Card ──
          if (_paymentMethod == 'Tunai') _buildTunaiCard(isDark),
          if (_paymentMethod == 'QRIS') _buildQrisCard(isDark),
          if (_paymentMethod == 'Transfer') _buildTransferCard(isDark),

          SizedBox(height: 24),

          // ── Konfirmasi Button ──
          Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(vertical: 16, horizontal: 20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [NusaConfig.activePrimary, NusaConfig.activeDark],
              ),
              boxShadow: [
                BoxShadow(
                  color: NusaConfig.activePrimary.withValues(alpha: 0.3),
                  blurRadius: 12,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: GestureDetector(
              onTap: _loading ? null : _confirmPayment,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_loading)
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  else ...[
                    Icon(
                      Icons.check_circle_outline,
                      color: Colors.white,
                      size: 22,
                    ),
                    SizedBox(width: 10),
                    Text(
                      'Konfirmasi Pembayaran',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          SizedBox(height: 10),
          Center(
            child: TextButton(
              onPressed: _loading ? null : () => context.pop(),
              child: Text(
                '← Kembali ke Kasir',
                style: TextStyle(
                  color: isDark
                      ? NusaConfig.darkTextSecondary
                      : NusaConfig.textSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Salon Booking Card ─────────────────────────────────────────────

  Widget _buildSalonBookingCard(bool isDark) {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: _sectionCard(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: NusaConfig.info.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.event_available,
                  color: NusaConfig.info,
                  size: 18,
                ),
              ),
              SizedBox(width: 10),
              Text(
                'Booking',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              Spacer(),
              Text(
                '#BKG-...',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark
                      ? NusaConfig.darkTextTertiary
                      : NusaConfig.textTertiary,
                ),
              ),
            ],
          ),
          SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: _salonDate,
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (d != null) setState(() => _salonDate = d);
                  },
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    decoration: BoxDecoration(
                      color: isDark
                          ? NusaConfig.darkInputFill
                          : NusaConfig.inputFill,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isDark
                            ? NusaConfig.darkBorder
                            : NusaConfig.inputBorder,
                      ),
                    ),
                    child: Text(
                      DateFormat('dd MMM yyyy').format(_salonDate),
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary,
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(width: 8),
              SizedBox(
                width: 72,
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                  decoration: BoxDecoration(
                    color: isDark
                        ? NusaConfig.darkInputFill
                        : NusaConfig.inputFill,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isDark
                          ? NusaConfig.darkBorder
                          : NusaConfig.inputBorder,
                    ),
                  ),
                  child: TextField(
                    controller: _salonTimeCtrl,
                    keyboardType: TextInputType.datetime,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark
                          ? NusaConfig.darkTextPrimary
                          : NusaConfig.textPrimary,
                    ),
                    decoration: const InputDecoration.collapsed(
                      hintText: 'HH:mm',
                    ),
                  ),
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: isDark
                        ? NusaConfig.darkInputFill
                        : NusaConfig.inputFill,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isDark
                          ? NusaConfig.darkBorder
                          : NusaConfig.inputBorder,
                    ),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      value: _salonDuration,
                      isExpanded: true,
                      icon: Icon(
                        Icons.arrow_drop_down,
                        size: 18,
                        color: isDark
                            ? NusaConfig.darkTextSecondary
                            : NusaConfig.textSecondary,
                      ),
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary,
                      ),
                      items: const [
                        DropdownMenuItem(value: 30, child: Text('30mnt')),
                        DropdownMenuItem(value: 45, child: Text('45mnt')),
                        DropdownMenuItem(value: 60, child: Text('60mnt')),
                        DropdownMenuItem(value: 90, child: Text('90mnt')),
                        DropdownMenuItem(value: 120, child: Text('2jam')),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _salonDuration = v);
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 10),
          // v2.2.54: stylist = dropdown karyawan Staf Layanan (bukan teks
          // bebas) — pilihan tersimpan sebagai stylist_id di appointment.
          Container(
            padding: EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: isDark
                  ? NusaConfig.darkInputFill
                  : NusaConfig.inputFill,
              borderRadius: BorderRadius.circular(10),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: _selectedStylistId,
                isExpanded: true,
                hint: Text(
                  'Stylist (opsional)',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? NusaConfig.darkTextTertiary
                        : NusaConfig.textTertiary,
                  ),
                ),
                icon: Icon(
                  Icons.arrow_drop_down,
                  size: 18,
                  color: isDark
                      ? NusaConfig.darkTextSecondary
                      : NusaConfig.textSecondary,
                ),
                style: TextStyle(
                  fontSize: 12,
                  color: isDark
                      ? NusaConfig.darkTextPrimary
                      : NusaConfig.textPrimary,
                ),
                items: [
                  const DropdownMenuItem<int>(
                    value: null,
                    child: Text('— Tanpa stylist —'),
                  ),
                  ..._salonStaff.map(
                    (e) => DropdownMenuItem<int>(
                      value: e.id,
                      child: Text('${e.name} · ${e.role}'),
                    ),
                  ),
                ],
                onChanged: (v) {
                  setState(() => _selectedStylistId = v);
                  final emp = _salonStaff
                      .where((e) => e.id == v)
                      .firstOrNull;
                  _salonStylistCtrl.text = emp?.name ?? '';
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Card Builders ────────────────────────────────────────────────

  Widget _buildSplitToggle(bool isDark) {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: _sectionCard(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row with toggle
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: NusaConfig.activePrimary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.people_outline,
                  color: NusaConfig.activePrimary,
                  size: 18,
                ),
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Split Bill',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
              Switch(
                value: _splitBill,
                onChanged: (v) => setState(() => _splitBill = v),
                activeColor: NusaConfig.activePrimary,
              ),
            ],
          ),
          // Split count input (visible when ON)
          if (_splitBill) ...[
            SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  onPressed: _splitCount > 2
                      ? () => setState(() => _splitCount--)
                      : null,
                  icon: Icon(
                    Icons.remove_circle_outline,
                    color: NusaConfig.activePrimary,
                  ),
                ),
                SizedBox(width: 16),
                Text(
                  '$_splitCount Orang',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: isDark
                        ? NusaConfig.darkTextPrimary
                        : NusaConfig.textPrimary,
                  ),
                ),
                SizedBox(width: 16),
                IconButton(
                  onPressed: _splitCount < 10
                      ? () => setState(() => _splitCount++)
                      : null,
                  icon: Icon(
                    Icons.add_circle_outline,
                    color: NusaConfig.activePrimary,
                  ),
                ),
              ],
            ),
            SizedBox(height: 6),
            Center(
              child: Text(
                'Rp ${formatRupiah((_total / _splitCount).ceil())} / orang',
                style: TextStyle(
                  fontSize: 14,
                  color: NusaConfig.activePrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            SizedBox(height: 4),
            Center(
              child: Text(
                'Cetak $_splitCount struk setelah konfirmasi',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark
                      ? NusaConfig.darkTextTertiary
                      : NusaConfig.textTertiary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCustomerCard(bool isDark) {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: _sectionCard(isDark),
      child: InkWell(
        onTap: _pickCustomer,
        borderRadius: BorderRadius.circular(12),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: NusaConfig.activePrimary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.person_outline,
                color: NusaConfig.activePrimary,
                size: 22,
              ),
            ),
            SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _selectedCustomer != null
                        ? _selectedCustomer!.name
                        : 'Pilih Pelanggan',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? NusaConfig.darkTextPrimary
                          : NusaConfig.textPrimary,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    _selectedCustomer != null
                        ? 'Level: ${_selectedCustomer!.level} • Rp ${formatRupiah(_selectedCustomer!.totalSpent)}'
                        : 'Opsional — dapatkan diskon member',
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
            if (_selectedCustomer != null)
              GestureDetector(
                onTap: () => setState(() => _selectedCustomer = null),
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.close,
                    size: 16,
                    color: isDark
                        ? NusaConfig.darkTextSecondary
                        : NusaConfig.textSecondary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard(bool isDark, int subtotal) {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: _sectionCard(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: NusaConfig.success.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.receipt_long_outlined,
                  color: NusaConfig.success,
                  size: 18,
                ),
              ),
              SizedBox(width: 10),
              Text(
                'Ringkasan Belanja',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          SizedBox(height: 14),

          _summaryRow('Subtotal', formatRupiah(subtotal), isDark),
          if (_selectedCustomer != null) ...[
            SizedBox(height: 6),
            _summaryRow(
              'Diskon ${_selectedCustomer!.level}',
              '-${formatRupiah(_tierDiscount)}',
              isDark,
              isDiscount: true,
            ),
          ],
          if (_appliedPromo != null) ...[
            SizedBox(height: 6),
            _summaryRow(
              'Promo ${_appliedPromo!.name}',
              '-${formatRupiah(_promoDiscount)}',
              isDark,
              isDiscount: true,
            ),
            if (_promoDiscount == 0 && _appliedPromo!.minBelanja > 0) ...[
              SizedBox(height: 4),
              Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 13,
                    color: Colors.amber.shade700,
                  ),
                  SizedBox(width: 4),
                  Text(
                    'Min. belanja ${formatRupiah(_appliedPromo!.minBelanja)} belum terpenuhi',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.amber.shade700,
                    ),
                  ),
                ],
              ),
            ],
          ],
          if (_pointsUsed > 0) ...[
            SizedBox(height: 6),
            _summaryRow(
              'Tukar Poin',
              '-${formatRupiah(_pointsUsed)}',
              isDark,
              isDiscount: true,
            ),
          ],

          // ── Disc / Promo / Points Row ──
          SizedBox(height: 12),
          Row(
            children: [
              // Promo code
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: 42,
                  child: TextField(
                    controller: _promoCtrl,
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark
                          ? NusaConfig.darkTextPrimary
                          : NusaConfig.textPrimary,
                    ),
                    decoration: InputDecoration(
                      hintText: _appliedPromo != null
                          ? _appliedPromo!.name
                          : 'Kode promo...',
                      hintStyle: TextStyle(
                        fontSize: 12,
                        color: isDark
                            ? NusaConfig.darkTextTertiary
                            : NusaConfig.textTertiary,
                      ),
                      prefixIcon: Icon(
                        Icons.local_offer_outlined,
                        size: 16,
                        color: isDark
                            ? NusaConfig.darkTextSecondary
                            : NusaConfig.textSecondary,
                      ),
                      filled: true,
                      fillColor: isDark
                          ? NusaConfig.darkSurface2
                          : Color(0xFFF9FAFB),
                      contentPadding: EdgeInsets.symmetric(vertical: 0),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(width: 8),
              if (_appliedPromo != null)
                SizedBox(
                  height: 42,
                  child: ElevatedButton(
                    onPressed: _clearPromo,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Color(0xFFEF4444),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: EdgeInsets.symmetric(horizontal: 14),
                    ),
                    child: Text('Hapus', style: TextStyle(fontSize: 12)),
                  ),
                )
              else
                SizedBox(
                  height: 42,
                  child: ElevatedButton(
                    onPressed: _applyPromo,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: NusaConfig.activePrimary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: EdgeInsets.symmetric(horizontal: 14),
                    ),
                    child: Text(
                      'Pakai',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),

          // ── Pilih Diskon (mode 'bebas') ──
          // Sembunyikan tombol kalau tidak ada promo mode 'bebas' yang aktif —
          // hindari tombol yang selalu muncul tapi daftarnya kosong.
          if (_hasBebasPromos || _appliedPromo?.mode == 'bebas') ...[
            SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _promoLoading ? null : _showPickDiscountSheet,
                    icon: _promoLoading
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(Icons.discount_outlined, size: 16),
                    label: Text(
                      _appliedPromo != null
                          ? 'Ganti diskon dari daftar'
                          : 'Pilih diskon dari daftar',
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: NusaConfig.activePrimary,
                      side: BorderSide(
                        color: NusaConfig.activePrimary.withValues(alpha: 0.5),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: EdgeInsets.symmetric(vertical: 10),
                      textStyle: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],

          // Diskon manual
          SizedBox(height: 10),
          Row(
            children: [
              Icon(
                Icons.discount_outlined,
                size: 16,
                color: isDark
                    ? NusaConfig.darkTextTertiary
                    : NusaConfig.textTertiary,
              ),
              SizedBox(width: 8),
              SizedBox(
                width: 100,
                child: TextField(
                  controller: _discountCtrl,
                  keyboardType: TextInputType.number,
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark
                        ? NusaConfig.darkTextPrimary
                        : NusaConfig.textPrimary,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Diskon Rp',
                    hintStyle: TextStyle(
                      fontSize: 12,
                      color: isDark
                          ? NusaConfig.darkTextTertiary
                          : NusaConfig.textTertiary,
                    ),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    filled: true,
                    fillColor: isDark
                        ? NusaConfig.darkSurface2
                        : Color(0xFFF9FAFB),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              Spacer(),
              // Poin tukar
              if (_selectedCustomer != null &&
                  _selectedCustomer!.points > 0) ...[
                _buildPointsBadge(isDark),
                SizedBox(width: 6),
                Container(
                  height: 32,
                  child: ElevatedButton(
                    onPressed: _pointsUsed > 0
                        ? () => setState(() => _pointsUsed = 0)
                        : _showRedeemPoints,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _pointsUsed > 0
                          ? Color(0xFFEF4444)
                          : Colors.amber,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(horizontal: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      elevation: 0,
                      minimumSize: Size.zero,
                    ),
                    child: Text(
                      _pointsUsed > 0 ? 'Batal' : 'Tukar',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),

          SizedBox(height: 12),
          Divider(color: Colors.grey.withValues(alpha: 0.2)),
          SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'TOTAL',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: isDark
                      ? NusaConfig.darkTextSecondary
                      : NusaConfig.textSecondary,
                  letterSpacing: 1,
                ),
              ),
              Text(
                formatRupiah(_total),
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: NusaConfig.activePrimary,
                  letterSpacing: -0.5,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _summaryRow(
    String label,
    String value,
    bool isDark, {
    bool isDiscount = false,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: isDark
                ? NusaConfig.darkTextSecondary
                : NusaConfig.textSecondary,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isDiscount
                ? Color(0xFF10B981)
                : (isDark
                      ? NusaConfig.darkTextPrimary
                      : NusaConfig.textPrimary),
          ),
        ),
      ],
    );
  }

  Widget _buildPaymentMethodCard(bool isDark) {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: _sectionCard(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: NusaConfig.accentPurple.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.payment_outlined,
                  color: NusaConfig.accentPurple,
                  size: 18,
                ),
              ),
              SizedBox(width: 10),
              Text(
                'Metode Pembayaran',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          SizedBox(height: 14),
          // 4 metode → Expanded merata (bagi rata kanan-kiri);
          // >4 metode → scroll horizontal (aman untuk penambahan).
          if (_paymentMethods().length <= 4)
            Row(
              children: _paymentMethods().asMap().entries.map((e) {
                final m = e.value;
                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      right: e.key == _paymentMethods().length - 1 ? 0 : 10,
                    ),
                    child: _payCard(m.$1, m.$2, isDark, expand: true),
                  ),
                );
              }).toList(),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final m in _paymentMethods()) ...[
                    _payCard(m.$1, m.$2, isDark),
                    const SizedBox(width: 10),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Daftar metode pembayaran aktif (3 item — EDC "Segera Hadir").
  List<(String, IconData)> _paymentMethods() => [
        ('Tunai', Icons.money),
        ('QRIS', Icons.qr_code_2),
        ('Transfer', Icons.account_balance),
      ];

  Widget _payCard(String method, IconData icon, bool isDark,
      {bool expand = false}) {
    final active = _paymentMethod == method;
    return GestureDetector(
      onTap: () => setState(() => _paymentMethod = method),
      child: AnimatedContainer(
        duration: Duration(milliseconds: 200),
        // Lebar tetap 108 — dipakai saat >4 metode (scroll horizontal).
        // Saat expand (≤4 metode), lebar penuh dari Expanded parent
        // supaya kartu bagi rata kanan-kiri.
        width: expand ? null : 108,
        padding: EdgeInsets.symmetric(vertical: 16, horizontal: expand ? 4 : 0),
        decoration: BoxDecoration(
          color: active
              ? NusaConfig.activeSoft
              : (isDark ? NusaConfig.darkSurface2 : Color(0xFFF9FAFB)),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active
                ? NusaConfig.activePrimary
                : NusaConfig.dividerColor,
            width: active ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              size: 28,
              color: active
                  ? NusaConfig.activePrimary
                  : isDark
                  ? NusaConfig.darkTextTertiary
                  : NusaConfig.textTertiary,
            ),
            SizedBox(height: 6),
            Text(
              method,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: expand ? 11 : 13,
                fontWeight: FontWeight.w700,
                color: active
                    ? NusaConfig.activePrimary
                    : isDark
                    ? NusaConfig.darkTextSecondary
                    : NusaConfig.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTunaiCard(bool isDark) {
    denoms = [100000, 50000, 20000, 10000, 5000, 2000, 1000];
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? NusaConfig.darkSurface : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark ? NusaConfig.darkBorder : Color(0xFFF1F5F9),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: Offset(0, 2),
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
                  color: NusaConfig.accentGreen.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.money,
                  color: NusaConfig.accentGreen,
                  size: 18,
                ),
              ),
              SizedBox(width: 10),
              Text(
                'Pembayaran Tunai',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          SizedBox(height: 14),
          TextField(
            controller: _cashCtrl,
            keyboardType: TextInputType.number,
            autofocus: true,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: isDark
                  ? NusaConfig.darkTextPrimary
                  : NusaConfig.textPrimary,
            ),
            decoration: InputDecoration(
              hintText: 'Rp 0',
              hintStyle: TextStyle(
                color: isDark
                    ? NusaConfig.darkTextTertiary
                    : NusaConfig.textTertiary,
                fontSize: 20,
              ),
              filled: true,
              fillColor: isDark ? NusaConfig.darkSurface2 : Color(0xFFF9FAFB),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 16,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                  color: NusaConfig.activePrimary,
                  width: 2,
                ),
              ),
            ),
            onChanged: (v) => setState(() => _cashGiven = int.tryParse(v)),
          ),
          SizedBox(height: 10),
          // Quick-action denomination chips + Uang Pas + custom nominal
          _buildDenomChips(isDark),
          if (_kembalian != null) ...[
            SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Color(0xFFECFDF5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Color(0xFFA7F3D0)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Kembalian',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF065F46),
                    ),
                  ),
                  Text(
                    formatRupiah(_kembalian!),
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF059669),
                    ),
                  ),
                ],
              ),
            ),
          ],
          SizedBox(height: 14),
          Divider(color: Colors.grey.withValues(alpha: 0.15)),
          SizedBox(height: 4),
          _buildDpSection(isDark),
        ],
      ),
    );
  }

  /// Bagian Uang Muka (DP) + HUTANG — bayar sebagian / bayar belakangan.
  /// Sisa atau seluruh total dicatat sebagai piutang (menu Utang).
  /// Tersedia untuk semua varian (lazim di servis/bengkel/salon).
  /// Muat opsi cicilan dari DB (default 1/2/3/6/12 bulan, CRUD owner).
  Future<void> _loadInstallmentOptions() async {
    try {
      final db = ref.read(databaseProvider);
      final opts = await InstallmentOptionRepository(db).getAll();
      if (mounted) {
        setState(() {
          _installmentOptions = opts;
          if (opts.isNotEmpty && _installmentMonths == null) {
            _installmentMonths = opts.first.months;
          }
        });
      }
    } catch (_) {}
  }

  /// Kartu toggle mode pembayaran tunda: DP (bayar sebagian) & Hutang
  /// (bayar 0 sekarang). Dua kartu FULL-WIDTH tersusun ATAS-BAWAH dengan gaya
  /// identik (kuning soft) — v2.2.36: sebelumnya sejajar kiri-kanan (Row 2
  /// Expanded) → judul panjang meluber di HP sempit + terlihat berantakan.
  Widget _modeToggleBlock({
    required String title,
    required String subtitle,
    required bool value,
    required bool isDark,
    required VoidCallback onChanged,
  }) {
    return GestureDetector(
      onTap: onChanged,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: value
              ? (isDark ? NusaConfig.darkSurface2 : const Color(0xFFFEF3C7))
              : (isDark ? NusaConfig.darkSurface2 : const Color(0xFFFEFCE8)),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: value
                ? const Color(0xFFF59E0B).withValues(alpha: 0.6)
                : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: isDark
                          ? NusaConfig.darkTextPrimary
                          : NusaConfig.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.3,
                      color: isDark
                          ? NusaConfig.darkTextTertiary
                          : NusaConfig.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            Transform.scale(
              scale: 0.85,
              child: Switch(
                value: value,
                activeThumbColor: NusaConfig.activePrimary,
                onChanged: (_) => onChanged(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Bagian Uang Muka (DP) + HUTANG — bayar sebagian / bayar belakangan.
  /// Sisa atau seluruh total dicatat sebagai piutang (menu Utang).
  /// Tersedia untuk semua varian (lazim di servis/bengkel/salon).
  /// Sinkronkan default jatuh tempo saat mode DP/Hutang berubah.
  void _ensureDueDate() {
    if (_dueDate == null) {
      _dueDate = DateTime.now().add(const Duration(days: 7));
    }
  }

  Widget _buildDpSection(bool isDark) {
    final creditActive = _creditMode;
    final dpActive = _dpEnabled && !creditActive;
    // Nilai nominal DP yang sedang diketik (Rp).
    final dpNominal = int.tryParse(_dpCtrl.text) ?? 0;
    // % dari total yang diwakili nominal tsb (mode Nominal, tampil kecil).
    final dpPctOfTotal =
        _total > 0 && dpNominal > 0 ? (dpNominal * 100 / _total).ceil() : 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Dua kartu ATAS-BAWAH: DP (atas) & Hutang (bawah) ──
        // v2.2.36: full-width, gaya kuning soft identik (sebelumnya sejajar
        // kiri-kanan → meluber di HP sempit + terlihat tidak konsisten).
        _modeToggleBlock(
          title: 'Uang Muka (DP)',
          subtitle: 'Bayar sebagian, sisa dicatat hutang',
          value: dpActive,
          isDark: isDark,
          onChanged: () => setState(() {
            if (creditActive) {
              _creditMode = false;
              _dpEnabled = true;
            } else {
              _dpEnabled = !_dpEnabled;
              if (_dpEnabled) _ensureDueDate();
              if (!_dpEnabled) _dpCtrl.clear();
            }
          }),
        ),
        const SizedBox(height: 8),
        _modeToggleBlock(
          title: 'Hutang (bayar belakangan)',
          subtitle: 'Bayar 0 sekarang — total jadi hutang',
          value: creditActive,
          isDark: isDark,
          onChanged: () => setState(() {
            _creditMode = !creditActive;
            if (_creditMode) {
              _dpEnabled = false;
              _dpCtrl.clear();
              _ensureDueDate();
            }
          }),
        ),
        // ── Detail: mode DP aktif ──
        if (dpActive) ...[
          const SizedBox(height: 10),
          // Mode DP: Nominal / Persen
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: isDark ? NusaConfig.darkSurface2 : const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                _dpModeChip('Nominal', !_dpIsPercent, isDark, () {
                  setState(() => _dpIsPercent = false);
                }),
                _dpModeChip('Persen (%)', _dpIsPercent, isDark, () {
                  setState(() => _dpIsPercent = true);
                }),
              ],
            ),
          ),
          const SizedBox(height: 10),
          if (!_dpIsPercent) ...[
            // ── Nominal: input BESAR, persen kecil hasil hitung ──
            TextField(
              controller: _dpCtrl,
              keyboardType: TextInputType.number,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: isDark
                    ? NusaConfig.darkTextPrimary
                    : NusaConfig.textPrimary,
              ),
              decoration: InputDecoration(
                hintText: 'Rp 0',
                hintStyle: TextStyle(
                  fontSize: 22,
                  color: isDark
                      ? NusaConfig.darkTextTertiary
                      : NusaConfig.textTertiary,
                ),
                filled: true,
                fillColor:
                    isDark ? NusaConfig.darkSurface2 : const Color(0xFFF9FAFB),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(
                    color: NusaConfig.activePrimary,
                    width: 2,
                  ),
                ),
              ),
            ),
            if (dpNominal > 0) ...[
              const SizedBox(height: 6),
              Text(
                '= $dpPctOfTotal% dari total',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isDark
                      ? NusaConfig.darkTextSecondary
                      : NusaConfig.textSecondary,
                ),
              ),
            ],
          ] else ...[
            // ── Persen: input KECIL, nominal besar hasil hitung ──
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _dpPercentCtrl,
                    keyboardType: TextInputType.number,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: isDark
                          ? NusaConfig.darkTextPrimary
                          : NusaConfig.textPrimary,
                    ),
                    decoration: InputDecoration(
                      hintText: 'cth: 20',
                      hintStyle: TextStyle(
                        fontSize: 18,
                        color: isDark
                            ? NusaConfig.darkTextTertiary
                            : NusaConfig.textTertiary,
                      ),
                      filled: true,
                      fillColor: isDark
                          ? NusaConfig.darkSurface2
                          : const Color(0xFFF9FAFB),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: NusaConfig.activePrimary,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: NusaConfig.activeSoft,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    _downPayment > 0 ? '= ${formatRupiah(_downPayment)}' : '= Rp 0',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: NusaConfig.activePrimary,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
        // ── Ringkasan + Cicilan + Jatuh Tempo (tampil saat DP/Hutang aktif) ──
        if (dpActive || creditActive) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color:
                  isDark ? NusaConfig.darkSurface2 : const Color(0xFFFEFCE8),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFFF59E0B).withValues(alpha: 0.3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _dpRow(
                  'Uang muka (dibayar)',
                  formatRupiah(creditActive ? 0 : _downPayment),
                  isDark,
                ),
                SizedBox(height: 4),
                _dpRow(
                  creditActive ? 'Total jadi hutang' : 'Sisa piutang',
                  formatRupiah(_remainingDue),
                  isDark,
                ),
                if (_installmentEnabled && _installmentMonths != null) ...[
                  SizedBox(height: 4),
                  _dpRow(
                    'Cicilan ${_installmentMonths}×',
                    '${formatRupiah(_installmentPerMonth)}/bulan',
                    isDark,
                  ),
                ],
                SizedBox(height: 6),
                Text(
                  'Pelanggan wajib dipilih — sisa otomatis dicatat di menu Utang.',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark
                        ? NusaConfig.darkTextTertiary
                        : const Color(0xFF854D0E),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // ── Sub-toggle CICILAN (opsional) ──
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Cicilan',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Sisa dibagi rata per bulan',
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
              Switch(
                value: _installmentEnabled,
                activeThumbColor: NusaConfig.activePrimary,
                onChanged: (v) => setState(() {
                  _installmentEnabled = v;
                  if (v && _installmentMonths == null) {
                    _installmentMonths = _installmentOptions.isNotEmpty
                        ? _installmentOptions.first.months
                        : 1;
                  }
                }),
              ),
            ],
          ),
          if (_installmentEnabled) ...[
            SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color:
                    isDark ? NusaConfig.darkSurface2 : const Color(0xFFF9FAFB),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isDark
                      ? NusaConfig.darkBorder
                      : NusaConfig.borderColor,
                ),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: _installmentMonths,
                  isExpanded: true,
                  hint: const Text('Pilih lama cicilan'),
                  items: _installmentOptions
                      .map((o) => DropdownMenuItem(
                            value: o.months,
                            child: Text(
                              o.label?.isNotEmpty == true
                                  ? o.label!
                                  : '${o.months}× bulanan',
                              style: const TextStyle(fontSize: 14),
                            ),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() => _installmentMonths = v),
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          // ── Jatuh Tempo (date picker, default +7 hari) ──
          _buildDueDateField(isDark),
        ],
      ],
    );
  }

  /// Field Jatuh Tempo — date picker (default +7 hari). Tampil selama
  /// mode DP/Hutang aktif, dengan atau tanpa cicilan.
  Widget _buildDueDateField(bool isDark) {
    return GestureDetector(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          useRootNavigator: true,
          initialDate: _dueDate ?? DateTime.now().add(const Duration(days: 7)),
          firstDate: DateTime.now(),
          lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
          helpText: 'Jatuh Tempo Piutang',
          cancelText: 'BATAL',
          confirmText: 'PILIH',
        );
        if (picked != null) {
          if (!mounted) return;
          setState(() => _dueDate = picked);
        }
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkInputFill : NusaConfig.inputFill,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isDark ? NusaConfig.darkInputBorder : NusaConfig.inputBorder,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.event_outlined,
              size: 18,
              color: isDark
                  ? NusaConfig.darkTextSecondary
                  : NusaConfig.textSecondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Jatuh Tempo',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? NusaConfig.darkTextSecondary
                          : NusaConfig.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _dueDate != null
                        ? DateFormat('dd MMM yyyy', 'id').format(_dueDate!)
                        : 'Pilih tanggal (default +7 hari)',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: isDark
                          ? NusaConfig.darkTextPrimary
                          : NusaConfig.textPrimary,
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

  Widget _dpRow(String label, String value, bool isDark) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: isDark
                ? NusaConfig.darkTextSecondary
                : const Color(0xFF854D0E),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: isDark
                ? NusaConfig.darkTextPrimary
                : const Color(0xFF854D0E),
          ),
        ),
      ],
    );
  }

  /// Chip pemilih mode DP (Nominal / Persen) — pola UI konsisten
  /// dengan chips yang sudah ada di layar ini.
  Widget _dpModeChip(
    String label,
    bool active,
    bool isDark,
    VoidCallback onTap,
  ) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: active
                ? NusaConfig.activePrimary
                : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: active
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

  /// EDC / Kartu debit-kredit: pembayaran lewat mesin EDC.
  /// Dianggap lunas (total) — tidak ada input nominal, hanya info.
  Widget _buildEdcCard(bool isDark) {
    return Container(
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? NusaConfig.darkSurface : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark ? NusaConfig.darkBorder : Color(0xFFF1F5F9),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Color(0xFF0D9488).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.credit_card, size: 26, color: Color(0xFF0D9488)),
          ),
          SizedBox(height: 12),
          Text(
            'Bayar dengan mesin EDC',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: isDark
                  ? NusaConfig.darkTextPrimary
                  : NusaConfig.textPrimary,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'Total ${formatRupiah(_total)}',
            style: TextStyle(
              fontSize: 13,
              color: isDark
                  ? NusaConfig.darkTextSecondary
                  : NusaConfig.textSecondary,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'Swipe / tap kartu di mesin, lalu konfirmasi.',
            style: TextStyle(
              fontSize: 12,
              color: isDark
                  ? NusaConfig.darkTextTertiary
                  : NusaConfig.textTertiary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQrisCard(bool isDark) {
    // Check if uploaded QRIS image exists
    final hasQrisImage =
        _qrisImagePath != null &&
        _qrisImagePath!.isNotEmpty &&
        File(_qrisImagePath!).existsSync();
    final hasQrisString = _qrisString != null && _qrisString!.isNotEmpty;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(24),
      decoration: _sectionCard(isDark),
      child: Column(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: Color(0xFF6366F1).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.qr_code_2, color: Color(0xFF6366F1), size: 18),
          ),
          SizedBox(height: 14),
          if (hasQrisImage) ...[
            // ── Uploaded QRIS photo (priority 1) ──
            Container(
              padding: EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: NusaConfig.dividerColor),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  File(_qrisImagePath!),
                  width: 200,
                  height: 200,
                  fit: BoxFit.contain,
                  cacheWidth: 400,
                ),
              ),
            ),
            SizedBox(height: 12),
            Text(
              'Scan QRIS untuk membayar',
              style: TextStyle(
                fontSize: 13,
                color: isDark
                    ? NusaConfig.darkTextSecondary
                    : NusaConfig.textSecondary,
              ),
            ),
          ] else if (hasQrisString) ...[
            // ── Generated QR code from text (priority 2) ──
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: NusaConfig.dividerColor),
              ),
              child: QrImageView(
                data: _qrisString!,
                version: QrVersions.auto,
                size: 180,
              ),
            ),
            SizedBox(height: 12),
            Text(
              'Scan QRIS untuk membayar',
              style: TextStyle(
                fontSize: 13,
                color: isDark
                    ? NusaConfig.darkTextSecondary
                    : NusaConfig.textSecondary,
              ),
            ),
          ] else ...[
            // ── No QRIS configured ──
            Icon(
              Icons.qr_code,
              size: 64,
              color: isDark ? NusaConfig.darkTextSecondary : Colors.grey,
            ),
            SizedBox(height: 8),
            Text(
              'Set QRIS di Pengaturan',
              style: TextStyle(
                color: isDark ? NusaConfig.darkTextSecondary : Colors.grey,
                fontSize: 15,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTransferCard(bool isDark) {
    final bankName = _bankName ?? '';
    final bankAccount = _bankAccount ?? '';
    final bankHolder = _bankHolder ?? '';
    final hasBankInfo = bankName.isNotEmpty || bankAccount.isNotEmpty;
    return Container(
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? NusaConfig.darkSurface : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark ? NusaConfig.darkBorder : Color(0xFFF1F5F9),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Color(0xFF6366F1).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              Icons.account_balance,
              size: 26,
              color: Color(0xFF6366F1),
            ),
          ),
          SizedBox(height: 12),
          if (hasBankInfo) ...[
            Text(
              'Transfer ke rekening',
              style: TextStyle(
                fontSize: 13,
                color: isDark
                    ? NusaConfig.darkTextSecondary
                    : NusaConfig.textSecondary,
              ),
            ),
            SizedBox(height: 6),
            Container(
              padding: EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isDark ? NusaConfig.darkSurface2 : Color(0xFFF9FAFB),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  if (bankName.isNotEmpty)
                    Text(
                      bankName,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary,
                      ),
                    ),
                  if (bankAccount.isNotEmpty) ...[
                    SizedBox(height: 2),
                    Text(
                      bankAccount,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'monospace',
                        letterSpacing: 1,
                        color: isDark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary,
                      ),
                    ),
                  ],
                  if (bankHolder.isNotEmpty) ...[
                    SizedBox(height: 4),
                    Text(
                      'a.n. $bankHolder',
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark
                            ? NusaConfig.darkTextSecondary
                            : NusaConfig.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ] else ...[
            Icon(
              Icons.account_balance_wallet_outlined,
              size: 48,
              color: isDark ? NusaConfig.darkTextSecondary : Colors.grey,
            ),
            SizedBox(height: 8),
            Text(
              'Atur rekening di Pengaturan',
              style: TextStyle(
                color: isDark ? NusaConfig.darkTextSecondary : Colors.grey,
                fontSize: 15,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPointsBadge(bool isDark) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.stars_rounded, size: 14, color: Colors.amber),
          SizedBox(width: 4),
          if (_pointsUsed > 0)
            Text(
              '${_selectedCustomer!.points - _pointsUsed} → ${_pointsUsed} pts',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(0xFFB45309),
              ),
            )
          else
            Text(
              '${_selectedCustomer!.points} pts',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFFB45309),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _printSplitBills(
    int numPeople,
    int perPerson,
    List<CartItem> cart,
  ) async {
    // Pre-flight: check Bluetooth permissions & state
    if (!await ReceiptPrinter.ensureBluetoothReady()) {
      if (mounted)
        TopToast.error(
          context,
          'Bluetooth tidak siap. Periksa izin & nyalakan Bluetooth.',
        );
      return;
    }

    final printer = ReceiptPrinter();
    try {
      final devices = await printer.discover();
      if (devices.isEmpty) {
        if (mounted)
          TopToast.error(context, 'Sambungkan printer di Pengaturan');
        return;
      }

      final saved = await SecureStore.getPrinterAddress();
      PrinterDevice? target;
      if (saved != null && saved.contains('|')) {
        final savedAddr = saved.split('|').last;
        final found = devices.where((d) => d.address == savedAddr);
        if (found.isNotEmpty) target = found.first;
      }
      if (target == null) {
        if (mounted)
          TopToast.error(
            context,
            'Printer belum diatur. Pilih printer di Pengaturan.',
          );
        printer.dispose();
        return;
      }

      final paperSize = await SecureStore.getPaperSize();
      final logoPath2 = await SecureStore.getPrinterLogoPath();
      if (logoPath2 != null) await ReceiptPrinter.loadLogo(logoPath2);
      await printer.connect(target);

      for (int i = 1; i <= numPeople; i++) {
        final lines = cart
            .map(
              (c) => ReceiptLine(
                name: c.name,
                qty: c.qty,
                // v2.2.57+122: harga sementara (tempPrice) ikut di struk
                // split bill — sebelumnya c.price (harga asli).
                price: c.unitPrice,
                originalPrice: c.originalPrice,
                discountPerItem: c.discountPerItem,
                productDiscount: c.productDiscount,
              ),
            )
            .toList();
        final notes = cart.map((c) => c.note).toList();
        await printer.printReceipt(
          storeName: 'Split ${i}/$numPeople',
          lines: lines,
          total: perPerson,
          discount: 0,
          paymentMethod: 'Split',
          cashierName: 'Split Bill',
          paperWidth: paperSize,
          orderType: _orderType,
          tableName: _tableName,
          itemNotes: notes,
        );
      }

      await printer.dispose();
      if (mounted)
        TopToast.success(context, '$numPeople struk berhasil dicetak');
    } catch (_) {
      if (mounted) TopToast.error(context, 'Gagal mencetak split bill');
    }
  }

  void _showRedeemPoints() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final maxPts = _selectedCustomer?.points ?? 0;
    final maxRp = maxPts; // 1 poin = Rp 1
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Tukar Poin'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Kamu punya ${_selectedCustomer?.points ?? 0} poin.',
              style: TextStyle(fontSize: 13),
            ),
            SizedBox(height: 4),
            Text(
              '1 poin = Rp 1',
              style: TextStyle(
                fontSize: 12,
                color: isDark
                    ? NusaConfig.darkTextTertiary
                    : Colors.grey.shade600,
              ),
            ),
            SizedBox(height: 12),
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Jumlah poin',
                hintText: 'Maksimal $maxRp',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) {
                final val = int.tryParse(v) ?? 0;
                if (val > maxPts) ctrl.text = maxPts.toString();
              },
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Batal')),
          ElevatedButton(
            onPressed: () {
              final pts = int.tryParse(ctrl.text) ?? 0;
              if (pts <= 0 || pts > maxPts) return;
              setState(() => _pointsUsed = pts);
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.amber,
              foregroundColor: Colors.white,
            ),
            child: Text('Tukar'),
          ),
        ],
      ),
    );
  }

  // ── Customer quick-add from checkout ──

  /// Shows a bottom sheet to register a new customer on the spot.
  /// Returns the newly created Customer, or null if cancelled.
  Future<Customer?> _showAddCustomerSheet() async {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return showModalBottomSheet<Customer>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            12,
            20,
            MediaQuery.of(ctx).viewInsets.bottom + 20,
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
                    color: Colors.grey.shade400,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Daftar Pelanggan Baru',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Nama Pelanggan',
                  hintText: 'Cth: Dimas',
                  filled: true,
                  fillColor: isDark
                      ? NusaConfig.darkSurface2
                      : const Color(0xFFF9FAFB),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: 'Telepon (opsional)',
                  hintText: 'Cth: 0812xxxx',
                  filled: true,
                  fillColor: isDark
                      ? NusaConfig.darkSurface2
                      : const Color(0xFFF9FAFB),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: NusaConfig.activePrimary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () async {
                    if (nameCtrl.text.trim().isEmpty) {
                      if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(content: Text('Nama wajib diisi')),
                        );
                      }
                      return;
                    }
                    final repo = CustomerRepository(ref.read(databaseProvider));
                    final id = await repo.addCustomer(
                      name: nameCtrl.text.trim(),
                      phone: phoneCtrl.text.trim().isEmpty
                          ? null
                          : phoneCtrl.text.trim(),
                    );
                    final created = await repo.byId(id);
                    Navigator.pop(ctx, created);
                  },
                  child: const Text('Daftar'),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

/// Customer/member picker dialog with "Tambah Baru" option — B11.
/// Mendukung: cari nama, scan barcode member via kamera, dan auto-scan HID
/// (scanner eksternal) — pakai STREAM employee_session_provider via callback.
class _CustomerPickerDialog extends StatefulWidget {
  final List<Customer> customers;
  final VoidCallback onAddNew;
  final Future<Customer?> Function(String barcode) byBarcode;
  final Future<void> Function(ValueChanged<String> onResult) scanBarcode;

  const _CustomerPickerDialog({
    required this.customers,
    required this.onAddNew,
    required this.byBarcode,
    required this.scanBarcode,
  });

  @override
  State<_CustomerPickerDialog> createState() => _CustomerPickerDialogState();
}

class _CustomerPickerDialogState extends State<_CustomerPickerDialog> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  String _normQuery = '';

  List<Customer> get _filtered {
    final all = widget.customers;
    if (_normQuery.isEmpty) return all;
    return all.where((c) {
      final name = c.name.toLowerCase();
      if (_normQuery.length < 3) {
        return name.contains(_query.toLowerCase());
      }
      return name.contains(_query.toLowerCase()) ||
          (c.barcode?.replaceAll(RegExp(r'[\s\-]'), '').contains(_normQuery) ??
              false) ||
          (c.phone ?? '').contains(_query);
    }).toList();
  }

  /// Normalisasi barcode member — konsisten dgn capture lain (B11).
  String _norm(String code) => code.replaceAll(RegExp(r'[\s\-]'), '').trim();

  /// Tangani scan (HID / kamera) → cari member by barcode → pilih/langsung
  /// tutup bila ketemu, kalau tidak toast.
  Future<void> _onScan(String raw) async {
    final code = _norm(raw);
    if (code.isEmpty) return;
    if (!mounted) return;
    final matched = await widget.byBarcode(code);
    if (!mounted) return;
    if (matched != null) {
      Navigator.pop(context, matched);
    } else {
      TopToast.error(context, 'Member "$code" tidak ditemukan');
      if (mounted) setState(() => _query = code);
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final filtered = _filtered;
    return HidBarcodeListener(
      onBarcode: _onScan,
      autofocus: false,
      child: AlertDialog(
        title: const Text('Pilih Pelanggan'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Search + scan camera ──
              // Search bar standar (NusaSearchBar) — tombol scan kamera
              // dipertahankan di kanan seperti sebelumnya.
              Row(
                children: [
                  Expanded(
                    child: NusaSearchBar(
                      controller: _searchCtrl,
                      hint: 'Cari nama / barcode / telp',
                      onChanged: (v) {
                        setState(() {
                          _query = v;
                          _normQuery = _norm(v);
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: 'Pindai barcode member',
                    onPressed: () => widget.scanBarcode(
                      (code) => _onScan(code),
                    ),
                    icon: const Icon(Icons.qr_code_scanner, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Scan barcode member (kamera / scanner HID) untuk auto-pilih',
                  style: TextStyle(
                    color: isDark
                        ? NusaConfig.darkTextTertiary
                        : NusaConfig.textTertiary,
                    fontSize: 11,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // "Tambah Baru" button
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: widget.onAddNew,
                  icon: const Icon(Icons.person_add_outlined, size: 18),
                  label: const Text('Daftar Pelanggan Baru'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: NusaConfig.activePrimary,
                    side: BorderSide(
                      color: NusaConfig.activePrimary.withValues(alpha: 0.4),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              if (filtered.isNotEmpty) ...[
                const SizedBox(height: 12),
                Divider(color: Colors.grey.withValues(alpha: 0.2)),
                const SizedBox(height: 8),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: filtered.length,
                    itemBuilder: (_, i) => ListTile(
                      title: Text(
                        filtered[i].name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        '${formatRupiah(filtered[i].totalSpent)} • ${filtered[i].level}'
                        '${filtered[i].barcode != null && filtered[i].barcode!.isNotEmpty ? ' • ${filtered[i].barcode}' : ''}',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.pop(context, filtered[i]),
                    ),
                  ),
                ),
              ] else
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    widget.customers.isEmpty
                        ? 'Belum ada pelanggan'
                        : 'Tidak ada hasil untuk "$_query"',
                    style: TextStyle(
                      color: isDark
                          ? NusaConfig.darkTextTertiary
                          : NusaConfig.textTertiary,
                      fontSize: 13,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Batal'),
          ),
        ],
      ),
    );
  }
}
