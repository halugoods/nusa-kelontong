import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:nusa_kasir/core/providers.dart';
import 'package:nusa_kasir/core/config/nusa_config.dart';
import 'package:nusa_kasir/core/services/delta_sync_service.dart';
import 'package:nusa_kasir/core/utils/format_rupiah.dart';
import 'package:nusa_kasir/core/utils/product_discount.dart';
import 'package:nusa_kasir/data/database/app_database.dart';
import 'package:nusa_kasir/data/repositories/settings_repository.dart';
import 'package:nusa_kasir/data/repositories/category_repository.dart';
import 'package:nusa_kasir/data/repositories/product_repository.dart';
import 'package:nusa_kasir/data/repositories/recipe_repository.dart';
import 'package:nusa_kasir/features/products/product_form_screen.dart';
import 'package:nusa_kasir/features/products/label_print_sheet.dart';
import 'package:nusa_kasir/shared/widgets/nusa_input.dart';
import 'package:nusa_kasir/shared/widgets/nusa_search_bar.dart';
import 'package:nusa_kasir/shared/widgets/nusa_product_image.dart';
import 'package:nusa_kasir/shared/widgets/unit_manager_sheet.dart';
import 'package:nusa_kasir/shared/widgets/screen_scaffold.dart';
import 'package:nusa_kasir/shared/widgets/skeleton_list.dart';
import 'package:nusa_kasir/shared/widgets/empty_state.dart';
import 'package:nusa_kasir/shared/widgets/top_toast.dart';
import 'package:nusa_kasir/shared/widgets/animated_scanner_overlay.dart';

/// Sort options.
enum _SortBy { nameAsc, nameDesc, priceHigh, priceLow }

const _sortLabels = <_SortBy, String>{
  _SortBy.nameAsc: 'Nama (A-Z)',
  _SortBy.nameDesc: 'Nama (Z-A)',
  _SortBy.priceHigh: 'Harga (Tertinggi)',
  _SortBy.priceLow: 'Harga (Terendah)',
};

/// Shared section-card style konsisten dengan checkout (B3 v2.2.44).
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

class ProductsScreen extends ConsumerStatefulWidget {
  ProductsScreen({super.key});
  @override
  ConsumerState<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends ConsumerState<ProductsScreen> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  String _statusFilter = 'Semua';
  _SortBy _sortBy = _SortBy.nameAsc;
  List<Product> _products = [];
  bool _loading = true;
  int _gridColumns = 2;
  // v2.2.43: tab menu Produk — 0=Produk, 1=Kategori, 2=Bahan Baku (F&B only).
  int _tabIndex = 0;
  // v2.2.44 (B9): reload kategori tab setelah CRUD langsung.
  int _kategoriTick = 0;
  // Legacy alias (Produk mode) — dipertahankan agar referensi lama tetap jalan.
  bool get _showKategori => _tabIndex == 1;
  /// v2.2.55: ganti tab + reload — isi list kini tergantung tab aktif
  /// (Produk = barang, Layanan = isService).
  void _switchTab(int i) {
    if (_tabIndex == i) return;
    setState(() => _tabIndex = i);
    _load();
  }
  // Increment saat bahan ditambah dari FAB → _BahanView re-init & reload.
  int _bahanTick = 0;
  List<String> labels = [];

  @override
  void initState() {
    super.initState();
    _search.addListener(_onSearchChanged);
    _initGrid();
    _load();
    // v2.2.57+136: produk/kategori dari device lain tampil tanpa pull-refresh
    // manual (edit produk di kasir langsung terlihat di device owner).
    try {
      DeltaSyncService.I.stream.listen((e) {
        if (!mounted) return;
        if (e.table == '*' ||
            e.table == 'products' ||
            e.table == 'categories') {
          _load();
        }
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _search.removeListener(_onSearchChanged);
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _initGrid() async {
    final settings = SettingsRepository(ref.read(databaseProvider));
    final cols = await settings.getProductsGridColumns();
    if (mounted) setState(() => _gridColumns = cols);
  }

  Future<void> _setGridColumns(int cols) async {
    setState(() => _gridColumns = cols);
    await SettingsRepository(
      ref.read(databaseProvider),
    ).setProductsGridColumns(cols);
  }

  void _onSearchChanged() => _load();

  /// Enter dari scanner barcode EKSTERNAL (HID): barcode eksak → buka form
  /// produk. Fokus TETAP di kolom cari supaya bisa scan beruntun tanpa tap
  /// ulang (v2.2.29).
  Future<void> _submitScanHid() async {
    final raw = _search.text.trim();
    if (raw.isEmpty) {
      _searchFocus.requestFocus();
      return;
    }
    final repo = ref.read(productRepoProvider);
    final product = await repo.byBarcode(raw);
    if (product != null && mounted) {
      _search.clear();
      await _openProductForm(productId: product.id);
    } else if (mounted) {
      TopToast.info(context, 'Produk tidak ditemukan. Coba cari manual.');
    }
    // Tetap fokus — scan berikutnya langsung jalan.
    _searchFocus.requestFocus();
  }

  /// v2.2.55: tab Layanan memakai pipeline yang SAMA dengan tab Produk —
  /// hanya filternya dibalik (isService true), jadi status chips, sort,
  /// count badge, grid 1/2/3, dan kartu berfoto identik.
  bool get _serviceTab => _tabIndex == 3 && NusaConfig.isJasaVariant;

  Future<void> _load() async {
    final repo = ref.read(productRepoProvider);
    final q = _search.text.trim().toLowerCase();
    final serviceOnly = _serviceTab;

    List<Product> all;
    if (q.isNotEmpty) {
      all = await repo.searchProducts(q);
      // B10: tab Produk = barang fisik saja; layanan pindah ke tab Layanan.
      if (NusaConfig.isJasaVariant) {
        all = all.where((p) => p.isService == serviceOnly).toList();
      }
    } else {
      all = await repo.getProducts(
        status: _statusFilter == 'Semua' ? null : _statusFilter,
        isService: NusaConfig.isJasaVariant ? serviceOnly : null,
      );
    }
    all = _sort(all);

    if (mounted) {
      setState(() {
        _products = all;
        _loading = false;
      });
    }
  }

  List<Product> _sort(List<Product> list) {
    switch (_sortBy) {
      case _SortBy.nameAsc:
        list.sort((a, b) => a.name.compareTo(b.name));
      case _SortBy.nameDesc:
        list.sort((a, b) => b.name.compareTo(a.name));
      case _SortBy.priceHigh:
        list.sort((a, b) => b.sellPrice.compareTo(a.sellPrice));
      case _SortBy.priceLow:
        list.sort((a, b) => a.sellPrice.compareTo(b.sellPrice));
    }
    return list;
  }

  // ── Barcode scan ──

  Future<void> _scanBarcode() async {
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
    String? scanned;
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
              Text('Scan Barcode Produk'),
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
                    final barcode = capture.barcodes.firstOrNull;
                    if (barcode != null && barcode.rawValue != null) {
                      scanned = barcode.rawValue;
                      Navigator.pop(ctx);
                    }
                  },
                  errorBuilder: (context, error, child) {
                    debugPrint('[Products] scanner error: $error');
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
    // Kembalikan fokus ke kolom cari — scan EKSTERNAL lanjut beruntun
    // tanpa tap ulang (v2.2.29).
    _searchFocus.requestFocus();
    if (scanned == null || !mounted) return;

    final repo = ref.read(productRepoProvider);
    final product = await repo.byBarcode(scanned!);
    if (product != null && mounted) {
      await _openProductForm(productId: product.id);
      return;
    }
    if (mounted) {
      _search.text = scanned!;
      TopToast.info(context, 'Produk tidak ditemukan. Coba cari manual.');
    }
    _searchFocus.requestFocus();
  }

  /// Buka form produk sebagai slide-up sheet (state baru).
  Future<void> _openProductForm({int? productId, bool? isService}) async {
    final result = await showProductFormSheet(
      context,
      productId: productId,
      isService: isService,
    );
    if (result != null && mounted) _load();
  }

  /// v2.2.44 (B4): "Kelola Satuan" — kamus satuan dinamis (CRUD) dari tab
  /// Produk. Reusable widget UnitManagerSheet (shared/widgets).
  Future<void> _openUnitManager() async {
    final repo = ref.read(recipeRepoProvider);
    final changed = await UnitManagerSheet.show(context: context, repo: repo);
    if (changed == true && mounted) {
      // Kamus berubah → daftar produk mungkin pakai satuan baru; reload.
      _load();
    }
  }

  Future<void> _deleteProduct(Product product) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NusaConfig.radiusXL),
        ),
        title: Text('Hapus Produk'),
        content: Text(
          'Hapus "${product.name}"?\nTindakan ini tidak dapat dibatalkan.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Batal'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: NusaConfig.activePrimary,
            ),
            child: Text('Hapus'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await ref.read(productRepoProvider).deleteProduct(product.id);
    if (mounted) {
      TopToast.success(context, 'Produk dihapus');
      _load();
    }
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ScreenScaffold(
      'Daftar Produk',
      Column(
        children: [
          // Produk-Kategori switch + grid toggle + export/import
          Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                // Produk / Kategori segment switch
                Container(
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
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _SegmentTab(
                        label: 'Produk',
                        active: _tabIndex == 0,
                        onTap: () => _switchTab(0),
                      ),
                      _SegmentTab(
                        label: 'Kategori',
                        active: _tabIndex == 1,
                        onTap: () => _switchTab(1),
                      ),
                      // v2.2.43: tab ke-3 Bahan Baku — HANYA varian F&B.
                      if (NusaConfig.isFnbVariant)
                        _SegmentTab(
                          label: 'Bahan Baku',
                          active: _tabIndex == 2,
                          onTap: () => _switchTab(2),
                        ),
                      // B10 (v2.2.44): tab Layanan — HANYA varian jasa.
                      // Varian barang: tab disembunyikan (produk jasa tidak
                      // lazim di kelontong/fnb/apotek).
                      if (NusaConfig.isJasaVariant)
                        _SegmentTab(
                          label: 'Layanan',
                          active: _tabIndex == 3,
                          onTap: () => _switchTab(3),
                        ),
                    ],
                  ),
                ),
                Spacer(),
                // Grid toggle (only when in Produk mode) — dipisah jelas dari
                // tab switch (Spacer + jarak) supaya 3 filter list/grid tidak
                // menempel pada 3-4 tab di kiri (v2.2.45).
                if (_tabIndex == 0 || _tabIndex == 3) ...[
                  Container(
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
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _GridToggleBtn(
                          icon: Icons.view_agenda_rounded,
                          active: _gridColumns == 1,
                          onTap: () => _setGridColumns(1),
                        ),
                        _GridToggleBtn(
                          icon: Icons.grid_view_rounded,
                          active: _gridColumns == 2,
                          onTap: () => _setGridColumns(2),
                        ),
                        _GridToggleBtn(
                          icon: Icons.apps_rounded,
                          active: _gridColumns == 3,
                          onTap: () => _setGridColumns(3),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: 8),
                ],
              ],
            ),
          ),
          SizedBox(height: 10),

          // Search + scan (sembunyi di tab Bahan Baku — daftar bahan punya
          // tombol aksi sendiri + barcode HID tetap jalan via ScreenScaffold).
          if (_tabIndex != 2)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              // v2.2.55: search bar standar Kasir (NusaSearchBar) — konsisten
              // dengan audit searchbar v2.2.54; HID submit + scanner dipertahankan.
              child: NusaSearchBar(
                controller: _search,
                hint: 'Cari nama atau barcode...',
                onChanged: (_) => _onSearchChanged(),
                onSubmit: (_) => _submitScanHid(),
                showScanner: true,
                onScan: _scanBarcode,
              ),
            ),

          // Content: product list, category grid, bahan baku (F&B), or layanan (jasa)
          if (_tabIndex == 2 && NusaConfig.isFnbVariant)
            Expanded(child: _BahanView(key: ValueKey(_bahanTick)))
          else if (_showKategori)
            Expanded(child: _KategoriView(key: ValueKey(_kategoriTick)))
          else ...[
            // Status chips row
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: 16),
                itemCount: 3,
                separatorBuilder: (_, __) => SizedBox(width: 8),
                itemBuilder: (_, i) {
                  labels = ['Semua', 'Aktif', 'Habis'];
                  final label = labels[i];
                  final selected = label == _statusFilter;
                  return FilterChip(
                    label: Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: selected
                            ? Colors.white
                            : isDark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary,
                      ),
                    ),
                    selected: selected,
                    showCheckmark: false,
                    selectedColor: NusaConfig.activePrimary,
                    backgroundColor: isDark
                        ? NusaConfig.darkSurface
                        : NusaConfig.surfaceColor,
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onSelected: (_) {
                      if (label != _statusFilter) {
                        setState(() => _statusFilter = label);
                        _load();
                      }
                    },
                  );
                },
              ),
            ),
            SizedBox(height: 8),
            // Sort + count
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Icon(
                    Icons.sort,
                    size: 18,
                    color: isDark
                        ? NusaConfig.darkTextSecondary
                        : NusaConfig.textSecondary,
                  ),
                  SizedBox(width: 8),
                  DropdownButtonHideUnderline(
                    child: DropdownButton<_SortBy>(
                      value: _sortBy,
                      isDense: true,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary,
                      ),
                      items: _sortLabels.entries
                          .map(
                            (e) => DropdownMenuItem(
                              value: e.key,
                              child: Text(e.value),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v != null) {
                          setState(() => _sortBy = v);
                          _load();
                        }
                      },
                    ),
                  ),
                  Spacer(),
                  if (!_loading)
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: NusaConfig.activePrimary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(
                          NusaConfig.radiusFull,
                        ),
                      ),
                      child: Text(
                        '${_products.length} ${_serviceTab ? 'layanan' : 'produk'}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: NusaConfig.activePrimary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(height: 8),
            // Product list/grid
            Expanded(
              child: _loading
                  ? SkeletonList()
                  : _products.isEmpty
                  ? EmptyState(
                      icon: _serviceTab
                          ? Icons.handyman_outlined
                          : Icons.inventory_2_outlined,
                      message: _search.text.isNotEmpty
                          ? (_serviceTab
                                ? 'Layanan tidak ditemukan'
                                : 'Produk tidak ditemukan')
                          : (_serviceTab
                                ? 'Belum ada layanan'
                                : 'Belum ada produk'),
                      actionLabel: _serviceTab
                          ? 'Tambah Layanan'
                          : 'Tambah Produk',
                      onAction: () => _serviceTab
                          ? _openProductForm(isService: true)
                          : _openProductForm(),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: _gridColumns == 1
                          ? _buildListView()
                          : _gridColumns == 2
                          ? _buildGridView()
                          : _buildMultiGridView(_gridColumns),
                    ),
            ),
          ],
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // v2.2.47: tab Bahan Baku — "Kelola Satuan" jadi icon gear (settings) kecil
          // DI ATAS tombol "+ Tambah Bahan" (bukan lagi tombol teks di
          // tengah layar / header list).
          if (_tabIndex == 2 && NusaConfig.isFnbVariant)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: FloatingActionButton.small(
                heroTag: 'kelola_satuan',
                backgroundColor: isDark
                    ? NusaConfig.darkSurface
                    : NusaConfig.surfaceColor,
                foregroundColor: NusaConfig.activePrimary,
                tooltip: 'Kelola Satuan',
                onPressed: _openUnitManager,
                child: const Icon(Icons.settings, size: 20),
              ),
            ),
          FloatingActionButton.extended(
            backgroundColor: NusaConfig.activePrimary,
            foregroundColor: Colors.white,
            icon: Icon(_tabIndex == 1
                ? Icons.create_new_folder
                : _tabIndex == 3
                    ? Icons.handyman_outlined
                    : Icons.add),
            label: Text(_tabIndex == 1
                ? 'Tambah Kategori'
                : _tabIndex == 3
                    ? 'Tambah Layanan'
                    : _tabIndex == 2
                        ? 'Tambah Bahan'
                        : 'Tambah Produk'),
            onPressed: () async {
              if (_tabIndex == 1) {
                await showAddCategoryDialog(
                  context,
                  ref.read(databaseProvider),
                  onChanged: () {
                    if (mounted) setState(() => _kategoriTick++);
                  },
                );
              } else if (_tabIndex == 3) {
                final saved = await showProductFormSheet(
                  context,
                  isService: true,
                );
                if (saved != null && mounted) {
                  TopToast.success(context, 'Layanan disimpan');
                  setState(() => _kategoriTick++);
                }
              } else if (_tabIndex == 2) {
                await showAddBahanSheet(context, ref.read(databaseProvider));
                if (mounted) setState(() => _bahanTick++);
              } else {
                _openProductForm();
              }
            },
          ),
        ],
      ),
      // v2.2.57+115 (Area B): cetak label barcode — TSPL / struk 58mm / PDF.
      actions: [
        IconButton(
          icon: const Icon(Icons.print_outlined),
          tooltip: 'Cetak Label',
          onPressed: () => LabelPrintSheet.show(context),
        ),
      ],
      onBarcode: _onExternalBarcode,
    );
  }

  /// Barcode eksternal (HID) — v2.2.43: scan jalan otomatis tanpa tap kolom
  /// cari. Reuse _submitScanHid via buffer kolom cari.
  Future<void> _onExternalBarcode(String code) async {
    final norm = ProductRepository.normalizeBarcode(code);
    if (norm.isEmpty) return;
    // Tab Kategori: scan barcode PRODUK → buka kategori produk tsb (B6).
    if (_tabIndex == 1) {
      final repo = ref.read(productRepoProvider);
      final product = await repo.byBarcode(norm);
      if (product != null && mounted) {
        context.push('/produk/kategori/${product.category}');
        return;
      }
      if (mounted) {
        TopToast.info(context, 'Barcode tidak terdaftar di produk mana pun.');
      }
      return;
    }
    _search.text = norm;
    if (mounted) setState(() {});
    await _submitScanHid();
  }

  // 1-column list view (thin horizontal cards)
  Widget _buildListView() {
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 80),
      itemCount: _products.length,
      separatorBuilder: (_, __) => SizedBox(height: 8),
      itemBuilder: (_, i) => _ProductListCard(
        product: _products[i],
        onEdit: () => _openProductForm(productId: _products[i].id),
        onDelete: () => _deleteProduct(_products[i]),
        onTogglePriceType: () => _togglePriceType(_products[i]),
      ),
    );
  }

  // 2-column grid view
  Widget _buildGridView() {
    final colW = (MediaQuery.of(context).size.width - 32 - 10) / 2;
    // Tinggi sel = gambar kotak (colW) + konten bawah (nama 2 baris, kategori,
    // barcode, harga, aksi) + padding. Diperbesar dari (colW+110) supaya gambar
    // TIDAK menciut (v2.2.57+116): sel yang terlalu pendek bikin gambar
    // dibatasi, terlalu tinggi bikin card lega. 150 = buffer aman 2 baris nama
    // + barcode + aksi 32px.
    final ratio = (colW / (colW + 150)).clamp(0.42, 0.75);
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 80),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: ratio,
      ),
      itemCount: _products.length,
      itemBuilder: (_, i) => _ProductGridCard(
        product: _products[i],
        onEdit: () => _openProductForm(productId: _products[i].id),
        onDelete: () => _deleteProduct(_products[i]),
        onTogglePriceType: () => _togglePriceType(_products[i]),
      ),
    );
  }

  // N-column grid view (3+)
  Widget _buildMultiGridView(int columns) {
    final colW =
        (MediaQuery.of(context).size.width - 32 - 10 * (columns - 1)) / columns;
    // Sama dengan grid 2 kolom: konten bawah (nama/kategori/barcode/harga/aksi)
    // perlu ruang tetap, gambar kotak mengikuti lebar colW (tidak menciut).
    final ratio = (colW / (colW + 150)).clamp(0.42, 0.75);
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 80),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: ratio,
      ),
      itemCount: _products.length,
      itemBuilder: (_, i) => _ProductGridCard(
        product: _products[i],
        onEdit: () => _openProductForm(productId: _products[i].id),
        onDelete: () => _deleteProduct(_products[i]),
        onTogglePriceType: () => _togglePriceType(_products[i]),
      ),
    );
  }

  Future<void> _togglePriceType(Product product) async {
    final newType = product.priceType == 'kg' ? 'pcs' : 'kg';
    await ref.read(productRepoProvider).setPriceType(product.id, newType);
    TopToast.success(
      context,
      newType == 'kg' ? 'Harga per kg' : 'Harga per pcs',
    );
    _load();
  }

// v2.2.54: toggle jasa<->produk di kartu DIHAPUS — penandaan layanan
  // sekarang lewat flag isService di form produk (tab Layanan).
}

// ── Segment Tab ──

class _SegmentTab extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  _SegmentTab({required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: active ? NusaConfig.activePrimary : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: active
                ? Colors.white
                : (isDark
                      ? NusaConfig.darkTextSecondary
                      : NusaConfig.textSecondary),
          ),
        ),
      ),
    );
  }
}

// ── Grid Toggle Button ──

class _GridToggleBtn extends StatelessWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  _GridToggleBtn({
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 34,
        decoration: BoxDecoration(
          color: active ? NusaConfig.activeSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          icon,
          size: 18,
          color: active
              ? NusaConfig.activePrimary
              : isDark
              ? NusaConfig.darkTextTertiary
              : NusaConfig.textTertiary,
        ),
      ),
    );
  }
}

// ── Kategori View (inline) ──

// ── B9 (v2.2.44): Kategori CRUD langsung di tab ──
// Dialog tambah kategori top-level (dipakai FAB tab Kategori + menu long-press).
// onChanged dipanggil setelah sukses supaya _KategoriView reload via tick.
Future<void> showAddCategoryDialog(
  BuildContext context,
  AppDatabase db, {
  VoidCallback? onChanged,
}) async {
  final ctrl = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Tambah Kategori'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'Nama kategori',
          border: OutlineInputBorder(),
        ),
        textCapitalization: TextCapitalization.words,
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          style: ElevatedButton.styleFrom(
            backgroundColor: NusaConfig.activePrimary,
            foregroundColor: Colors.white,
          ),
          child: const Text('Simpan'),
        ),
      ],
    ),
  );
  if (name == null || name.isEmpty) return;
  await CategoryRepository(db).add(name);
  if (context.mounted) TopToast.success(context, 'Kategori "$name" ditambahkan');
  onChanged?.call();
}

/// Dialog ubah nama kategori (dipakai menu long-press).
Future<void> _renameCategoryDialog(
  BuildContext context,
  AppDatabase db,
  String oldName, {
  VoidCallback? onChanged,
}) async {
  final ctrl = TextEditingController(text: oldName);
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Ubah Nama Kategori'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'Nama baru',
          border: OutlineInputBorder(),
        ),
        textCapitalization: TextCapitalization.words,
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          style: ElevatedButton.styleFrom(
            backgroundColor: NusaConfig.activePrimary,
            foregroundColor: Colors.white,
          ),
          child: const Text('Simpan'),
        ),
      ],
    ),
  );
  if (result == null || result.isEmpty || result == oldName) return;
  await CategoryRepository(db).rename(oldName, result);
  // Update referensi kategori di produk.
  final affected = await (db.select(db.products)
        ..where((t) => t.category.equals(oldName)))
      .get();
  await (db.update(db.products)..where((t) => t.category.equals(oldName)))
      .write(ProductsCompanion(category: Value(result)));
  for (final p in affected) {
    DeltaSyncService.I.pushDelta(
      table: 'products',
      recordId: p.id.toString(),
      operation: 'UPDATE',
      data: {'id': p.id, 'category': result},
    );
  }
  if (context.mounted) TopToast.success(context, 'Kategori diubah ke "$result"');
  onChanged?.call();
}

/// Hapus kategori — produk dipindah ke "Lainnya".
Future<void> _deleteCategoryDialog(
  BuildContext context,
  AppDatabase db,
  String name, {
  VoidCallback? onChanged,
}) async {
  final confirm = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Hapus Kategori'),
      content: Text(
        'Hapus kategori "$name"? Produk dengan kategori ini akan dipindah ke "Lainnya".',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: ElevatedButton.styleFrom(
            backgroundColor: NusaConfig.error,
            foregroundColor: Colors.white,
          ),
          child: const Text('Hapus'),
        ),
      ],
    ),
  );
  if (confirm != true) return;
  final affected = await (db.select(db.products)
        ..where((t) => t.category.equals(name)))
      .get();
  await (db.update(db.products)..where((t) => t.category.equals(name)))
      .write(ProductsCompanion(category: Value('Lainnya')));
  for (final p in affected) {
    DeltaSyncService.I.pushDelta(
      table: 'products',
      recordId: p.id.toString(),
      operation: 'UPDATE',
      data: {'id': p.id, 'category': 'Lainnya'},
    );
  }
  await CategoryRepository(db).delete(name);
  if (context.mounted) TopToast.success(context, 'Kategori "$name" dihapus');
  onChanged?.call();
}

/// Tab Kategori di menu Produk — CRUD langsung:
/// tap → buka isi kategori; long-press → ubah nama / hapus.
class _KategoriView extends ConsumerStatefulWidget {
  const _KategoriView({super.key});
  @override
  ConsumerState<_KategoriView> createState() => _KategoriViewState();
}

class _KategoriViewState extends ConsumerState<_KategoriView> {
  Map<String, int> _counts = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final counts = await ref.read(productRepoProvider).categoryProductCounts();
    if (mounted)
      setState(() {
        _counts = counts;
        _loading = false;
      });
  }

  /// Menu long-press: Ubah Nama / Hapus.
  void _showCategoryMenu(String cat) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: NusaConfig.dividerColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Text(
            cat,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary,
            ),
          ),
          const SizedBox(height: 16),
          ListTile(
            leading: Icon(Icons.edit_rounded, color: NusaConfig.activePrimary),
            title: const Text('Ubah Nama'),
            onTap: () {
              Navigator.pop(ctx);
              _renameCategoryDialog(context, ref.read(databaseProvider), cat,
                  onChanged: () => setState(() {}));
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_rounded, color: NusaConfig.error),
            title: Text('Hapus Kategori', style: TextStyle(color: NusaConfig.error)),
            onTap: () {
              Navigator.pop(ctx);
              _deleteCategoryDialog(context, ref.read(databaseProvider), cat,
                  onChanged: () => setState(() {}));
            },
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (_loading) return Center(child: CircularProgressIndicator());
    final cats = _counts.entries.toList();
    if (cats.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.category_outlined,
              size: 48,
              color: isDark
                  ? NusaConfig.darkTextTertiary
                  : NusaConfig.textTertiary,
            ),
            const SizedBox(height: 8),
            Text(
              'Belum ada kategori',
              style: TextStyle(
                color: isDark
                    ? NusaConfig.darkTextSecondary
                    : NusaConfig.textSecondary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Tekan Tambah Kategori untuk mulai',
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
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 80),
        itemCount: cats.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) {
          final cat = cats[i].key;
          final count = cats[i].value;
          final emoji = NusaConfig.catEmojiFor(cat);
          final gradient = NusaConfig.catGradientFor(cat);
          return GestureDetector(
            onTap: () => context.push('/produk/kategori/$cat'),
            onLongPress: () => _showCategoryMenu(cat),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: isDark
                    ? NusaConfig.darkSurface
                    : NusaConfig.surfaceColor,
                borderRadius: BorderRadius.circular(NusaConfig.radiusMD),
                border: Border.all(
                  color: isDark
                      ? NusaConfig.darkBorder
                      : NusaConfig.dividerColor,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: gradient,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: Text(emoji, style: const TextStyle(fontSize: 20)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          cat,
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
                          '$count produk',
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark
                                ? NusaConfig.darkTextSecondary
                                : NusaConfig.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: () => _showCategoryMenu(cat),
                    child: Icon(
                      Icons.more_vert,
                      size: 20,
                      color: isDark
                          ? NusaConfig.darkTextTertiary
                          : NusaConfig.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ── Bahan Baku View (F&B) — tab ke-3 menu Produk ──

/// Helper FAB "Tambah Bahan": buka sheet form bahan baru (F&B).
/// Dipanggil dari FloatingActionButton — form-nya top-level supaya bisa
/// dipakai tanpa perlu GlobalKey ke [_BahanViewState].
Future<void> showAddBahanSheet(BuildContext context, AppDatabase db) async {
  final saved = await _BahanFormSheet.show(
    context: context,
    db: db,
    units: await RecipeRepository(db).getUnits(),
    materials: await RecipeRepository(db).getMaterials(),
  );
  if (saved && context.mounted) TopToast.success(context, 'Bahan disimpan');
}

/// Daftar bahan baku (raw material) + aksi "Pembelian" (fast-track ke
/// Catat Pembelian → stok & HPP ikut update) + "Stok Masuk" (tambah stok
/// cepat, TANPA ubah HPP). Hanya varian F&B.
class _BahanView extends ConsumerStatefulWidget {
  const _BahanView({super.key});
  @override
  ConsumerState<_BahanView> createState() => _BahanViewState();
}

class _BahanViewState extends ConsumerState<_BahanView> {
  List<RawMaterial> _materials = [];
  Map<int, String> _unitNames = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(recipeRepoProvider);
    final materials = await repo.getMaterials();
    final units = await repo.getUnits();
    if (!mounted) return;
    setState(() {
      _materials = materials;
      _unitNames = {for (final u in units) u.id: u.name};
      _loading = false;
    });
  }

  Future<void> _openForm({RawMaterial? material}) async {
    final repo = ref.read(recipeRepoProvider);
    final units = await repo.getUnits();
    final saved = await _BahanFormSheet.show(
      context: context,
      db: ref.read(databaseProvider),
      units: units,
      materials: _materials,
      material: material,
    );
    if (saved && mounted) {
      TopToast.success(
        context,
        material == null ? 'Bahan disimpan' : 'Bahan diperbarui',
      );
      await _load();
    }
  }

  Future<void> _stokMasuk(RawMaterial m) async {
    final repo = ref.read(recipeRepoProvider);
    final qty = await _promptStokMasuk(m);
    if (qty == null || qty <= 0) return;
    await repo.addMaterialStock(m.id, qty);
    if (mounted) {
      TopToast.success(context, 'Stok ${m.name} bertambah $qty');
      await _load();
    }
  }

  Future<double?> _promptStokMasuk(RawMaterial m) {
    final ctrl = TextEditingController(text: '1');
    return showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _StokMasukSheet(material: m, controller: ctrl),
    );
  }

  Future<void> _deleteBahan(RawMaterial m) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NusaConfig.radiusXL),
        ),
        title: const Text('Hapus Bahan'),
        content: Text('Hapus "${m.name}"?\nTindakan ini tidak dapat dibatalkan.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: NusaConfig.activePrimary,
            ),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await ref.read(recipeRepoProvider).deleteMaterial(m.id);
    if (mounted) {
      TopToast.success(context, 'Bahan dihapus');
      await _load();
    }
  }

  /// v2.2.44 (B3): tap baris bahan → sheet detail (pola app), bukan popup menu.
  /// Aksi edit/hapus/pembelian/stok masuk tersedia di dalam sheet.
  Future<void> _openDetail(RawMaterial m) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _BahanDetailSheet(
        material: m,
        unitName: _unitNames[m.unitId] ?? '',
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'edit':
        await _openForm(material: m);
      case 'hapus':
        await _deleteBahan(m);
      case 'pembelian':
        if (mounted) context.push('/pembelian');
      case 'stok':
        if (mounted) await _stokMasuk(m);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_materials.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.inventory_2_outlined,
              size: 48,
              color: isDark
                  ? NusaConfig.darkTextTertiary
                  : NusaConfig.textTertiary,
            ),
            const SizedBox(height: 8),
            Text(
              'Belum ada bahan baku',
              style: TextStyle(
                color: isDark
                    ? NusaConfig.darkTextSecondary
                    : NusaConfig.textSecondary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Tambah bahan lalu catat pembeliannya',
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
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 80),
        itemCount: _materials.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) {
          final m = _materials[i];
          return _BahanCard(
            material: m,
            unitName: _unitNames[m.unitId] ?? '',
            onEdit: () => _openDetail(m),
            onDelete: () => _openDetail(m),
            onPembelian: () => context.push('/pembelian'),
            onStokMasuk: () => _stokMasuk(m),
          );
        },
      ),
    );
  }
}

/// Kartu satu bahan: nama + satuan + stok + modal + 2 tombol aksi.
class _BahanCard extends StatelessWidget {
  final RawMaterial material;
  final String unitName;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onPembelian;
  final VoidCallback onStokMasuk;
  _BahanCard({
    required this.material,
    required this.unitName,
    required this.onEdit,
    required this.onDelete,
    required this.onPembelian,
    required this.onStokMasuk,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lowStock =
        material.minStock > 0 && material.stock <= material.minStock;

    return GestureDetector(
      onTap: onEdit,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
          borderRadius: BorderRadius.circular(NusaConfig.radiusMD),
          border: Border.all(
            color: isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: NusaConfig.accentGreen.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.eco_outlined,
                    color: NusaConfig.accentGreen,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        material.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Modal ${formatRupiah(material.costPrice)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? NusaConfig.darkTextSecondary
                              : NusaConfig.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                // v2.2.44 (B3): tap baris → detail sheet; chevron sebagai
                // affordance (bukan popup menu).
                Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: isDark
                      ? NusaConfig.darkTextTertiary
                      : NusaConfig.textTertiary,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  lowStock
                      ? Icons.warning_amber_rounded
                      : Icons.inventory_2_outlined,
                  size: 16,
                  color: lowStock
                      ? const Color(0xFFF59E0B)
                      : isDark
                          ? NusaConfig.darkTextTertiary
                          : NusaConfig.textTertiary,
                ),
                const SizedBox(width: 6),
                Text(
                  'Stok ${material.stock}'
                  '${unitName.isNotEmpty ? ' $unitName' : ''}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: lowStock
                        ? const Color(0xFFF59E0B)
                        : isDark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _ActionBtn(
                    icon: Icons.shopping_cart_outlined,
                    label: 'Pembelian',
                    filled: false,
                    onTap: onPembelian,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ActionBtn(
                    icon: Icons.add_circle_outline,
                    label: 'Stok Masuk',
                    filled: true,
                    onTap: onStokMasuk,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool filled;
  final VoidCallback onTap;
  _ActionBtn({
    required this.icon,
    required this.label,
    required this.filled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          color: filled ? NusaConfig.activePrimary : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: filled
              ? null
              : Border.all(color: NusaConfig.activePrimary, width: 1.2),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 18,
              color: filled ? Colors.white : NusaConfig.activePrimary,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: filled ? Colors.white : NusaConfig.activePrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Sheet detail bahan (v2.2.44 B3): tap baris → lihat info + aksi.
/// Return String aksi: 'edit' | 'hapus' | 'pembelian' | 'stok'.
class _BahanDetailSheet extends StatelessWidget {
  final RawMaterial material;
  final String unitName;
  const _BahanDetailSheet({required this.material, required this.unitName});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lowStock =
        material.minStock > 0 && material.stock <= material.minStock;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkSurface : Colors.white,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(NusaConfig.radiusXL)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Drag handle ──
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
            const SizedBox(height: 14),
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: NusaConfig.accentGreen.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.eco_outlined,
                    color: NusaConfig.accentGreen,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        material.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Bahan Baku',
                        style: TextStyle(
                          fontSize: 12,
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
            const SizedBox(height: 16),
            // ── Info card ──
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: _sectionCard(isDark),
              child: Column(
                children: [
                  _InfoRow(
                    label: 'Stok saat ini',
                    value: '${material.stock}'
                        '${unitName.isNotEmpty ? ' $unitName' : ''}',
                    valueColor: lowStock
                        ? const Color(0xFFF59E0B)
                        : null,
                  ),
                  const Divider(height: 16),
                  _InfoRow(
                    label: 'Stok minimal',
                    value: '${material.minStock}'
                        '${unitName.isNotEmpty ? ' $unitName' : ''}',
                  ),
                  const Divider(height: 16),
                  _InfoRow(
                    label: 'Harga modal (HPP)',
                    value: formatRupiah(material.costPrice),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // ── Aksi ──
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.pop(context, 'edit'),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Edit'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.pop(context, 'pembelian'),
                    icon: const Icon(Icons.shopping_cart_outlined, size: 18),
                    label: const Text('Pembelian'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => Navigator.pop(context, 'stok'),
                    icon: const Icon(Icons.add_circle_outline, size: 18),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: NusaConfig.activePrimary,
                      foregroundColor: Colors.white,
                    ),
                    label: const Text('Stok Masuk'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.pop(context, 'hapus'),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: NusaConfig.error,
                    ),
                    label: const Text('Hapus'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  const _InfoRow({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
            fontWeight: FontWeight.w700,
            color: valueColor ??
                (isDark
                    ? NusaConfig.darkTextPrimary
                    : NusaConfig.textPrimary),
          ),
        ),
      ],
    );
  }
}

/// Bottom-sheet form tambah/edit bahan baku.
class _BahanFormSheet extends StatefulWidget {
  final db;
  final List<Unit> units;
  final List<RawMaterial> materials;
  final RawMaterial? material;
  const _BahanFormSheet({
    required this.db,
    required this.units,
    required this.materials,
    this.material,
  });

  static Future<bool> show({
    required BuildContext context,
    required AppDatabase db,
    required List<Unit> units,
    required List<RawMaterial> materials,
    RawMaterial? material,
  }) async {
    final res = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _BahanFormSheet(
        db: db,
        units: units,
        materials: materials,
        material: material,
      ),
    );
    return res ?? false;
  }

  @override
  State<_BahanFormSheet> createState() => _BahanFormSheetState();
}

class _BahanFormSheetState extends State<_BahanFormSheet> {
  late final _name = TextEditingController(text: widget.material?.name ?? '');
  late final _stock = TextEditingController(
    text: (widget.material?.stock ?? 0).toString(),
  );
  late final _minStock = TextEditingController(
    text: (widget.material?.minStock ?? 0).toString(),
  );
  late final _cost = TextEditingController(
    text: (widget.material?.costPrice ?? 0).toString(),
  );
  int? _unitId;
  String? _error;

  @override
  void initState() {
    super.initState();
    _unitId = widget.material?.unitId;
  }

  @override
  void dispose() {
    _name.dispose();
    _stock.dispose();
    _minStock.dispose();
    _cost.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Nama bahan wajib diisi');
      return;
    }
    final repo = RecipeRepository(widget.db);
    if (widget.material == null) {
      await repo.addMaterial(
        name: name,
        unitId: _unitId,
        stock: int.tryParse(_stock.text) ?? 0,
        minStock: int.tryParse(_minStock.text) ?? 0,
        costPrice: int.tryParse(_cost.text.replaceAll(RegExp(r'[^\d]'), '')) ?? 0,
      );
    } else {
      await repo.updateMaterial(
        widget.material!.id,
        name: name,
        unitId: _unitId == null ? null : _unitId,
        minStock: int.tryParse(_minStock.text) ?? 0,
        costPrice:
            int.tryParse(_cost.text.replaceAll(RegExp(r'[^\d]'), '')) ?? 0,
      );
    }
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: Container(
        padding: EdgeInsets.fromLTRB(20, 12, 20, 16 + bottom),
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkSurface : Colors.white,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(NusaConfig.radiusXL)),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Drag handle ──
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
              const SizedBox(height: 14),
              Text(
                widget.material == null ? 'Tambah Bahan Baku' : 'Edit Bahan Baku',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 16),
              // ── Bagian 1: identitas & satuan ──
              Container(
                padding: const EdgeInsets.all(14),
                decoration: _sectionCard(isDark),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Informasi Bahan',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? NusaConfig.darkTextSecondary
                            : NusaConfig.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 12),
                    NusaInput(
                      'Nama bahan',
                      controller: _name,
                      hint: 'cth: Tepung terigu',
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int?>(
                      value: _unitId,
                      decoration: InputDecoration(
                        labelText: 'Satuan (dari kamus satuan)',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      items: [
                        const DropdownMenuItem<int?>(
                          value: null,
                          child: Text('Pilih satuan'),
                        ),
                        ...widget.units.map(
                          (u) => DropdownMenuItem<int?>(
                            value: u.id,
                            child: Text(u.name),
                          ),
                        ),
                      ],
                      onChanged: (v) => setState(() => _unitId = v),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // ── Bagian 2: harga & stok ──
              Container(
                padding: const EdgeInsets.all(14),
                decoration: _sectionCard(isDark),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Harga & Stok',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? NusaConfig.darkTextSecondary
                            : NusaConfig.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 12),
                    NusaInput(
                      'Harga modal (HPP per satuan)',
                      controller: _cost,
                      type: TextInputType.number,
                      hint: '0',
                    ),
                    const SizedBox(height: 12),
                    NusaInput(
                      'Stok awal',
                      controller: _stock,
                      type: TextInputType.number,
                      hint: '0',
                    ),
                    const SizedBox(height: 12),
                    NusaInput(
                      'Stok minimal (peringatan)',
                      controller: _minStock,
                      type: TextInputType.number,
                      hint: '0',
                    ),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.red, fontSize: 13),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Batal'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _save,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: NusaConfig.activePrimary,
                        foregroundColor: Colors.white,
                      ),
                      child: Text(widget.material == null ? 'Simpan' : 'Perbarui'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Sheet "Stok Masuk" — tambah stok cepat, TANPA supplier/ubah HPP.
class _StokMasukSheet extends StatefulWidget {
  final RawMaterial material;
  final TextEditingController controller;
  const _StokMasukSheet({required this.material, required this.controller});

  @override
  State<_StokMasukSheet> createState() => _StokMasukSheetState();
}

class _StokMasukSheetState extends State<_StokMasukSheet> {
  double _qty = 1;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final unit = widget.material.unitId != null
        ? widget.material.unitId!.toString()
        : '';
    return SafeArea(
      child: Container(
        padding: EdgeInsets.fromLTRB(20, 12, 20, 16 + bottom),
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkSurface : Colors.white,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(NusaConfig.radiusXL)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Drag handle ──
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
            const SizedBox(height: 14),
            Text(
              'Stok Masuk — ${widget.material.name}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Menambah stok bahan tanpa mengubah harga modal (HPP).',
              style: TextStyle(
                fontSize: 12,
                color: isDark
                    ? NusaConfig.darkTextSecondary
                    : NusaConfig.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: _sectionCard(isDark),
              child: NusaInput(
                'Jumlah (${unit.isNotEmpty ? unit : 'unit'})',
                controller: widget.controller,
                type: const TextInputType.numberWithOptions(decimal: true),
                hint: 'cth: 1.5',
                onChanged: (v) => _qty = double.tryParse(v) ?? 0,
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.pop(context, _qty > 0 ? _qty : null);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: NusaConfig.activePrimary,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Tambah Stok'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Product Grid Card (2-column) ──

class _ProductGridCard extends StatelessWidget {
  final Product product;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onTogglePriceType;
  _ProductGridCard({
    required this.product,
    required this.onEdit,
    required this.onDelete,
    this.onTogglePriceType,
  });

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.isNotEmpty
        ? name.substring(0, name.length >= 2 ? 2 : 1).toUpperCase()
        : '??';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final outOfStock = product.stock <= 0;
    final gradient = NusaConfig.catGradientFor(product.category);

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(NusaConfig.radiusLG),
      child: InkWell(
        onTap: onEdit,
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
          padding: EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Image (inset) — kotak selebar card (ukuran semula).
              // JANGAN dibungkus Expanded: sel grid dibuat lebih tinggi lewat
              // childAspectRatio supaya konten bawah (nama/barcode/harga/aksi)
              // selalu muat tanpa membuat gambar menciut (v2.2.57+116 fix).
              ClipRRect(
                borderRadius: BorderRadius.circular(NusaConfig.radiusSM),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Stack(
                    fit: StackFit.expand,
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
                                : (product.stock <= product.minStock
                                      ? NusaConfig.stockLow
                                      : NusaConfig.surfaceColor
                                          .withValues(alpha: 0.92)),
                            borderRadius: BorderRadius.circular(
                              NusaConfig.radiusFull,
                            ),
                          ),
                          child: Text(
                            outOfStock ? 'Habis' : '${product.stock}x',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: outOfStock
                                  ? NusaConfig.stockOutText
                                  : (product.stock <= product.minStock
                                        ? NusaConfig.stockLowText
                                        : NusaConfig.activePrimary),
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
                  color: isDark
                      ? NusaConfig.darkTextPrimary
                      : NusaConfig.textPrimary,
                ),
              ),
              SizedBox(height: 2),
              // ── Category ──
              Text(
                product.category,
                style: TextStyle(
                  fontSize: 11,
                  color: isDark
                      ? NusaConfig.darkTextTertiary
                      : NusaConfig.textTertiary,
                ),
              ),
              // ── Kode barcode (v2.2.57+115) — cek cepat tanpa buka edit ──
              if (product.barcode != null && product.barcode!.isNotEmpty) ...[
                SizedBox(height: 2),
                Text(
                  '• ${product.barcode}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: isDark
                        ? NusaConfig.darkTextTertiary
                        : NusaConfig.textTertiary,
                  ),
                ),
              ],
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
              Spacer(),
              // ── Actions ──
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (NusaConfig.isLaundryVariant &&
                      onTogglePriceType != null) ...[
                    _ActionButton(
                      icon: product.priceType == 'kg'
                          ? Icons.scale_rounded
                          : Icons.inventory_2_rounded,
                      color: product.priceType == 'kg'
                          ? NusaConfig.accentPurple
                          : (isDark
                                ? NusaConfig.darkTextSecondary
                                : NusaConfig.textSecondary),
                      onTap: onTogglePriceType!,
                    ),
                    SizedBox(width: 6),
                  ],
                  _ActionButton(
                    icon: Icons.edit_outlined,
                    color: isDark
                        ? NusaConfig.darkTextSecondary
                        : NusaConfig.textSecondary,
                    onTap: onEdit,
                  ),
                  SizedBox(width: 6),
                  _ActionButton(
                    icon: Icons.delete_outline,
                    color: NusaConfig.error,
                    onTap: onDelete,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Product List Card (1-column, thin horizontal) ──

class _ProductListCard extends StatelessWidget {
  final Product product;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onTogglePriceType;
  _ProductListCard({
    required this.product,
    required this.onEdit,
    required this.onDelete,
    this.onTogglePriceType,
  });

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.isNotEmpty
        ? name.substring(0, name.length >= 2 ? 2 : 1).toUpperCase()
        : '??';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final outOfStock = product.stock <= 0;
    final gradient = NusaConfig.catGradientFor(product.category);

    return GestureDetector(
      onTap: onEdit,
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
                width: 60,
                height: 60,
                child: NusaProductImage(
                  imagePath: product.imagePath,
                  imageBase64: product.imageBase64,
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
                        fontSize: 20,
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
                      fontWeight: FontWeight.w700,
                      color: isDark
                          ? NusaConfig.darkTextPrimary
                          : NusaConfig.textPrimary,
                    ),
                  ),
                  SizedBox(height: 3),
                  Row(
                    children: [
                      Text(
                        product.category,
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark
                              ? NusaConfig.darkTextSecondary
                              : NusaConfig.textSecondary,
                        ),
                      ),
                      SizedBox(width: 8),
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: outOfStock
                              ? NusaConfig.stockOut
                              : (product.stock <= product.minStock
                                    ? NusaConfig.stockLow
                                    : NusaConfig.stockActive),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          outOfStock
                              ? 'Habis'
                              : (product.stock <= product.minStock
                                    ? 'Menipis'
                                    : 'Aktif'),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: outOfStock
                                ? NusaConfig.stockOutText
                                : (product.stock <= product.minStock
                                      ? NusaConfig.stockLowText
                                      : NusaConfig.stockActiveText),
                          ),
                        ),
                      ),
                    ],
                  ),
                  // ── Kode barcode (v2.2.57+115) ──
                  if (product.barcode != null && product.barcode!.isNotEmpty) ...[
                    SizedBox(height: 2),
                    Text(
                      '• ${product.barcode}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        color: isDark
                            ? NusaConfig.darkTextTertiary
                            : NusaConfig.textTertiary,
                      ),
                    ),
                  ],
                  SizedBox(height: 2),
                  product.hasDiscount
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              formatRupiah(product.effectivePrice),
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: NusaConfig.activePrimary,
                              ),
                            ),
                            SizedBox(width: 4),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 1),
                              child: Text(
                                formatRupiah(product.sellPrice),
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
                          formatRupiah(product.sellPrice),
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: NusaConfig.activePrimary,
                          ),
                        ),
                ],
              ),
            ),
            SizedBox(width: 8),
            // Actions
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (NusaConfig.isLaundryVariant &&
                    onTogglePriceType != null) ...[
                  _ActionButton(
                    icon: product.priceType == 'kg'
                        ? Icons.scale_rounded
                        : Icons.inventory_2_rounded,
                    color: product.priceType == 'kg'
                        ? NusaConfig.accentPurple
                        : (isDark
                              ? NusaConfig.darkTextSecondary
                              : NusaConfig.textSecondary),
                    onTap: onTogglePriceType!,
                  ),
                  SizedBox(width: 4),
                ],
                _ActionButton(
                  icon: Icons.edit_outlined,
                  color: isDark
                      ? NusaConfig.darkTextSecondary
                      : NusaConfig.textSecondary,
                  onTap: onEdit,
                ),
                SizedBox(width: 4),
                _ActionButton(
                  icon: Icons.delete_outline,
                  color: NusaConfig.error,
                  onTap: onDelete,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String label;
  final Color color;
  _Tag({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  _ActionButton({required this.icon, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 18, color: color),
      ),
    );
  }
}
