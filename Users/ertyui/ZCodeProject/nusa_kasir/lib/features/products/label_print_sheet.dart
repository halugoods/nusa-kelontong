import 'dart:io';
import 'dart:typed_data';

import 'package:barcode/barcode.dart' as bc;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import 'package:nusa_kasir/core/config/nusa_config.dart';
import 'package:nusa_kasir/core/label/label_commands.dart';
import 'package:nusa_kasir/core/label/label_font_config.dart';
import 'package:nusa_kasir/core/label/label_renderer.dart';
import 'package:nusa_kasir/core/label/label_size_config.dart';
import 'package:nusa_kasir/core/providers.dart';
import 'package:nusa_kasir/core/utils/bluetooth_utils.dart';
import 'package:nusa_kasir/core/utils/format_rupiah.dart';
import 'package:nusa_kasir/core/utils/receipt_printer.dart';
import 'package:nusa_kasir/core/utils/secure_storage.dart';
import 'package:nusa_kasir/data/database/app_database.dart';
import 'package:nusa_kasir/data/repositories/product_repository.dart';
import 'package:nusa_kasir/shared/widgets/animated_scanner_overlay.dart';
import 'package:nusa_kasir/shared/widgets/hid_barcode_listener.dart';
import 'package:nusa_kasir/shared/widgets/nusa_product_image.dart';
import 'package:nusa_kasir/shared/widgets/screen_scaffold.dart';
import 'package:nusa_kasir/shared/widgets/top_toast.dart';

/// Alur Cetak Label Barcode (v2.2.57+116) — 3 langkah:
///   1. Pilih produk (checkbox, "Pilih Semua")
///   2. Pilih ISI label (Nama / Harga / Barcode) + UKURAN FONT (v2.2.57+116:
///      slider nama & harga — user bisa sesuaikan sendiri, berlaku ke SEMUA
///      jalur cetak supaya preview = hasil cetak)
///   3. Pilih JALUR cetak — KLIK jalur → muncul PREVIEW ACTUAL jalur tsb
///      (bukan preview generik) + tombol cetak di dalam preview:
///      a. Thermal Label (TSPL) — preview bitmap 203 DPI (isi persis yang
///         dikirim ke printer label)
///      b. Thermal Struk 58mm (ESC/POS) — preview di atas kertas struk
///      c. PDF A4 grid — preview lembar A4 (grid 4×8 label seperti aslinya),
///         tombol cetak = buka PDF → share/unduh/print via Android
///
/// Isi label & ukuran diteruskan ke [LabelRenderer] — render SAMA untuk semua
/// jalur (konsistensi, pratinjau = hasil cetak).
class LabelPrintSheet extends ConsumerStatefulWidget {
  const LabelPrintSheet({super.key, this.initialProducts});

  /// Produk yang sudah dipilih sebelumnya (dari toolbar — bisa kosong).
  final List<Product>? initialProducts;

  /// Tampilkan sebagai halaman penuh.
  static Future<void> show(BuildContext context, {List<Product>? products}) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LabelPrintSheet(initialProducts: products),
      ),
    );
  }

  @override
  ConsumerState<LabelPrintSheet> createState() => _LabelPrintSheetState();
}

class _LabelPrintSheetState extends ConsumerState<LabelPrintSheet> {
  // ── Step 1: pilih produk ──
  List<Product> _all = [];
  final Set<int> _selectedIds = {};

  // ── Step 1 (v2.2.57+121): cari & auto-scan barcode ──
  // Searchbar: filter by nama / barcode live. Auto-scan: scanner eksternal
  // (HID) / barcode diketik + Enter → produk ketemu → auto-centang.
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  bool _scannerActive = true;

  // ── Step 2: isi label ──
  bool _showName = true;
  bool _showPrice = true;
  bool _showBarcode = true;

  // ── Step 2 (v2.2.57+116): ukuran font label ──
  // Skala font nama & harga (1.0–3.0) — tersimpan di SecureStore via
  // [LabelFontConfig] (pola sama seperti ReceiptConfig di struk).
  double _nameScale = 1.0;
  double _priceScale = 1.0;

  // ── Step 3: jalur cetak ──
  // Jalur yang sedang dibuka preview-nya (null = semua tertutup).
  // 0 = TSPL, 1 = Struk thermal, 2 = PDF A4.
  int? _expandedPath;
  bool _printing = false;
  String _status = '';

  // ── Qty cetak per produk (v2.2.57+121, dipindah ke dalam tiap cara cetak) ──
  // Berlaku ke SEMUA jalur: TSPL (perintah PRINT n), struk thermal (n×
  // bitmap beruntun), PDF A4 (n× duplikat di grid). Stepper EDITABLE —
  // user bisa ketik sendiri jumlahnya (pola _PosQtyField di POS), bukan
  // cuma tombol −/+.
  final TextEditingController _qtyCtrl = TextEditingController(text: '1');
  int get _qty {
    final v = int.tryParse(_qtyCtrl.text.replaceAll(RegExp(r'[^\d]'), ''));
    if (v == null || v < 1) return 1;
    return v > 999 ? 999 : v;
  }

  /// Set qty — min 1, max 999 (dipakai tombol −/+ dan edit manual).
  void _setQty(int v) {
    final clamped = v.clamp(1, 999);
    _qtyCtrl.text = '$clamped';
    _qtyCtrl.selection = TextSelection.collapsed(offset: _qtyCtrl.text.length);
  }

  // Ukuran label fisik (mm) yang sedang dipilih — didukung oleh getter
  // [_labelW]/[_labelH] (dipakai renderer, TSPL SIZE, PDF grid, preview).
  // v2.2.57+121: dipilih lewat DROPDOWN di dalam jalur Thermal Label (TSPL),
  // bukan chips global. Orientasi LANDSCAPE (lebar ≥ tinggi) supaya barcode
  // lebar kiri-kanan — 19×50mm jadi 50×19mm, dst.
  double _labelWmm = LabelRenderer.defaultWidthMm; // 40
  double _labelHmm = LabelRenderer.defaultHeightMm; // 30

  @override
  void initState() {
    super.initState();
    _loadProducts();
    _loadFontConfig();
    _loadLabelSize();
    // v2.2.57+127: preload lebar kertas struk ke cache sekali di awal —
    // render preview struk jadi sinkron (realtime).
    _paperMm();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _qtyCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadLabelSize() async {
    final cfg = await LabelSizeConfig.load();
    if (mounted) {
      setState(() {
        _labelWmm = cfg.widthMm;
        _labelHmm = cfg.heightMm;
      });
    }
  }

  Future<void> _loadFontConfig() async {
    final cfg = await LabelFontConfig.load();
    if (mounted) {
      setState(() {
        _nameScale = cfg.nameScale;
        _priceScale = cfg.priceScale;
      });
    }
  }

  Future<void> _loadProducts() async {
    final repo = ref.read(productRepoProvider);
    // v2.2.57+127: SEMUA produk bisa dipilih — produk tanpa barcode tetap
    // bisa dicetak (label cuma nama+harga; renderer skip barcode kosong).
    final all = await repo.getProducts();
    if (mounted) {
      setState(() {
        _all = all;
        if (widget.initialProducts != null) {
          for (final p in widget.initialProducts!) {
            _selectedIds.add(p.id);
          }
        }
      });
    }
  }

  List<Product> get _selected =>
      _all.where((p) => _selectedIds.contains(p.id)).toList();

  /// Produk yang TAMPAK di daftar pilih (v2.2.57+121) — filter live oleh
  /// [_query] (nama / barcode). Kosong = tampil semua.
  List<Product> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _all;
    return _all.where((p) {
      final name = p.name.toLowerCase();
      final barcode = (p.barcode ?? '').toLowerCase();
      return name.contains(q) || barcode.contains(q);
    }).toList();
  }

  // ── Render ──

  double get _labelW => _labelWmm;
  double get _labelH => _labelHmm;

  /// Render label bitmap untuk SATU produk (dipakai TSPL + ESC/POS + preview).
  /// Ukuran font nama & harga memakai [_nameScale]/[_priceScale] — SAMA untuk
  /// preview dan print (konsistensi render).
  ///
  /// [fullWidthBarcode] (v2.2.57+116): barcode direntang selebar label —
  /// dipakai jalur struk thermal (barcode rata kiri-kanan kertas struk).
  img.Image _renderFor(Product p, int dpi, {bool fullWidthBarcode = false}) {
    return LabelRenderer.renderLabelBitmap(
      barcode: p.barcode ?? '',
      name: p.name,
      price: p.sellPrice,
      showName: _showName,
      showPrice: _showPrice,
      showBarcode: _showBarcode,
      widthPx: LabelRenderer.mmToPx(_labelW, dpi: dpi).round(),
      heightPx: LabelRenderer.mmToPx(_labelH, dpi: dpi).round(),
      nameFontScale: _nameScale,
      priceFontScale: _priceScale,
      fullWidthBarcode: fullWidthBarcode,
    );
  }

  /// Lebar kertas struk (mm) dari pengaturan — 58 atau 80.
  /// Label struk dirender selebar kertas (full-width barcode) supaya barcode
  /// rata kiri-kanan di kertas struk (v2.2.57+116).
  Future<double> _paperMm() async {
    // v2.2.57+127: cache — preview struk jadi SYNC (realtime mengikuti
    // slider font tanpa tutup-buka card). Paper size jarang berubah;
    // reload tiap kali sheet dibuka via [_loadLabelSize].
    if (_cachedPaperMm != null) return _cachedPaperMm!;
    final w = await SecureStore.getPaperSize(); // '58' | '80'
    _cachedPaperMm = w == '80' ? 80.0 : 58.0;
    return _cachedPaperMm!;
  }

  /// Cache lebar kertas struk (58/80) — di-load sekali di initState.
  double? _cachedPaperMm;

  /// Render bitmap label untuk jalur STRUK: selebar PRINTABLE kertas (384
  /// dot @58mm / 576 @80mm — bukan lebar fisik), tinggi proporsional, barcode
  /// FULL lebar. Preview dan print pakai render yang SAMA → hasil cetak =
  /// preview.
  ///
  /// v2.2.57+128: pakai [LabelRenderer.renderStrukLabelBitmap] — dulu render
  /// 462px (58mm fisik) padahal printer struk hanya mencetak 384 dot → kanan
  /// bitmap dibuang printer (baris barcode kanan hilang) + teks center
  /// bergeser kanan ±5mm.
  img.Image _renderForStruk(Product p, int dpi) {
    final paperMm = _cachedPaperMm ?? 58.0;
    return LabelRenderer.renderStrukLabelBitmap(
      barcode: p.barcode ?? '',
      name: p.name,
      price: p.sellPrice,
      showName: _showName,
      showPrice: _showPrice,
      showBarcode: _showBarcode,
      paperMm: paperMm,
      // Tinggi label struk proporsional: 40×30 → tinggi = printable × 0.75.
      heightMm: 48.0 * (_labelH / _labelW),
      dpi: dpi,
      nameFontScale: _nameScale,
      priceFontScale: _priceScale,
    );
  }

  // ── Koneksi printer (pola printer_settings_sheet) ──

  /// Pastikan izin + Bluetooth aktif, lalu siapkan koneksi printer.
  Future<ReceiptPrinter> _readyPrinter() async {
    await ReceiptPrinter.ensureBluetoothReady();
    return ReceiptPrinter();
  }

  /// Connect ke printer yang alamatnya tersimpan ("Name|MAC").
  Future<bool> _connectStored(String storedAddr) async {
    if (storedAddr.isEmpty || !storedAddr.contains('|')) return false;
    final printer = await _readyPrinter();
    try {
      final devices = await printer.discover();
      final mac = storedAddr.split('|').last;
      for (final d in devices) {
        if (d.address == mac) {
          await printer.connect(d);
          return true;
        }
      }
      // v2.2.57+122: discovery kosong / MAC tidak ketemu → DIRECT-CONNECT ke
      // alamat tersimpan (pola Print Struk _autoPrintReceipt). Beberapa
      // Android menyembunyikan bonded devices sampai connect eksplisit
      // dicoba — tanpa fallback ini printer label "tidak terdeteksi" walau
      // printer yang sama terdeteksi di modul Print Struk.
      debugPrint(
        '[LabelPrint] bonded list tak ada printer — direct connect $mac',
      );
      final ok = await printer.connect(
        PrinterDevice(name: storedAddr.split('|').first, address: mac),
      );
      return ok;
    } finally {
      await printer.dispose();
    }
  }

  /// Printer label belum tersimpan → minta user pilih dari hasil scan,
  /// simpan ke SecureStore, langsung connect.
  Future<bool> _pickLabelPrinter() async {
    final printer = await _readyPrinter();
    List<PrinterDevice> devices;
    try {
      devices = await printer.discover();
    } finally {
      await printer.dispose();
    }
    if (devices.isEmpty) {
      // v2.2.57+122: discovery label kosong, tapi printer STRUK mungkin sudah
      // tersimpan (kasus: 1 printer untuk struk+label). Coba pakai printer
      // struk itu dulu — langsung simpan sebagai label printer juga.
      final savedStruk = await SecureStore.getPrinterAddress();
      if (savedStruk != null && savedStruk.contains('|')) {
        debugPrint(
          '[LabelPrint] discovery kosong — pakai printer struk $savedStruk',
        );
        final ok = await _connectStored(savedStruk);
        if (ok) {
          await SecureStore.setLabelPrinterAddress(savedStruk);
          return true;
        }
      }
      if (mounted) {
        // v2.2.57+122: toast gampang terlewat & pemula tidak tahu harus
        // pairing manual dulu (persis kasus user: "otak-atik" ternyata pair
        // di Settings Bluetooth). Tampilkan panduan langkah + pintasan.
        final retry = await showModalBottomSheet<bool>(
          context: context,
          backgroundColor: Colors.transparent,
          builder: (_) => _printerHelpSheet(),
        );
        if (retry == true) return _pickLabelPrinter(); // scan ulang
      }
      return false;
    }
    if (!mounted) return false;
    final picked = await showModalBottomSheet<PrinterDevice>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _printerPickerSheet(devices),
    );
    if (picked == null) return false;
    final p = ReceiptPrinter();
    try {
      await p.connect(picked);
    } finally {
      await p.dispose();
    }
    await SecureStore.setLabelPrinterAddress(
      '${picked.name}|${picked.address}',
    );
    return true;
  }

  /// Sheet panduan saat TIDAK ADA printer terdeteksi — langkah pairing yang
  /// jelas untuk pemula + pintasan langsung ke Pengaturan Bluetooth Android.
  Widget _printerHelpSheet() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.bluetooth_disabled_outlined,
                color: NusaConfig.warning,
                size: 28,
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Printer Belum Terdeteksi',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _helpStep(
            isDark,
            '1',
            'Pastikan printer label sudah NYALA dan mode Bluetooth-nya aktif.',
          ),
          _helpStep(
            isDark,
            '2',
            'Buka Pengaturan Bluetooth di HP → cari nama printer → ketuk untuk PAIRING (konfirmasi di layar HP maupun printer bila diminta).',
          ),
          _helpStep(
            isDark,
            '3',
            'Setelah ter-pairing, kembali ke aplikasi ini dan ketuk "Cari Ulang".',
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => BluetoothUtils.openBluetoothSettings(),
                  icon: const Icon(Icons.settings_bluetooth, size: 18),
                  label: const Text(
                    'Buka Bluetooth',
                    style: TextStyle(fontSize: 13),
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => Navigator.pop(context, true),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text(
                    'Cari Ulang',
                    style: TextStyle(fontSize: 13),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: NusaConfig.activePrimary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Center(
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                'Batal',
                style: TextStyle(
                  fontSize: 13,
                  color: isDark
                      ? NusaConfig.darkTextSecondary
                      : NusaConfig.textSecondary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _helpStep(bool isDark, String num, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            margin: const EdgeInsets.only(top: 1),
            decoration: BoxDecoration(
              color: NusaConfig.activePrimary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              num,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: NusaConfig.activePrimary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: isDark
                    ? NusaConfig.darkTextSecondary
                    : NusaConfig.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _printerPickerSheet(List<PrinterDevice> devices) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Pilih Printer Label',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'Printer ini akan disimpan khusus untuk cetak label '
            '(terpisah dari printer struk).',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).brightness == Brightness.dark
                  ? NusaConfig.darkTextSecondary
                  : NusaConfig.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: devices.length,
              itemBuilder: (_, i) {
                final d = devices[i];
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.print_outlined,
                    color: NusaConfig.activePrimary,
                  ),
                  title: Text(d.name, style: const TextStyle(fontSize: 14)),
                  subtitle: Text(
                    d.address,
                    style: const TextStyle(fontSize: 11),
                  ),
                  onTap: () => Navigator.pop(context, d),
                );
              },
            ),
          ),
          const SizedBox(height: 4),
          // Pemula sering: printer belum di-pairing → tidak muncul di daftar.
          Row(
            children: [
              Icon(
                Icons.info_outline,
                size: 14,
                color: Theme.of(context).brightness == Brightness.dark
                    ? NusaConfig.darkTextSecondary
                    : NusaConfig.textSecondary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Printer tidak muncul? Pairing dulu di Pengaturan Bluetooth.',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).brightness == Brightness.dark
                        ? NusaConfig.darkTextSecondary
                        : NusaConfig.textSecondary,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => BluetoothUtils.openBluetoothSettings(),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Buka', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Jalur 1: TSPL (thermal label) ──

  /// Auto-scan barcode (v2.2.57+121) — scanner eksternal HID/keyboard wedge:
  /// barcode diketuk cepat + Enter → produk dicari (normalisasi konsisten
  /// dengan POS), ketemu → langsung AUTO-CENTANG + scroll ke item di daftar.
  /// Produk yang tidak ada di [_all] (tanpa barcode) tidak dianggap error.
  Future<void> _handleExternalBarcode(String raw) async {
    final repo = ref.read(productRepoProvider);
    final norm = ProductRepository.normalizeBarcode(raw);
    if (norm.isEmpty) return;
    final product = await repo.byBarcode(norm);
    if (product == null || !mounted) return;
    // Auto-select: centang produk hasil scan (langsung siap cetak).
    setState(() {
      _selectedIds.add(product.id);
      _query = '';
      _searchCtrl.clear();
      _scannerActive = false; // jeda 1.2 dtk supaya scan beruntun rapi
    });
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _scannerActive = true);
    });
    TopToast.success(
      context,
      '${product.name} dipilih — ${_selectedIds.length} produk siap cetak',
    );
  }

  /// Enter di kolom cari — jalur manual scan (ketik barcode lalu Enter),
  /// konsisten dengan POS. Ketemu → auto-centang + focus kolom tetap untuk
  /// scan beruntun.
  Future<void> _handleSearchSubmit(String raw) async {
    if (_scannerActive) return; // HID listener yang handle scan eksternal
    final repo = ref.read(productRepoProvider);
    final norm = ProductRepository.normalizeBarcode(raw);
    if (norm.isEmpty) return;
    final product = await repo.byBarcode(norm);
    if (product == null) {
      if (mounted) {
        TopToast.error(context, 'Barcode tidak ditemukan di daftar produk');
      }
      return;
    }
    setState(() {
      _selectedIds.add(product.id);
      _query = '';
      _searchCtrl.clear();
    });
    if (mounted) {
      TopToast.success(context, '${product.name} dipilih');
    }
  }

  /// Auto-scan jalur print label (v2.2.57+121) — produk dari scan barcode
  /// (HID eksternal ATAU Enter kolom cari) DITAMBAHKAN ke pilihan, bukan
  /// menggantikan. Setiap produk dicetak [_qty]×.
  ///
  /// Dipakai [HidBarcodeListener] di build (selalu aktif) dan [_searchCtrl]
  /// (onSubmitted).
  void _handleScanInput(String raw) {
    if (!_scannerActive) return;
    _handleExternalBarcode(raw);
  }

  /// Scan barcode via KAMERA INTERNAL (v2.2.57+121) — mobile_scanner,
  /// pola sama dengan layar Produk & Kasir. Hasil scan → produk auto-centang,
  /// langsung siap cetak.
  Future<void> _scanWithCamera() async {
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
              const SizedBox(width: 8),
              const Text('Scan Barcode Produk'),
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
                    debugPrint('[LabelPrint] scanner error: $error');
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
                              'Kamera tidak tersedia.\nBarcode manual di Form Produk.',
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
              child: const Text('Batal'),
            ),
          ],
        ),
      ),
    );
    await controller.dispose();
    if (scanned == null || !mounted) return;
    await _handleExternalBarcode(scanned!);
  }

  Future<bool> _printTspl() async {
    if (_selected.isEmpty) return false;
    var connected = false;
    final stored = await SecureStore.getLabelPrinterAddress();
    if (stored != null && stored.isNotEmpty) {
      connected = await _connectStored(stored);
    } else {
      connected = await _pickLabelPrinter();
    }
    if (!connected) {
      if (mounted) {
        TopToast.error(
          context,
          'Printer label tidak ditemukan / belum tersambung',
        );
      }
      return false;
    }
    final buf = BytesBuilder();
    for (final p in _selected) {
      buf.add(
        LabelCommands.buildTspl(
          _renderFor(p, LabelDpi.dpi203),
          labelWidthMm: _labelW,
          labelHeightMm: _labelH,
          gapMm: 2,
          copies: _qty,
        ),
      );
    }
    final sent = await BluetoothUtils.sendBytes(buf.toBytes());
    if (!sent && mounted) {
      TopToast.error(context, 'Gagal mengirim ke printer label');
    }
    return sent;
  }

  // ── Jalur 2: ESC/POS thermal struk ──

  Future<bool> _printEscPos() async {
    if (_selected.isEmpty) return false;
    final stored = await SecureStore.getPrinterAddress();
    if (stored == null || stored.isEmpty) {
      if (mounted) {
        TopToast.error(
          context,
          'Atur printer struk dulu di Pengaturan → Printer Struk',
        );
      }
      return false;
    }
    final ok = await _connectStored(stored);
    if (!ok) {
      if (mounted) {
        TopToast.error(
          context,
          'Printer struk tidak ditemukan. Cek Pengaturan → Printer Struk.',
        );
      }
      return false;
    }
    final buf = BytesBuilder();
    for (final p in _selected) {
      // v2.2.57+127: render sync (paper size dari cache) — await tidak lagi
      // diperlukan, tapi tetap dipanggil di fungsi async ini tanpa masalah.
      final bitmap = _renderForStruk(p, LabelDpi.dpi203);
      // v2.2.57+121: qty cetak → kirim bitmap yang sama n× beruntun
      // (feed+cut antar label, konsisten dengan qty di TSPL).
      for (var i = 0; i < _qty; i++) {
        buf.add(
          LabelCommands.buildEscPosLabel(
            bitmap: bitmap,
            name: p.name,
            price: p.sellPrice,
            showName: _showName,
            showPrice: _showPrice,
          ),
        );
      }
    }
    final sent = await BluetoothUtils.sendBytes(buf.toBytes());
    if (!sent && mounted) {
      TopToast.error(context, 'Gagal mengirim ke printer struk');
    }
    return sent;
  }

  // ── Jalur 3: PDF A4 grid ──

  Future<File?> _buildPdf() async {
    if (_selected.isEmpty) return null;
    final doc = pw.Document(title: 'Label Barcode', author: 'NUSA Kasir');
    // Grid: label 40×30mm, margin 8mm, gap 4mm → ~4 kolom × 8 baris per A4.
    // Angka SAMA dengan preview _A4GridPreview (konsistensi layout).
    // v2.2.57+121: ukuran label bisa dipilih user → kolom/baris dihitung
    // ulang; qty cetak → tiap produk masuk [_qty]× ke grid.
    const pageW = 210.0, pageH = 297.0;
    const marginMm = 8.0, gapMm = 4.0;
    final cols = ((pageW - 2 * marginMm + gapMm) / (_labelW + gapMm)).floor();
    final rows = ((pageH - 2 * marginMm + gapMm) / (_labelH + gapMm)).floor();
    final perPage = cols * rows;

    // Daftar label dengan duplikasi qty — urutan: semua produk × qty,
    // lalu dibagi per halaman.
    final expanded = <Product>[
      for (final p in _selected)
        for (var i = 0; i < _qty; i++) p,
    ];

    for (var i = 0; i < expanded.length; i += perPage) {
      final end = i + perPage > expanded.length ? expanded.length : i + perPage;
      final pageItems = expanded.sublist(i, end);
      final widgets = pageItems
          .map(
            (p) => LabelRenderer.pdfLabel(
              barcode: p.barcode ?? '',
              name: p.name,
              price: p.sellPrice,
              showName: _showName,
              showPrice: _showPrice,
              showBarcode: _showBarcode,
              widthMm: _labelW,
              heightMm: _labelH,
              nameFontScale: _nameScale,
              priceFontScale: _priceScale,
            ),
          )
          .toList();
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4.copyWith(
            marginLeft: marginMm * PdfPageFormat.mm,
            marginRight: marginMm * PdfPageFormat.mm,
            marginTop: marginMm * PdfPageFormat.mm,
            marginBottom: marginMm * PdfPageFormat.mm,
          ),
          build: (_) => pw.Wrap(
            spacing: gapMm * PdfPageFormat.mm,
            runSpacing: gapMm * PdfPageFormat.mm,
            children: widgets,
          ),
        ),
      );
    }
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/label_barcode_${DateTime.now().millisecondsSinceEpoch}.pdf',
    );
    await file.writeAsBytes(await doc.save());
    return file;
  }

  Future<bool> _sharePdf() async {
    try {
      final file = await _buildPdf();
      if (file == null) return false;
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], subject: 'Label Barcode'),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Jalankan aksi cetak untuk jalur [path] dengan spinner + status.
  Future<void> _runPrint(int path) async {
    if (_selected.isEmpty) {
      TopToast.error(context, 'Pilih produk dulu');
      return;
    }
    setState(() {
      _printing = true;
      _status = 'Mencetak ${_selected.length} label…';
    });
    final ok = switch (path) {
      0 => await _printTspl(),
      1 => await _printEscPos(),
      _ => await _sharePdf(),
    };
    if (mounted) {
      setState(() {
        _printing = false;
        _status = ok
            ? 'Selesai — ${_selected.length} label dikirim.'
            : 'Gagal mencetak. Periksa printer & Bluetooth.';
      });
    }
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    // v2.2.57+121: HidBarcodeListener menangkap scanner eksternal (HID/USB/
    // Bluetooth keyboard wedge) di layar ini — scan barcode langsung
    // auto-centang produk tanpa mengetik. Keypad layar TIDAK muncul karena
    // listener bekerja di level Focus (pola sama dengan POS).
    return HidBarcodeListener(
      onBarcode: _handleScanInput,
      child: ScreenScaffold('Cetak Label Barcode', _buildBody()),
    );
  }

  Widget _buildBody() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _stepHeader('1', 'Pilih Produk'),
        // ── Search + auto-scan barcode (v2.2.57+121) ──
        // Search bar PUTIH + icon kamera (scan internal) di kanan — selain
        // scanner eksternal HID (auto-centang). Ketik nama/barcode filter
        // daftar; scan kamera / HID → produk auto-centang.
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _query = v),
            onSubmitted: _handleSearchSubmit,
            textInputAction: TextInputAction.search,
            style: const TextStyle(color: Colors.black87, fontSize: 15),
            decoration: InputDecoration(
              hintText: 'Cari nama atau scan barcode…',
              hintStyle: TextStyle(color: Colors.grey.shade500, fontSize: 15),
              prefixIcon: Icon(Icons.search, color: Colors.grey.shade600),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    onPressed: _scanWithCamera,
                    icon: Icon(
                      Icons.qr_code_scanner_rounded,
                      color: NusaConfig.activePrimary,
                      size: 24,
                    ),
                    tooltip: 'Scan barcode (kamera)',
                  ),
                  if (_query.isNotEmpty)
                    IconButton(
                      icon: Icon(Icons.clear, color: Colors.grey.shade600),
                      onPressed: () => setState(() {
                        _query = '';
                        _searchCtrl.clear();
                      }),
                    ),
                ],
              ),
              filled: true,
              fillColor: Colors.white,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Icon(
              Icons.qr_code_scanner,
              size: 13,
              color: Theme.of(context).brightness == Brightness.dark
                  ? NusaConfig.darkTextTertiary
                  : NusaConfig.textTertiary,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                'Scan barcode (kamera / scanner eksternal / ketik + Enter) → '
                'produk langsung dipilih',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).brightness == Brightness.dark
                      ? NusaConfig.darkTextTertiary
                      : NusaConfig.textTertiary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _selectAllRow(),
        const SizedBox(height: 8),
        if (_filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                _all.isEmpty
                    ? 'Belum ada produk.\nTambahkan produk dulu di Form Produk.'
                    : 'Tidak ada produk cocok "$_query".',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          )
        else
          _productList(),
        const SizedBox(height: 20),

        _stepHeader('2', 'Isi Label & Ukuran Font'),
        _checkRow(
          value: _showName,
          onChanged: (v) => setState(() => _showName = v),
          label: 'Nama Produk',
        ),
        _checkRow(
          value: _showPrice,
          onChanged: (v) => setState(() => _showPrice = v),
          label: 'Harga',
        ),
        // v2.2.57+127: checkbox Barcode otomatis DISABLE bila semua produk
        // terpilih tidak ber-barcode — tidak ada yang bisa dicetak, jadi
        // user tidak bingung kenapa barcode tidak muncul.
        Builder(builder: (context) {
          final selected = _selected;
          final noneHaveBarcode = selected.isNotEmpty &&
              selected.every(
                (p) => p.barcode == null || p.barcode!.trim().isEmpty,
              );
          if (noneHaveBarcode && _showBarcode) {
            // Auto-matikan sekali (di build — aman, cuma sinkronisasi UI).
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _showBarcode) setState(() => _showBarcode = false);
            });
          }
          return _checkRow(
            value: _showBarcode && !noneHaveBarcode,
            // Kalau noneHaveBarcode: toggle tidak berpengaruh (tetap off).
            onChanged: (v) {
              if (noneHaveBarcode) return;
              setState(() => _showBarcode = v);
            },
            label: 'Barcode',
            enabled: !noneHaveBarcode,
            hint: noneHaveBarcode
                ? 'Semua produk terpilih tanpa barcode'
                : null,
          );
        }),
        const SizedBox(height: 12),
        // ── Ukuran font label (v2.2.57+116) ──
        // User bisa sesuaikan ukuran font nama & harga — berlaku ke SEMUA
        // jalur cetak (TSPL / struk / PDF), preview ikut berubah live.
        Text(
          'Ukuran Font Label',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).brightness == Brightness.dark
                ? NusaConfig.darkTextPrimary
                : NusaConfig.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Atur besar tulisan nama & harga. Berlaku untuk semua jalur cetak.',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).brightness == Brightness.dark
                ? NusaConfig.darkTextSecondary
                : NusaConfig.textSecondary,
          ),
        ),
        _fontSlider(
          label: 'Nama Produk',
          value: _nameScale,
          onChanged: (v) {
            setState(() => _nameScale = v);
            LabelFontConfig(nameScale: v, priceScale: _priceScale).save();
          },
        ),
        _fontSlider(
          label: 'Harga',
          value: _priceScale,
          onChanged: (v) {
            setState(() => _priceScale = v);
            LabelFontConfig(nameScale: _nameScale, priceScale: v).save();
          },
        ),
        const SizedBox(height: 16),
        // ── Ukuran label & qty DIPINDAH ke dalam tiap cara cetak ──
        // (v2.2.57+121): ukuran label dropdown ada di jalur Thermal Label
        // (TSPL) karena memang untuk printer label; qty stepper EDITABLE
        // ada di dalam tiap cara cetak (TSPL / Struk / PDF) — dekat tombol
        // Cetak, bukan di pengaturan global.
        const SizedBox(height: 16),

        _stepHeader('3', 'Cara Cetak'),
        Text(
          'Klik jalur cetak untuk lihat preview hasilnya, lalu tekan Cetak.',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).brightness == Brightness.dark
                ? NusaConfig.darkTextSecondary
                : NusaConfig.textSecondary,
          ),
        ),
        const SizedBox(height: 10),
        _pathCard(
          path: 0,
          icon: Icons.print_outlined,
          title: 'Thermal Label (TSPL)',
          subtitle: 'Printer label khusus — Rongta/HPRT/Godex/BluePrint',
          // v2.2.57+121: ukuran label + qty ADA DI SINI (dalam jalur TSPL)
          // — dropdown ukuran (tanpa kode) + stepper qty editable.
          sizeDropdown: _labelSizeDropdown(),
          preview: _selected.isEmpty
              ? null
              : _LabelBitmapPreview(
                  product: _selected.first,
                  sheet: this,
                  dpi: LabelDpi.dpi203,
                  // v2.2.57+121: ukuran label mengikuti pilihan user.
                  paperNote:
                      'Printer label ${_mmLabel(_labelW, _labelH)} • $_qty× • bitmap 203 DPI',
                ),
        ),
        _pathCard(
          path: 1,
          icon: Icons.receipt_long_outlined,
          title: 'Thermal Struk 58mm',
          subtitle: 'Printer struk yang sudah dipakai — label beruntun',
          preview: _selected.isEmpty
              ? null
              : _StrukPreview(product: _selected.first, sheet: this),
        ),
        _pathCard(
          path: 2,
          icon: Icons.picture_as_pdf_outlined,
          title: 'PDF A4 (grid)',
          subtitle:
              'Banyak label sekaligus, siap dipotong / dicetak printer umum',
          preview: _selected.isEmpty
              ? null
              : _A4GridPreview(products: _selected, sheet: this),
        ),
        if (_status.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _status,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).brightness == Brightness.dark
                    ? NusaConfig.darkTextSecondary
                    : NusaConfig.textSecondary,
              ),
            ),
          ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _stepHeader(String num, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: NusaConfig.activePrimary,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              num,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _selectAllRow() {
    // v2.2.57+127: produk tanpa barcode ikut terpilih — checkbox "Barcode"
    // otomatis nonaktif bila SEMUA terpilih tanpa barcode (label cuma
    // nama & harga; renderer sudah skip barcode kosong per item).
    final allSelected = _filtered.isNotEmpty && _selectedIds.length == _all.length;
    final selected = _selected;
    final noneHaveBarcode = selected.isNotEmpty &&
        selected.every((p) => p.barcode == null || p.barcode!.trim().isEmpty);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        Checkbox(
          value: allSelected,
          onChanged: (v) => setState(() {
            if (v == true) {
              _selectedIds.addAll(_all.map((p) => p.id));
            } else {
              _selectedIds.clear();
            }
          }),
        ),
        const SizedBox(width: 8),
        Text(
          'Pilih Semua (${_selectedIds.length}/${_all.length})',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
        if (noneHaveBarcode) ...[
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: Colors.orange.withValues(alpha: 0.4),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 12,
                  color: Colors.orange.shade700,
                ),
                const SizedBox(width: 4),
                Text(
                  'Tanpa barcode — label nama & harga',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: isDark ? Colors.orange.shade300 : Colors.orange.shade800,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _productList() {
    // v2.2.57+127: daftar checkbox dibungkus CARD STATIS 3D raised SCROLLABLE
    // — saat produk sudah ratusan/ribuan, yang tampak ±5 item, sisanya di-
    // scroll atas-bawah di dalam card (page tidak memanjang tak terbatas).
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.08);
    final shadowColor = isDark
        ? Colors.black.withValues(alpha: 0.55)
        : Colors.black.withValues(alpha: 0.10);
    return Container(
      // Tinggi card ≈ 5 item (± 64px/item) + padding — sisanya discroll.
      height: 340,
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
      decoration: BoxDecoration(
        // Permukaan 3D: gradient halus terang→gelap + border + double shadow
        // (atas terang, bawah gelap) = kesan raised.
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? [const Color(0xFF2A2D34), const Color(0xFF1E2128)]
              : [Colors.white, const Color(0xFFF4F5F7)],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor, width: 1),
        boxShadow: [
          BoxShadow(
            color: shadowColor,
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: isDark
                ? Colors.white.withValues(alpha: 0.04)
                : Colors.white.withValues(alpha: 0.9),
            blurRadius: 1,
            offset: const Offset(0, -1),
          ),
        ],
      ),
      // ListView.builder = efisien utk ribuan produk (lazy build per item).
      child: ListView.builder(
        itemCount: _filtered.length,
        itemBuilder: (context, i) {
          final p = _filtered[i];
          final sel = _selectedIds.contains(p.id);
          final hasBarcode = p.barcode != null && p.barcode!.trim().isNotEmpty;
          return Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: sel ? NusaConfig.activePrimary : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Row(
              children: [
                Checkbox(
                  value: sel,
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _selectedIds.add(p.id);
                    } else {
                      _selectedIds.remove(p.id);
                    }
                  }),
                ),
                NusaProductImage(
                  imagePath: p.imagePath,
                  imageBase64: p.imageBase64,
                  productId: p.id,
                  tintColor: NusaConfig.activePrimary,
                  width: 34,
                  height: 34,
                  borderRadius: BorderRadius.circular(6),
                  placeholder: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: Colors.grey.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(
                      Icons.inventory_2_outlined,
                      size: 18,
                      color: Colors.grey,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      // Ber-barcode → tampil barcode • harga; tanpa barcode
                      // → badge oranye (label cuma nama & harga — renderer
                      // otomatis skip barcode kosong, tidak crash).
                      hasBarcode
                          ? Text(
                              '${p.barcode}  •  ${formatRupiah(p.sellPrice)}',
                              style: TextStyle(
                                fontSize: 11,
                                fontFamily: 'monospace',
                                color: Colors.grey.shade600,
                              ),
                            )
                          : Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.orange.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(5),
                                    border: Border.all(
                                      color: Colors.orange.withValues(alpha: 0.5),
                                      width: 1,
                                    ),
                                  ),
                                  child: const Text(
                                    'Tanpa barcode',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.orange,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  formatRupiah(p.sellPrice),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                              ],
                            ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Opsi ukuran label (v2.2.57+121) — (kode, lebar mm, tinggi mm).
  /// Semua ukuran diputar LANDSCAPE (lebar ≥ tinggi) supaya barcode lebar
  /// kiri-kanan dan nama/harga muat — mis. "19×50" jadi 50×19. Kode tidak
  /// ditampilkan ke user (hanya ukuran mm).
  static const List<(int, double, double)> _labelSizes = [
    (0, 40, 30), // default thermal label
    (99, 34, 5),
    (100, 100, 38),
    (101, 100, 50),
    (102, 50, 50),
    (103, 64, 32),
    (104, 76, 25),
    (105, 38, 25),
    (106, 25, 25),
    (107, 50, 19),
    (108, 38, 19),
    (109, 38, 13),
    (110, 22, 16),
    (111, 19, 13),
    (112, 13, 9),
    (119, 152, 102),
    (120, 118, 78),
    (121, 76, 38),
    (122, 85, 17),
    (123, 30, 12),
    (124, 57, 40),
    (125, 58, 17),
    (126, 100, 17),
    (127, 100, 25),
  ];

  /// Label ukuran mm — "50×19 mm" (tanpa kode, v2.2.57+121).
  String _sizeLabel(int code, double w, double h) {
    final a = w == w.roundToDouble() ? w.toInt().toString() : w.toString();
    final b = h == h.roundToDouble() ? h.toInt().toString() : h.toString();
    return '$a×$b mm';
  }

  /// Label polos ukuran mm, mis. "40×30 mm" (dipakai caption preview).
  String _mmLabel(double w, double h) {
    final a = w == w.roundToDouble() ? w.toInt().toString() : w.toString();
    final b = h == h.roundToDouble() ? h.toInt().toString() : h.toString();
    return '$a×$b mm';
  }

  Widget _checkRow({
    required bool value,
    required ValueChanged<bool> onChanged,
    required String label,
    bool enabled = true,
    String? hint,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        Checkbox(value: value, onChanged: (v) => onChanged(v ?? value)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  color: enabled
                      ? null
                      : (isDark
                          ? NusaConfig.darkTextTertiary
                          : NusaConfig.textTertiary),
                ),
              ),
              if (hint != null)
                Text(
                  hint,
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
    );
  }

  /// Slider ukuran font label (v2.2.57+116): 1.0× – 3.0×.
  Widget _fontSlider({
    required String label,
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(label, style: const TextStyle(fontSize: 13)),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(1.0, 3.0),
              min: 1.0,
              max: 3.0,
              divisions: 16,
              activeColor: NusaConfig.activePrimary,
              label: '${value.toStringAsFixed(1)}×',
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 36,
            child: Text(
              '${value.toStringAsFixed(1)}×',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: isDark
                    ? NusaConfig.darkTextPrimary
                    : NusaConfig.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Kartu jalur cetak — KLIK untuk buka/tutup preview ACTUAL jalur tsb.
  /// Preview + tombol cetak muncul di dalam kartu saat terbuka.
  ///
  /// v2.2.57+121: [sizeDropdown] (khusus TSPL — pilih ukuran label) dan
  /// qty stepper EDITABLE ([_qtyControl]) ditampilkan di dalam kartu,
  /// dekat tombol Cetak — bukan global.
  Widget _pathCard({
    required int path,
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget? preview,
    Widget? sizeDropdown,
  }) {
    final expanded = _expandedPath == path;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: expanded
              ? NusaConfig.activePrimary.withValues(alpha: 0.6)
              : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: Column(
        children: [
          ListTile(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            tileColor: Colors.grey.withValues(alpha: 0.06),
            leading: Icon(icon, color: NusaConfig.activePrimary),
            title: Text(
              title,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
            trailing: AnimatedRotation(
              turns: expanded ? 0.5 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: const Icon(Icons.keyboard_arrow_down),
            ),
            onTap: () {
              if (_selected.isEmpty) {
                TopToast.error(context, 'Pilih produk dulu');
                return;
              }
              setState(() {
                _expandedPath = expanded ? null : path;
                _status = '';
              });
            },
          ),
          if (expanded && preview != null)
            Container(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
              decoration: BoxDecoration(
                color: isDark
                    ? NusaConfig.darkSurface2.withValues(alpha: 0.5)
                    : Colors.grey.withValues(alpha: 0.04),
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(12),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Ukuran label — hanya jalur TSPL (v2.2.57+121).
                  if (sizeDropdown != null) ...[
                    sizeDropdown,
                    const SizedBox(height: 10),
                  ],
                  preview,
                  const SizedBox(height: 12),
                  // Qty cetak — stepper EDITABLE di dalam tiap cara cetak
                  // (v2.2.57+121): user bisa ketik sendiri jumlahnya.
                  _qtyControl(),
                  const SizedBox(height: 12),
                  // Tombol cetak — ada DI DALAM preview (permintaan user).
                  FilledButton.icon(
                    onPressed: _printing ? null : () => _runPrint(path),
                    icon: _printing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Icon(
                            path == 2
                                ? Icons.share_outlined
                                : Icons.print_outlined,
                            size: 18,
                          ),
                    label: Text(
                      _printing
                          ? 'Mencetak…'
                          : path == 2
                          ? 'Buka PDF — Print / Simpan'
                          : 'Cetak ${_selected.length * _qty} Label',
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    path == 2
                        ? 'PDF dibuat dari render yang sama dengan preview — '
                              'share sheet Android bisa langsung Print ke printer umum.'
                        : 'Dikirim via Bluetooth ke printer yang tersimpan.',
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
        ],
      ),
    );
  }

  /// Stepper qty cetak EDITABLE (v2.2.57+121) — tombol −/+ ATAU ketik angka
  /// langsung (pola _PosQtyField di POS). Min 1, max 999.
  Widget _qtyControl() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? NusaConfig.darkSurface2 : NusaConfig.backgroundColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: NusaConfig.activePrimary.withValues(alpha: 0.35),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.print_outlined, size: 18, color: NusaConfig.activePrimary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Qty Cetak per Produk',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isDark
                        ? NusaConfig.darkTextPrimary
                        : NusaConfig.textPrimary,
                  ),
                ),
                Text(
                  'Tiap produk dicetak $_qty× (total ${_selected.length * _qty} label)',
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
          const SizedBox(width: 8),
          // Stepper − [isi] + — qty bisa diketik manual.
          Container(
            height: 38,
            decoration: BoxDecoration(
              color: isDark ? NusaConfig.darkSurface : NusaConfig.activeSoft,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: NusaConfig.activePrimary.withValues(alpha: 0.5),
                width: 1.2,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _qtyBtn(Icons.remove, () => _setQty(_qty - 1)),
                SizedBox(
                  width: 44,
                  child: TextField(
                    controller: _qtyCtrl,
                    textAlign: TextAlign.center,
                    keyboardType: TextInputType.number,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: NusaConfig.activePrimary,
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
                _qtyBtn(Icons.add, () => _setQty(_qty + 1)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _qtyBtn(IconData icon, VoidCallback onTap) {
    final enabled = icon == Icons.remove ? _qty > 1 : _qty < 999;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 38,
          height: 38,
          child: Center(
            child: Icon(
              icon,
              size: 18,
              color: enabled
                  ? NusaConfig.activePrimary
                  : NusaConfig.textTertiary.withValues(alpha: 0.4),
            ),
          ),
        ),
      ),
    );
  }

  /// Dropdown ukuran label (v2.2.57+121) — muncul di jalur Thermal Label
  /// (TSPL). Tanpa kode, orientasi LANDSCAPE (lebar ≥ tinggi). Setiap
  /// pemilihan langsung tersimpan (LabelSizeConfig) + preview ikut berubah.
  Widget _labelSizeDropdown() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selectedIndex = _labelSizes.indexWhere(
      (s) => _labelWmm == s.$2 && _labelHmm == s.$3,
    );
    final idx = selectedIndex >= 0 ? selectedIndex : 0;
    final textPri = isDark
        ? NusaConfig.darkTextPrimary
        : NusaConfig.textPrimary;
    final textSec = isDark
        ? NusaConfig.darkTextSecondary
        : NusaConfig.textSecondary;
    final border = isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark ? NusaConfig.darkSurface : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Row(
        children: [
          Icon(
            Icons.straighten_outlined,
            size: 18,
            color: NusaConfig.activePrimary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: idx,
                isExpanded: true,
                icon: Icon(Icons.arrow_drop_down, size: 20, color: textSec),
                style: TextStyle(fontSize: 13, color: textPri),
                items: [
                  for (var i = 0; i < _labelSizes.length; i++)
                    DropdownMenuItem<int>(
                      value: i,
                      child: Text(
                        _sizeLabel(
                          _labelSizes[i].$1,
                          _labelSizes[i].$2,
                          _labelSizes[i].$3,
                        ),
                        style: const TextStyle(fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  final s = _labelSizes[v];
                  setState(() {
                    _labelWmm = s.$2;
                    _labelHmm = s.$3;
                    LabelSizeConfig(widthMm: s.$2, heightMm: s.$3).save();
                  });
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Preview bitmap label — render ACTUAL via [LabelRenderer.renderLabelBitmap]
/// (SAMA dengan yang dikirim ke printer TSPL/struk). Dipakai jalur TSPL.
class _LabelBitmapPreview extends StatelessWidget {
  final Product product;
  final _LabelPrintSheetState sheet;
  final int dpi;
  final String paperNote;

  const _LabelBitmapPreview({
    required this.product,
    required this.sheet,
    required this.dpi,
    required this.paperNote,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bitmap = sheet._renderFor(product, dpi);
    final pngBytes = Uint8List.fromList(img.encodePng(bitmap));
    final previewH = 140.0;
    final aspect = bitmap.width / bitmap.height;

    return Column(
      children: [
        Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isDark ? NusaConfig.darkSurface2 : const Color(0xFFF3F4F6),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(4),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Image.memory(
              pngBytes,
              height: previewH,
              width: previewH * aspect,
              gaplessPlayback: true,
              fit: BoxFit.contain,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          paperNote,
          style: TextStyle(
            fontSize: 11,
            color: isDark
                ? NusaConfig.darkTextTertiary
                : NusaConfig.textTertiary,
          ),
        ),
      ],
    );
  }
}

/// Preview jalur struk thermal — render ACTUAL selebar kertas (58/80mm,
/// barcode full-width) di atas visual kertas struk, lalu garis potong.
/// Preview = hasil cetak (render sama dengan _printEscPos).
///
/// v2.2.57+127: STATELESS render SYNC di build() — pola persis
/// [_LabelBitmapPreview] (TSPL). Setiap perubahan slider font nama/harga
/// / isi label → parent setState → build() jalan ulang → bitmap render
/// ULANG LANGSUNG → preview REALTIME (sebelumnya StatefulWidget dengan
/// didUpdateWidget yang membandingkan field instance sheet yang SAMA —
/// tidak pernah trigger, user harus tutup-buka card).
class _StrukPreview extends StatelessWidget {
  final Product product;
  final _LabelPrintSheetState sheet;

  const _StrukPreview({required this.product, required this.sheet});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Render langsung di build — paper size dari cache (preload initState).
    final bitmap = sheet._renderForStruk(product, LabelDpi.dpi203);
    final pngBytes = Uint8List.fromList(img.encodePng(bitmap));
    final paperMm = sheet._cachedPaperMm ?? 58.0;
    // Visual kertas struk: selebar bitmap (full paper width).
    final paperW = 190.0;
    final bitmapW = paperW;
    final bitmapH = bitmapW * bitmap.height / bitmap.width;

    return Column(
      children: [
        Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isDark ? NusaConfig.darkSurface2 : const Color(0xFFF3F4F6),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Container(
            width: paperW,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(3),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              children: [
                Image.memory(
                  pngBytes,
                  width: bitmapW,
                  height: bitmapH,
                  gaplessPlayback: true,
                  fit: BoxFit.contain,
                ),
                const SizedBox(height: 6),
                // Garis potong putus-putus (dari cutter printer struk).
                CustomPaint(
                  size: const Size(double.infinity, 1),
                  painter: _DashedLinePainter(
                    color: isDark ? Colors.grey.shade500 : Colors.grey.shade400,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '✂ potong',
                  style: TextStyle(
                    fontSize: 9,
                    letterSpacing: 2,
                    color: isDark
                        ? NusaConfig.darkTextTertiary
                        : NusaConfig.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Kertas ${paperMm == 80 ? '80' : '58'}mm • label selebar kertas • bit-image ESC/POS'
          '${sheet._qty > 1 ? ' • ${sheet._qty}×' : ''}',
          style: TextStyle(
            fontSize: 11,
            color: isDark
                ? NusaConfig.darkTextTertiary
                : NusaConfig.textTertiary,
          ),
        ),
      ],
    );
  }
}

/// Preview PDF A4 — replika lembar A4 yang akurat dengan layout yang SAMA
/// dengan PDF asli (grid 4×8, margin 8mm, gap 4mm, label 40×30mm).
/// Konten label (barcode/nama/harga) dirender sungguhan, bukan mockup —
/// skala per-lembar supaya terlihat seperti hasil cetak.
class _A4GridPreview extends StatelessWidget {
  final List<Product> products;
  final _LabelPrintSheetState sheet;

  const _A4GridPreview({required this.products, required this.sheet});

  static const _pageWmm = 210.0, _pageHmm = 297.0;
  static const _marginMm = 8.0, _gapMm = 4.0;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final labelW = sheet._labelW, labelH = sheet._labelH;
    // Hitung grid SAMA seperti _buildPdf (konsistensi preview = hasil).
    final cols = ((_pageWmm - 2 * _marginMm + _gapMm) / (labelW + _gapMm))
        .floor();
    final rows = ((_pageHmm - 2 * _marginMm + _gapMm) / (labelH + _gapMm))
        .floor();
    final perPage = cols * rows;
    final pages = ((products.length + perPage - 1) / perPage).ceil();
    final shown = products.take(perPage).toList();
    // Ukuran logis lembar; FittedBox mengecilkan agar muat selebar kartu.
    const sheetW = 380.0;
    final scale = sheetW / _pageWmm;
    final sheetH = _pageHmm * scale;

    return Column(
      children: [
        Center(
          child: FittedBox(
            fit: BoxFit.contain,
            child: Container(
              width: sheetW,
              height: sheetH,
              padding: EdgeInsets.all(_marginMm * scale),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(4),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Stack(
                children: [
                  for (var i = 0; i < shown.length; i++)
                    Positioned(
                      left: (i % cols) * (labelW + _gapMm) * scale,
                      top: (i ~/ cols) * (labelH + _gapMm) * scale,
                      width: labelW * scale,
                      height: labelH * scale,
                      child: _MiniLabel(
                        product: shown[i],
                        sheet: sheet,
                        scale: scale,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Lembar A4 • $cols×$rows label • '
          '${products.length} label → $pages ${pages > 1 ? 'halaman' : 'halaman'} '
          '(${labelW.toStringAsFixed(0)}×${labelH.toStringAsFixed(0)}mm)',
          style: TextStyle(
            fontSize: 11,
            color: isDark
                ? NusaConfig.darkTextTertiary
                : NusaConfig.textTertiary,
          ),
        ),
      ],
    );
  }
}

/// Satu label mini di dalam preview lembar A4 — konten ACTUAL (barcode
/// CODE128 + nama + harga) dirender sesuai isi label & ukuran font.
/// Layout = persis [LabelRenderer.pdfLabel] (preview = hasil PDF):
/// barcode selebar 90% label × tinggi 22% label, lalu nama (maks 2 baris),
/// lalu harga — semua center.
class _MiniLabel extends StatelessWidget {
  final Product product;
  final _LabelPrintSheetState sheet;
  final double scale;

  const _MiniLabel({
    required this.product,
    required this.sheet,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    final showBarcode = sheet._showBarcode;
    final showName = sheet._showName;
    final showPrice = sheet._showPrice;
    final barcode = product.barcode ?? '';
    // Ukuran barcode SAMA dengan pdfLabel: lebar 90% label, tinggi 22%.
    final barW = sheet._labelW * scale * 0.9;
    final barH = sheet._labelH * scale * 0.22;
    final bars = showBarcode && barcode.trim().isNotEmpty
        ? LabelRenderer.barcodeBars(barcode, barW, barH)
        : const <bc.BarcodeElement>[];

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade400, width: 0.5),
      ),
      padding: EdgeInsets.all(2 * scale),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Barcode: SizedBox UKURAN PASTI = ruang koordinat bars →
          // painter tidak mungkin meluber keluar kotak (fix v2.2.57+116).
          if (bars.isNotEmpty)
            SizedBox(
              width: barW,
              height: barH,
              child: CustomPaint(
                painter: _BarPainter(bars),
                size: Size(barW, barH),
              ),
            ),
          if (bars.isNotEmpty && showName) SizedBox(height: 1.5 * scale),
          if (showName && product.name.trim().isNotEmpty)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 1 * scale),
              child: Text(
                product.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 7.5 * sheet._nameScale * scale / 2.6,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF111827),
                  height: 1.1,
                ),
              ),
            ),
          if (showName && showPrice) SizedBox(height: 0.8 * scale),
          if (showPrice)
            Text(
              'Rp ${_fmtPrice(product.sellPrice)}',
              maxLines: 1,
              style: TextStyle(
                fontSize: 8 * sheet._priceScale * scale / 2.6,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF111827),
              ),
            ),
        ],
      ),
    );
  }

  static String _fmtPrice(int price) {
    final s = price.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write('.');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}

/// Painter barcode CODE128 dari [LabelRenderer.barcodeBars] (rendered SAMA
/// dengan print — bukan gambar placeholder).
class _BarPainter extends CustomPainter {
  final List<bc.BarcodeElement> bars;
  _BarPainter(this.bars);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black;
    for (final el in bars) {
      if (el is bc.BarcodeBar && el.black) {
        canvas.drawRect(
          Rect.fromLTWH(el.left, el.top, el.width, el.height),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BarPainter oldDelegate) =>
      oldDelegate.bars != bars;
}

/// Garis putus-putus (potongan kertas struk).
class _DashedLinePainter extends CustomPainter {
  final Color color;
  _DashedLinePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const dashW = 6.0, gapW = 4.0;
    var x = 0.0;
    while (x < size.width) {
      canvas.drawLine(Offset(x, 0), Offset(x + dashW, 0), paint);
      x += dashW + gapW;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedLinePainter oldDelegate) =>
      oldDelegate.color != color;
}
