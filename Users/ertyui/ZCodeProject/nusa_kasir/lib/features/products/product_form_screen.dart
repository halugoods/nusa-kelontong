import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:barcode_widget/barcode_widget.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mobile_scanner/mobile_scanner.dart' hide Barcode;
import 'package:nusa_kasir/core/providers.dart';
import 'package:nusa_kasir/core/activation/activation_key.dart';
import 'package:nusa_kasir/core/cloud/cloud_gateway.dart';
import 'package:nusa_kasir/core/config/nusa_config.dart';
import 'package:nusa_kasir/core/services/google_auth_service.dart';
import 'package:nusa_kasir/core/services/image_storage_service.dart';
import 'package:nusa_kasir/core/services/delta_sync_service.dart';
import 'package:nusa_kasir/core/utils/image_utils.dart';
import 'package:nusa_kasir/core/utils/format_rupiah.dart';
import 'package:nusa_kasir/core/utils/product_discount.dart';
import 'package:nusa_kasir/data/database/app_database.dart';
import 'package:nusa_kasir/data/repositories/product_repository.dart';
import 'package:nusa_kasir/data/repositories/category_repository.dart';
import 'package:nusa_kasir/data/repositories/recipe_repository.dart';
import 'package:nusa_kasir/data/repositories/supplier_repository.dart';
import 'package:nusa_kasir/shared/widgets/animated_scanner_overlay.dart';
import 'package:nusa_kasir/shared/widgets/hid_barcode_listener.dart';
import 'package:nusa_kasir/shared/widgets/unit_manager_sheet.dart';
import 'package:nusa_kasir/shared/widgets/nusa_product_image.dart';
import 'package:nusa_kasir/shared/widgets/nusa_button.dart';
import 'package:nusa_kasir/shared/widgets/nusa_form_field.dart';
import 'package:nusa_kasir/shared/widgets/top_toast.dart';

/// Variant data model (stored as JSON in variantsJson)
class _ProductVariant {
  String name;
  int priceAdjustment;
  int stock;
  _ProductVariant({this.name = '', this.priceAdjustment = 0, this.stock = 0});

  Map<String, dynamic> toJson() => {
    'name': name,
    'priceAdjustment': priceAdjustment,
    'stock': stock,
  };
  factory _ProductVariant.fromJson(Map<String, dynamic> j) => _ProductVariant(
    name: j['name'] ?? '',
    priceAdjustment: j['priceAdjustment'] ?? 0,
    stock: j['stock'] ?? 0,
  );
}

/// Wholesale tier data model (stored as JSON in wholesaleJson)
class _WholesaleTier {
  int minQty;
  int price;
  _WholesaleTier({this.minQty = 1, this.price = 0});

  Map<String, dynamic> toJson() => {'minQty': minQty, 'price': price};
  factory _WholesaleTier.fromJson(Map<String, dynamic> j) =>
      _WholesaleTier(minQty: j['minQty'] ?? 1, price: j['price'] ?? 0);
}

/// Buka form produk sebagai slide-up bottom sheet (state design baru).
/// Kembali dengan `int?` = id produk BARU saat mode tambah (dipakai Catat
/// Pembelian C3 untuk langsung memasukkan produk ke keranjang).
Future<int?> showProductFormSheet(
  BuildContext context, {
  int? productId,
  int? supplierId,
  String? supplierName,
  bool? isService,
}) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => ProductFormSheet(
      productId: productId,
      supplierId: supplierId,
      supplierName: supplierName,
      isService: isService,
    ),
  );
}

class ProductFormSheet extends ConsumerStatefulWidget {
  final int? productId;

  /// Supplier yang sudah dipilih (dari Catat Pembelian) — toggle supplier
  /// langsung ON + terisi.
  final int? supplierId;
  final String? supplierName;

  /// B10 (v2.2.44): preset produk sebagai LAYANAN (dibuka dari tab Layanan).
  final bool? isService;
  const ProductFormSheet({
    this.productId,
    this.supplierId,
    this.supplierName,
    this.isService,
    super.key,
  });
  @override
  ConsumerState<ProductFormSheet> createState() => _ProductFormSheetState();
}

class _ProductFormSheetState extends ConsumerState<ProductFormSheet> {
  final _name = TextEditingController();
  final _sku = TextEditingController();
  final _buy = TextEditingController();
  final _sell = TextEditingController();
  final _discount = TextEditingController();
  final _stock = TextEditingController();
  final _min = TextEditingController();
  String _category = '';
  List<String> _availableCategories = [];
  late String? _barcode;
  Product? _existing;
  bool _loading = true;
  bool _saving = false;
  bool _barcodeOn = false;
  final _barcodeCtrl = TextEditingController();
  bool _isOnline = false;
  String? _imagePath;
  /// v2.2.57+130 (A2): simpan id produk baru untuk path R2 upload.
  int? _createdId;
  /// Fallback base64 untuk render foto saat file lokal hilang.
  String? _imageBase64;
  DateTime? _expiryDate;
  // B10 (v2.2.44): produk = LAYANAN (jasa). Tanpa wajib stok, kategori default
  // 'Layanan'. Barcode tetap boleh (keputusan user: jangan dihilangkan).
  bool _isService = false;
  // Diskon: 'persen' | 'nominal' (Rp)
  String _discountType = ProductDiscountX.typePersen;

  // Supplier langganan produk (C4): toggle + dropdown supplier.
  bool _hasSupplier = false;
  Supplier? _supplier;
  List<Supplier> _suppliers = [];
  bool _suppliersLoading = true;

  // Toggle-based product type
  bool _hasVarian = false;
  bool _hasGrosir = false;

  // F&B: Resep / Komposisi (bahan baku + qty). Hanya varian F&B.
  bool _hasResep = false;
  List<({int materialId, String name, double qty, int costPrice})>
      _recipeItems = [];
  List<RawMaterial> _recipeMaterials = [];

  // Satuan dinamis (v2.2.43): kamus global + konversi per produk.
  bool _hasUnit = false;
  int? _baseUnitId; // satuan dasar produk (qtyPerBase = 1)
  final List<({int unitId, String name, double qtyPerBase})> _sellingUnits = [];
  List<Unit> _unitKamus = [];

  // Dynamic lists
  List<_ProductVariant> _variants = [];
  List<_WholesaleTier> _wholesaleTiers = [];

  bool get _isEdit => widget.productId != null;

  @override
  void initState() {
    super.initState();
    // v2.2.45: barcode TIDAK auto-generate saat form dibuka — user yang
    // memutuskan lewat tombol "Generate Barcode" (lihat toggle Barcode).
    _barcode = null;
    _barcodeCtrl.text = '';
    // B10: preset layanan dari tab Layanan (add mode).
    _isService = widget.isService ?? false;
    _init();
  }

  @override
  void dispose() {
    _name.dispose();
    _sku.dispose();
    _buy.dispose();
    _sell.dispose();
    _stock.dispose();
    _min.dispose();
    _barcodeCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    final repo = CategoryRepository(ref.read(databaseProvider));
    final cats = await repo.getAll();
    if (mounted) {
      setState(() {
        _availableCategories = cats;
        if (_category.isEmpty && cats.isNotEmpty)
          _category = cats.first;
        else if (!cats.contains(_category) && cats.isNotEmpty)
          _category = cats.first;
      });
    }
  }

  Future<void> _loadSuppliers() async {
    final list = await SupplierRepository(
      ref.read(databaseProvider),
    ).getSuppliers();
    if (mounted)
      setState(() {
        _suppliers = list;
        _suppliersLoading = false;
      });
  }

  Future<void> _init() async {
    await _loadCategories();
    await _loadSuppliers();
    // Kamus satuan (semua varian — dipakai produk & bahan).
    try {
      final units = await RecipeRepository(
        ref.read(databaseProvider),
      ).getUnits();
      if (mounted) setState(() => _unitKamus = units);
    } catch (_) {}
    // F&B: kamus bahan untuk form resep (di-load sekali, bukan tiap build).
    if (NusaConfig.isFnbVariant) {
      try {
        final mats = await RecipeRepository(
          ref.read(databaseProvider),
        ).getMaterials();
        if (mounted) {
          setState(() {
            _recipeMaterials = mats;
          });
        }
      } catch (_) {}
    }
    // C6: dibuka dari Catat Pembelian → toggle supplier ON + terisi
    // (via constructor supplierId/supplierName — sheet tidak punya GoRouter).
    final fromSupplierId = widget.supplierId;
    final fromSupplierName = widget.supplierName;
    if (fromSupplierId != null && !_isEdit) {
      _hasSupplier = true;
      final match = _suppliers.where((s) => s.id == fromSupplierId).firstOrNull;
      if (match != null) {
        _supplier = match;
      } else if (fromSupplierName != null && fromSupplierName.isNotEmpty) {
        // Supplier mungkin belum tersimpan — tampilkan nama saja.
        _supplier = Supplier(
          id: fromSupplierId,
          name: fromSupplierName,
          phone: null,
          address: null,
          contactPerson: null,
          note: null,
          createdAt: DateTime.now(),
        );
      }
    }
    if (!_isEdit) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final repo = ProductRepository(ref.read(databaseProvider));
    final p = await repo.byId(widget.productId!);
    if (p != null && mounted) {
      _existing = p;
      _name.text = p.name;
      _sku.text = p.sku ?? '';
      _buy.text = p.buyPrice > 0 ? p.buyPrice.toString() : '';
      _sell.text = p.sellPrice.toString();
      _discount.text = p.discountPercent > 0
          ? p.discountPercent.toString()
          : '';
      _discountType = (p.discountType == ProductDiscountX.typeNominal)
          ? ProductDiscountX.typeNominal
          : ProductDiscountX.typePersen;
      _stock.text = p.stock.toString();
      _min.text = p.minStock > 0 ? p.minStock.toString() : '';
      _category = _availableCategories.contains(p.category)
          ? p.category
          : (_availableCategories.isNotEmpty ? _availableCategories.first : '');
      _imagePath = p.imagePath;
      _imageBase64 = p.imageBase64;
      _isOnline = p.isOnline;
      _expiryDate = p.expiryDate;
      // B10: flag layanan produk (edit mode) — override preset awal.
      _isService = p.isService;
      // Supplier tersimpan pada produk (edit mode).
      if (p.supplierId != null) {
        _hasSupplier = true;
        final match = _suppliers.where((s) => s.id == p.supplierId).firstOrNull;
        if (match != null) _supplier = match;
      }

      // Load variants
      if (p.variantsJson != null && p.variantsJson!.isNotEmpty) {
        try {
          final list = jsonDecode(p.variantsJson!) as List;
          _variants = list
              .map((e) => _ProductVariant.fromJson(e as Map<String, dynamic>))
              .toList();
          _hasVarian = _variants.isNotEmpty;
        } catch (_) {}
      }
      // Load wholesale tiers
      if (p.wholesaleJson != null && p.wholesaleJson!.isNotEmpty) {
        try {
          final list = jsonDecode(p.wholesaleJson!) as List;
          _wholesaleTiers = list
              .map((e) => _WholesaleTier.fromJson(e as Map<String, dynamic>))
              .toList();
          _hasGrosir = _wholesaleTiers.isNotEmpty;
        } catch (_) {}
      }

      // F&B: load resep produk (bahan + qty).
      if (NusaConfig.isFnbVariant) {
        final recipeRepo = RecipeRepository(ref.read(databaseProvider));
        final items = await recipeRepo.getRecipeWithNames(p.id);
        if (mounted) {
          _recipeItems = items;
          _hasResep = items.isNotEmpty;
        }
      }

      // Load satuan produk (kamus + konversi per produk).
      final recipeRepo = RecipeRepository(ref.read(databaseProvider));
      final productUnits = await recipeRepo.getProductUnits(p.id);
      if (mounted && productUnits.isNotEmpty) {
        final baseRow = productUnits
            .where((pu) => pu.isBase)
            .firstOrNull;
        final baseId = baseRow?.unitId;
        setState(() {
          _hasUnit = true;
          _baseUnitId = baseId;
          _sellingUnits
            ..clear()
            ..addAll([
              for (final pu in productUnits)
                if (pu.unitId != baseId)
                  (
                    unitId: pu.unitId,
                    name:
                        _unitKamus.where((u) => u.id == pu.unitId).firstOrNull
                            ?.name ??
                        '',
                    qtyPerBase: pu.qtyPerBase,
                  ),
            ]);
        });
      }

      if (p.barcode != null && p.barcode!.isNotEmpty) {
        _barcodeOn = true;
        _barcode = p.barcode!;
        _barcodeCtrl.text = p.barcode!;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  int? _toInt(String v) {
    if (v.trim().isEmpty) return null;
    return int.tryParse(v.trim());
  }

  void _toggleBarcode(bool v) {
    setState(() {
      _barcodeOn = v;
      if (v && _existing?.barcode != null && _existing!.barcode!.isNotEmpty) {
        _barcode = _existing!.barcode!;
        _barcodeCtrl.text = _barcode!;
      }
      // v2.2.45: toggle ON → field KOSONG (jangan auto-generate). User bisa
      // scan/ketik manual atau tekan "Generate Barcode".
    });
  }

  /// Generate barcode acak (pola serial aktivasi) untuk produk baru.
  void _generateBarcode() {
    setState(() {
      _barcode = ActivationKey.generateSerial();
      _barcodeCtrl.text = _barcode!;
    });
  }

  /// Scan barcode from camera (no manual input here — manual lives in the
  /// barcode TextField in the form itself).
  Future<void> _scanBarcodeFromCamera() async {
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
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(
              Icons.qr_code_scanner,
              size: 22,
              color: NusaConfig.activePrimary,
            ),
            SizedBox(width: 8),
            Text('Scan Barcode'),
          ],
        ),
        content: AnimatedScannerOverlay(
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
              debugPrint('[ProductForm] scanner error: $error');
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
                        'Kamera tidak tersedia.\nKetuk Batal lalu ketik kode barcode manual.',
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
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Batal')),
        ],
      ),
    );
    await controller.dispose();
    if (scanned == null || !mounted) return;
    setState(() {
      _barcodeOn = true;
      _barcode = scanned!;
      _barcodeCtrl.text = scanned!;
    });
  }

  Future<void> _pickImage() async {
    // Downscale via ImagePicker (maxWidth) instead of file_picker withData:
    // avoids OOM on low-RAM devices (Samsung A14 50MP photos crash the app).
    final path = await pickAndSaveImage(maxSize: 1024, prefix: 'product_');
    if (path == null) return;
    // Crop 1:1 ANTI-FC: file sudah di-downscale ≤1024px, jadi UCrop tidak
    // membuka bitmap 50MP. Gagal → tetap pakai foto tanpa crop (app jalan).
    final cropped = await cropAndSaveImage(path);
    setState(() => _imagePath = cropped ?? path);
    TopToast.success(context, 'Gambar ditambahkan');
  }

  /// Re-crop foto yang sudah terpasang (ikon crop di preview).
  Future<void> _recropImage() async {
    if (_imagePath == null) return;
    final cropped = await cropAndSaveImage(_imagePath!);
    if (cropped == null || !mounted) return;
    setState(() => _imagePath = cropped);
    TopToast.success(context, 'Foto diperbarui');
  }

  /// v2.2.57+130 (A2): upload gambar produk ke R2 (CloudGateway.storageUpload).
  /// Path: nusa-images/{uid}/{productId}/products/{filename}.
  /// Fallback path "new" untuk produk baru sebelum sync berikutnya (nama file
  /// product_{id}_{ts} mencerminkan produk unik).
  void _uploadToCloud(String localPath) {
    _uploadToCloudImpl(localPath);
  }

  Future<void> _uploadToCloudImpl(String localPath) async {
    try {
      final uid = await GoogleAuthService.getStoredUserId();
      if (uid == null) return;
      // Path: nusa-images/{uid}/{productId}/products/{filename} — match
      // ImageStorageService._remotePath convention. Untuk produk baru,
      // _createdId sudah tersedia sebagai field state setelah insert.
      final pid = _isEdit ? widget.productId : _createdId;
      if (pid != null) {
        final filename = localPath.split('/').last;
        final remotePath = '$uid/${NusaConfig.productId}/products/$filename';
        // Langsung pakai CloudGateway.storageUpload untuk kontrol path penuh.
        final file = File(localPath);
        if (!await file.exists()) return;
        final bytes = await file.readAsBytes();
        final ext = filename.contains('.') ? filename.split('.').last.toLowerCase() : '';
        final mime = switch (ext) {
              'jpg' || 'jpeg' => 'image/jpeg',
              'png' => 'image/png',
              'webp' => 'image/webp',
              'gif' => 'image/gif',
              _ => 'application/octet-stream',
            };
        final ok = await CloudGateway.shared.storageUpload(
          'nusa-images',
          remotePath,
          bytes,
          contentType: mime,
          upsert: true,
        );
        if (ok) debugPrint('[ProductForm] R2 upload OK: $remotePath');
      } else {
        // Produk belum punya id lokal — fallback via ImageStorageService.
        final svc = ImageStorageService(uid);
        final ok = await svc.uploadImage('products', localPath);
        if (ok) debugPrint('[ProductForm] R2 upload OK (fallback path)');
      }
    } catch (e) {
      // Non-fatal — backup arsip tetap mencakup gambar.
      debugPrint('[ProductForm] R2 upload gagal (non-fatal): $e');
    }
  }

  String? _serializeVariants() {
    if (!_hasVarian || _variants.isEmpty) return null;
    return jsonEncode(_variants.map((v) => v.toJson()).toList());
  }

  String? _serializeWholesale() {
    if (!_hasGrosir || _wholesaleTiers.isEmpty) return null;
    return jsonEncode(_wholesaleTiers.map((w) => w.toJson()).toList());
  }

  Future<void> _save() async {
    if (_saving) return;
    final name = _name.text.trim();
    final sell = _toInt(_sell.text);
    if (name.isEmpty) {
      TopToast.error(context, 'Nama produk wajib diisi');
      return;
    }
    if (sell == null) {
      TopToast.error(context, 'Harga jual wajib diisi');
      return;
    }
    if (_category.isEmpty) {
      TopToast.error(context, 'Pilih atau buat kategori dulu');
      return;
    }

    final db = ref.read(databaseProvider);
    final buy = _toInt(_buy.text) ?? 0;
    final stock = _toInt(_stock.text) ?? 0;
    final min = _toInt(_min.text) ?? 0;
    final isNominal = _discountType == ProductDiscountX.typeNominal;
    // Nominal: berapa pun ≤ harga jual; Persen: clamp 0–100.
    final rawDiscount = _toInt(_discount.text) ?? 0;
    final discount = isNominal
        ? rawDiscount.clamp(0, sell)
        : rawDiscount.clamp(0, 100);
    final sku = _sku.text.trim().isEmpty ? null : _sku.text.trim();
    final variants = _serializeVariants();
    final wholesale = _serializeWholesale();
    final pType = _hasVarian ? 'Varian' : (_hasGrosir ? 'Grosir' : 'Regular');

    setState(() => _saving = true);
    try {
      // v2.2.57: anti-dobel (temuan user) — sebelum simpan, cek:
      // 1) barcode belum dipakai produk lain (scan tidak "muncul 2"),
      // 2) tidak ada produk identik (nama+kategori+harga jual sama).
      final prodRepo = ProductRepository(db);
      final excludeId = _isEdit ? widget.productId : null;
      if (_barcodeOn) {
        final bcRaw = _barcodeCtrl.text.trim();
        if (bcRaw.isNotEmpty) {
          final owner = await prodRepo.barcodeOwner(bcRaw, excludeId: excludeId);
          if (owner != null) {
            setState(() => _saving = false);
            TopToast.error(
              context,
              'Barcode sudah dipakai produk "${owner.name}". Ganti barcode-nya.',
            );
            return;
          }
        }
      }
      final twin = await prodRepo.identicalProduct(
        name,
        _category,
        sell,
        excludeId: excludeId,
      );
      if (twin != null) {
        setState(() => _saving = false);
        TopToast.error(
          context,
          'Produk "${twin.name}" (${twin.category}, ${formatRupiah(twin.sellPrice)}) sudah ada. Kalau mau tambah stok, pakai menu Stok Masuk.',
        );
        return;
      }
      final supplierVal = _hasSupplier && _supplier != null
          ? Value<int?>(_supplier!.id)
          : const Value<int?>(null);
      // v2.2.57+130 (A1.3): JANGAN simpan foto sebagai BASE64 lagi. Dulu
      // base64 ikut backup DB-only sehingga foto bertahan setelah restore —
      // tapi di DB besar (183 produk) kolom ini membengkak 17+ MB: bikin
      // arsip backup gemuk → OOM saat pack/encrypt + bom egress upload.
      // Foto sekarang file-first: file lokal + bucket nusa-images, dan
      // restore memulihkannya via _relinkImagesFromCloud() / syncAll().
      const imageBase64 = null;
      int? createdId;
      if (_isEdit) {
        await (db.update(
          db.products,
        )..where((t) => t.id.equals(widget.productId!))).write(
          ProductsCompanion(
            name: Value(name),
            category: Value(_category),
            buyPrice: Value(buy),
            sellPrice: Value(sell),
            minStock: Value(min),
            sku: Value(sku),
            stock: Value(stock),
            barcode: Value(_barcodeOn ? _barcodeCtrl.text.trim() : null),
            imagePath: Value(_imagePath),
            isOnline: Value(_isOnline),
            expiryDate: Value(_expiryDate),
            productType: Value(pType == 'Regular' ? null : pType),
            variantsJson: Value(variants),
            wholesaleJson: Value(wholesale),
            discountPercent: Value(discount),
            discountType: Value(
              isNominal
                  ? ProductDiscountX.typeNominal
                  : ProductDiscountX.typePersen,
            ),
            supplierId: supplierVal,
            isService: Value(_isService),
            imageBase64: Value(imageBase64),
          ),
        );
      } else {
        createdId = await db
            .into(db.products)
            .insert(
              ProductsCompanion.insert(
                name: name,
                sellPrice: sell,
                category: Value(_category),
                buyPrice: Value(buy),
                stock: Value(stock),
                minStock: Value(min),
                sku: Value(sku),
                imagePath: Value(_imagePath),
                barcode: Value(_barcodeOn ? _barcodeCtrl.text.trim() : null),
                isOnline: Value(_isOnline),
                expiryDate: Value(_expiryDate),
                productType: Value(pType == 'Regular' ? null : pType),
                variantsJson: Value(variants),
                wholesaleJson: Value(wholesale),
                discountPercent: Value(discount),
                discountType: Value(
                  isNominal
                      ? ProductDiscountX.typeNominal
                      : ProductDiscountX.typePersen,
                ),
                supplierId: supplierVal,
                isService: Value(_isService),
                imageBase64: Value(imageBase64),
              ),
            );
        // v2.2.57+130 (A2): simpan id baru untuk path R2 upload.
        _createdId = createdId;
      }
      // Satuan dinamis (v2.2.43): simpan konversi per produk bila aktif.
      final recipeRepoForUnits = RecipeRepository(db);
      if (_hasUnit && _baseUnitId != null) {
        await recipeRepoForUnits.setProductUnits(
          _isEdit ? widget.productId! : createdId!,
          _baseUnitId,
          [
            for (final su in _sellingUnits)
              if (su.qtyPerBase > 0) (su.unitId, su.qtyPerBase),
          ],
        );
      } else {
        await recipeRepoForUnits.setProductUnits(
          _isEdit ? widget.productId! : createdId!,
          null,
          const [],
        );
      }
      // F&B: simpan resep (bahan + qty) — gated, non-F&B tidak tersentuh.
      if (NusaConfig.isFnbVariant) {
        final recipeRepo = RecipeRepository(db);
        final pid = _isEdit ? widget.productId! : createdId!;
        if (_hasResep) {
          await recipeRepo.setRecipe(
            pid,
            [
              for (final it in _recipeItems)
                if (it.qty > 0) (it.materialId, it.qty),
            ],
          );
        } else {
          await recipeRepo.setRecipe(pid, const []);
        }
      }
      // Upload image to cloud in background
      if (_imagePath != null) _uploadToCloud(_imagePath!);
      if (mounted) {
        TopToast.success(
          context,
          _isEdit ? 'Produk diperbarui' : 'Produk disimpan',
        );
        // C3: balik ke Catat Pembelian dengan id produk baru (untuk masuk keranjang).
        Navigator.pop(context, createdId);
      }
      // v2.2.57+131: announce product change via delta sync so other
      // devices on the same account pick up the change within seconds.
      final pid = _isEdit ? widget.productId : createdId;
      if (pid != null) {
        try {
          DeltaSyncService.I.pushDelta(
            table: 'products',
            recordId: pid.toString(),
            operation: _isEdit ? 'UPDATE' : 'INSERT',
            data: {
              'id': pid,
              'name': name,
              'category': _category,
              'buy_price': buy,
              'sell_price': sell,
              'stock': stock,
              'is_online': _isOnline,
              'is_service': _isService,
              'image_path': _imagePath,
            },
          );
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[ProductForm] save error: $e');
      if (mounted) {
        setState(() => _saving = false);
        TopToast.error(context, 'Gagal menyimpan produk. Coba lagi.');
      }
    }
  }

  Future<void> _showAddCategoryDialog() async {
    final ctrl = TextEditingController();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Tambah Kategori Baru'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(
            color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary,
          ),
          decoration: InputDecoration(
            labelText: 'Nama Kategori',
            hintText: NusaConfig.hintsFor('productCategory'),
            hintStyle: TextStyle(
              color: isDark
                  ? NusaConfig.darkTextTertiary
                  : NusaConfig.textTertiary,
            ),
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Batal')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            style: ElevatedButton.styleFrom(
              backgroundColor: NusaConfig.activePrimary,
              foregroundColor: Colors.white,
            ),
            child: Text('Simpan'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      final catRepo = CategoryRepository(ref.read(databaseProvider));
      await catRepo.add(result);
      await _loadCategories();
      setState(() => _category = result);
      TopToast.success(context, 'Kategori "$result" disimpan');
    }
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // B6: scan barcode EKSTERNAL (HID) di mana pun dalam form → isi kolom
    // barcode + aktifkan toggle. Scanner bertingkah keyboard; HidBarcodeListener
    // menangkapnya di level Focus TANPA membuka keypad layar.
    return HidBarcodeListener(
      onBarcode: (code) {
        final norm = ProductRepository.normalizeBarcode(code);
        if (norm.isEmpty) return;
        setState(() {
          _barcode = norm;
          _barcodeCtrl.text = norm;
          _barcodeOn = true;
        });
        TopToast.success(context, 'Barcode: $norm');
      },
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.fromLTRB(
          20,
          10,
        20,
        MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: _loading
          ? Padding(
              padding: EdgeInsets.symmetric(vertical: 60),
              child: Center(child: CircularProgressIndicator()),
            )
          : SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── Drag handle ──
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: NusaConfig.dividerColor,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  SizedBox(height: 14),
                  // ── Header ──
                  Row(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: NusaConfig.activePrimary.withValues(
                            alpha: 0.12,
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          _isEdit
                              ? Icons.edit_outlined
                              : Icons.inventory_2_outlined,
                          color: NusaConfig.activePrimary,
                          size: 20,
                        ),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _isEdit ? 'Edit Produk' : 'Tambah Produk',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            color: isDark
                                ? NusaConfig.darkTextPrimary
                                : NusaConfig.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 18),

                  // ── 1. Product image ──
                  _buildImagePicker(isDark),
                  SizedBox(height: NusaConfig.spaceMD),

                  // ── 2. Nama Produk ──
                  NusaFormField(
                    label: 'Nama Produk',
                    controller: _name,
                    hintText: NusaConfig.hintsFor('productName'),
                  ),
                  SizedBox(height: NusaConfig.spaceSM),

                  // ── 3. SKU (opsional) ──
                  NusaFormField(
                    label: 'SKU (opsional)',
                    controller: _sku,
                    hintText: 'Cth: SKU-001',
                  ),
                  SizedBox(height: NusaConfig.spaceMD),

                  // ── 4. Kategori ──
                  _buildCategorySection(isDark),
                  SizedBox(height: NusaConfig.spaceMD),

                  // ── 5. Harga Beli (opsional) ──
                  NusaFormField(
                    label: 'Harga Beli (opsional)',
                    controller: _buy,
                    keyboardType: TextInputType.number,
                    hintText: 'Cth: 2500',
                  ),
                  SizedBox(height: NusaConfig.spaceSM),

                  // ── 5. Harga Jual ──
                  NusaFormField(
                    label: 'Harga Jual',
                    controller: _sell,
                    keyboardType: TextInputType.number,
                    hintText: 'Cth: 3000',
                  ),
                  SizedBox(height: NusaConfig.spaceSM),

                  // ── 5b. Diskon Standalone (opsional) — % atau nominal Rp ──
                  _buildDiscountField(isDark),
                  SizedBox(height: NusaConfig.spaceSM),

                  // ── 6. Stok — disembunyikan untuk Layanan (jasa) ──
                  if (!_isService) ...[
                    NusaFormField(
                      label: 'Stok',
                      controller: _stock,
                      keyboardType: TextInputType.number,
                      hintText: 'Cth: 100',
                    ),
                    SizedBox(height: NusaConfig.spaceSM),

                    // ── 7. Kadaluarsa (opsional) ──
                    _buildExpiryPicker(isDark),
                    SizedBox(height: NusaConfig.spaceSM),

                    // ── 8. Stok Minimum (opsional) ──
                    NusaFormField(
                      label: 'Stok Minimum (opsional)',
                      controller: _min,
                      keyboardType: TextInputType.number,
                      hintText: 'Cth: 10',
                    ),
                  ],
                  SizedBox(height: NusaConfig.spaceMD),

                  // ── Divider ──
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 1,
                          color: isDark
                              ? NusaConfig.darkDivider
                              : NusaConfig.dividerColor,
                        ),
                      ),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          'Opsi Lanjutan',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: isDark
                                ? NusaConfig.darkTextTertiary
                                : NusaConfig.textTertiary,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Container(
                          height: 1,
                          color: isDark
                              ? NusaConfig.darkDivider
                              : NusaConfig.dividerColor,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: NusaConfig.spaceMD),

                  // ── B10: Toggle: Layanan (jasa) — BUKAN produk fisik ──
                  // Varian jasa: layanan tanpa wajib stok, masuk kategori
                  // "Layanan". Barcode tetap boleh (keputusan user).
                  if (NusaConfig.isJasaVariant) ...[
                    _buildToggleCard(
                      title: 'Layanan (Jasa)',
                      icon: Icons.handyman_outlined,
                      value: _isService,
                      onChanged: (v) => setState(() {
                        _isService = v;
                        if (v) {
                          // Layanan: kategori default "Layanan" (bisa diganti),
                          // stok di-nol-kan (tidak dilacak).
                          if (_category.isEmpty) _category = 'Layanan';
                          _stock.text = '0';
                          _hasVarian = false;
                          _variants.clear();
                          _hasGrosir = false;
                          _wholesaleTiers.clear();
                        }
                      }),
                    ),
                    SizedBox(height: NusaConfig.spaceSM),
                  ],

                  // ── Toggle: Varian ──
                  _buildToggleCard(
                    title: 'Varian (Rasa/Ukuran)',
                    icon: Icons.layers_outlined,
                    value: _hasVarian,
                    onChanged: (v) => setState(() {
                      _hasVarian = v;
                      if (!v) _variants.clear();
                    }),
                    expandedChild: _hasVarian
                        ? _buildVariantList(isDark)
                        : null,
                  ),
                  SizedBox(height: NusaConfig.spaceSM),

                  // ── Toggle: Satuan (dinamis, v2.2.43) ──
                  _buildToggleCard(
                    title: 'Satuan',
                    icon: Icons.straighten_outlined,
                    value: _hasUnit,
                    onChanged: (v) => setState(() {
                      _hasUnit = v;
                      if (!v) {
                        _baseUnitId = null;
                        _sellingUnits.clear();
                      } else if (_baseUnitId == null) {
                        // Default satuan dasar = pcs bila ada di kamus.
                        final pcs = _unitKamus
                            .where((u) => u.name.toLowerCase() == 'pcs')
                            .firstOrNull;
                        _baseUnitId = pcs?.id ?? _unitKamus.firstOrNull?.id;
                      }
                    }),
                    expandedChild: _hasUnit ? _buildUnitSection(isDark) : null,
                  ),
                  SizedBox(height: NusaConfig.spaceSM),

                  // ── Toggle: Grosir ──
                  _buildToggleCard(
                    title: 'Harga Grosir',
                    icon: Icons.inventory_2_outlined,
                    value: _hasGrosir,
                    onChanged: (v) => setState(() {
                      _hasGrosir = v;
                      if (!v) _wholesaleTiers.clear();
                    }),
                    expandedChild: _hasGrosir
                        ? _buildWholesaleList(isDark)
                        : null,
                  ),
                  SizedBox(height: NusaConfig.spaceSM),

                  // ── Toggle: Resep / Komposisi (F&B only) ──
                  if (NusaConfig.isFnbVariant) ...[
                    _buildToggleCard(
                      title: 'Resep / Komposisi',
                      icon: Icons.restaurant_menu_outlined,
                      value: _hasResep,
                      onChanged: (v) => setState(() {
                        _hasResep = v;
                        if (!v) _recipeItems.clear();
                      }),
                      expandedChild: _hasResep
                          ? _buildRecipeList(isDark)
                          : null,
                    ),
                    SizedBox(height: NusaConfig.spaceSM),
                  ],

                  // ── Toggle: Barcode ──
                  _buildToggleCard(
                    title: 'Barcode',
                    icon: Icons.qr_code_2,
                    value: _barcodeOn,
                    onChanged: _toggleBarcode,
                    expandedChild: _barcodeOn
                        ? Container(
                            padding: EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? NusaConfig.darkSurface2
                                  : NusaConfig.surfaceColor,
                              borderRadius: BorderRadius.only(
                                bottomLeft: Radius.circular(12),
                                bottomRight: Radius.circular(12),
                              ),
                            ),
                            child: Column(
                              children: [
                                // Scan kamera + input manual (barcode form pindah ke sini)
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: _barcodeCtrl,
                                        keyboardType: TextInputType.number,
                                        style: TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 13,
                                          color: isDark
                                              ? NusaConfig.darkTextPrimary
                                              : NusaConfig.textPrimary,
                                        ),
                                        decoration: InputDecoration(
                                          labelText: 'Kode barcode',
                                          hintText: NusaConfig.hintsFor('barcode'),
                                          isDense: true,
                                          border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                          ),
                                        ),
                                        onChanged: (_) => setState(() {}),
                                      ),
                                    ),
                                    SizedBox(width: 8),
                                    IconButton.filledTonal(
                                      tooltip: 'Scan kamera',
                                      onPressed: _scanBarcodeFromCamera,
                                      icon: Icon(
                                        Icons.qr_code_scanner,
                                        size: 20,
                                        color: NusaConfig.activePrimary,
                                      ),
                                    ),
                                  ],
                                ),
                                // v2.2.45: Generate barcode acak — pengganti
                                // auto-generate saat toggle ON.
                                SizedBox(height: 6),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: TextButton.icon(
                                    onPressed: _generateBarcode,
                                    icon: Icon(
                                      Icons.casino_outlined,
                                      size: 16,
                                      color: NusaConfig.activePrimary,
                                    ),
                                    label: Text(
                                      'Generate Barcode',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: NusaConfig.activePrimary,
                                      ),
                                    ),
                                  ),
                                ),
                                SizedBox(height: 6),
                                if (_barcodeCtrl.text.trim().isNotEmpty) ...[
                                  BarcodeWidget(
                                    data: _barcodeCtrl.text.trim(),
                                    barcode: Barcode.code128(),
                                    width: double.infinity,
                                    height: 60,
                                  ),
                                  SizedBox(height: 4),
                                  Text(
                                    _barcodeCtrl.text.trim(),
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 11,
                                      color: isDark
                                          ? NusaConfig.darkTextSecondary
                                          : NusaConfig.textSecondary,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          )
                        : null,
                  ),
                  SizedBox(height: NusaConfig.spaceSM),

                  // ── Toggle: Toko Online ──
                  _buildToggleCard(
                    title: 'Tampil di Toko Online',
                    icon: Icons.storefront_outlined,
                    value: _isOnline,
                    onChanged: (v) => setState(() => _isOnline = v),
                    expandedChild: _isOnline
                        ? Container(
                            padding: EdgeInsets.fromLTRB(16, 12, 16, 12),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? NusaConfig.darkSurface2
                                  : NusaConfig.surfaceColor,
                              borderRadius: BorderRadius.only(
                                bottomLeft: Radius.circular(12),
                                bottomRight: Radius.circular(12),
                              ),
                            ),
                            child: Text(
                              'Produk akan muncul di website toko online Anda.',
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark
                                    ? NusaConfig.darkTextSecondary
                                    : NusaConfig.textSecondary,
                              ),
                            ),
                          )
                        : null,
                  ),
                  SizedBox(height: NusaConfig.spaceSM),

                  // ── Toggle: Supplier langganan (C4) ──
                  _buildToggleCard(
                    title: 'Supplier (opsional)',
                    icon: Icons.local_shipping_outlined,
                    value: _hasSupplier,
                    onChanged: (v) => setState(() {
                      _hasSupplier = v;
                      if (v && _supplier == null && _suppliers.isNotEmpty)
                        _supplier = _suppliers.first;
                    }),
                    expandedChild: _hasSupplier
                        ? Container(
                            padding: EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? NusaConfig.darkSurface2
                                  : NusaConfig.surfaceColor,
                              borderRadius: BorderRadius.only(
                                bottomLeft: Radius.circular(12),
                                bottomRight: Radius.circular(12),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (_suppliersLoading)
                                  Padding(
                                    padding: EdgeInsets.symmetric(vertical: 6),
                                    child: Text(
                                      'Memuat supplier…',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: isDark
                                            ? NusaConfig.darkTextSecondary
                                            : NusaConfig.textSecondary,
                                      ),
                                    ),
                                  )
                                else if (_suppliers.isEmpty)
                                  Padding(
                                    padding: EdgeInsets.symmetric(vertical: 6),
                                    child: Text(
                                      'Belum ada supplier. Tambah lewat menu Supplier.',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: isDark
                                            ? NusaConfig.darkTextSecondary
                                            : NusaConfig.textSecondary,
                                      ),
                                    ),
                                  )
                                else ...[
                                  DropdownButtonHideUnderline(
                                    child: DropdownButton<Supplier>(
                                      isExpanded: true,
                                      value: _supplier,
                                      hint: Text(
                                        'Pilih supplier',
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: isDark
                                              ? NusaConfig.darkTextTertiary
                                              : NusaConfig.textTertiary,
                                        ),
                                      ),
                                      dropdownColor: isDark
                                          ? NusaConfig.darkSurface
                                          : NusaConfig.surfaceColor,
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: isDark
                                            ? NusaConfig.darkTextPrimary
                                            : NusaConfig.textPrimary,
                                      ),
                                      items: _suppliers
                                          .map(
                                            (s) => DropdownMenuItem(
                                              value: s,
                                              child: Text(s.name),
                                            ),
                                          )
                                          .toList(),
                                      onChanged: (v) =>
                                          setState(() => _supplier = v),
                                    ),
                                  ),
                                  SizedBox(height: 4),
                                  Text(
                                    'Produk ini dipasok dari supplier tersebut. HPP tetap dari harga beli.',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: isDark
                                          ? NusaConfig.darkTextTertiary
                                          : NusaConfig.textTertiary,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          )
                        : null,
                  ),
                  SizedBox(height: NusaConfig.spaceMD),

                  // ── Divider ──
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 1,
                          color: isDark
                              ? NusaConfig.darkDivider
                              : NusaConfig.dividerColor,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: NusaConfig.spaceLG),

                  // ── Save button ──
                  NusaButton(
                    _saving ? 'Menyimpan…' : 'Simpan Produk',
                    onPressed: _saving ? null : _save,
                  ),
                ],
              ),
            ),
      ),
    );
  }

  // ── Discount field (% atau nominal Rp) ──
  Widget _buildDiscountField(bool isDark) {
    final isNominal = _discountType == ProductDiscountX.typeNominal;
    final sell = _toInt(_sell.text) ?? 0;
    final d = _toInt(_discount.text) ?? 0;
    final preview = d > 0 && sell > 0
        ? formatRupiah(
            isNominal
                ? (sell - d).clamp(0, sell)
                : (sell - (sell * d / 100).round()).clamp(0, sell),
          )
        : null;
    return Container(
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? NusaConfig.darkInputFill : NusaConfig.inputFill,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? NusaConfig.darkInputBorder : NusaConfig.inputBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Diskon Produk (opsional)',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: isDark
                        ? NusaConfig.darkTextSecondary
                        : NusaConfig.textSecondary,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              // Toggle % / Rp
              Container(
                padding: EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: isDark
                      ? NusaConfig.darkSurface2
                      : Colors.black.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _discountSegBtn('Persen (%)', false, isDark),
                    SizedBox(width: 3),
                    _discountSegBtn('Nominal (Rp)', true, isDark),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 10),
          TextField(
            controller: _discount,
            keyboardType: TextInputType.number,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: isDark
                  ? NusaConfig.darkTextPrimary
                  : NusaConfig.textPrimary,
            ),
            decoration: InputDecoration(
              hintText: isNominal
                  ? 'Contoh: 10000 → potong Rp 10.000'
                  : 'Contoh: 10 → potong 10%',
              hintStyle: TextStyle(
                fontSize: 12,
                color: isDark
                    ? NusaConfig.darkTextTertiary
                    : NusaConfig.textTertiary,
              ),
              isDense: true,
              prefixText: isNominal ? 'Rp ' : '',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              prefixStyle: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isDark
                    ? NusaConfig.darkTextSecondary
                    : NusaConfig.textSecondary,
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (preview != null) ...[
            SizedBox(height: 8),
            Text(
              'Harga setelah diskon: ${preview}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: isDark
                    ? NusaConfig.darkTextSecondary
                    : NusaConfig.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _discountSegBtn(String label, bool isNominal, bool isDark) {
    final selected =
        _discountType ==
        (isNominal
            ? ProductDiscountX.typeNominal
            : ProductDiscountX.typePersen);
    return GestureDetector(
      onTap: () => setState(
        () => _discountType = isNominal
            ? ProductDiscountX.typeNominal
            : ProductDiscountX.typePersen,
      ),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? NusaConfig.activePrimary : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: selected
                ? Colors.white
                : (isDark
                      ? NusaConfig.darkTextSecondary
                      : NusaConfig.textSecondary),
          ),
        ),
      ),
    );
  }

  // ── Image picker ──
  Widget _buildImagePicker(bool isDark) {
    return GestureDetector(
      onTap: _pickImage,
      child: Container(
        // Preview 1:1 (v2.2.35) — foto produk tampil persegi, bukan 160px.
        constraints: BoxConstraints(maxHeight: 260),
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkInputFill : NusaConfig.inputFill,
          borderRadius: BorderRadius.circular(NusaConfig.radiusLG),
          border: Border.all(
            color: isDark ? NusaConfig.darkInputBorder : Color(0xFFD1D5DB),
            width: 2,
          ),
        ),
        child: _imagePath != null
            ? AspectRatio(
                aspectRatio: 1,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: NusaProductImage(
                        imagePath: _imagePath,
                        imageBase64: _imageBase64,
                        fit: BoxFit.cover,
                        placeholder: Container(
                          decoration: BoxDecoration(
                            color: isDark
                                ? NusaConfig.darkSurface
                                : Color(0xFFF3F4F6),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            Icons.image_outlined,
                            size: 48,
                            color: isDark
                                ? NusaConfig.darkTextTertiary
                                : Color(0xFF9CA3AF),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 12,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Re-crop (v2.2.35): foto sudah ada → bisa
                            // dipotong ulang tanpa harus ambil foto baru.
                            GestureDetector(
                              onTap: _recropImage,
                              child: Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.crop_rounded,
                                        color: Colors.white, size: 14),
                                    SizedBox(width: 4),
                                    Text(
                                      'Crop',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            SizedBox(width: 8),
                            GestureDetector(
                              onTap: _pickImage,
                              child: Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  'Ganti Foto',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.cloud_upload_outlined,
                    size: 40,
                    color: isDark
                        ? NusaConfig.darkTextTertiary
                        : NusaConfig.textTertiary,
                  ),
                  SizedBox(height: 10),
                  Text(
                    'TAP UNTUK UPLOAD FOTO',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: isDark
                          ? NusaConfig.darkTextSecondary
                          : NusaConfig.textSecondary,
                      letterSpacing: 0.5,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'atau drag & drop',
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
    );
  }

  // ── Expiry date picker ──
  Widget _buildExpiryPicker(bool isDark) {
    return GestureDetector(
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: _expiryDate ?? now,
          firstDate: now,
          lastDate: DateTime(now.year + 10),
          helpText: 'Pilih Tanggal Kadaluarsa',
        );
        if (picked != null) setState(() => _expiryDate = picked);
      },
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkInputFill : NusaConfig.inputFill,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isDark ? NusaConfig.darkInputBorder : NusaConfig.inputBorder,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Kadaluarsa (opsional)',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: isDark
                          ? NusaConfig.darkTextSecondary
                          : NusaConfig.textSecondary,
                      letterSpacing: 0.5,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    _expiryDate != null
                        ? '${_expiryDate!.day}/${_expiryDate!.month}/${_expiryDate!.year}'
                        : 'Pilih tanggal',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: _expiryDate != null
                          ? isDark
                                ? NusaConfig.darkTextPrimary
                                : NusaConfig.textPrimary
                          : isDark
                          ? NusaConfig.darkTextTertiary
                          : NusaConfig.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            if (_expiryDate != null)
              GestureDetector(
                onTap: () => setState(() => _expiryDate = null),
                child: Icon(
                  Icons.close,
                  size: 18,
                  color: isDark
                      ? NusaConfig.darkTextTertiary
                      : NusaConfig.textTertiary,
                ),
              ),
            SizedBox(width: 4),
            Icon(
              Icons.calendar_today,
              size: 18,
              color: isDark
                  ? NusaConfig.darkTextSecondary
                  : NusaConfig.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  // ── Category section at bottom with CRUD ──
  Widget _buildCategorySection(bool isDark) {
    final items = <DropdownMenuItem<String>>[
      for (final cat in _availableCategories)
        DropdownMenuItem(
          value: cat,
          child: Text(
            cat,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
      DropdownMenuItem<String>(
        value: '__divider__',
        enabled: false,
        child: Divider(height: 1, thickness: 1),
      ),
      DropdownMenuItem<String>(
        value: '__add__',
        child: Text(
          'Tambah Kategori',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: NusaConfig.activePrimary,
          ),
        ),
      ),
      DropdownMenuItem<String>(
        value: '__manage__',
        child: Text(
          'Kelola Kategori',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: isDark
                ? NusaConfig.darkTextSecondary
                : NusaConfig.textSecondary,
          ),
        ),
      ),
    ];
    return NusaDropdownField<String>(
      label: 'Kategori',
      value: _category.isNotEmpty ? _category : null,
      items: items,
      onChanged: (val) {
        if (val == null) return;
        if (val == '__add__') {
          _showAddCategoryDialog();
        } else if (val == '__manage__') {
          _showManageCategorySheet();
        } else {
          setState(() => _category = val);
        }
      },
    );
  }

  // ── Category management (reachable from the dropdown) ──
  Future<void> _showManageCategorySheet() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cats = List<String>.from(_availableCategories);
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => Container(
          decoration: BoxDecoration(
            color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            top: 8,
            left: 16,
            right: 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: EdgeInsets.symmetric(vertical: 10),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: NusaConfig.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              SizedBox(height: 4),
              Text(
                'Kelola Kategori',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: isDark
                      ? NusaConfig.darkTextPrimary
                      : NusaConfig.textPrimary,
                ),
              ),
              SizedBox(height: 12),
              ...cats.map(
                (cat) => Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Container(
                    decoration: BoxDecoration(
                      color: isDark
                          ? NusaConfig.darkSurface2
                          : NusaConfig.inputFill,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isDark
                            ? NusaConfig.darkBorder
                            : NusaConfig.dividerColor,
                      ),
                    ),
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            cat,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? NusaConfig.darkTextPrimary
                                  : NusaConfig.textPrimary,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () =>
                              _renameCategory(ctx, setSt, cats, cat),
                          child: Text('Ubah'),
                        ),
                        TextButton(
                          onPressed: () =>
                              _confirmDeleteCategory(ctx, setSt, cats, cat),
                          child: Text(
                            'Hapus',
                            style: TextStyle(color: NusaConfig.error),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await _showAddCategoryDialog();
                  },
                  icon: Icon(Icons.add),
                  label: Text('Tambah Kategori'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: NusaConfig.activePrimary,
                    side: BorderSide(color: NusaConfig.activePrimary),
                    padding: EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await _loadCategories();
    if (mounted) setState(() {});
  }

  Future<void> _renameCategory(
    BuildContext ctx,
    StateSetter setSt,
    List<String> cats,
    String oldName,
  ) async {
    final ctrl = TextEditingController(text: oldName);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final newName = await showDialog<String>(
      context: ctx,
      builder: (d) => AlertDialog(
        title: Text('Ubah Nama Kategori'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(
            color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary,
          ),
          decoration: InputDecoration(
            border: OutlineInputBorder(),
            hintStyle: TextStyle(
              color: isDark
                  ? NusaConfig.darkTextTertiary
                  : NusaConfig.textTertiary,
            ),
          ),
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text('Batal')),
          ElevatedButton(
            onPressed: () => Navigator.pop(d, ctrl.text.trim()),
            style: ElevatedButton.styleFrom(
              backgroundColor: NusaConfig.activePrimary,
              foregroundColor: Colors.white,
            ),
            child: Text('Simpan'),
          ),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty && newName != oldName) {
      final catRepo = CategoryRepository(ref.read(databaseProvider));
      await catRepo.rename(oldName, newName);
      setSt(() {
        final i = cats.indexOf(oldName);
        if (i >= 0) cats[i] = newName;
      });
      if (_category == oldName) setState(() => _category = newName);
    }
  }

  Future<void> _confirmDeleteCategory(
    BuildContext ctx,
    StateSetter setSt,
    List<String> cats,
    String name,
  ) async {
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (d) => AlertDialog(
        title: Text('Hapus Kategori'),
        content: Text(
          'Hapus kategori "$name"? Produk dengan kategori ini akan dipindah ke "Lainnya".',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: Text('Batal'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(d, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: NusaConfig.error,
              foregroundColor: Colors.white,
            ),
            child: Text('Hapus'),
          ),
        ],
      ),
    );
    if (ok == true) {
      final catRepo = CategoryRepository(ref.read(databaseProvider));
      final db = ref.read(databaseProvider);
      await catRepo.delete(name);
      await (db.update(db.products)..where((t) => t.category.equals(name)))
          .write(ProductsCompanion(category: Value('Lainnya')));
      setSt(() => cats.remove(name));
      if (_category == name)
        setState(() => _category = cats.isNotEmpty ? cats.first : '');
    }
  }

  // ── Toggle card with visual depth ──
  Widget _buildToggleCard({
    required String title,
    required IconData icon,
    required bool value,
    required ValueChanged<bool> onChanged,
    Widget? expandedChild,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
        borderRadius: BorderRadius.circular(NusaConfig.radiusMD),
        border: Border.all(
          color: isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: isDark
                      ? NusaConfig.darkTextSecondary
                      : NusaConfig.textSecondary,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? NusaConfig.darkTextSecondary
                          : NusaConfig.textSecondary,
                    ),
                  ),
                ),
                Text(
                  value ? 'ON' : 'OFF',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: value
                        ? NusaConfig.accentGreen
                        : isDark
                        ? NusaConfig.darkTextTertiary
                        : NusaConfig.textTertiary,
                  ),
                ),
                SizedBox(width: 8),
                SizedBox(
                  height: 24,
                  width: 44,
                  child: Switch(
                    value: value,
                    onChanged: onChanged,
                    activeColor: NusaConfig.activePrimary,
                  ),
                ),
              ],
            ),
          ),
          // Expanded child with depth
          if (value && expandedChild != null) ...[
            Container(
              height: 1,
              color: isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor,
            ),
            expandedChild,
          ],
        ],
      ),
    );
  }

  // ── Variant list ──
  Widget _buildVariantList(bool isDark) {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? NusaConfig.darkSurface2 : NusaConfig.surfaceColor,
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(12),
          bottomRight: Radius.circular(12),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ..._variants.asMap().entries.map((e) {
            final i = e.key;
            final v = e.value;
            return Container(
              margin: EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Header
                  Row(
                    children: [
                      Text(
                        'Varian ${i + 1}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: isDark
                              ? NusaConfig.darkTextSecondary
                              : NusaConfig.textSecondary,
                        ),
                      ),
                      Spacer(),
                      GestureDetector(
                        onTap: () => setState(() => _variants.removeAt(i)),
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: NusaConfig.errorSoft,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'Hapus',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: NusaConfig.error,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  // Nama Varian — card sendiri
                  _variantFieldCard(
                    isDark,
                    label: 'Nama Varian',
                    controller: TextEditingController(text: v.name),
                    onChanged: (val) => _variants[i].name = val,
                    hintText: 'Cth: Ukuran M',
                  ),
                  SizedBox(height: 8),
                  // Â± Harga — card sendiri
                  _variantFieldCard(
                    isDark,
                    label: 'Â± Harga',
                    controller: TextEditingController(
                      text: v.priceAdjustment == 0
                          ? ''
                          : v.priceAdjustment.toString(),
                    ),
                    onChanged: (val) =>
                        _variants[i].priceAdjustment = int.tryParse(val) ?? 0,
                    keyboardType: TextInputType.number,
                    prefixText: '+/- ',
                    hintText: 'Cth: 2000',
                  ),
                  SizedBox(height: 8),
                  // Stok — card sendiri
                  _variantFieldCard(
                    isDark,
                    label: 'Stok',
                    controller: TextEditingController(
                      text: v.stock == 0 ? '' : v.stock.toString(),
                    ),
                    onChanged: (val) =>
                        _variants[i].stock = int.tryParse(val) ?? 0,
                    keyboardType: TextInputType.number,
                    hintText: 'Cth: 50',
                  ),
                ],
              ),
            );
          }),
          TextButton.icon(
            onPressed: () => setState(() => _variants.add(_ProductVariant())),
            icon: Icon(Icons.add, size: 18),
            label: Text('Tambah Varian'),
            style: TextButton.styleFrom(
              foregroundColor: NusaConfig.activePrimary,
            ),
          ),
        ],
      ),
    );
  }

  // ── Per-field card for variant / wholesale ──
  Widget _variantFieldCard(
    bool isDark, {
    required String label,
    required TextEditingController controller,
    required ValueChanged<String> onChanged,
    TextInputType? keyboardType,
    String? prefixText,
    String? hintText,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor,
        ),
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        keyboardType: keyboardType,
        style: TextStyle(
          fontSize: 13,
          color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary,
        ),
        decoration: InputDecoration(
          labelText: label,
          hintText: hintText,
          hintStyle: TextStyle(
            fontSize: 12,
            color: isDark
                ? NusaConfig.darkTextTertiary
                : NusaConfig.textTertiary,
          ),
          labelStyle: TextStyle(
            fontSize: 12,
            color: isDark
                ? NusaConfig.darkTextSecondary
                : NusaConfig.textSecondary,
          ),
          isDense: true,
          border: InputBorder.none,
          prefixText: prefixText,
        ),
      ),
    );
  }

  // ── Wholesale list ──
  Widget _buildWholesaleList(bool isDark) {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? NusaConfig.darkSurface2 : NusaConfig.surfaceColor,
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(12),
          bottomRight: Radius.circular(12),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ..._wholesaleTiers.asMap().entries.map((e) {
            final i = e.key;
            final w = e.value;
            return Container(
              margin: EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Header
                  Row(
                    children: [
                      Text(
                        'Tingkat ${i + 1}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: isDark
                              ? NusaConfig.darkTextSecondary
                              : NusaConfig.textSecondary,
                        ),
                      ),
                      Spacer(),
                      GestureDetector(
                        onTap: () =>
                            setState(() => _wholesaleTiers.removeAt(i)),
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: NusaConfig.errorSoft,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'Hapus',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: NusaConfig.error,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  // Min Qty — card sendiri
                  _variantFieldCard(
                    isDark,
                    label: 'Min Qty',
                    controller: TextEditingController(
                      text: w.minQty == 1 ? '' : w.minQty.toString(),
                    ),
                    onChanged: (val) =>
                        _wholesaleTiers[i].minQty = int.tryParse(val) ?? 1,
                    keyboardType: TextInputType.number,
                    hintText: 'Cth: 10',
                  ),
                  SizedBox(height: 8),
                  // Harga Grosir — card sendiri
                  _variantFieldCard(
                    isDark,
                    label: 'Harga Grosir',
                    controller: TextEditingController(
                      text: w.price == 0 ? '' : w.price.toString(),
                    ),
                    onChanged: (val) =>
                        _wholesaleTiers[i].price = int.tryParse(val) ?? 0,
                    keyboardType: TextInputType.number,
                    prefixText: 'Rp ',
                    hintText: 'Cth: 27000',
                  ),
                ],
              ),
            );
          }),
          TextButton.icon(
            onPressed: () =>
                setState(() => _wholesaleTiers.add(_WholesaleTier())),
            icon: Icon(Icons.add, size: 18),
            label: Text('Tambah Harga Grosir'),
            style: TextButton.styleFrom(
              foregroundColor: NusaConfig.activePrimary,
            ),
          ),
        ],
      ),
    );
  }

  // ── F&B: Resep / Komposisi ──

  int get _recipeHpp => _recipeItems.fold(
        0,
        (s, it) => s + (it.qty * it.costPrice).round(),
      );

  /// Buka sheet pilih bahan + qty untuk ditambah ke resep.
  Future<void> _addRecipeItem() async {
    if (_recipeMaterials.isEmpty) {
      TopToast.info(
        context,
        'Tambah bahan baku dulu di menu Produk → Bahan Baku',
      );
      return;
    }
    // Hanya bahan yang belum ada di resep.
    final used = _recipeItems.map((it) => it.materialId).toSet();
    final available = _recipeMaterials.where((m) => !used.contains(m.id)).toList();
    if (available.isEmpty) {
      TopToast.info(context, 'Semua bahan sudah ada di resep');
      return;
    }
    final picked = await showModalBottomSheet<
        ({int materialId, String name, double qty})>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _RecipeItemPickerSheet(materials: available),
    );
    if (picked == null || !mounted) return;
    final cost = _recipeMaterials
        .where((m) => m.id == picked.materialId)
        .firstOrNull
        ?.costPrice ?? 0;
    setState(() {
      _recipeItems.add((
        materialId: picked.materialId,
        name: picked.name,
        qty: picked.qty,
        costPrice: cost,
      ));
    });
  }

  Widget _buildRecipeList(bool isDark) {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? NusaConfig.darkSurface2 : NusaConfig.surfaceColor,
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(12),
          bottomRight: Radius.circular(12),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ..._recipeItems.asMap().entries.map((e) {
            final i = e.key;
            final it = e.value;
            return Container(
              margin: EdgeInsets.only(bottom: 10),
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isDark
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
                          it.name,
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
                          '${_fmtQty(it.qty)} × ${formatRupiah(it.costPrice)}'
                          ' = ${formatRupiah((it.qty * it.costPrice).round())}',
                          style: TextStyle(
                            fontSize: 11,
                            color: isDark
                                ? NusaConfig.darkTextSecondary
                                : NusaConfig.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.remove_circle_outline,
                      size: 18,
                      color: NusaConfig.error,
                    ),
                    onPressed: () => setState(() => _recipeItems.removeAt(i)),
                  ),
                ],
              ),
            );
          }),
          // Estimasi HPP live
          Container(
            margin: EdgeInsets.only(bottom: 10),
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: NusaConfig.accentGreen.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.calculate_outlined,
                    size: 16, color: NusaConfig.accentGreen),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Estimasi HPP',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark
                          ? NusaConfig.darkTextSecondary
                          : NusaConfig.textSecondary,
                    ),
                  ),
                ),
                Text(
                  formatRupiah(_recipeHpp),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: NusaConfig.accentGreen,
                  ),
                ),
              ],
            ),
          ),
          if (_recipeMaterials.isEmpty)
            Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Belum ada bahan baku. Tambah dulu di menu Produk → Bahan Baku.',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark
                      ? NusaConfig.darkTextTertiary
                      : NusaConfig.textTertiary,
                ),
              ),
            ),
          TextButton.icon(
            onPressed: _addRecipeItem,
            icon: Icon(Icons.add, size: 18),
            label: Text('Tambah Bahan'),
            style: TextButton.styleFrom(
              foregroundColor: NusaConfig.activePrimary,
            ),
          ),
        ],
      ),
    );
  }

  String _fmtQty(double q) =>
      q == q.roundToDouble() ? q.round().toString() : q.toString();

  // ── Satuan (dinamis, v2.2.43) ──

  String _unitNameById(int? id) =>
      _unitKamus.where((u) => u.id == id).firstOrNull?.name ?? '';

  Widget _buildUnitSection(bool isDark) {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? NusaConfig.darkSurface2 : NusaConfig.surfaceColor,
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(12),
          bottomRight: Radius.circular(12),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Satuan dasar
          Text(
            'Satuan Dasar',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color:
                  isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary,
            ),
          ),
          SizedBox(height: 6),
          DropdownButtonFormField<int>(
            initialValue: _baseUnitId,
            decoration: _unitInputDecor('Pilih satuan dasar'),
            items: [
              for (final u in _unitKamus)
                DropdownMenuItem(value: u.id, child: Text(u.name)),
            ],
            onChanged: (v) => setState(() {
              _baseUnitId = v;
              // Satuan dasar tidak boleh jadi satuan jual.
              _sellingUnits.removeWhere((s) => s.unitId == v);
            }),
          ),
          SizedBox(height: 12),
          // Satuan jual
          Row(
            children: [
              Expanded(
                child: Text(
                  'Satuan Jual',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: isDark
                        ? NusaConfig.darkTextSecondary
                        : NusaConfig.textSecondary,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _addSellingUnit,
                icon: Icon(Icons.add, size: 16),
                label: Text('Tambah'),
                style: TextButton.styleFrom(
                  foregroundColor: NusaConfig.activePrimary,
                  minimumSize: Size(0, 30),
                  padding: EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ],
          ),
          ..._sellingUnits.asMap().entries.map((e) {
            final i = e.key;
            final su = e.value;
            return Container(
              margin: EdgeInsets.only(bottom: 8),
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isDark
                      ? NusaConfig.darkBorder
                      : NusaConfig.dividerColor,
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      su.name,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary,
                      ),
                    ),
                  ),
                  Text(
                    '1 ${su.name} = ${_fmtQty(su.qtyPerBase)} ${_unitNameById(_baseUnitId)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark
                          ? NusaConfig.darkTextSecondary
                          : NusaConfig.textSecondary,
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.remove_circle_outline,
                        size: 18, color: NusaConfig.error),
                    onPressed: () =>
                        setState(() => _sellingUnits.removeAt(i)),
                  ),
                ],
              ),
            );
          }),
          // Kelola kamus satuan
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _openUnitManager,
              icon: Icon(Icons.settings_outlined, size: 16),
              label: Text('Kelola Satuan'),
              style: TextButton.styleFrom(
                foregroundColor: NusaConfig.activePrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _unitInputDecor(String hint) => InputDecoration(
        hintText: hint,
        isDense: true,
        filled: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      );

  Future<void> _addSellingUnit() async {
    if (_unitKamus.isEmpty) {
      TopToast.info(context, 'Tambah satuan dulu lewat "Kelola Satuan"');
      return;
    }
    final used = {
      for (final s in _sellingUnits) s.unitId,
      if (_baseUnitId != null) _baseUnitId!,
    };
    final available = _unitKamus.where((u) => !used.contains(u.id)).toList();
    if (available.isEmpty) {
      TopToast.info(context, 'Semua satuan sudah dipakai');
      return;
    }
    final picked = await showModalBottomSheet<
        ({int unitId, String name, double qtyPerBase})>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SellingUnitPickerSheet(units: available),
    );
    if (picked == null || !mounted) return;
    setState(() => _sellingUnits.add(picked));
  }

  /// "Kelola Satuan" — CRUD kamus satuan global (tambah/rename/hapus).
  Future<void> _openUnitManager() async {
    final repo = RecipeRepository(ref.read(databaseProvider));
    final result = await UnitManagerSheet.show(context: context, repo: repo);
    if (result == true && mounted) {
      // Kamus berubah → reload + pertahankan pilihan lama kalau masih ada.
      final units = await repo.getUnits();
      if (mounted) {
        setState(() {
          final oldBase = _baseUnitId;
          _unitKamus = units;
          if (oldBase != null && !units.any((u) => u.id == oldBase)) {
            _baseUnitId = null;
          }
          _sellingUnits.removeWhere(
            (s) => !units.any((u) => u.id == s.unitId),
          );
        });
      }
    }
  }
}

/// Bottom-sheet picker bahan + qty untuk resep produk (F&B).
class _RecipeItemPickerSheet extends StatefulWidget {
  final List<RawMaterial> materials;
  const _RecipeItemPickerSheet({required this.materials});

  @override
  State<_RecipeItemPickerSheet> createState() => _RecipeItemPickerSheetState();
}

class _RecipeItemPickerSheetState extends State<_RecipeItemPickerSheet> {
  RawMaterial? _selected;
  final _qty = TextEditingController(text: '1');

  @override
  void initState() {
    super.initState();
    if (widget.materials.isNotEmpty) _selected = widget.materials.first;
  }

  @override
  void dispose() {
    _qty.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: Container(
        padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + bottom),
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
              const Text(
                'Tambah Bahan ke Resep',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<RawMaterial>(
                value: _selected,
                decoration: InputDecoration(
                  labelText: 'Bahan baku',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                items: widget.materials
                    .map(
                      (m) => DropdownMenuItem(
                        value: m,
                        child: Text(
                          '${m.name} (stok ${m.stock}, '
                          'modal ${formatRupiah(m.costPrice)})',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() => _selected = v),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _qty,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Jumlah untuk 1 porsi (qty)',
                  hintText: 'cth: 0.25 (250 gram)',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    final qty = double.tryParse(_qty.text) ?? 0;
                    if (_selected == null || qty <= 0) {
                      TopToast.error(context, 'Pilih bahan & isi qty');
                      return;
                    }
                    Navigator.pop(
                      context,
                      (
                        materialId: _selected!.id,
                        name: _selected!.name,
                        qty: qty,
                      ),
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: NusaConfig.activePrimary,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Tambah'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Picker satuan jual (dari kamus) + qty per satuan dasar (v2.2.43).
class _SellingUnitPickerSheet extends StatefulWidget {
  final List<Unit> units;
  const _SellingUnitPickerSheet({required this.units});

  @override
  State<_SellingUnitPickerSheet> createState() => _SellingUnitPickerSheetState();
}

class _SellingUnitPickerSheetState extends State<_SellingUnitPickerSheet> {
  Unit? _selected;
  final _qty = TextEditingController(text: '12');

  @override
  void initState() {
    super.initState();
    if (widget.units.isNotEmpty) _selected = widget.units.first;
  }

  @override
  void dispose() {
    _qty.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(
      child: Container(
        padding: EdgeInsets.all(20),
        margin: EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Satuan Jual',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: isDark
                    ? NusaConfig.darkTextPrimary
                    : NusaConfig.textPrimary,
              ),
            ),
            SizedBox(height: 16),
            DropdownButtonFormField<Unit>(
              initialValue: _selected,
              decoration: InputDecoration(labelText: 'Pilih satuan'),
              items: [
                for (final u in widget.units)
                  DropdownMenuItem(value: u, child: Text(u.name)),
              ],
              onChanged: (v) => setState(() => _selected = v),
            ),
            SizedBox(height: 12),
            TextField(
              controller: _qty,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: '1 satuan = berapa satuan dasar?',
                hintText: 'cth: 12 (dus = 12 pcs)',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  final qty = double.tryParse(_qty.text) ?? 0;
                  if (_selected == null || qty <= 0) {
                    TopToast.error(context, 'Pilih satuan & isi konversi');
                    return;
                  }
                  Navigator.pop(
                    context,
                    (
                      unitId: _selected!.id,
                      name: _selected!.name,
                      qtyPerBase: qty,
                    ),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: NusaConfig.activePrimary,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Tambah'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
