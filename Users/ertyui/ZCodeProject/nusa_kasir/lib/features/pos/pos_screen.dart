import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:nusa_kasir/core/providers.dart';
import 'package:nusa_kasir/core/services/delta_sync_service.dart';
import 'package:nusa_kasir/core/config/nusa_config.dart';
import 'package:nusa_kasir/core/services/sound_service.dart';
import 'package:nusa_kasir/core/utils/format_rupiah.dart';
import 'package:nusa_kasir/core/utils/product_discount.dart';
import 'package:nusa_kasir/core/utils/secure_storage.dart';
import 'package:nusa_kasir/core/utils/wholesale_price.dart';
import 'package:nusa_kasir/data/database/app_database.dart';
import 'package:nusa_kasir/data/repositories/cashier_session_repository.dart';
import 'package:nusa_kasir/data/repositories/category_repository.dart';
import 'package:nusa_kasir/data/repositories/dining_table_repository.dart';
import 'package:nusa_kasir/data/repositories/product_repository.dart';
import 'package:nusa_kasir/data/repositories/recipe_repository.dart';
import 'package:nusa_kasir/data/repositories/tab_repository.dart';
import 'package:nusa_kasir/features/pos/cart.dart';
import 'package:nusa_kasir/shared/widgets/top_toast.dart';
import 'package:nusa_kasir/shared/widgets/hid_barcode_listener.dart';
import 'package:nusa_kasir/shared/widgets/nusa_cart_controls.dart';
import 'package:nusa_kasir/shared/widgets/nusa_form_field.dart';
import 'package:nusa_kasir/shared/widgets/nusa_product_image.dart';
import 'package:nusa_kasir/shared/widgets/animated_scanner_overlay.dart';

class PosScreen extends ConsumerStatefulWidget {
  final int? sessionId;
  PosScreen({super.key, this.sessionId});
  @override
  ConsumerState<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends ConsumerState<PosScreen> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();

  /// Produk yang sedang "dikunci" dari hasil scan barcode (v2.2.57+116).
  /// Saat tidak null, grid produk HANYA menampilkan produk ini — scan
  /// barcode tidak lagi tenggelam di antara semua produk. Di-clear saat
  /// kolom cari dikosongkan (sinonim "batal filter") atau tap ikon X.
  Product? _scanFocusProduct;
  String _category = 'Semua';
  String _cashierName = '';
  bool _searching = false;
  bool _cartExpanded = false;
  int _gridColumns = 2;
  bool _productsLoading = true;

  // ── FnB state ──
  String _orderType = 'Dine In';
  int? _selectedTableId;
  String? _selectedTableName;
  List<DiningTable> _diningTables = [];
  int? _activeTabId;

  // ── Route customer (dari servis / booking: "Kasir" trigger) ──
  String? _routeCustomer;
  String? _routeCustomerPhone;

  List<Product>? _allProducts;
  List<String> _allCats = [];

  // B10 (v2.2.44): segmen POS Produk | Layanan (varian jasa only).
  // false = produk biasa, true = layanan. Keranjang tetap bisa campur.
  bool _posServiceOnly = false;

  // Satuan dinamis (v2.2.43): productId → daftar satuan jual produk.
  // Empty list = belum atur satuan → fallback 'pcs'.
  Map<int, List<({int unitId, String name, int? unitStock, double qtyPerBase, bool isBase})>>
      _productUnits = {};

  List<String> get _chips => ['Semua', ..._allCats];

  @override
  void initState() {
    super.initState();
    _loadCashier();
    _preloadProducts();
    _loadGridColumns();
    // v2.2.57+136: produk baru / perubahan stok dari device lain tampil
    // tanpa reopen. Keranjang yang SEDANG diisi tidak pernah diganggu —
    // reload hanya saat keranjang kosong.
    try {
      DeltaSyncService.I.stream.listen((e) {
        if (!mounted || ref.read(cartProvider).isNotEmpty) return;
        if (e.table == '*' ||
            e.table == 'products' ||
            e.table == 'categories') {
          _preloadProducts();
        }
      });
    } catch (_) {}
    if (NusaConfig.isFnbVariant) _loadTables();
    _searchFocus.addListener(() {
      if (mounted) setState(() => _searching = _searchFocus.hasFocus);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleRouteParams();
    });
  }

  /// Reads route query params for both FnB (tab/table) and the "Kasir"
  /// trigger from servis/booking (customer name + phone). The customer
  /// params are forwarded to checkout so the ticket's customer is
  /// automatically selected at payment time.
  Future<void> _handleRouteParams() async {
    final extra = GoRouterState.of(context).uri.queryParameters;
    final customer = extra['customer'];
    final customerPhone = extra['customerPhone'];
    if (customer != null || customerPhone != null) {
      setState(() {
        _routeCustomer = customer != null
            ? Uri.decodeComponent(customer)
            : null;
        _routeCustomerPhone = customerPhone != null
            ? Uri.decodeComponent(customerPhone)
            : null;
      });
    }
    if (NusaConfig.isFnbVariant) await _handleFnbRouteParams();
  }

  Future<void> _handleFnbRouteParams() async {
    final extra = GoRouterState.of(context).uri.queryParameters;
    final tabId = int.tryParse(extra['tabId'] ?? '');
    final tableId = int.tryParse(extra['tableId'] ?? '');
    final tableName = extra['tableName'] != null
        ? Uri.decodeComponent(extra['tableName']!)
        : null;

    if (tabId != null) {
      // Coming from "Lanjutkan" — load existing tab
      final tab = await TabRepository(ref.read(databaseProvider)).byId(tabId);
      if (tab != null) {
        await _loadTab(tab);
      }
    } else if (tableId != null) {
      // Coming from "Buka Pesanan" — set table
      final db = ref.read(databaseProvider);
      final payFirst = NusaConfig.isFnbVariant
          ? await SecureStore.getFnbPaymentFirst()
          : false;
      if (!payFirst) {
        // Pesan Dulu: mark table as occupied immediately
        await DiningTableRepository(db).updateStatus(tableId, 'Dipesan');
      }
      // Bayar Dulu: table stays Kosong until payment completes in checkout
      setState(() {
        _selectedTableId = tableId;
        _selectedTableName = tableName;
      });
      await _loadTables(); // refresh dropdown
    }
  }

  Future<void> _loadTables() async {
    try {
      final repo = DiningTableRepository(ref.read(databaseProvider));
      final tables = await repo.getAll();
      if (mounted) setState(() => _diningTables = tables);
    } catch (e) {
      // Non-fatal: varian non-FnB tidak punya tabel — jangan crash initState.
      debugPrint('[POS] _loadTables error (skip): $e');
    }
  }

  Future<void> _loadGridColumns() async {
    try {
      final repo = ref.read(settingsRepoProvider);
      final cols = await repo.getPosGridColumns();
      if (mounted) setState(() => _gridColumns = cols.clamp(1, 3));
    } catch (e) {
      debugPrint('[POS] _loadGridColumns error (default 3): $e');
    }
  }

  void _setGridColumns(int cols) {
    setState(() => _gridColumns = cols);
    ref.read(settingsRepoProvider).setPosGridColumns(cols);
  }

  Future<void> _preloadProducts() async {
    List<Product> all = const [];
    List<String> cats = const [];
    try {
      final repo = ProductRepository(ref.read(databaseProvider));
      all = await repo.getProducts();
      // Also load real categories for the filter chips.
      final catRepo = CategoryRepository(ref.read(databaseProvider));
      cats = await catRepo.getAll();
      // Satuan dinamis (v2.2.43): kamus konversi per produk untuk dropdown
      // satuan jual di keranjang. Gagal → fallback kosong (pcs).
      try {
        final unitRepo = RecipeRepository(ref.read(databaseProvider));
        final map = <int,
            List<
                ({
                  int unitId,
                  String name,
                  int? unitStock,
                  double qtyPerBase,
                  bool isBase
                })>>{};
        for (final p in all) {
          final labels = await unitRepo.getProductUnitLabels(p.id);
          if (labels.isNotEmpty) map[p.id] = labels;
        }
        _productUnits = map;
      } catch (e) {
        debugPrint('[POS] load product units error: $e');
      }
    } catch (e) {
      // Jangan pernah menggantung: DB rusak/kosong → tampilkan list kosong
      // (bukan spinner abadi). Produk tetap bisa di-scan via byBarcode.
      debugPrint('[POS] _preloadProducts error (fallback empty): $e');
    }
    if (mounted)
      setState(() {
        _allProducts = all;
        _allCats = cats;
        _productsLoading = false;
      });
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _loadCashier() async {
    if (widget.sessionId == null) return;
    try {
      final repo = CashierSessionRepository(ref.read(databaseProvider));
      final session = await repo.getLast();
      if (session != null && mounted) {
        final emps =
            await (ref
                    .read(databaseProvider)
                    .select(ref.read(databaseProvider).employees)
                  ..where((t) => t.id.equals(session.employeeId)))
                .get();
        if (emps.isNotEmpty) setState(() => _cashierName = emps.first.name);
      }
    } catch (e) {
      // Non-fatal: kasir tanpa sesi tetap bisa buka layar POS.
      debugPrint('[POS] _loadCashier error (skip): $e');
    }
  }

  List<Product> _filteredProducts() {
    final all = _allProducts ?? [];
    // v2.2.57+116: filter hasil scan barcode — grid HANYA menampilkan produk
    // yang baru discan. Ditekan "Tampilkan Semua" / clear search → kembali
    // ke semua produk.
    final focus = _scanFocusProduct;
    final q = _search.text.toLowerCase();
    return all.where((p) {
      if (focus != null) {
        return p.id == focus.id;
      }
      if (_category != 'Semua' && p.category != _category) return false;
      // B10: segmen Produk | Layanan — filter flag isService.
      if (NusaConfig.isJasaVariant && _posServiceOnly != p.isService) {
        return false;
      }
      if (q.isNotEmpty && !p.name.toLowerCase().contains(q)) return false;
      return true;
    }).toList();
  }

  /// Set fokus produk hasil scan: grid cuma tampilkan produk ini + kolom cari
  /// diisi kode/barcode yang discan (terlihat jelas, bisa dihapus untuk
  /// kembali ke semua produk).
  void _setScanFocus(Product? product) {
    if (!mounted) return;
    setState(() {
      _scanFocusProduct = product;
      if (product != null) {
        _search.text = product.barcode?.isNotEmpty == true
            ? product.barcode!
            : product.name;
      } else {
        _search.text = '';
      }
    });
  }

  /// Batal filter hasil scan — kembali ke semua produk.
  void _clearScanFocus() => _setScanFocus(null);

  /// Enter / scanner submission: exact barcode first, then name match on the
  /// loaded list. On hit → add to cart (respecting kg weight dialog) + clear
  /// the search box so the next scan starts fresh. Fokus dikembalikan ke
  /// kolom cari supaya scan barcode EKSTERNAL (HID) bisa scan beruntun tanpa
  /// tap ulang (v2.2.29).
  Future<void> _handleSearchSubmit() async {
    final raw = _search.text.trim();
    if (raw.isEmpty) {
      _searchFocus.requestFocus();
      return;
    }
    Product? product;

    // 1) Exact barcode lookup (HID scanner input)
    product = await ProductRepository(
      ref.read(databaseProvider),
    ).byBarcode(raw);
    if (product == null) {
      // 2) Exact name match, then unique substring match on loaded products
      final all = _allProducts ?? [];
      final lower = raw.toLowerCase();
      final byName = all.where((p) => p.name.toLowerCase() == lower).toList();
      if (byName.isNotEmpty) {
        product = byName.first;
      } else {
        final partial = all
            .where((p) => p.name.toLowerCase().contains(lower))
            .toList();
        if (partial.length == 1) product = partial.first;
      }
    }

    if (product == null) {
      _search.clear();
      SoundService.I.play(NusaSound.error);
      if (mounted) TopToast.error(context, 'Produk tidak ditemukan');
      // Tetap fokus: scan berikutnya langsung jalan tanpa tap kolom cari.
      _searchFocus.requestFocus();
      return;
    }
    SoundService.I.play(NusaSound.scan);
    _addToCart(product);
    // v2.2.57+116: scan barcode → grid cuma menampilkan produk yang discan.
    _setScanFocus(product);
    _searchFocus.requestFocus();
  }

  /// Barcode eksternal (HID) yang ditangkap HidBarcodeListener — scan dari
  /// mana pun di layar kasir tanpa tap kolom cari dulu. Reuse logika
  /// _handleSearchSubmit (byBarcode ternormalisasi + addToCart).
  Future<void> _onExternalBarcode(String code) async {
    final norm = ProductRepository.normalizeBarcode(code);
    if (norm.isEmpty) return;
    _search.text = norm;
    if (mounted) setState(() {});
    await _handleSearchSubmit();
  }

  // ── Barcode scanner ──

  /// Scanner barcode KAMERA — modal popup (UI asli, konsisten dengan
  /// products_screen): buka → scan SATU barcode → tutup → tambah ke keranjang.
  /// Scan kontinu hanya berlaku untuk scanner EKSTERNAL (HID/keyboard):
  /// ketik barcode di kolom cari + Enter, langsung masuk keranjang.
  Future<void> _scanBarcode(BuildContext context) async {
    String? scannedCode;
    // Include the full common barcode family + QR. Restricting formats avoids
    // the "no codes found" timeout some cheap scanners hit with the default
    // all-format detector.
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
    if (!mounted) return;

    // Modal popup — consistent UI with products_screen barcode scanner.
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Row(
            children: [
              Icon(
                Icons.qr_code_scanner,
                size: 22,
                color: NusaConfig.activePrimary,
              ),
              SizedBox(width: 8),
              Text('Pindai Barcode'),
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
                    final barcode = capture.barcodes.firstOrNull;
                    final raw = barcode?.rawValue;
                    if (raw == null || raw.isEmpty) return;
                    scannedCode = raw;
                    Navigator.pop(ctx);
                  },
                  errorBuilder: (context, error, child) {
                    // Camera permission denied / no camera: show guidance
                    // (barcode manual diatur via Form Produk).
                    debugPrint('[POS] scanner error: $error');
                    if (errorMsg == null) {
                      errorMsg =
                          'Kamera tidak tersedia atau izin kamera ditolak.';
                      setSt(() {});
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
                            Icon(
                              Icons.no_photography_outlined,
                              size: 36,
                              color: Colors.grey,
                            ),
                            SizedBox(height: 8),
                            Text(
                              'Kamera tidak tersedia.\nBarcode manual diatur via Form Produk.',
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
                SizedBox(height: 8),
                Text(
                  errorMsg!,
                  style: TextStyle(fontSize: 11, color: Colors.orange.shade800),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Batal'),
            ),
          ],
        ),
      ),
    );
    await controller.dispose();
    // Kembalikan fokus ke kolom cari setelah modal scanner ditutup supaya
    // scanner EKSTERNAL (HID) bisa lanjut scan beruntun (v2.2.29).
    _searchFocus.requestFocus();
    if (scannedCode == null || !context.mounted) return;

    final product = await ProductRepository(
      ref.read(databaseProvider),
    ).byBarcode(scannedCode!);
    if (product != null) {
      _addToCart(product);
      // v2.2.57+116: scan kamera → grid cuma menampilkan produk yang discan.
      _setScanFocus(product);
    } else if (context.mounted) {
      TopToast.error(context, 'Produk tidak ditemukan');
    }
  }

  Future<void> _closeKasir() async {
    // ── FnB: revert orphaned table (opened but no tab created) ──
    if (NusaConfig.isFnbVariant &&
        _selectedTableId != null &&
        _activeTabId == null) {
      try {
        await DiningTableRepository(
          ref.read(databaseProvider),
        ).updateStatus(_selectedTableId!, 'Kosong');
      } catch (_) {}
    }
    if (widget.sessionId == null) {
      if (mounted) context.go('/home');
      return;
    }
    final repo = CashierSessionRepository(ref.read(databaseProvider));
    await repo.close(widget.sessionId!);
    if (mounted) {
      context.go('/home');
      TopToast.success(context, 'Kasir ditutup. Sampai jumpa!');
    }
  }

  /// Add product to cart — applies live wholesale pricing (qty ≥ minQty →
  /// harga tier grosir) and shows weight dialog for per-kg products.
  ///
  /// Guard stok: produk stok 0 TIDAK masuk cart (toast), dan qty tidak boleh
  /// melebihi stok — scan barcode, search, dan tap grid semua lewat sini.
  /// Re-apply harga grosir pada baris keranjang setelah qty berubah
  /// (decrement / qty editable / ganti varian / ganti satuan).
  ///
  /// Sebelum v2.2.44 hanya tombol `+` yang menghitung ulang grosir — `-` dan
  /// qty editable membiarkan harga "beku" di tier tinggi walau qty sudah
  /// turun di bawah ambang. Ambang pakai [CartItem.qtyInBase] (qty ×
  /// qtyPerBase) supaya satuan jual (mis. dus = 12 pcs) ikut ambang grosir.
  void _reapplyWholesale(CartItem item, Product product) {
    if (item.isManual || item.isPerKg) return;
    ref.read(cartProvider.notifier).recomputeWholesale(
          item.productId,
          wholesalePriceForQty: product.wholesalePriceFor,
          normalPrice: product.effectivePrice,
          fullPrice: product.sellPrice,
          variantName: item.variantName,
        );
  }

  void _addToCart(Product product) {
    // Stok guard: produk ber-varian pakai Σ stok semua varian; reguler pakai
    // stok produk langsung. B10: LAYANAN (isService) TIDAK dilacak stoknya —
    // lewati guard, selalu bisa ditambahkan ke keranjang.
    final variants = ProductRepository.parseVariants(product);
    final totalStock = variants.isEmpty
        ? product.stock
        : variants.fold<int>(0, (s, v) => s + v.stock);
    if (totalStock <= 0 && !product.isService) {
      SoundService.I.play(NusaSound.error);
      TopToast.error(context, 'Stok "${product.name}" habis');
      return;
    }
    // Satuan dinamis (v2.2.43): default = satuan dasar produk bila ada.
    // Stok guard pakai qtyInBase (= qty × qtyPerBase) di dalam keranjang.
    final units = _productUnits[product.id] ?? const [];
    final baseUnit = units.where((u) => u.isBase).firstOrNull;
    final defaultUnitName = baseUnit?.name ?? 'pcs';
    final defaultQtyPerBase = baseUnit?.qtyPerBase ?? 1;
    final inCartNow = ref
        .read(cartProvider)
        .cast<CartItem?>()
        .firstWhere((c) => c?.productId == product.id, orElse: () => null);
    final inCartBase = inCartNow == null ? 0 : inCartNow.qtyInBase;
    if (totalStock > 0 && inCartBase >= totalStock) {
      SoundService.I.play(NusaSound.error);
      TopToast.error(
        context,
        'Stok "${product.name}" tidak cukup (tersedia: $totalStock)',
      );
      return;
    }
    if (product.priceType == 'kg') {
      _showWeightDialog(product);
    } else {
      final inCart = ref
          .read(cartProvider)
          .cast<CartItem?>()
          .firstWhere((c) => c?.productId == product.id, orElse: () => null);
      final nextQty = (inCart?.qty ?? 0) + 1;
      final wPrice = product.wholesalePriceFor(nextQty);
      ref
          .read(cartProvider.notifier)
          .addProduct(
            product.id,
            product.name,
            wPrice ?? product.effectivePrice,
            originalPrice: (product.hasDiscount || wPrice != null)
                ? product.sellPrice
                : null,
            qty: 1,
            variantStock: variants.isEmpty ? null : totalStock,
            unitName: baseUnit != null ? defaultUnitName : null,
            unitQtyPerBase: baseUnit != null ? defaultQtyPerBase : 1,
            isService: product.isService,
          );
      SoundService.I.play(NusaSound.pop);
    }
  }

  /// Weight input dialog for per-kg laundry products.
  void _showWeightDialog(Product product) {
    final ctrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(        padding: EdgeInsets.fromLTRB(
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
            SizedBox(height: 16),
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: NusaConfig.accentPurple.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.scale_rounded,
                    color: NusaConfig.accentPurple,
                    size: 20,
                  ),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    product.name,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            SizedBox(height: 4),
            Text(
              '${formatRupiah(product.sellPrice)} / kg',
              style: TextStyle(fontSize: 13, color: NusaConfig.textSecondary),
            ),
            SizedBox(height: 16),
            NusaFormField(
              label: 'Berat (kg)',
              controller: ctrl,
              hintText: 'Contoh: 2.5',
              keyboardType: TextInputType.numberWithOptions(decimal: true),
              validator: (v) {
                if (v == null || v.isEmpty) return 'Wajib diisi';
                final w = double.tryParse(v);
                if (w == null || w <= 0) return 'Berat tidak valid';
                return null;
              },
            ),
            SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: NusaConfig.activePrimary,
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () {
                  final w = double.tryParse(ctrl.text.trim());
                  if (w == null || w <= 0) return;
                  if (product.stock <= 0) {
                    TopToast.error(ctx, 'Stok "${product.name}" habis');
                    return;
                  }
                  final inCart = ref
                      .read(cartProvider)
                      .cast<CartItem?>()
                      .firstWhere(
                        (c) => c?.productId == product.id,
                        orElse: () => null,
                      );
                  final nextQty = (inCart?.qty ?? 0) + 1;
                  final wPrice = product.wholesalePriceFor(nextQty);
                  ref
                      .read(cartProvider.notifier)
                      .addProduct(
                        product.id,
                        product.name,
                        wPrice ?? product.effectivePrice,
                        originalPrice: (product.hasDiscount || wPrice != null)
                            ? product.sellPrice
                            : null,
                        weightKg: w,
                      );
                  SoundService.I.play(NusaSound.pop);
                  Navigator.pop(ctx);
                  // Kembalikan fokus ke kolom cari — scan berikutnya langsung
                  // jalan tanpa tap (v2.2.29).
                  _searchFocus.requestFocus();
                },
                child: Text('Tambah ke Keranjang'),
              ),
            ),
            SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cart = ref.watch(cartProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final totalItems = cart.fold(0, (s, e) => s + e.qty);
    // v2.2.57+127: total = Σ subtotal — diskon MANUAL per satuan saja.
    // Diskon produk/menu sudah tercermin di price (jangan kurang lagi, fix
    // dobel diskon: 87.500 + diskon 50rb harus 37.500, bukan 12.500).
    final totalPrice = cart.fold(0, (s, e) => s + e.subtotal - e.itemDiscountTotal);
    final isWide = MediaQuery.of(context).size.width > 720;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeKasir();
      },
      child: Scaffold(
        backgroundColor: isDark
            ? NusaConfig.darkBackground
            : NusaConfig.backgroundColor,
        body: SafeArea(
          // v2.2.43: barcode eksternal (HID) jalan tanpa tap field pencarian
          // di SEMUA layar scan. Listener ini menangkap scan di level Focus
          // TANPA membuka keyboard layar. Field pencarian tetap dipakai kalau
          // user men-tap-nya (scan lalu fokus balik ke kolom cari).
          child: HidBarcodeListener(
            onBarcode: _onExternalBarcode,
            child: isWide
                ? _buildWideLayout(isDark, cart, totalItems, totalPrice)
                : _buildNarrowLayout(isDark, cart, totalItems, totalPrice),
          ),
        ),
      ),
    );
  }

  // =========== NARROW LAYOUT (phone) ===========

  Widget _buildNarrowLayout(
    bool isDark,
    List<CartItem> cart,
    int totalItems,
    int totalPrice,
  ) {
    return Stack(
      children: [
        Column(
          children: [
            _buildTopBar(isDark),
            Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: _buildSearchBar(isDark),
            ),
            if (_scanFocusProduct != null) ...[
              const SizedBox(height: 8),
              _buildScanFilterBanner(isDark),
            ],
            if (NusaConfig.isJasaVariant) ...[
              const SizedBox(height: 10),
              _buildServiceSegment(isDark),
            ],
            _buildCategoryChips(isDark),
            Expanded(child: _buildProductGrid(isDark)),
            if (!_cartExpanded) _buildCartBar(isDark, totalItems, totalPrice),
          ],
        ),
        if (_cartExpanded)
          _buildCartPanel(isDark, cart, totalItems, totalPrice, isSheet: true),
      ],
    );
  }

  // =========== WIDE LAYOUT (tablet) ===========

  Widget _buildWideLayout(
    bool isDark,
    List<CartItem> cart,
    int totalItems,
    int totalPrice,
  ) {
    return Column(
      children: [
        _buildTopBar(isDark),
        Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: _buildSearchBar(isDark),
        ),
        if (_scanFocusProduct != null) ...[
          const SizedBox(height: 8),
          _buildScanFilterBanner(isDark),
        ],
        if (NusaConfig.isJasaVariant) ...[
          const SizedBox(height: 10),
          _buildServiceSegment(isDark),
        ],
        _buildCategoryChips(isDark),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: _buildProductGrid(isDark)),
              SizedBox(
                width: 380,
                child: _buildCartPanel(
                  isDark,
                  cart,
                  totalItems,
                  totalPrice,
                  isSheet: false,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // =========== COMPONENTS ===========

  /// Banner hasil scan (v2.2.57+116): grid cuma menampilkan produk yang
  /// discan — jelas terlihat bahwa list sedang difilter. Tombol
  /// "Tampilkan Semua" kembali ke semua produk (sinonim clear search).
  Widget _buildScanFilterBanner(bool isDark) {
    final p = _scanFocusProduct;
    if (p == null) return const SizedBox.shrink();
    final primary = NusaConfig.activePrimary;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(
          color: primary.withValues(alpha: isDark ? 0.18 : 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: primary.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Icon(Icons.qr_code_2_rounded, size: 18, color: primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Hasil scan: ${p.name}',
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
            ),
            TextButton(
              onPressed: _clearScanFocus,
              style: TextButton.styleFrom(
                foregroundColor: primary,
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('Tampilkan Semua'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(bool isDark) {
    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          Text(
            'Kasir',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: isDark
                  ? NusaConfig.darkTextPrimary
                  : NusaConfig.textPrimary,
            ),
          ),
          SizedBox(width: 12),
          _gridToggle(1, Icons.view_agenda_rounded, isDark),
          SizedBox(width: 4),
          _gridToggle(2, Icons.grid_view_rounded, isDark),
          SizedBox(width: 4),
          _gridToggle(3, Icons.apps_rounded, isDark),
          SizedBox(width: 4),
          // ── Pesanan Tersimpan (B7): draft/antrian — SEMUA varian ──
          GestureDetector(
            onTap: _showSavedOrders,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: isDark
                    ? NusaConfig.darkSurface2
                    : NusaConfig.inputFill,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.bookmark_border,
                size: 18,
                color: isDark
                    ? NusaConfig.darkTextSecondary
                    : NusaConfig.textSecondary,
              ),
            ),
          ),
          Spacer(),
          if (_cashierName.isNotEmpty)
            Container(
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: NusaConfig.activeSoft,
                borderRadius: BorderRadius.circular(NusaConfig.radiusFull),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.person, size: 14, color: NusaConfig.activePrimary),
                  SizedBox(width: 4),
                  Text(
                    _cashierName,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: NusaConfig.activePrimary,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // B10 (v2.2.44): segmen Produk | Layanan — varian jasa only.
  // v2.2.54: diganti switch card LEBAR PENUH selebar search bar (bukan chip
  // kecil) — pil primary bergeser animasi, ikon + label per sisi.
  Widget _buildServiceSegment(bool isDark) {
    if (!NusaConfig.isJasaVariant) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color:
              isDark ? NusaConfig.darkSurface2 : NusaConfig.surfaceColor,
          borderRadius: BorderRadius.circular(NusaConfig.radiusXL),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.20 : 0.04),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Stack(
          children: [
            // Pil indikator yang bergeser kiri/kanan.
            AnimatedAlign(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: _posServiceOnly
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: 0.5,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Container(
                    decoration: BoxDecoration(
                      color: NusaConfig.activePrimary,
                      borderRadius:
                          BorderRadius.circular(NusaConfig.radiusLG),
                      boxShadow: [
                        BoxShadow(
                          color: NusaConfig.activePrimary
                              .withValues(alpha: 0.30),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: _switchSegmentHalf(
                    icon: Icons.inventory_2_rounded,
                    label: 'Produk',
                    selected: !_posServiceOnly,
                    onTap: () => setState(() => _posServiceOnly = false),
                  ),
                ),
                Expanded(
                  child: _switchSegmentHalf(
                    icon: Icons.handyman_outlined,
                    label: 'Layanan',
                    selected: _posServiceOnly,
                    onTap: () => setState(() => _posServiceOnly = true),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _switchSegmentHalf({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 17,
              color: selected ? Colors.white : NusaConfig.textSecondary,
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: selected
                    ? Colors.white
                    : (Theme.of(context).brightness == Brightness.dark
                        ? NusaConfig.darkTextSecondary
                        : NusaConfig.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _gridToggle(int cols, IconData icon, bool isDark) {
    final active = _gridColumns == cols;
    return GestureDetector(
      onTap: () => _setGridColumns(cols),
      child: AnimatedContainer(
        duration: Duration(milliseconds: 200),
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: active
              ? NusaConfig.activePrimary
              : (isDark ? NusaConfig.darkSurface2 : NusaConfig.inputFill),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          icon,
          size: 18,
          color: active
              ? Colors.white
              : isDark
              ? NusaConfig.darkTextSecondary
              : NusaConfig.textSecondary,
        ),
      ),
    );
  }

  Widget _buildSearchBar(bool isDark) {
    return AnimatedContainer(
      duration: Duration(milliseconds: 250),
      decoration: BoxDecoration(
        color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
        borderRadius: BorderRadius.circular(NusaConfig.radiusXL),
        boxShadow: _searching
            ? [
                BoxShadow(
                  color: NusaConfig.activePrimary.withValues(alpha: 0.2),
                  blurRadius: 12,
                  offset: Offset(0, 3),
                ),
              ]
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ],
      ),
      child: TextField(
        controller: _search,
        focusNode: _searchFocus,
        style: TextStyle(
          fontSize: 15,
          color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary,
        ),
        decoration: InputDecoration(
          hintText: 'Cari produk...',
          hintStyle: TextStyle(
            color: isDark
                ? NusaConfig.darkTextTertiary
                : NusaConfig.textTertiary,
          ),
          prefixIcon: Icon(
            Icons.search_rounded,
            color: isDark
                ? NusaConfig.darkTextSecondary
                : NusaConfig.textSecondary,
            size: 22,
          ),
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: () => _scanBarcode(context),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(
                    Icons.qr_code_scanner,
                    color: NusaConfig.activePrimary,
                    size: 22,
                  ),
                ),
              ),
              if (_search.text.isNotEmpty)
                GestureDetector(
                  onTap: () {
                    _search.clear();
                    // v2.2.57+116: hapus juga filter hasil scan (kalau ada)
                    // — ikon X = kembali ke semua produk.
                    if (_scanFocusProduct != null) _clearScanFocus();
                    setState(() {});
                  },
                  child: Icon(
                    Icons.clear_rounded,
                    color: isDark
                        ? NusaConfig.darkTextSecondary
                        : NusaConfig.textSecondary,
                    size: 20,
                  ),
                ),
            ],
          ),
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
        onChanged: (_) => setState(() {}),
        // Physical barcode scanners act as HID keyboards: they type the
        // barcode digits instantly then send Enter (\n). Without onSubmitted
        // the Enter is a no-op and the scanned code never reaches the cart.
        // Here we resolve the scanned code → exact barcode match → product,
        // falling back to a name match on the already-loaded product list.
        //
        // IMPORTANT (v2.2.29): textInputAction KEEP textInputAction.done /
        // unfocus behavior — pressing Enter would drop focus and the next
        // scan would go nowhere. textInputAction.newline does NOT unfocus,
        // so an external HID scanner can scan the SAME barcode repeatedly
        // without tapping the search bar again (komplain user).
        textInputAction: TextInputAction.newline,
        onSubmitted: (_) => _handleSearchSubmit(),
      ),
    );
  }

  Widget _buildCategoryChips(bool isDark) {
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.fromLTRB(16, 10, 8, 4),
              itemCount: _chips.length,
              separatorBuilder: (_, __) => SizedBox(width: 8),
              itemBuilder: (_, i) {
                final chip = _chips[i];
                final selected = chip == _category;
                return GestureDetector(
                  onTap: () => setState(() => _category = chip),
                  child: AnimatedContainer(
                    duration: Duration(milliseconds: 200),
                    padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: selected
                          ? NusaConfig.activePrimary
                          : (isDark
                                ? NusaConfig.darkSurface2
                                : NusaConfig.surfaceColor),
                      borderRadius: BorderRadius.circular(
                        NusaConfig.radiusFull,
                      ),
                      boxShadow: selected
                          ? [
                              BoxShadow(
                                color: NusaConfig.activePrimary.withValues(
                                  alpha: 0.3,
                                ),
                                blurRadius: 8,
                                offset: Offset(0, 2),
                              ),
                            ]
                          : [],
                    ),
                    child: Text(
                      chip,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: selected
                            ? Colors.white
                            : (isDark
                                  ? NusaConfig.darkTextSecondary
                                  : NusaConfig.textSecondary),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          // ── "+" item manual (transaksi di luar menu produk) ──
          Padding(
            padding: EdgeInsets.only(right: 12, top: 6, bottom: 0),
            child: GestureDetector(
              onTap: () => _showManualItemSheet(),
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: NusaConfig.activePrimary,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: NusaConfig.activePrimary.withValues(alpha: 0.3),
                      blurRadius: 8,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: Icon(Icons.add, size: 20, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Manual item: transaksi ad-hoc di luar menu produk ──

  String get _manualHint {
    if (NusaConfig.isLaundryVariant)
      return 'Contoh: jasa antar jemput, setrika express';
    if (NusaConfig.isBengkelVariant)
      return 'Contoh: turun mesin, cuci motor, service AC';
    if (NusaConfig.isSalonVariant)
      return 'Contoh: cukur alis, cat rambut, kreasi';
    if (NusaConfig.isApotekVariant)
      return 'Contoh: konsultasi, obat racikan, tes tensi';
    if (NusaConfig.isFotocopyVariant)
      return 'Contoh: jilid, laminating, jasa print';
    if (NusaConfig.isServisVariant)
      return 'Contoh: service AC, pasang antena, perbaikan';
    if (NusaConfig.isFnbVariant)
      return 'Contoh: biaya delivery, parkir, asuransi';
    return 'Contoh: jasa angkut, ongkir, biaya layanan';
  }

  void _showManualItemSheet() {
    final nameCtrl = TextEditingController();
    final priceCtrl = TextEditingController();
    final costCtrl = TextEditingController();
    final qtyCtrl = TextEditingController(text: '1');
    int? previewCost; // untuk preview laba bersih (state sheet lokal)
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
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
              SizedBox(height: 16),
              Text(
                'Item Manual',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              SizedBox(height: 4),
              Text(
                'Transaksi di luar menu produk. ${_manualHint}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              SizedBox(height: 16),
              NusaFormField(
                label: 'Nama Item',
                controller: nameCtrl,
                hintText: 'contoh: jasa angkut',
              ),
              SizedBox(height: 12),
              NusaFormField(
                label: 'Harga (Rp)',
                controller: priceCtrl,
                hintText: 'contoh: 15000',
                keyboardType: TextInputType.number,
              ),
              SizedBox(height: 12),
              NusaFormField(
                label: 'Harga Modal (Rp) — opsional',
                controller: costCtrl,
                hintText: 'contoh: 10000',
                keyboardType: TextInputType.number,
                onChanged: (_) {
                  previewCost = int.tryParse(
                    costCtrl.text.replaceAll(RegExp(r'[^\d]'), ''),
                  );
                  setSheet(() {});
                },
              ),
              if (previewCost != null && previewCost! > 0) ...[
                SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color:
                        (int.tryParse(
                                  priceCtrl.text.replaceAll(
                                    RegExp(r'[^\d]'),
                                    '',
                                  ),
                                ) ??
                                0) >
                            previewCost!
                        ? NusaConfig.success.withValues(alpha: 0.12)
                        : NusaConfig.warning.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    'Laba bersih per item: ${formatRupiah((int.tryParse(priceCtrl.text.replaceAll(RegExp(r'[^\d]'), '')) ?? 0) - previewCost!)}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color:
                          (int.tryParse(
                                    priceCtrl.text.replaceAll(
                                      RegExp(r'[^\d]'),
                                      '',
                                    ),
                                  ) ??
                                  0) >
                              previewCost!
                          ? NusaConfig.success
                          : NusaConfig.warning,
                    ),
                  ),
                ),
              ],
              SizedBox(height: 12),
              NusaFormField(
                label: 'Jumlah',
                controller: qtyCtrl,
                hintText: '1',
                keyboardType: TextInputType.number,
              ),
              SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: NusaConfig.activePrimary,
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () {
                    final name = nameCtrl.text.trim();
                    final price =
                        int.tryParse(
                          priceCtrl.text.replaceAll(RegExp(r'[^\d]'), ''),
                        ) ??
                        0;
                    final cost = int.tryParse(
                      costCtrl.text.replaceAll(RegExp(r'[^\d]'), ''),
                    );
                    final qty =
                        int.tryParse(
                          qtyCtrl.text.replaceAll(RegExp(r'[^\d]'), ''),
                        ) ??
                        1;
                    if (name.isEmpty || price <= 0) {
                      TopToast.error(context, 'Isi nama item & harga');
                      return;
                    }
                    if (qty < 1) {
                      TopToast.error(context, 'Jumlah minimal 1');
                      return;
                    }
                    if (cost != null && cost > price) {
                      TopToast.error(
                        context,
                        'Harga modal tidak boleh melebihi harga jual',
                      );
                      return;
                    }
                    ref
                        .read(cartProvider.notifier)
                        .addManualItem(name, price, qty: qty, costPrice: cost);
                    Navigator.pop(ctx);
                    TopToast.success(context, '$name ditambahkan');
                  },
                  child: Text('Tambah ke Keranjang'),
                ),
              ),
              SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProductGrid(bool isDark) {
    if (_productsLoading) {
      return Center(
        child: CircularProgressIndicator(color: NusaConfig.activePrimary),
      );
    }
    final products = _filteredProducts();
    if (products.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.inventory_2_outlined,
              size: 56,
              color: isDark
                  ? NusaConfig.darkTextTertiary
                  : NusaConfig.textTertiary,
            ),
            SizedBox(height: 8),
            Text(
              'Produk tidak ditemukan',
              style: TextStyle(
                color: isDark
                    ? NusaConfig.darkTextSecondary
                    : NusaConfig.textSecondary,
                fontSize: 15,
              ),
            ),
            SizedBox(height: 4),
            Text(
              'Muat ulang untuk mencoba memuat lagi dari database.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: isDark
                    ? NusaConfig.darkTextTertiary
                    : NusaConfig.textTertiary,
              ),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: () {
                setState(() => _productsLoading = true);
                _preloadProducts();
              },
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Muat Ulang'),
              style: OutlinedButton.styleFrom(
                foregroundColor: NusaConfig.activePrimary,
                side: BorderSide(color: NusaConfig.activePrimary),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      );
    }
    final cart = ref.watch(cartProvider);

    // 1x1 mode: thin horizontal list cards
    if (_gridColumns == 1) {
      return ListView.builder(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
        itemCount: products.length,
        itemBuilder: (_, i) {
          final product = products[i];
          final cartItem = cart.cast<CartItem?>().firstWhere(
            (c) => c?.productId == product.id,
            orElse: () => null,
          );
          return _ProductListCard(
            product: product,
            isDark: isDark,
            qtyInCart: cartItem?.qty ?? 0,
            onAdd: () => _addToCart(product),
            onDecrement: () {
              ref.read(cartProvider.notifier).changeQty(product.id, -1);
              if (cartItem != null) _reapplyWholesale(cartItem, product);
            },
            onIncrement: () => _addToCart(product),
          );
        },
      );
    }

    final cross = _gridColumns;
    return LayoutBuilder(
      builder: (context, constraints) {
        // ── Rasio pintar (2x2, 3x3, dst) ──
        // colW dari lebar aktual grid (bukan MediaQuery seluruh layar).
        // Tinggi kartu = gambar persegi (colW-20) + footer konten-real
        // (nama 2 baris + kategori + harga + grosir + gap + tombol 36).
        // Tanpa clamp yang mendistorsi → tombol TIDAK pernah meluber keluar
        // card di HP panjang/sempit, dan margin bawah antar kartu konsisten.
        final colW = (constraints.maxWidth - 32 - 10 * (cross - 1)) / cross;
        final imgH = colW - 20; // padding kartu 10 tiap sisi
        const footerH =
            150.0; // nama 2 baris + kategori + harga + grosir + gap + tombol
        final ratio = (colW / (imgH + footerH)).clamp(0.4, 0.95);
        return GridView.builder(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _gridColumns,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: ratio,
          ),
          itemCount: products.length,
          itemBuilder: (_, i) {
            final product = products[i];
            final cartItem = cart.cast<CartItem?>().firstWhere(
              (c) => c?.productId == product.id,
              orElse: () => null,
            );
            return _ProductCard(
              product: product,
              isDark: isDark,
              qtyInCart: cartItem?.qty ?? 0,
              onAdd: () => _addToCart(product),
              onDecrement: () {
                ref.read(cartProvider.notifier).changeQty(product.id, -1);
                if (cartItem != null) _reapplyWholesale(cartItem, product);
              },
              onIncrement: () => _addToCart(product),
              onQtyEdited: cartItem == null || cartItem.isPerKg
                  ? null
                  : (v) {
                      final nq = int.tryParse(v) ?? 0;
                      if (nq <= 0) {
                        ref
                            .read(cartProvider.notifier)
                            .changeQty(product.id, -9999);
                      } else {
                        ref.read(cartProvider.notifier).setQty(product.id, nq);
                        _reapplyWholesale(cartItem, product);
                      }
                    },
            );
          },
        );
      },
    );
  }

  // ── Cart Bar (collapsed, narrow only) ──

  Widget _buildCartBar(bool isDark, int totalItems, int totalPrice) {
    return GestureDetector(
      onTap: totalItems > 0 ? () => setState(() => _cartExpanded = true) : null,
      child: Container(
        margin: EdgeInsets.fromLTRB(12, 4, 12, 12),
        padding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(NusaConfig.radiusXL),
          gradient: LinearGradient(
            colors: [NusaConfig.activePrimary, NusaConfig.activeDark],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: NusaConfig.activePrimary.withValues(alpha: 0.35),
              blurRadius: 16,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$totalItems item',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  formatRupiah(totalPrice),
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: -0.5,
                  ),
                ),
              ],
            ),
            Spacer(),
            if (totalItems > 0)
              Icon(Icons.keyboard_arrow_up, color: Colors.white70, size: 28),
            SizedBox(width: 8),
            ElevatedButton(
              onPressed: totalItems == 0 ? null : () => _goToCheckout(),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: NusaConfig.activePrimary,
                disabledBackgroundColor: Colors.white38,
                disabledForegroundColor: Colors.white54,
                elevation: 0,
                padding: EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                textStyle: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              child: Text('Bayar'),
            ),
          ],
        ),
      ),
    );
  }

  // ── Cart Panel (sheet for narrow, sidebar for wide) ──

  Widget _buildCartPanel(
    bool isDark,
    List<CartItem> cart,
    int totalItems,
    int totalPrice, {
    required bool isSheet,
  }) {
    final separator = Container(
      height: 1,
      color: isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor,
    );

    Widget body = Column(
      children: [
        if (isSheet) ...[
          Center(
            child: Container(
              margin: EdgeInsets.symmetric(vertical: 10),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: NusaConfig.dividerColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(
                  'Keranjang',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: isDark
                        ? NusaConfig.darkTextPrimary
                        : NusaConfig.textPrimary,
                  ),
                ),
                Spacer(),
                TextButton(
                  onPressed: () => ref.read(cartProvider.notifier).clear(),
                  child: Text(
                    'Kosongkan',
                    style: TextStyle(
                      color: NusaConfig.activePrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => setState(() => _cartExpanded = false),
                  icon: Icon(
                    Icons.keyboard_arrow_down,
                    color: isDark
                        ? NusaConfig.darkTextSecondary
                        : NusaConfig.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ] else ...[
          Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                Icon(
                  Icons.shopping_basket_outlined,
                  color: NusaConfig.activePrimary,
                  size: 20,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Keranjang',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: isDark
                          ? NusaConfig.darkTextPrimary
                          : NusaConfig.textPrimary,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: cart.isEmpty
                      ? null
                      : () => ref.read(cartProvider.notifier).clear(),
                  child: Text(
                    'Kosongkan',
                    style: TextStyle(
                      fontSize: 12,
                      color: NusaConfig.activePrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          separator,
        ],
        // ── FnB: Order type chips ──
        if (NusaConfig.isFnbVariant) ...[
          SizedBox(height: 6),
          _buildOrderTypeChips(isDark, isSheet ? 16 : 12),
          if (_orderType == 'Dine In')
            _buildTableSelector(isDark, isSheet ? 16 : 12),
        ],
        separator,
        // Cart items
        Expanded(
          child: cart.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.receipt_long_outlined,
                        size: 48,
                        color: NusaConfig.textTertiary.withValues(alpha: 0.5),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Keranjang masih kosong',
                        style: TextStyle(
                          color: isDark
                              ? NusaConfig.darkTextTertiary
                              : NusaConfig.textTertiary,
                        ),
                      ),
                    ],
                  ),
                )
              : Consumer(
                  builder: (_, ref, __) => ListView.builder(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemCount: cart.length,
                    itemBuilder: (_, i) {
                      final item = cart[i];
                      final prod = (_allProducts ?? const <Product>[])
                          .where((p) => p.id == item.productId)
                          .firstOrNull;
                      final hasProd = prod != null;
                      final hasVariants =
                          hasProd &&
                          ProductRepository.parseVariants(prod).isNotEmpty;
                      final units = _productUnits[item.productId] ?? const [];
                      return _CartItemTile(
                        item: item,
                        isDark: isDark,
                        hasVariants: hasVariants,
                        onSelectVariant: hasVariants
                            ? () => _pickVariant(item, prod)
                            : null,
                        units: units,
                        onSelectUnit: (name, qtyPerBase) {
                          final notifier = ref.read(cartProvider.notifier);
                          notifier.setUnit(
                            item.productId,
                            name,
                            qtyPerBase,
                            variantName: item.variantName,
                          );
                          // Ganti satuan mengubah qtyInBase → ambang grosir
                          // bisa berubah; re-apply harga (B5).
                          if (prod != null) _reapplyWholesale(item, prod);
                        },
                        onDecrement: () {
                          final notifier = ref.read(cartProvider.notifier);
                          notifier.changeQty(
                            item.productId,
                            -1,
                            variantName: item.variantName,
                          );
                          if (prod != null) _reapplyWholesale(item, prod);
                        },
                        onIncrement: () {
                          final notifier = ref.read(cartProvider.notifier);
                          // Satuan: naikkan qty dalam satuan jual; stok guard
                          // pakai qtyInBase (qty × qtyPerBase).
                          final nextQty = item.qty + 1;
                          final nextBase = (nextQty * item.unitQtyPerBase).round();
                          // Re-apply wholesale tier when qty crosses a threshold.
                          // Guard stok: jangan biarkan qty melebihi stok yang ada
                          // (produk ber-varian: Σ stok varian).
                          if (prod != null) {
                            final variants =
                                ProductRepository.parseVariants(prod);
                            final totalStock = variants.isEmpty
                                ? prod.stock
                                : variants.fold<int>(
                                    0,
                                    (s, v) => s + v.stock,
                                  );
                            if (totalStock > 0 && nextBase > totalStock) {
                              TopToast.error(
                                context,
                                'Stok "${item.name}" tidak cukup (tersedia: $totalStock)',
                              );
                              return;
                            }
                            final wPrice = prod.wholesalePriceFor(nextQty);
                            notifier.addProduct(
                              item.productId,
                              item.name,
                              wPrice ?? item.price,
                              originalPrice: (prod.hasDiscount ||
                                      wPrice != null)
                                  ? prod.sellPrice
                                  : item.originalPrice,
                              note: item.note,
                              weightKg: item.weightKg,
                              variantName: item.variantName,
                              variantPriceAdjustment:
                                  item.variantPriceAdjustment,
                              variantStock: item.variantStock,
                              unitName: item.unitName,
                              unitQtyPerBase: item.unitQtyPerBase,
                              isService: item.isService,
                            );
                            return;
                          }
                          notifier.addProduct(
                            item.productId,
                            item.name,
                            item.price,
                            originalPrice: item.originalPrice,
                            note: item.note,
                            weightKg: item.weightKg,
                            variantName: item.variantName,
                            variantPriceAdjustment: item.variantPriceAdjustment,
                            variantStock: item.variantStock,
                            unitName: item.unitName,
                            unitQtyPerBase: item.unitQtyPerBase,
                            isService: item.isService,
                          );
                        },
                        onTap: () => _showItemSheet(item),
                      );
                    },
                  ),
                ),
        ),
        // ── Simple summary ──
        Container(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
          decoration: BoxDecoration(
            color: isDark ? NusaConfig.darkSurface : NusaConfig.backgroundColor,
            border: Border(
              top: BorderSide(
                color: isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor,
              ),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '$totalItems item',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark
                      ? NusaConfig.darkTextSecondary
                      : NusaConfig.textSecondary,
                ),
              ),
              Text(
                formatRupiah(totalPrice),
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: NusaConfig.activePrimary,
                  letterSpacing: -0.5,
                ),
              ),
            ],
          ),
        ),
        // Buttons
        Container(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            children: [
              // ── Simpan Pesanan (B7 — semua varian; FnB = open tab, lainnya
              // = draft antrian yang bisa dilanjutkan/bayar belakangan) ──
              if (cart.isNotEmpty) ...[
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _saveOrder(),
                    icon: Icon(Icons.bookmark_outline, size: 18),
                    label: Text(
                      'Simpan Pesanan',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: NusaConfig.activePrimary,
                      side: BorderSide(
                        color: NusaConfig.activePrimary.withValues(alpha: 0.4),
                      ),
                      padding: EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
                SizedBox(height: 8),
              ],
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: totalItems == 0 ? null : () => _goToCheckout(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: NusaConfig.activePrimary,
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    textStyle: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  child: Text('Lanjut Pembayaran'),
                ),
              ),
            ],
          ),
        ),
      ],
    );

    if (isSheet) {
      return Positioned.fill(
        top: MediaQuery.of(context).padding.top + 80,
        child: GestureDetector(
          onVerticalDragEnd: (d) {
            if (d.primaryVelocity! > 500) setState(() => _cartExpanded = false);
          },
          child: Container(
            decoration: BoxDecoration(
              color: isDark
                  ? NusaConfig.darkBackground
                  : NusaConfig.surfaceColor,
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(NusaConfig.radiusXL),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 20,
                  offset: Offset(0, -5),
                ),
              ],
            ),
            child: body,
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
        border: Border(
          left: BorderSide(
            color: isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor,
          ),
        ),
      ),
      child: body,
    );
  }

  // ── Navigate to payment screen ──

  void _goToCheckout() {
    final cart = ref.read(cartProvider);
    if (cart.isEmpty) {
      TopToast.error(context, 'Keranjang kosong');
      return;
    }
    final qp = <String, String>{};
    if (widget.sessionId != null) qp['sessionId'] = widget.sessionId.toString();
    if (NusaConfig.isFnbVariant) {
      qp['orderType'] = _orderType;
      if (_selectedTableId != null) qp['tableId'] = _selectedTableId.toString();
      if (_selectedTableName != null)
        qp['tableName'] = Uri.encodeComponent(_selectedTableName!);
    }
    // B7: draft/antrian berlaku SEMUA varian — tab yang di-save (Simpan
    // Pesanan) dikunci saat bayar di checkout.
    if (_activeTabId != null) qp['activeTabId'] = _activeTabId.toString();
    if (_routeCustomer != null && _routeCustomer!.isNotEmpty) {
      qp['customer'] = Uri.encodeComponent(_routeCustomer!);
    }
    if (_routeCustomerPhone != null && _routeCustomerPhone!.isNotEmpty) {
      qp['customerPhone'] = Uri.encodeComponent(_routeCustomerPhone!);
    }
    final uri = Uri(
      path: '/checkout',
      queryParameters: qp.isNotEmpty ? qp : null,
    );
    context.push(uri.toString());
  }

  // ── Save order (Open Tab / draft antrian) — B7: semua varian ──

  Future<void> _saveOrder() async {
    final cart = ref.read(cartProvider);
    if (cart.isEmpty) return;
    final db = ref.read(databaseProvider);
    final tabRepo = TabRepository(db);
    final items = cart
        .map(
          // v2.2.57+116: pakai toJson() penuh — harga sementara, diskon per
          // satuan, catatan, toggle struk ikut tersimpan & direstore.
          (c) => c.toJson(),
        )
        .toList();
    // v2.2.57+127: total = Σ subtotal — diskon MANUAL per satuan saja
    // (diskon produk/menu sudah di price; konsisten checkout, fix dobel).
    final total = cart.fold<int>(
      0,
      (s, e) => s + e.subtotal - e.itemDiscountTotal,
    );
    // Non-FnB: draft antrian tanpa meja/orderType — pakai label 'Draft'.
    final orderType = NusaConfig.isFnbVariant ? _orderType : 'Draft';
    await tabRepo.save(
      tableId: NusaConfig.isFnbVariant ? _selectedTableId : null,
      orderType: orderType,
      items: items,
      total: total,
    );
    if (NusaConfig.isFnbVariant && _selectedTableId != null) {
      await DiningTableRepository(
        db,
      ).updateStatus(_selectedTableId!, 'Dipesan');
    }
    _activeTabId = null;
    ref.read(cartProvider.notifier).clear();
    final savedName = _selectedTableName;
    _selectedTableId = null;
    _selectedTableName = null;
    if (mounted)
      TopToast.success(
        context,
        savedName != null
            ? 'Pesanan disimpan — $savedName'
            : 'Pesanan disimpan sebagai draft',
      );
  }

  // ── B7: Daftar pesanan tersimpan (draft/antrian) — semua varian ──

  Future<void> _showSavedOrders() async {
    final db = ref.read(databaseProvider);
    final tabs = await TabRepository(db).getOpen();
    if (!mounted) return;
    if (tabs.isEmpty) {
      TopToast.info(context, 'Belum ada pesanan tersimpan');
      return;
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                'Pesanan Tersimpan (${tabs.length})',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: isDark
                      ? NusaConfig.darkTextPrimary
                      : NusaConfig.textPrimary,
                ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: tabs.length,
                itemBuilder: (_, i) {
                  final tab = tabs[i];
                  final items = (json.decode(tab.itemsJson) as List)
                      .cast<Map<String, dynamic>>();
                  final itemCount =
                      items.fold<int>(0, (s, e) => s + (e['qty'] as int));
                  final title = NusaConfig.isFnbVariant && tab.tableId != null
                      ? 'Meja ${tab.tableId}'
                      : 'Draft #${tab.id}';
                  final sub = tab.orderType == 'Draft'
                      ? '$itemCount item · ${formatRupiah(tab.total)}'
                      : '${tab.orderType} · $itemCount item · '
                          '${formatRupiah(tab.total)}';
                  return ListTile(
                    leading: Icon(
                      Icons.bookmark_outline,
                      color: NusaConfig.activePrimary,
                    ),
                    title: Text(
                      title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    subtitle: Text(
                      sub,
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark
                            ? NusaConfig.darkTextSecondary
                            : NusaConfig.textSecondary,
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Lanjutkan',
                          icon: Icon(
                            Icons.play_arrow,
                            color: NusaConfig.activePrimary,
                          ),
                          onPressed: () {
                            Navigator.pop(ctx);
                            _loadTab(tab);
                          },
                        ),
                        IconButton(
                          tooltip: 'Hapus',
                          icon: Icon(
                            Icons.delete_outline,
                            color: Colors.red.shade400,
                          ),
                          onPressed: () async {
                            await TabRepository(db).delete(tab.id);
                            if (ctx.mounted) {
                              Navigator.pop(ctx);
                              _showSavedOrders();
                            }
                          },
                        ),
                      ],
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      _loadTab(tab);
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

  // ── FnB: Load open tab into cart ──

  Future<void> _loadTab(OpenTab tab) async {
    try {
      final items = (json.decode(tab.itemsJson) as List)
          .cast<Map<String, dynamic>>();
      final notifier = ref.read(cartProvider.notifier);
      notifier.clear();
      for (final item in items) {
        // v2.2.57+116: restore penuh (harga sementara, diskon per satuan,
        // catatan, toggle struk) — bukan cuma nama/harga/qty.
        notifier.restoreFromJson(item);
      }
      _activeTabId = tab.id;
      _selectedTableId = tab.tableId;
      _orderType = tab.orderType;
      if (tab.tableId != null &&
          _diningTables.any((t) => t.id == tab.tableId)) {
        _selectedTableName = _diningTables
            .firstWhere((t) => t.id == tab.tableId)
            .name;
      }
      setState(() {});
      if (mounted)
        TopToast.success(context, 'Pesanan dilanjutkan — $_selectedTableName');
    } catch (_) {
      if (mounted) TopToast.error(context, 'Gagal melanjutkan pesanan');
    }
  }

  // ── FnB: Note dialog per item ──

  /// Hitung harga efektif per unit dari input sheet — tempPrice (bila
  /// checkbox aktif + terisi) ganti harga normal [item.price].
  int _sheetUnitPrice(CartItem item, bool enablePrice, String priceText) {
    if (!enablePrice) return item.price;
    final v = int.tryParse(priceText.trim());
    return v ?? item.price;
  }

  /// Hitung diskon manual per unit dari input sheet (0 bila kosong/mati).
  int _sheetDiscPerItem(bool enableDisc, String discText) {
    if (!enableDisc) return 0;
    return int.tryParse(discText.trim()) ?? 0;
  }

  /// Bottom-sheet item keranjang (v2.2.57+116) — klik card produk di
  /// keranjang:
  ///   • Ubah HARGA SEMENTARA (per unit)
  ///   • Ubah DISKON per jumlah
  ///   • Tambah CATATAN
  ///   • Toggle "Informasikan di struk cetak"
  /// Semua tersimpan di [CartItem] → dibawa ke transaksi (checkout), struk
  /// cetak, reprint riwayat, dan laporan (HPP/laba tetap memakai harga jual
  /// final). Route profesional: subtotal keranjang & checkout langsung
  /// menghitung ulang (subtotal - diskon item).
  ///
  /// v2.2.57+127: PREVIEW REAL-TIME — ketik harga/diskon → efeknya langsung
  /// tampil (inline di bawah input + blok ringkasan total cart sebelum
  /// tombol Simpan), tanpa perlu simpan dulu.
  void _showItemSheet(CartItem item) {
    final priceCtrl = TextEditingController(
      text: item.tempPrice != null ? '${item.tempPrice}' : '',
    );
    final discCtrl = TextEditingController(
      text: item.discountPerItem != null ? '${item.discountPerItem}' : '',
    );
    final noteCtrl = TextEditingController(text: item.note ?? '');
    var showInReceipt = item.showInReceipt;
    // v2.2.57+120: pendekatan checkbox — user aktifkan dulu opsi yang
    // dibutuhkan, baru form muncul. Checkbox default ON bila item sudah
    // punya nilai (mis. sudah pernah diubah sebelumnya).
    var enablePrice = item.tempPrice != null;
    var enableDisc = item.discountPerItem != null;
    var enableNote = (item.note ?? '').isNotEmpty;
    final isDark =
        Theme.of(context).brightness == Brightness.dark;
    // Preview real-time (v2.2.57+127): ketik di field → setState → recompute
    // preview. Listener controller dipasang SEKALI di luar builder; setState
    // sheet diambil dari StatefulBuilder via [sheetSetState].
    StateSetter? sheetSetState;
    void refresh() => sheetSetState?.call(() {});

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        priceCtrl.addListener(refresh);
        discCtrl.addListener(refresh);
        return StatefulBuilder(
        builder: (ctx, setSt) {
          sheetSetState = setSt;
          // Preview real-time: state efektif dihitung dari input saat ini.
          int unitPriceOf() =>
              _sheetUnitPrice(item, enablePrice, priceCtrl.text);
          int discOf() => _sheetDiscPerItem(enableDisc, discCtrl.text);
          // Nominal diskon yang DIHITUNG: manual (Ubah Diskon). Diskon
          // produk (coret) sudah tercermin di price — tidak dipotong (+127).
          int itemSubtotalOf() {
            final unit = unitPriceOf() - discOf().clamp(0, unitPriceOf());
            return item.isPerKg
                ? (unit * item.weightKg!).ceil()
                : unit * item.qty;
          }

          // Selisih total cart bila perubahan disimpan vs kondisi sekarang.
          int cartDeltaOf() =>
              itemSubtotalOf() - (item.subtotal - item.itemDiscountTotal);

          // Preview inline di bawah input (harga sementara / diskon).
          Widget previewInline({required bool forPrice}) {
      final unit = unitPriceOf();
      final disc = discOf().clamp(0, unit);
      final effUnit = unit - disc;
      final lines = <Widget>[];
      if (forPrice) {
        final orig = item.originalPrice;
        lines.add(Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Harga jadi: ',
              style: TextStyle(fontSize: 11, color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary),
            ),
            Text(
              formatRupiah(effUnit),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: NusaConfig.activePrimary,
              ),
            ),
            if (orig != null && orig > effUnit) ...[
              const SizedBox(width: 4),
              Text(
                formatRupiah(orig),
                style: TextStyle(
                  fontSize: 10,
                  color: isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary,
                  decoration: TextDecoration.lineThrough,
                ),
              ),
            ],
          ],
        ));
      } else {
        lines.add(Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Diskon: ',
              style: TextStyle(fontSize: 11, color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary),
            ),
            Text(
              formatRupiah(disc),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: NusaConfig.warning,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              'Harga jadi: ',
              style: TextStyle(fontSize: 11, color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary),
            ),
            Text(
              formatRupiah(effUnit),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: NusaConfig.activePrimary,
              ),
            ),
          ],
        ));
      }
      lines.add(const SizedBox(height: 2));
      lines.add(Text(
        'Subtotal item (${item.qtyLabel}): ${formatRupiah(itemSubtotalOf())}',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary,
        ),
      ));
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: NusaConfig.activePrimary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: NusaConfig.activePrimary.withValues(alpha: 0.25),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: lines,
          ),
        ),
      );
    }

          // Blok ringkasan perubahan total cart — di atas tombol Simpan.
          Widget summaryBlock() {
            final delta = cartDeltaOf();
            final color = delta < 0
                ? NusaConfig.success
                : delta > 0
                    ? NusaConfig.warning
                    : isDark
                        ? NusaConfig.darkTextTertiary
                        : NusaConfig.textTertiary;
            return Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: isDark ? NusaConfig.darkSurface2 : NusaConfig.backgroundColor,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: NusaConfig.activePrimary.withValues(alpha: 0.2),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.receipt_long_outlined,
                    size: 16,
                    color: NusaConfig.activePrimary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Total keranjang menjadi: '
                      '${formatRupiah((ref.read(cartProvider.notifier).total + delta).clamp(0, 1 << 62))}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary,
                      ),
                    ),
                  ),
                  if (delta != 0)
                    Text(
                      '${delta > 0 ? '+' : '-'}${formatRupiah(delta.abs())}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: color,
                      ),
                    ),
                ],
              ),
            );
          }

          return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            12,
            20,
            MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
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
                SizedBox(height: 16),
                // Header: nama + subtotal saat ini (harga sementara/disc).
                Text(
                  item.displayName,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: isDark
                        ? NusaConfig.darkTextPrimary
                        : NusaConfig.textPrimary,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  '${item.qty} ${item.unitName ?? 'pcs'}'
                  '${item.isPerKg ? ' (${item.weightKg!.toStringAsFixed(1)} kg)' : ''}'
                  ' • ${formatRupiah(item.subtotal)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? NusaConfig.darkTextSecondary
                        : NusaConfig.textSecondary,
                  ),
                ),
                if (item.hasDiscount) ...[
                  SizedBox(height: 2),
                  Text(
                    'Potongan: ${formatRupiah(item.itemDiscountTotal + item.productDiscount * (item.isPerKg ? 1 : item.qty))}',
                    style: TextStyle(
                      fontSize: 11,
                      color: NusaConfig.warning,
                    ),
                  ),
                ],
                SizedBox(height: 16),
                // ── Opsi item: checkbox → form muncul saat aktif (v2.2.57+120) ──
                _buildItemOptionCheckbox(
                  icon: Icons.price_change_outlined,
                  title: 'Ubah Harga Sementara',
                  subtitle: 'Set harga jual khusus item ini (per unit)',
                  value: enablePrice,
                  onChanged: (v) => setSt(() => enablePrice = v),
                ),
                if (enablePrice) ...[
                  const SizedBox(height: 8),
                  NusaFormField(
                    label: 'Harga per unit (kosongkan = pakai harga normal)',
                    controller: priceCtrl,
                    hintText: '${item.price}',
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Harga normal: ${formatRupiah(item.price)}${item.originalPrice != null ? ' (coret ${formatRupiah(item.originalPrice!)})' : ''}',
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark
                          ? NusaConfig.darkTextTertiary
                          : NusaConfig.textTertiary,
                    ),
                  ),
                  // Preview real-time (v2.2.57+127): efek harga langsung
                  // terlihat saat mengetik.
                  previewInline(forPrice: true),
                ],
                const SizedBox(height: 6),
                _buildItemOptionCheckbox(
                  icon: Icons.discount_outlined,
                  title: 'Ubah Diskon per Jumlah',
                  subtitle: 'Ganti diskon produk dengan nominal baru per satuan',
                  value: enableDisc,
                  onChanged: (v) => setSt(() => enableDisc = v),
                ),
                if (enableDisc) ...[
                  const SizedBox(height: 8),
                  NusaFormField(
                    label: 'Diskon per satuan (Rp) — kosongkan = diskon dari menu Produk',
                    controller: discCtrl,
                    hintText: '0',
                    keyboardType: TextInputType.number,
                  ),
                  // Preview real-time (v2.2.57+127): diskon + harga jadi +
                  // subtotal item langsung terlihat.
                  previewInline(forPrice: false),
                ],
                const SizedBox(height: 6),
                _buildItemOptionCheckbox(
                  icon: Icons.notes_outlined,
                  title: 'Catatan',
                  subtitle: 'Info tambahan yang ikut tersimpan & tercetak',
                  value: enableNote,
                  onChanged: (v) => setSt(() => enableNote = v),
                ),
                if (enableNote) ...[
                  const SizedBox(height: 8),
                  NusaFormField(
                    label: 'Catatan',
                    controller: noteCtrl,
                    hintText: NusaConfig.isLaundryVariant
                        ? 'Contoh: noda di lengan kiri, kain sutra delicate'
                        : NusaConfig.isSalonVariant
                        ? 'Contoh: model two-block undercut, fade rendah'
                        : 'Contoh: tidak pedas, es batu terpisah',
                    maxLines: 2,
                  ),
                ],
                const SizedBox(height: 14),
                // ── Toggle informasikan di struk cetak ──
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: isDark
                        ? NusaConfig.darkSurface2
                        : NusaConfig.backgroundColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.receipt_long_outlined,
                        size: 18,
                        color: NusaConfig.activePrimary,
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Informasikan di struk cetak',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: isDark
                                    ? NusaConfig.darkTextPrimary
                                    : NusaConfig.textPrimary,
                              ),
                            ),
                            Text(
                              'Matikan untuk menyembunyikan detail & catatan produk ini dari struk pembelian',
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
                      Switch(
                        value: showInReceipt,
                        activeColor: NusaConfig.activePrimary,
                        onChanged: (v) => setSt(() => showInReceipt = v),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 18),
                // ── Ringkasan perubahan total (v2.2.57+127, real-time) ──
                summaryBlock(),
                SizedBox(height: 12),
                // ── Simpan ──
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: NusaConfig.activePrimary,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () {
                      final notifier = ref.read(cartProvider.notifier);
                      // Hanya simpan field yang checkbox-nya aktif; yang mati
                      // direset null (v2.2.57+120 checkbox approach).
                      notifier.setTempPrice(
                        item.productId,
                        !enablePrice
                            ? null
                            : priceCtrl.text.trim().isEmpty
                                ? null
                                : (int.tryParse(priceCtrl.text.trim()) ??
                                    item.tempPrice),
                        variantName: item.variantName,
                      );
                      notifier.setDiscountPerItem(
                        item.productId,
                        !enableDisc
                            ? null
                            : discCtrl.text.trim().isEmpty
                                ? null
                                : (int.tryParse(discCtrl.text.trim()) ??
                                    item.discountPerItem),
                        variantName: item.variantName,
                      );
                      notifier.setNote(
                        item.productId,
                        !enableNote
                            ? null
                            : noteCtrl.text.trim().isEmpty
                                ? null
                                : noteCtrl.text.trim(),
                        variantName: item.variantName,
                      );
                      notifier.setShowInReceipt(
                        item.productId,
                        showInReceipt,
                        variantName: item.variantName,
                      );
                      Navigator.pop(ctx);
                    },
                    child: const Text('Simpan'),
                  ),
                ),
                SizedBox(height: 8),
              ],
            ),
          ),
          ); // Padding — akhir return builder sheet
        }, // builder StatefulBuilder
        ); // StatefulBuilder
      }, // builder showModalBottomSheet
    );
  }
  /// ikon + judul + deskripsi. Form muncul hanya saat checkbox aktif —
  /// sheet tetap ringkas dan user yang kontrol apa yang mau diubah.
  Widget _buildItemOptionCheckbox({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: dark ? NusaConfig.darkSurface2 : NusaConfig.backgroundColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: value
              ? NusaConfig.activePrimary.withValues(alpha: 0.5)
              : Colors.transparent,
          width: 1.2,
        ),
      ),
      child: Row(
        children: [
          Checkbox(value: value, onChanged: (v) => onChanged(v ?? value)),
          Icon(icon, size: 18, color: NusaConfig.activePrimary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: dark
                        ? NusaConfig.darkTextPrimary
                        : NusaConfig.textPrimary,
                  ),
                ),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11,
                    color: dark
                        ? NusaConfig.darkTextTertiary
                        : NusaConfig.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Pilih varian produk dari keranjang (v2.2.43): modal daftar varian →
  /// nama, harga final (harga dasar + adjustment), stok varian.
  Future<void> _pickVariant(CartItem item, Product product) async {
    final variants = ProductRepository.parseVariants(product);
    if (variants.isEmpty) return;
    final selected = await showModalBottomSheet<({String name, int price, int stock})>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _VariantPickerSheet(
        product: product,
        variants: variants,
        current: item.variantName,
      ),
    );
    if (selected == null || !mounted) return;
    final notifier = ref.read(cartProvider.notifier);
    // Harga final = harga jual efektif + adjustment varian.
    final newPrice = product.effectivePrice + selected.price;
    notifier.setVariant(
      item.productId,
      selected.name,
      newPrice,
      selected.price,
      selected.stock,
    );
    // Grosir ikut dihitung ulang terhadap harga varian (B5).
    final updated = ref.read(cartProvider).cast<CartItem?>().firstWhere(
          (c) => c?.productId == item.productId &&
              c?.variantName == selected.name,
          orElse: () => null,
        );
    if (updated != null) {
      final variantBase = newPrice; // harga varian (normal)
      final variantFull = product.sellPrice + selected.price; // coret varian
      notifier.recomputeWholesale(
        item.productId,
        wholesalePriceForQty: product.wholesalePriceFor,
        normalPrice: variantBase,
        fullPrice: variantFull,
        variantName: selected.name,
      );
    }
    TopToast.success(context, 'Varian: ${item.name} — ${selected.name}');
  }

  // ── FnB: Order type chips ──

  Widget _buildOrderTypeChips(bool isDark, double padH) {
    final types = [
      {'label': 'Dine In', 'icon': Icons.table_restaurant, 'id': 'Dine In'},
      {'label': 'Takeaway', 'icon': Icons.takeout_dining, 'id': 'Takeaway'},
      {'label': 'GoFood', 'icon': Icons.delivery_dining, 'id': 'GoFood'},
    ];
    return Padding(
      padding: EdgeInsets.fromLTRB(padH, 4, padH, 4),
      child: Row(
        children: types.map((t) {
          final active = t['id'] == _orderType;
          final chipDark = Theme.of(context).brightness == Brightness.dark;
          return Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: t != types.last ? 6 : 0),
              child: GestureDetector(
                onTap: () => setState(() {
                  _orderType = t['id'] as String;
                  if (_orderType != 'Dine In') {
                    _selectedTableId = null;
                    _selectedTableName = null;
                  }
                }),
                child: AnimatedContainer(
                  duration: Duration(milliseconds: 200),
                  padding: EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: active
                        ? NusaConfig.activeSoft
                        : (chipDark
                              ? NusaConfig.darkInputFill
                              : NusaConfig.inputFill),
                    borderRadius: BorderRadius.circular(10),
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
                        t['icon'] as IconData,
                        size: 18,
                        color: active
                            ? NusaConfig.activePrimary
                            : chipDark
                            ? NusaConfig.darkTextSecondary
                            : NusaConfig.textSecondary,
                      ),
                      SizedBox(height: 2),
                      Text(
                        t['label'] as String,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: active
                              ? NusaConfig.activePrimary
                              : chipDark
                              ? NusaConfig.darkTextSecondary
                              : NusaConfig.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── FnB: Table selector ──

  Widget _buildTableSelector(bool isDark, double padH) {
    final available = _diningTables
        .where((t) => t.status == 'Kosong' || t.id == _selectedTableId)
        .toList();
    if (available.isEmpty) {
      return Padding(
        padding: EdgeInsets.fromLTRB(padH, 6, padH, 4),
        child: Text(
          'Tidak ada meja tersedia',
          style: TextStyle(
            fontSize: 11,
            color: isDark
                ? NusaConfig.darkTextTertiary
                : NusaConfig.textTertiary,
          ),
        ),
      );
    }

    final selectedLabel = _selectedTableName != null
        ? '$_selectedTableName (${_diningTables.firstWhere((t) => t.id == _selectedTableId, orElse: () => _diningTables.first).capacity})'
        : 'Tanpa Meja';

    return Padding(
      padding: EdgeInsets.fromLTRB(padH, 6, padH, 4),
      child: GestureDetector(
        onTap: () => _showTablePicker(isDark),
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _selectedTableId != null
                  ? NusaConfig.activePrimary.withOpacity(0.5)
                  : (isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor),
              width: _selectedTableId != null ? 1.5 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: (isDark ? Colors.black : NusaConfig.textTertiary)
                    .withOpacity(isDark ? 0.15 : 0.06),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _selectedTableId != null
                    ? Icons.table_restaurant
                    : Icons.table_bar_outlined,
                size: 16,
                color: _selectedTableId != null
                    ? NusaConfig.activePrimary
                    : (isDark
                          ? NusaConfig.darkTextSecondary
                          : NusaConfig.textSecondary),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  selectedLabel,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isDark
                        ? NusaConfig.darkTextPrimary
                        : NusaConfig.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 18,
                color: isDark
                    ? NusaConfig.darkTextTertiary
                    : NusaConfig.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showTablePicker(bool isDark) {
    final available = _diningTables
        .where((t) => t.status == 'Kosong' || t.id == _selectedTableId)
        .toList();
    final RenderBox button = context.findRenderObject() as RenderBox;
    final Offset offset = button.localToGlobal(Offset.zero);
    final Size size = button.size;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        offset.dx,
        offset.dy + size.height + 4,
        offset.dx + size.width,
        offset.dy + size.height + 4,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      elevation: 8,
      color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
      items: [
        // "Tanpa Meja" option
        PopupMenuItem<String>(
          value: '',
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: _tablePickerItem(
            icon: Icons.table_bar_outlined,
            label: 'Tanpa Meja',
            subtitle: 'Pesanan tanpa meja',
            isSelected: _selectedTableId == null,
            isDark: isDark,
          ),
        ),
        ...available.map((t) {
          final selected = t.id == _selectedTableId;
          return PopupMenuItem<String>(
            value: t.id.toString(),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: _tablePickerItem(
              icon: Icons.table_restaurant,
              label: t.name,
              subtitle: '${t.capacity} Kursi',
              isSelected: selected,
              isDark: isDark,
            ),
          );
        }),
      ],
    ).then((value) {
      if (value == null) return;
      if (value.isEmpty) {
        setState(() {
          _selectedTableId = null;
          _selectedTableName = null;
        });
      } else {
        final id = int.tryParse(value);
        if (id != null) {
          final t = _diningTables.firstWhere(
            (t) => t.id == id,
            orElse: () => _diningTables.first,
          );
          setState(() {
            _selectedTableId = t.id;
            _selectedTableName = t.name;
          });
        }
      }
    });
  }

  Widget _tablePickerItem({
    required IconData icon,
    required String label,
    required String subtitle,
    required bool isSelected,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      decoration: BoxDecoration(
        color: isSelected
            ? NusaConfig.activeSoft.withOpacity(isDark ? 0.2 : 0.6)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: isSelected
                  ? NusaConfig.activePrimary.withOpacity(0.12)
                  : (isDark ? NusaConfig.darkSurface2 : NusaConfig.inputFill),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              icon,
              size: 16,
              color: isSelected
                  ? NusaConfig.activePrimary
                  : (isDark
                        ? NusaConfig.darkTextSecondary
                        : NusaConfig.textSecondary),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isDark
                        ? NusaConfig.darkTextPrimary
                        : NusaConfig.textPrimary,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 10,
                    color: isDark
                        ? NusaConfig.darkTextTertiary
                        : NusaConfig.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          if (isSelected)
            Icon(
              Icons.check_circle_rounded,
              size: 18,
              color: NusaConfig.activePrimary,
            ),
        ],
      ),
    );
  }
}

// ── Product Card ──

class _ProductCard extends StatelessWidget {
  final Product product;
  final bool isDark;
  final int qtyInCart;
  final VoidCallback onAdd;
  final VoidCallback onDecrement;
  final VoidCallback onIncrement;

  /// Qty diubah manual dari kolom editable (null = non-editable, mis. per-kg).
  final ValueChanged<String>? onQtyEdited;
  _ProductCard({
    required this.product,
    required this.isDark,
    required this.qtyInCart,
    required this.onAdd,
    required this.onDecrement,
    required this.onIncrement,
    this.onQtyEdited,
  });

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return name.isNotEmpty
        ? name.substring(0, name.length >= 2 ? 2 : 1).toUpperCase()
        : '??';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final outOfStock = product.stock <= 0 && !product.isService;
    final lowStock = !outOfStock && product.stock <= product.minStock;
    final gradient = NusaConfig.catGradientFor(product.category);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(NusaConfig.radiusLG),
      child: InkWell(
        onTap: outOfStock
            ? null
            : () {
                if (qtyInCart == 0) onAdd();
              },
        borderRadius: BorderRadius.circular(NusaConfig.radiusLG),
        child: Container(
          decoration: BoxDecoration(
            color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
            borderRadius: BorderRadius.circular(NusaConfig.radiusLG),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.08),
                blurRadius: 10,
                offset: Offset(0, 3),
              ),
            ],
            border: Border.all(
              color: isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor,
            ),
          ),
          padding: EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Image (inset, square with own rounded corners) ──
              ClipRRect(
                borderRadius: BorderRadius.circular(NusaConfig.radiusSM),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Stack(
                    children: [
                      NusaProductImage(
                        imagePath: product.imagePath,
                        imageBase64: product.imageBase64,
                        width: double.infinity,
                        height: double.infinity,
                        fit: BoxFit.cover,
                        placeholder: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: gradient,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            _initials(product.name),
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                      // Stock badge top-left
                      Positioned(
                        top: 6,
                        left: 6,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: outOfStock
                                ? NusaConfig.stockOut
                                : (lowStock
                                      ? NusaConfig.stockLow
                                      : NusaConfig.surfaceColor.withValues(
                                          alpha: 0.92,
                                        )),
                            borderRadius: BorderRadius.circular(
                              NusaConfig.radiusFull,
                            ),
                          ),
                          child: Text(
                            product.isService
                                ? 'Layanan'
                                : outOfStock
                                    ? 'Habis'
                                    : '${product.stock}x',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: product.isService
                                  ? NusaConfig.activePrimary
                                  : outOfStock
                                      ? NusaConfig.stockOutText
                                      : (lowStock
                                            ? NusaConfig.stockLowText
                                            : NusaConfig.activePrimary),
                            ),
                          ),
                        ),
                      ),
                      if (product.hasDiscount)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: NusaConfig.errorSoft.withValues(
                                alpha: 0.95,
                              ),
                              borderRadius: BorderRadius.circular(
                                NusaConfig.radiusFull,
                              ),
                            ),
                            child: Text(
                              product.discountLabel,
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                color: NusaConfig.errorText,
                              ),
                            ),
                          ),
                        ),
                      if (outOfStock)
                        Container(color: Colors.white.withValues(alpha: 0.4)),
                    ],
                  ),
                ),
              ),
              SizedBox(height: 8),
              // ── Name ──
              Text(
                product.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  height: 1.25,
                  color: outOfStock
                      ? isDark
                            ? NusaConfig.darkTextTertiary
                            : NusaConfig.textTertiary
                      : (isDark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary),
                ),
              ),
              SizedBox(height: 2),
              // ── Category ──
              Text(
                product.category,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: isDark
                      ? NusaConfig.darkTextTertiary
                      : NusaConfig.textTertiary,
                ),
              ),
              SizedBox(height: 6),
              // ── Price ──
              product.hasDiscount
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          formatRupiah(product.effectivePrice),
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: NusaConfig.activePrimary,
                          ),
                        ),
                        SizedBox(width: 4),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 1),
                          child: Text(
                            formatRupiah(product.sellPrice),
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                              color: isDark
                                  ? NusaConfig.darkTextTertiary
                                  : NusaConfig.textTertiary,
                              decoration: TextDecoration.lineThrough,
                              decorationColor: isDark
                                  ? NusaConfig.darkTextTertiary
                                  : NusaConfig.textTertiary,
                            ),
                          ),
                        ),
                      ],
                    )
                  : Text(
                      formatRupiah(product.sellPrice),
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: NusaConfig.activePrimary,
                      ),
                    ),
              if (product.hasWholesale) ...[
                SizedBox(height: 3),
                Text(
                  'Grosir ${formatRupiah(product.wholesaleTiers.first.price)}'
                  ' / ≥${product.wholesaleTiers.first.minQty}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w600,
                    color: isDark
                        ? NusaConfig.darkTextSecondary
                        : NusaConfig.accentPurple,
                  ),
                ),
              ],
              SizedBox(height: 8),
              // ── Action ──
              outOfStock
                  ? Container(
                      height: 36,
                      decoration: BoxDecoration(
                        color: isDark
                            ? NusaConfig.darkSurface2
                            : NusaConfig.inputFill,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        'Stok Habis',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: isDark
                              ? NusaConfig.darkTextTertiary
                              : NusaConfig.textTertiary,
                        ),
                      ),
                    )
                  : qtyInCart == 0
                  ? NusaAddButton(onTap: onAdd, fullWidth: true)
                  : _PosQtyField(
                      qtyInCart: qtyInCart,
                      onDecrement: onDecrement,
                      onIncrement: onIncrement,
                      onChanged: onQtyEdited,
                      fullWidth: true,
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stepper "- qty +" dengan qty EDITABLE (keyboard device & fisik) — pola
/// sama di POS, Stok Masuk/Keluar, dan Catat Pembelian. Qty yang diketik
/// langsung diterapkan ke keranjang lewat [onChanged].
class _PosQtyField extends StatelessWidget {
  final int qtyInCart;
  final VoidCallback onDecrement;
  final VoidCallback onIncrement;
  final ValueChanged<String>? onChanged;
  final bool fullWidth;
  const _PosQtyField({
    required this.qtyInCart,
    required this.onDecrement,
    required this.onIncrement,
    this.onChanged,
    this.fullWidth = false,
  });

  static const double _h = 36;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final field = Container(
      height: _h,
      decoration: BoxDecoration(
        color: isDark ? NusaConfig.darkSurface2 : NusaConfig.activeSoft,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: NusaConfig.activePrimary.withValues(alpha: 0.5),
          width: 1.2,
        ),
      ),
      child: Row(
        children: [
          _btn(Icons.remove, onDecrement),
          Expanded(
            child: TextField(
              textAlign: TextAlign.center,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: NusaConfig.activePrimary,
              ),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText: '$qtyInCart',
                hintStyle: GoogleFonts.plusJakartaSans(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: NusaConfig.activePrimary,
                ),
              ),
              onChanged: onChanged,
            ),
          ),
          _btn(Icons.add, onIncrement),
        ],
      ),
    );
    return SizedBox(
      height: _h,
      width: fullWidth ? double.infinity : null,
      child: field,
    );
  }

  Widget _btn(IconData icon, VoidCallback onTap) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: _h,
        height: _h,
        child: Center(
          child: Icon(icon, size: 18, color: NusaConfig.activePrimary),
        ),
      ),
    ),
  );
}

/// Dropdown satuan jual di baris keranjang (satuan dinamis v2.2.43).
class _UnitDropdown extends StatelessWidget {
  final List<
      ({
        int unitId,
        String name,
        int? unitStock,
        double qtyPerBase,
        bool isBase
      })> units;
  final String currentName;
  final void Function(String name, double qtyPerBase) onSelected;
  const _UnitDropdown({
    required this.units,
    required this.currentName,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final current = units
        .where((u) => u.name == currentName)
        .firstOrNull;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: isDark ? NusaConfig.darkSurface2 : NusaConfig.surfaceColor,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor,
        ),
      ),
      child: PopupMenuButton<String>(
        onSelected: (name) {
          final u = units.where((e) => e.name == name).firstOrNull;
          if (u != null) onSelected(u.name, u.qtyPerBase);
        },
        itemBuilder: (_) => [
          for (final u in units)
            PopupMenuItem(
              value: u.name,
              child: Row(
                children: [
                  Icon(
                    Icons.straighten_outlined,
                    size: 14,
                    color: NusaConfig.activePrimary,
                  ),
                  SizedBox(width: 6),
                  Text(
                    u.name,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark
                          ? NusaConfig.darkTextPrimary
                          : NusaConfig.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
        ],
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.straighten_outlined,
              size: 12,
              color: NusaConfig.activePrimary,
            ),
            SizedBox(width: 4),
            Text(
              current?.name ?? currentName,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: NusaConfig.activePrimary,
              ),
            ),
            Icon(
              Icons.arrow_drop_down,
              size: 14,
              color: NusaConfig.activePrimary,
            ),
          ],
        ),
      ),
    );
  }
}

class _CartItemTile extends StatelessWidget {
  final CartItem item;
  final bool isDark;

  /// Produk punya varian → tampilkan tombol "Pilih Varian" di baris.
  final bool hasVariants;
  final VoidCallback? onSelectVariant;

  /// Satuan jual produk (v2.2.43 dinamis). Kosong = fallback 'pcs'.
  final List<
      ({
        int unitId,
        String name,
        int? unitStock,
        double qtyPerBase,
        bool isBase
      })> units;
  final void Function(String name, double qtyPerBase)? onSelectUnit;
  final VoidCallback? onDecrement, onIncrement, onTap;
  _CartItemTile({
    required this.item,
    required this.isDark,
    this.hasVariants = false,
    this.onSelectVariant,
    this.units = const [],
    this.onSelectUnit,
    this.onDecrement,
    this.onIncrement,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final qtyLabel = item.isPerKg
        ? item.weightKg!.toStringAsFixed(1)
        : '${item.qty}';
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.only(bottom: 8),
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isDark ? NusaConfig.darkBorder : NusaConfig.borderColor,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.displayName,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? NusaConfig.darkTextPrimary
                              : NusaConfig.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      SizedBox(height: 2),
                      item.hasDiscount
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  item.isPerKg
                                      ? '${formatRupiah(item.unitPrice)}/kg'
                                      : formatRupiah(item.unitPrice),
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: isDark
                                        ? NusaConfig.darkTextPrimary
                                        : NusaConfig.textPrimary,
                                  ),
                                ),
                                SizedBox(width: 4),
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 1),
                                  child: Text(
                                    item.isPerKg
                                        ? '${formatRupiah(item.originalPrice!)}/kg'
                                        : formatRupiah(item.originalPrice!),
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: isDark
                                          ? NusaConfig.darkTextTertiary
                                          : NusaConfig.textTertiary,
                                      decoration: TextDecoration.lineThrough,
                                      decorationColor: isDark
                                          ? NusaConfig.darkTextTertiary
                                          : NusaConfig.textTertiary,
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : Text(
                              item.isPerKg
                                  ? '${formatRupiah(item.unitPrice)}/kg'
                                  : formatRupiah(item.unitPrice),
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark
                                    ? NusaConfig.darkTextSecondary
                                    : NusaConfig.textSecondary,
                              ),
                            ),
                      // Varian: chip "Pilih Varian" / nama varian terpilih.
                      if (hasVariants) ...[
                        SizedBox(height: 4),
                        GestureDetector(
                          onTap: onSelectVariant,
                          child: Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: NusaConfig.activePrimary.withValues(
                                alpha: 0.1,
                              ),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.layers_outlined,
                                  size: 12,
                                  color: NusaConfig.activePrimary,
                                ),
                                SizedBox(width: 4),
                                Text(
                                  item.variantName == null
                                      ? 'Pilih Varian'
                                      : item.variantName!,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: NusaConfig.activePrimary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      // Satuan jual (v2.2.43): dropdown bila produk atur satuan.
                      if (units.isNotEmpty && onSelectUnit != null) ...[
                        SizedBox(height: 4),
                        _UnitDropdown(
                          units: units,
                          currentName: item.unitName ?? 'pcs',
                          onSelected: (name, qtyPerBase) =>
                              onSelectUnit!(name, qtyPerBase),
                        ),
                      ],
                    ],
                  ),
                ),
                Container(
                  height: 32,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: isDark
                          ? NusaConfig.darkBorder
                          : NusaConfig.dividerColor,
                    ),
                    borderRadius: BorderRadius.circular(10),
                    color: isDark
                        ? NusaConfig.darkBackground
                        : NusaConfig.backgroundColor,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GestureDetector(
                        onTap: onDecrement,
                        behavior: HitTestBehavior.opaque,
                        child: SizedBox(
                          width: 30,
                          height: 32,
                          child: Center(
                            child: Icon(
                              Icons.remove,
                              size: 16,
                              color: isDark
                                  ? NusaConfig.darkTextSecondary
                                  : NusaConfig.textSecondary,
                            ),
                          ),
                        ),
                      ),
                      Text(
                        qtyLabel,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: isDark
                              ? NusaConfig.darkTextPrimary
                              : NusaConfig.textPrimary,
                        ),
                      ),
                      GestureDetector(
                        onTap: onIncrement,
                        behavior: HitTestBehavior.opaque,
                        child: SizedBox(
                          width: 30,
                          height: 32,
                          child: Center(
                            child: Icon(
                              Icons.add,
                              size: 16,
                              color: isDark
                                  ? NusaConfig.darkTextSecondary
                                  : NusaConfig.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: 8),
                Text(
                  formatRupiah(item.subtotal),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: NusaConfig.activePrimary,
                  ),
                ),
              ],
            ),
            if (item.note != null && item.note!.isNotEmpty) ...[
              SizedBox(height: 4),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: NusaConfig.warningSoft,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.notes_rounded,
                      size: 12,
                      color: NusaConfig.warning,
                    ),
                    SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        item.note!,
                        style: TextStyle(
                          fontSize: 11,
                          color: NusaConfig.warningText,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onTap,
                icon: Icon(
                  Icons.tune_rounded,
                  size: 14,
                  color: isDark
                      ? NusaConfig.darkTextTertiary
                      : NusaConfig.textTertiary,
                ),
                label: Text(
                  item.note != null && item.note!.isNotEmpty
                      ? 'Ubah detail'
                      : 'Detail item',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark
                        ? NusaConfig.darkTextTertiary
                        : NusaConfig.textTertiary,
                  ),
                ),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Product List Card (1-column thin horizontal) ──

class _ProductListCard extends StatelessWidget {
  final Product product;
  final bool isDark;
  final int qtyInCart;
  final VoidCallback onAdd;
  final VoidCallback onDecrement;
  final VoidCallback onIncrement;
  _ProductListCard({
    required this.product,
    required this.isDark,
    required this.qtyInCart,
    required this.onAdd,
    required this.onDecrement,
    required this.onIncrement,
  });

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return name.isNotEmpty
        ? name.substring(0, name.length >= 2 ? 2 : 1).toUpperCase()
        : '??';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final outOfStock = product.stock <= 0 && !product.isService;
    final lowStock = !outOfStock && product.stock <= product.minStock;
    final gradient = NusaConfig.catGradientFor(product.category);
    return Padding(
      padding: EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(NusaConfig.radiusMD),
        child: InkWell(
          onTap: outOfStock
              ? null
              : () {
                  if (qtyInCart == 0) onAdd();
                },
          borderRadius: BorderRadius.circular(NusaConfig.radiusMD),
          child: Container(
            padding: EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
              borderRadius: BorderRadius.circular(NusaConfig.radiusMD),
              border: Border.all(
                color: isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor,
              ),
            ),
            child: Row(
              children: [
                // Thumbnail
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: NusaProductImage(
                      imagePath: product.imagePath,
                      imageBase64: product.imageBase64,
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                      placeholder: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: gradient,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          _initials(product.name),
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(width: 12),
                // Info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        product.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
                        product.category,
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark
                              ? NusaConfig.darkTextTertiary
                              : NusaConfig.textTertiary,
                        ),
                      ),
                      SizedBox(height: 2),
                      Row(
                        children: [
                          Text(
                            formatRupiah(product.sellPrice),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: NusaConfig.activePrimary,
                            ),
                          ),
                          SizedBox(width: 8),
                          Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: outOfStock
                                  ? NusaConfig.stockOut
                                  : (lowStock
                                        ? NusaConfig.stockLow
                                        : NusaConfig.stockActive),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              product.isService
                                  ? 'Layanan'
                                  : outOfStock
                                      ? 'Habis'
                                      : 'Stok ${product.stock}',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                color: product.isService
                                    ? NusaConfig.activePrimary
                                    : outOfStock
                                        ? NusaConfig.stockOutText
                                        : (lowStock
                                              ? NusaConfig.stockLowText
                                              : NusaConfig.stockActiveText),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                SizedBox(width: 8),
                // Action
                if (outOfStock)
                  SizedBox(width: 32, height: 32)
                else if (qtyInCart == 0)
                  NusaAddButton(onTap: onAdd)
                else
                  NusaQtyStepper(
                    qty: qtyInCart,
                    onDecrement: onDecrement,
                    onIncrement: onIncrement,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom-sheet daftar varian produk — pilih varian untuk item keranjang.
class _VariantPickerSheet extends StatelessWidget {
  final Product product;
  final List<({String name, int priceAdjustment, int stock})> variants;
  final String? current;
  const _VariantPickerSheet({
    required this.product,
    required this.variants,
    this.current,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(
      child: Container(
        padding: EdgeInsets.fromLTRB(20, 16, 20, 24),
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkSurface : Colors.white,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(NusaConfig.radiusXL),
          ),
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
            Text(
              'Pilih Varian — ${product.name}',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
            ...variants.map(
              (v) => GestureDetector(
                onTap: () => Navigator.pop(
                  context,
                  (
                    name: v.name,
                    price: v.priceAdjustment,
                    stock: v.stock,
                  ),
                ),
                child: Container(
                  margin: EdgeInsets.only(bottom: 8),
                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: v.name == current
                        ? NusaConfig.activePrimary.withValues(alpha: 0.1)
                        : isDark
                            ? NusaConfig.darkSurface2
                            : NusaConfig.backgroundColor,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: v.name == current
                          ? NusaConfig.activePrimary
                          : isDark
                              ? NusaConfig.darkBorder
                              : NusaConfig.dividerColor,
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              v.name,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              v.stock > 0
                                  ? 'Stok ${v.stock}'
                                  : 'Stok habis',
                              style: TextStyle(
                                fontSize: 11,
                                color: v.stock > 0
                                    ? NusaConfig.accentGreen
                                    : NusaConfig.error,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        formatRupiah(product.effectivePrice + v.priceAdjustment),
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (v.name == current) ...[
                        const SizedBox(width: 8),
                        Icon(
                          Icons.check_circle,
                          size: 18,
                          color: NusaConfig.activePrimary,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
