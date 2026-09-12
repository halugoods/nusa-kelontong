import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mobile_scanner/mobile_scanner.dart' hide Barcode;
import 'package:url_launcher/url_launcher.dart';
import 'package:barcode_widget/barcode_widget.dart';
import 'package:nusa_kasir/core/providers.dart';
import 'package:nusa_kasir/core/config/nusa_config.dart';
import 'package:nusa_kasir/core/utils/format_rupiah.dart';
import 'package:nusa_kasir/core/utils/contact_picker.dart';
import 'package:nusa_kasir/data/database/app_database.dart';
import 'package:nusa_kasir/data/repositories/customer_repository.dart';
import 'package:nusa_kasir/data/repositories/debt_repository.dart';
import 'package:nusa_kasir/data/repositories/settings_repository.dart';
import 'package:nusa_kasir/data/repositories/appointment_repository.dart';
import 'package:nusa_kasir/shared/widgets/animated_scanner_overlay.dart';
import 'package:nusa_kasir/shared/widgets/hid_barcode_listener.dart';
import 'package:nusa_kasir/shared/widgets/nusa_button.dart';
import 'package:nusa_kasir/shared/widgets/nusa_input.dart';
import 'package:nusa_kasir/shared/widgets/nusa_search_bar.dart';
import 'package:nusa_kasir/shared/widgets/screen_scaffold.dart';
import 'package:nusa_kasir/shared/widgets/skeleton_list.dart';
import 'package:nusa_kasir/shared/widgets/empty_state.dart';
import 'package:nusa_kasir/shared/widgets/top_toast.dart';
import 'package:nusa_kasir/core/utils/wa_phone.dart';
import 'package:share_plus/share_plus.dart';
import 'package:nusa_kasir/core/services/id_card_renderer.dart';

/// 6 random avatar colors picked from hash of customer name.
const _avatarColors = [
  Color(0xFFE63946),
  Color(0xFF3B82F6),
  Color(0xFF10B981),
  Color(0xFF8B5CF6),
  Color(0xFFF59E0B),
  Color(0xFFEC4899),
];

Color _avatarColor(String name) {
  final hash = name.runes.fold(0, (a, b) => a + b);
  return _avatarColors[hash % _avatarColors.length];
}

class CustomersScreen extends ConsumerStatefulWidget {
  CustomersScreen({super.key});
  @override
  ConsumerState<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends ConsumerState<CustomersScreen> {
  final _search = TextEditingController();
  List<Customer> _customers = [];
  Map<int, int> _outstanding = {}; // customerId -> outstanding debt amount
  bool _loading = true;
  String _levelFilter = 'Semua';

  // Level member SAMA dengan web toko online: Silver/Gold/Platinum.
  // (Sebelumnya app tampil 'Regular' untuk Silver — beda nama, membingungkan.)
  static const _levelOptions = ['Semua', 'Silver', 'Gold', 'Platinum'];

  @override
  void initState() {
    super.initState();
    _search.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _search.removeListener(_load);
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = CustomerRepository(ref.read(databaseProvider));
    final debtRepo = DebtRepository(ref.read(databaseProvider));
    final all = await repo.getCustomers();
    final activeDebts = await debtRepo.getActiveDebts();
    final outstanding = <int, int>{};
    for (final d in activeDebts) {
      outstanding[d.customerId] = (outstanding[d.customerId] ?? 0) + d.remainingAmount;
    }
    final q = _search.text.toLowerCase();
    var filtered = q.isEmpty
        ? all
        : all
            .where((c) =>
                c.name.toLowerCase().contains(q) ||
                (c.phone?.toLowerCase().contains(q) ?? false))
            .toList();
    if (_levelFilter != 'Semua') {
      filtered = filtered.where((c) => c.level == _levelFilter).toList();
    }
    if (mounted) {
      setState(() {
        _customers = filtered;
        _outstanding = outstanding;
        _loading = false;
      });
    }
  }

  void _showAddSheet() {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final addressCtrl = TextEditingController();
    final barcodeCtrl = TextEditingController();
    // v2.2.45 (B11): barcode member jadi toggle + generate/scan HID/kamera.
    bool barcodeOn = false;
    bool saving = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSt) {
            return HidBarcodeListener(
              onBarcode: (code) {
                final norm = _normBarcode(code);
                if (norm.isEmpty) return;
                setSt(() {
                  barcodeOn = true;
                  barcodeCtrl.text = norm;
                });
              },
              child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? NusaConfig.darkSurface
                    : NusaConfig.surfaceColor,
                borderRadius:
                    BorderRadius.vertical(top: Radius.circular(24)),
              ),
              padding: EdgeInsets.fromLTRB(
                20,
                10,
                20,
                MediaQuery.of(ctx).viewInsets.bottom + 20,
              ),
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
                  Row(children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: NusaConfig.activePrimary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(Icons.person_add_rounded,
                          color: NusaConfig.activePrimary, size: 20),
                    ),
                    SizedBox(width: 12),
                    Text(
                      'Tambah Pelanggan',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: Theme.of(context).brightness == Brightness.dark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary,
                      ),
                    ),
                  ]),
                  SizedBox(height: 18),
                  NusaInput('Nama Pelanggan', controller: nameCtrl, hint: 'Cth: Dimas'),
                  SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: NusaInput('Telepon (opsional)',
                            controller: phoneCtrl, type: TextInputType.phone, hint: 'Cth: 0812xxxx'),
                      ),
                      SizedBox(width: 8),
                      GestureDetector(
                        onTap: () async {
                          final contact = await pickContact();
                          if (contact != null) {
                            final name = contact['name'] ?? '';
                            final phone = contact['phone'] ?? '';
                            if (name.isNotEmpty && nameCtrl.text.trim().isEmpty) {
                              nameCtrl.text = name;
                            }
                            if (phone.isNotEmpty) {
                              phoneCtrl.text = phone;
                            }
                            setSt(() {}); // refresh UI after auto-fill
                          }
                        },
                        child: Container(
                          width: 48, height: 48,
                          decoration: BoxDecoration(
                            color: NusaConfig.activePrimary.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(Icons.contacts_outlined,
                              color: NusaConfig.activePrimary, size: 22),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 12),
                  NusaInput('Alamat (opsional)', controller: addressCtrl, hint: 'Cth: Jl. Merdeka No.1'),
                  SizedBox(height: 12),
                  // ── Barcode member (B11) — toggle + scan/generate ──
                  Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? NusaConfig.darkSurface
                          : NusaConfig.surfaceColor,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Theme.of(context).brightness == Brightness.dark
                            ? NusaConfig.darkBorder
                            : NusaConfig.dividerColor,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          child: Row(
                            children: [
                              Icon(Icons.qr_code_2,
                                  size: 18,
                                  color: Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? NusaConfig.darkTextSecondary
                                      : NusaConfig.textSecondary),
                              SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Barcode Member (kartu)',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? NusaConfig.darkTextSecondary
                                        : NusaConfig.textSecondary,
                                  ),
                                ),
                              ),
                              Text(barcodeOn ? 'ON' : 'OFF',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: barcodeOn
                                        ? NusaConfig.accentGreen
                                        : Theme.of(context).brightness ==
                                                Brightness.dark
                                            ? NusaConfig.darkTextTertiary
                                            : NusaConfig.textTertiary,
                                  )),
                              SizedBox(width: 8),
                              SizedBox(
                                height: 24,
                                width: 44,
                                child: Switch(
                                  value: barcodeOn,
                                  activeColor: NusaConfig.activePrimary,
                                  onChanged: (v) => setSt(() {
                                    barcodeOn = v;
                                  }),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (barcodeOn)
                          Container(
                            padding: EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Theme.of(ctx).brightness == Brightness.dark
                                  ? NusaConfig.darkSurface2
                                  : NusaConfig.inputFill,
                              borderRadius: BorderRadius.only(
                                bottomLeft: Radius.circular(12),
                                bottomRight: Radius.circular(12),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.stretch,
                              children: [
                                TextField(
                                  controller: barcodeCtrl,
                                  autofocus: false,
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 13,
                                    color: Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? NusaConfig.darkTextPrimary
                                        : NusaConfig.textPrimary,
                                  ),
                                  decoration: InputDecoration(
                                    labelText: 'Kode barcode',
                                    hintText: 'Scan kartu member atau ketik manual',
                                    isDense: true,
                                    border: OutlineInputBorder(
                                      borderRadius:
                                          BorderRadius.circular(10),
                                    ),
                                  ),
                                  onChanged: (_) => setSt(() {}),
                                ),
                                SizedBox(height: 6),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextButton.icon(
                                        onPressed: () => setSt(() {
                                          barcodeCtrl.text =
                                              _generateBarcode();
                                        }),
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
                                    SizedBox(width: 8),
                                    IconButton.filledTonal(
                                      tooltip: 'Scan kamera',
                                      onPressed: () => _scanMemberBarcode(
                                        ctx,
                                        (norm) => setSt(() {
                                          barcodeOn = true;
                                          barcodeCtrl.text = norm;
                                        }),
                                      ),
                                      icon: Icon(
                                        Icons.qr_code_scanner,
                                        size: 20,
                                        color: NusaConfig.activePrimary,
                                      ),
                                    ),
                                  ],
                                ),
                                // v2.2.46: preview barcode langsung di bawah
                                // toggle (pola form produk).
                                if (barcodeCtrl.text.trim().isNotEmpty) ...[
                                  SizedBox(height: 6),
                                  BarcodeWidget(
                                    data: barcodeCtrl.text.trim(),
                                    barcode: Barcode.code128(),
                                    width: double.infinity,
                                    height: 60,
                                  ),
                                  SizedBox(height: 4),
                                  Text(
                                    barcodeCtrl.text.trim(),
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 11,
                                      color: Theme.of(context).brightness ==
                                              Brightness.dark
                                          ? NusaConfig.darkTextSecondary
                                          : NusaConfig.textSecondary,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  SizedBox(height: 20),
                  NusaButton(
                    'Simpan',
                    onPressed: saving
                        ? null
                        : () async {
                            final name = nameCtrl.text.trim();
                            if (name.isEmpty) {
                              TopToast.error(
                                  context, 'Nama pelanggan wajib diisi');
                              return;
                            }
                            setSt(() => saving = true);
                            final repo = CustomerRepository(
                                ref.read(databaseProvider));
                            await repo.addCustomer(
                              name: name,
                              phone: phoneCtrl.text.trim(),
                              address: addressCtrl.text.trim(),
                              barcode: barcodeOn
                                  ? (barcodeCtrl.text.trim().isEmpty
                                        ? null
                                        : _normBarcode(
                                            barcodeCtrl.text.trim()))
                                  : null,
                            );
                            if (mounted) Navigator.pop(ctx);
                                            _load();
                                          },
                                  ),
                                  SizedBox(height: 4),
                                ],
                              ),
                            ),
                        );
                      },
                    );
                  },
    );
  }

  /// Normalisasi barcode member — buang spasi/dash supaya konsisten dengan
  /// scan HID (B11).
  String _normBarcode(String code) =>
      code.replaceAll(RegExp(r'[\s\-]'), '').trim();

  /// Generate kode member acak (alfanumerik aman untuk code128 + mudah
  /// diketik manual).
  String _generateBarcode() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final seed = DateTime.now().microsecondsSinceEpoch.toString().codeUnits;
    final buf = StringBuffer();
    for (var i = 0; i < 8; i++) {
      buf.write(alphabet[(seed[i % seed.length] ^ (i * 31 + 7)) %
          alphabet.length]);
    }
    return 'MBR-$buf';
  }

  /// Scan barcode member via kamera (pola sama dengan scanner POS/produk).
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
              SizedBox(width: 8),
              Text('Pindai Barcode Member'),
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
                    Navigator.pop(dctx);
                  },
                  errorBuilder: (context, error, child) {
                    debugPrint('[Pelanggan] scanner error: $error');
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
                            Icon(
                              Icons.no_photography_outlined,
                              size: 36,
                              color: Colors.grey,
                            ),
                            SizedBox(height: 8),
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
              onPressed: () => Navigator.pop(dctx),
              child: Text('Batal'),
            ),
          ],
        ),
      ),
    );
    await controller.dispose();
    if (scannedCode == null || !ctx.mounted) return;
    final norm = _normBarcode(scannedCode!);
    if (norm.isEmpty) return;
    onResult(norm);
  }

  void _showDetail(Customer c) {
    final phone = c.phone ?? '';
    final db = ref.read(databaseProvider);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: Theme.of(ctx).brightness == Brightness.dark
              ? NusaConfig.darkSurface
              : NusaConfig.surfaceColor,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: _CustomerDetailSheet(
          customer: c,
          phone: phone,
          db: db,
        ),
      ),
    );
  }

  Future<void> _deleteCustomer(Customer c) async {
    final repo = CustomerRepository(ref.read(databaseProvider));
    await repo.deleteCustomer(c.id);
    _load();
  }

  void _showWaTemplates() {
    final repo = SettingsRepository(ref.read(databaseProvider));
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _WaTemplateSheet(repo: repo),
    );
  }

  /// Scan barcode ke search field — populates search + filters list.
  /// v2.2.47 revisi: scanner icon di search bar pelanggan.
  Future<void> _scanBarcodeToSearch(BuildContext ctx) async {
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
    String? scannedCode;
    await showDialog(
      context: ctx,
      barrierDismissible: false,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, dSet) => AlertDialog(
          title: Row(
            children: [
              Icon(Icons.qr_code_scanner, size: 22, color: NusaConfig.activePrimary),
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
                    Navigator.pop(dctx);
                  },
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                controller.dispose();
                Navigator.pop(dctx);
              },
              child: Text('Batal'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (scannedCode != null && mounted) {
      _search.text = _normBarcode(scannedCode!);
      if (mounted) setState(() {});
    }
  }

  void _showPointSettings() {
    final repo = SettingsRepository(ref.read(databaseProvider));
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _PointSettingsSheet(repo: repo),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ScreenScaffold(
      'Pelanggan',
      onBarcode: (code) {
        final norm = _normBarcode(code);
        if (norm.isEmpty) return;
        _search.text = norm;
        if (mounted) setState(() {});
      },
      Column(
        children: [
          SizedBox(height: 8),
          // ── Action chips row ──
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              _actionChip(Icons.message_rounded, 'Template WA', _showWaTemplates, isDark),
              SizedBox(width: 8),
              _actionChip(Icons.stars_rounded, 'Pengaturan Poin', _showPointSettings, isDark),
            ]),
          ),
          SizedBox(height: 8),
          // ── Search (search bar standar v2.2.54) ──
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: NusaSearchBar(
              controller: _search,
              hint: 'Cari nama atau telepon…',
              showScanner: true,
              onScan: () => _scanBarcodeToSearch(context),
            ),
          ),
          SizedBox(height: 10),
          // ── Level segmented filter ──
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: _segmented(
              options: _levelOptions,
              selected: _levelFilter,
              onSelect: (v) {
                setState(() => _levelFilter = v);
                _load();
              },
            ),
          ),
          SizedBox(height: 12),
          // ── List ──
          Expanded(
            child: _loading
                ? SkeletonList()
                : _customers.isEmpty
                    ? EmptyState(
                        icon: Icons.people_outline,
                        message: 'Belum ada pelanggan',
                      )
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.separated(
                          padding:
                              EdgeInsets.fromLTRB(16, 0, 16, 16),
                          itemCount: _customers.length,
                          separatorBuilder: (_, __) =>
                              SizedBox(height: 12),
                          itemBuilder: (_, i) {
                            final c = _customers[i];
                            return Dismissible(
                              key: ValueKey(c.id),
                              direction: DismissDirection.endToStart,
                              background: Container(
                                alignment: Alignment.centerRight,
                                padding: EdgeInsets.only(right: 20),
                                decoration: BoxDecoration(
                                  color: Colors.red.shade400,
                                  borderRadius: BorderRadius.circular(
                                      NusaConfig.radiusLG),
                                ),
                                child: Icon(Icons.delete,
                                    color: Colors.white),
                              ),
                              confirmDismiss: (_) async {
                                return await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: Text('Hapus Pelanggan'),
                                    content: Text('Hapus "${c.name}"?'),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, false),
                                        child: Text('Batal'),
                                      ),
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, true),
                                        child: Text('Hapus',
                                            style: TextStyle(
                                                color: Colors.red)),
                                      ),
                                    ],
                                  ),
                                );
                              },
                              onDismissed: (_) => _deleteCustomer(c),
                              child: _CustomerTile(
                                customer: c,
                                onTap: () => _showDetail(c),
                                outstandingDebt: _outstanding[c.id] ?? 0,
                              ),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: NusaConfig.activePrimary,
        foregroundColor: Colors.white,
        icon: Icon(Icons.add),
        label: Text('Tambah Pelanggan'),
        onPressed: _showAddSheet,
      ),
    );
  }

  Widget _actionChip(IconData icon, String label, VoidCallback onTap, bool isDark) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 40,
          decoration: BoxDecoration(
            color: isDark ? NusaConfig.darkSurface2 : NusaConfig.surfaceColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: NusaConfig.activePrimary),
              SizedBox(width: 6),
              Text(label,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary,
                  )),
            ],
          ),
        ),
      ),
    );
  }

  Widget _segmented({
    required List<String> options,
    required String selected,
    required ValueChanged<String> onSelect,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: isDark ? NusaConfig.darkSurface : NusaConfig.backgroundColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor),
      ),
      child: Row(
        children: options.map((opt) {
          final active = opt == selected;
          return Expanded(
            child: GestureDetector(
              onTap: () => onSelect(opt),
              child: Container(
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: active ? NusaConfig.activePrimary : Colors.transparent,
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
                            : isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ===========================================
//  Customer tile card
// ===========================================

class _CustomerTile extends StatelessWidget {
  final Customer customer;
  final VoidCallback onTap;
  final int outstandingDebt;
  _CustomerTile({required this.customer, required this.onTap, this.outstandingDebt = 0});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final c = customer;
    final levelDisplay = c.level;
    final Color levelColor;
    switch (c.level) {
      case 'Platinum':
        levelColor = Colors.purple;
      case 'Gold':
        levelColor = Colors.amber.shade700;
      default:
        levelColor = Colors.grey;
    }

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(NusaConfig.radiusLG),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(NusaConfig.radiusLG),
        child: Container(
          decoration: BoxDecoration(
            color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
            borderRadius: BorderRadius.circular(NusaConfig.radiusLG),
            border: Border.all(
                color: isDark
                    ? NusaConfig.darkBorder
                    : NusaConfig.dividerColor),
            boxShadow: [
              BoxShadow(
                  color: Colors.black
                      .withValues(alpha: isDark ? 0.15 : 0.06),
                  blurRadius: 10,
                  offset: Offset(0, 3))
            ],
          ),
          padding: EdgeInsets.all(12),
          child: Row(children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: _avatarColor(c.name),
              child: Text(
                c.name.isNotEmpty ? c.name[0].toUpperCase() : '?',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
            SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? NusaConfig.darkTextPrimary
                            : isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary,
                      )),
                  SizedBox(height: 3),
                  if (c.phone != null && c.phone!.isNotEmpty)
                    Text(c.phone!,
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? NusaConfig.darkTextTertiary
                              : isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary,
                        )),
                  SizedBox(height: 6),
                  Text('Total: ${formatRupiah(c.totalSpent)}',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: NusaConfig.activePrimary,
                      )),
                  if (outstandingDebt > 0) ...[
                    SizedBox(height: 3),
                    Text('Piutang: ${formatRupiah(outstandingDebt)}',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: NusaConfig.accentGold,
                        )),
                  ],
                ],
              ),
            ),
            SizedBox(width: 8),
            Container(
              padding:
                  EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: levelColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(NusaConfig.radiusSM),
              ),
              child: Text(
                levelDisplay,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: levelColor,
                ),
              ),
            ),
            SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded,
                size: 18, color: isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary),
          ]),
        ),
      ),
    );
  }
}

// ===========================================
//  Customer detail sheet
// ===========================================

class _CustomerDetailSheet extends StatelessWidget {
  final Customer customer;
  final String phone;
  final AppDatabase db;

  _CustomerDetailSheet({
    required this.customer,
    required this.phone,
    required this.db,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final c = customer;
    final levelDisplay = c.level;
    final Color levelColor;
    switch (c.level) {
      case 'Platinum':
        levelColor = Colors.purple;
      case 'Gold':
        levelColor = Colors.amber.shade700;
      default:
        levelColor = Colors.grey;
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(24, 16, 24, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
          SizedBox(height: 20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 32,
                backgroundColor: _avatarColor(c.name),
                child: Text(
                  c.name.isNotEmpty ? c.name[0].toUpperCase() : '?',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
              SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: isDark
                              ? NusaConfig.darkTextPrimary
                              : isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary,
                        )),
                    SizedBox(height: 6),
                    Container(
                      padding: EdgeInsets.symmetric(
                          horizontal: 12, vertical: 5),
                      decoration: BoxDecoration(
                        color: levelColor.withValues(alpha: 0.12),
                        borderRadius:
                            BorderRadius.circular(NusaConfig.radiusSM),
                      ),
                      child: Text(
                        levelDisplay,
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: levelColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 24),
          _detailRow(Icons.phone_outlined, 'Telepon',
              phone.isEmpty ? '-' : phone, isDark),
          SizedBox(height: 8),
          _detailRow(Icons.location_on_outlined, 'Alamat',
              c.address?.isEmpty ?? true ? '-' : c.address!, isDark),
          SizedBox(height: 8),
          _detailRow(Icons.attach_money_rounded, 'Total Belanja',
              formatRupiah(c.totalSpent), isDark),
          SizedBox(height: 8),
          _detailRow(Icons.star_rounded, 'Poin', '${c.points}', isDark),
          SizedBox(height: 8),
          // ── Barcode member (B11) ──
          if (c.barcode != null && c.barcode!.isNotEmpty)
            _detailRow(
                Icons.qr_code_2, 'Barcode Member', c.barcode!, isDark),
          SizedBox(height: 8),
          // ── Riwayat Poin ──
          FutureBuilder<List<PointHistory>>(
            future: CustomerRepository(db).pointHistory(c.id),
            builder: (context, snap) {
              final hist = snap.data ?? const [];
              if (hist.isEmpty) return const SizedBox.shrink();
              return Container(
                width: double.infinity,
                padding:
                    EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: isDark
                      ? NusaConfig.darkSurface2
                      : NusaConfig.inputFill,
                  borderRadius: BorderRadius.circular(NusaConfig.radiusSM),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.history_rounded,
                          size: 16,
                          color: isDark
                              ? NusaConfig.darkTextSecondary
                              : NusaConfig.textSecondary),
                      SizedBox(width: 8),
                      Text('Riwayat Poin',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: isDark
                                ? NusaConfig.darkTextPrimary
                                : NusaConfig.textPrimary,
                          )),
                    ]),
                    SizedBox(height: 8),
                    ...hist.take(6).map((h) {
                      final earn = h.points >= 0;
                      final dateStr =
                          '${h.date.day}/${h.date.month}/${h.date.year}';
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            Icon(
                              earn
                                  ? Icons.add_circle_outline_rounded
                                  : Icons.remove_circle_outline_rounded,
                              size: 14,
                              color: earn
                                  ? NusaConfig.accentGreen
                                  : NusaConfig.activePrimary,
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                h.note?.isNotEmpty == true
                                    ? h.note!
                                    : (earn ? 'Dapat poin' : 'Pakai poin'),
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 12,
                                  color: isDark
                                      ? NusaConfig.darkTextSecondary
                                      : NusaConfig.textSecondary,
                                ),
                              ),
                            ),
                            Text('$dateStr • ${h.points >= 0 ? '+' : ''}${h.points}',
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: earn
                                      ? NusaConfig.accentGreen
                                      : NusaConfig.activePrimary,
                                )),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              );
            },
          ),
          SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => _shareMemberCard(context, c),
                  icon: Icon(Icons.badge_outlined, size: 18),
                  label: Text('Cetak Kartu'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: NusaConfig.activePrimary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: EdgeInsets.symmetric(vertical: 14),
                    elevation: 0,
                  ),
                ),
              ),
              if (phone.isNotEmpty) ...[
                SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _openWhatsApp(context, phone),
                    icon: Icon(Icons.chat_rounded, size: 18),
                    label: Text('Kirim WA'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Color(0xFF25D366),
                      side: BorderSide(color: Color(0xFF25D366)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ],
            ],
          ),
          // Salon booking history
          if (NusaConfig.isSalonVariant) ...[
            SizedBox(height: 24),
            FutureBuilder<List<Appointment>>(
              future: AppointmentRepository(db).getByCustomer(customer.name),
              builder: (context, snap) {
                final data = snap.data ?? [];
                if (data.isEmpty) return SizedBox.shrink();
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Riwayat Salon',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 15, fontWeight: FontWeight.w700,
                      color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary,
                    )),
                  SizedBox(height: 10),
                  ...data.take(5).map((a) => _salonHistoryRow(a, isDark)),
                ]);
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _detailRow(IconData icon, String label, String value, bool isDark) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? NusaConfig.darkSurface2 : NusaConfig.inputFill,
        borderRadius: BorderRadius.circular(NusaConfig.radiusSM),
      ),
      child: Row(children: [
        Icon(icon, size: 18, color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary),
        SizedBox(width: 10),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 13,
                    color: isDark
                        ? NusaConfig.darkTextTertiary
                        : isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary,
                  )),
              Text(value,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: isDark
                        ? NusaConfig.darkTextPrimary
                        : isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary,
                  )),
            ],
          ),
        ),
      ]),
    );
  }

  // ── Salon booking history row ──
  Widget _salonHistoryRow(Appointment a, bool isDark) {
    Color sc;
    switch (a.status) {
      case 'Dikonfirmasi': sc = NusaConfig.info; break;
      case 'Datang': sc = NusaConfig.accentGreen; break;
      case 'Menunggu': sc = NusaConfig.warning; break;
      case 'Selesai': sc = NusaConfig.success; break;
      case 'Batal': sc = Colors.red; break;
      default: sc = NusaConfig.activePrimary;
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkSurface2 : NusaConfig.inputFill,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(a.service, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            Text('${a.date.day}/${a.date.month}/${a.date.year} ${a.timeSlot}', style: TextStyle(fontSize: 11, color: isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary)),
          ])),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(color: sc.withOpacity(0.12), borderRadius: BorderRadius.circular(6)),
            child: Text(a.status, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: sc)),
          ),
        ]),
      ),
    );
  }

  Future<void> _shareMemberCard(BuildContext context, Customer c) async {
    try {
      TopToast.info(context, 'Menyiapkan kartu member…');
      final repo = SettingsRepository(db);
      final storeName = await repo.getStoreName();
      final cardWidget = IdCardRenderer.memberCard(
        storeName: storeName.isNotEmpty ? storeName : 'NUSA Store',
        name: c.name,
        level: c.level,
        points: c.points,
        barcode: c.barcode ?? 'MBR-${c.id}',
        phone: c.phone,
      );
      final file = await IdCardRenderer.renderSingle(
        card: cardWidget,
        fileName: 'kartu_member_${c.name.toLowerCase().replaceAll(' ', '_')}',
      );
      if (context.mounted) {
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path)],
            subject: 'Kartu Member - ${c.name}',
            text: 'Kartu Member ${c.name} (${c.level}) - $storeName',
          ),
        );
      }
    } catch (err) {
      if (context.mounted) TopToast.error(context, 'Gagal membuat kartu member: $err');
    }
  }

  Future<void> _openWhatsApp(BuildContext context, String phone) async {
    final repo = SettingsRepository(db);
    final templates = await repo.getWaTemplates();
    final storeName = await repo.getStoreName();

    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => _WaTemplatePicker(
        templates: templates,
        customerName: customer.name,
        phone: phone,
        storeName: storeName,
      ),
    );
  }
}

// ===========================================
//  WA Template Picker Dialog (Step 2)
// ===========================================

class _WaTemplatePicker extends StatefulWidget {
  final List<Map<String, String>> templates;
  final String customerName;
  final String phone;
  final String storeName;

  _WaTemplatePicker({
    required this.templates,
    required this.customerName,
    required this.phone,
    required this.storeName,
  });

  @override
  State<_WaTemplatePicker> createState() => _WaTemplatePickerState();
}

class _WaTemplatePickerState extends State<_WaTemplatePicker> {
  String? _body;

  String _fill(String template, {String invoice = '', String total = ''}) {
    return template
        .replaceAll('{nama}', widget.customerName)
        .replaceAll('{toko}', widget.storeName)
        .replaceAll('{invoice}', invoice)
        .replaceAll('{total}', total);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AlertDialog(
      title: Text('Pilih Template WA'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Kirim ke: ${widget.customerName}',
                style: TextStyle(fontSize: 13, color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary)),
            SizedBox(height: 12),
            ...widget.templates.map((t) {
              final active = _body == t['body'];
              return Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: GestureDetector(
                  onTap: () => setState(() => _body = active ? null : t['body']),
                  child: Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: active
                          ? NusaConfig.activePrimary.withValues(alpha: 0.08)
                          : (isDark ? NusaConfig.darkSurface2 : Color(0xFFF9FAFB)),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: active ? NusaConfig.activePrimary : NusaConfig.dividerColor,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Icon(Icons.message_outlined, size: 14, color: NusaConfig.activePrimary),
                          SizedBox(width: 6),
                          Expanded(
                            child: Text(t['name'] ?? '',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary,
                                )),
                          ),
                        ]),
                        SizedBox(height: 6),
                        Text(_fill(t['body'] ?? ''),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary,
                            )),
                      ],
                    ),
                  ),
                ),
              );
            }),
            if (_body != null) ...[
              SizedBox(height: 4),
              Text('Pesan akan diisi otomatis. Kamu bisa edit setelah WA terbuka.',
                  style: TextStyle(fontSize: 11, color: isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary)),
            ],
            SizedBox(height: 8),
            TextField(
              decoration: InputDecoration(
                hintText: 'Atau tulis pesan custom…',
                hintStyle: TextStyle(fontSize: 13, color: isDark ? NusaConfig.darkTextTertiary : Colors.grey.shade400),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _body = v.isEmpty ? null : v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Batal'),
        ),
        ElevatedButton(
          onPressed: () async {
            final msg = _body != null ? _fill(_body!) : '';
            // Normalisasi via helper (v2.2.35): 08xx → 628xx.
            final uri = waLink(widget.phone, text: msg.isEmpty ? null : msg);
            Navigator.pop(context);
            try {
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            } catch (_) {}
          },
          child: Text('Kirim'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Color(0xFF25D366),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ],
    );
  }
}

// ===========================================
//  WA Template Management Sheet (Step 1)
// ===========================================

class _WaTemplateSheet extends StatefulWidget {
  final SettingsRepository repo;
  _WaTemplateSheet({required this.repo});

  @override
  State<_WaTemplateSheet> createState() => _WaTemplateSheetState();
}

class _WaTemplateSheetState extends State<_WaTemplateSheet> {
  List<Map<String, String>> _templates = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final t = await widget.repo.getWaTemplates();
    if (mounted) setState(() { _templates = t; _loading = false; });
  }

  Future<void> _save() async {
    await widget.repo.saveWaTemplates(_templates);
  }

  void _add() {
    final nameCtrl = TextEditingController();
    final bodyCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Tambah Template'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: InputDecoration(labelText: 'Nama Template', hintText: 'Cth: Pesanan Siap'),
            ),
            SizedBox(height: 12),
            TextField(
              controller: bodyCtrl,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: 'Isi Pesan',
                hintText: 'Gunakan {nama}, {invoice}, {total}, {toko}',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Batal')),
          ElevatedButton(
            onPressed: () {
              final name = nameCtrl.text.trim();
              final body = bodyCtrl.text.trim();
              if (name.isEmpty || body.isEmpty) return;
              setState(() => _templates.add({'name': name, 'body': body}));
              _save();
              Navigator.pop(ctx);
            },
            child: Text('Simpan'),
          ),
        ],
      ),
    );
  }

  void _edit(int index) {
    final t = _templates[index];
    final nameCtrl = TextEditingController(text: t['name']);
    final bodyCtrl = TextEditingController(text: t['body']);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Edit Template'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: InputDecoration(labelText: 'Nama Template'),
            ),
            SizedBox(height: 12),
            TextField(
              controller: bodyCtrl,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: 'Isi Pesan',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Batal')),
          ElevatedButton(
            onPressed: () {
              final name = nameCtrl.text.trim();
              final body = bodyCtrl.text.trim();
              if (name.isEmpty || body.isEmpty) return;
              setState(() => _templates[index] = {'name': name, 'body': body});
              _save();
              Navigator.pop(ctx);
            },
            child: Text('Simpan'),
          ),
        ],
      ),
    );
  }

  void _delete(int index) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Hapus Template'),
        content: Text('Hapus template "${_templates[index]['name']}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Batal')),
          ElevatedButton(
            onPressed: () {
              setState(() => _templates.removeAt(index));
              _save();
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: Text('Hapus'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.5,
      maxChildSize: 0.9,
      expand: false,
      builder: (ctx, scrollCtrl) => Container(
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Stack(
          children: [
            Column(
              children: [
                // Handle
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Container(
                    width: 40, height: 4,
                    decoration: BoxDecoration(color: isDark ? NusaConfig.darkDivider : NusaConfig.dividerColor, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                // Header
                Padding(
                  padding: EdgeInsets.fromLTRB(20, 4, 12, 8),
                  child: Row(children: [
                    Container(
                      width: 38, height: 38,
                      decoration: BoxDecoration(
                        color: NusaConfig.activePrimary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child:  Icon(Icons.message_rounded, color: NusaConfig.activePrimary, size: 20),
                    ),
                    SizedBox(width: 12),
                    Text('Template WA',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 17, fontWeight: FontWeight.w800,
                          color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary,
                        )),
                    Spacer(),
                    Text('${_templates.length}',
                        style: TextStyle(fontSize: 13, color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary)),
                  ]),
                ),
                Divider(height: 1),
                // List
                Expanded(
                  child: _loading
                      ? Center(child: CircularProgressIndicator())
                      : _templates.isEmpty
                          ? Center(
                              child: Text('Belum ada template.\nTekan + untuk menambah.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: 13, color: isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary)),
                            )
                          : ListView.builder(
                              controller: scrollCtrl,
                              padding: EdgeInsets.fromLTRB(16, 8, 16, 80),
                              itemCount: _templates.length,
                              itemBuilder: (_, i) {
                                final t = _templates[i];
                                return Container(
                                  margin: EdgeInsets.only(bottom: 8),
                                  padding: EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: isDark ? NusaConfig.darkSurface2 : Color(0xFFF9FAFB),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(t['name'] ?? '',
                                                style: GoogleFonts.plusJakartaSans(
                                                  fontSize: 14, fontWeight: FontWeight.w700,
                                                  color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary,
                                                )),
                                            SizedBox(height: 4),
                                            Text(t['body'] ?? '',
                                                maxLines: 2, overflow: TextOverflow.ellipsis,
                                                style: TextStyle(fontSize: 11, color: isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary)),
                                          ],
                                        ),
                                      ),
                                      PopupMenuButton(
                                        itemBuilder: (_) => [
                                          PopupMenuItem(value: 'edit', child: Text('Edit')),
                                          PopupMenuItem(value: 'delete', child: Text('Hapus', style: TextStyle(color: Colors.red))),
                                        ],
                                        onSelected: (v) {
                                          if (v == 'edit') _edit(i);
                                          if (v == 'delete') _delete(i);
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
            // FAB for add
            Positioned(
              right: 16,
              bottom: 16,
              child: FloatingActionButton.small(
                onPressed: _add,
                backgroundColor: NusaConfig.activePrimary,
                foregroundColor: Colors.white,
                child: Icon(Icons.add),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ===========================================
//  Point Settings Sheet (Step 3)
// ===========================================

class _PointSettingsSheet extends StatefulWidget {
  final SettingsRepository repo;
  _PointSettingsSheet({required this.repo});

  @override
  State<_PointSettingsSheet> createState() => _PointSettingsSheetState();
}

class _PointSettingsSheetState extends State<_PointSettingsSheet> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _pointsCtrl;
  late TextEditingController _silverCtrl;
  late TextEditingController _goldCtrl;
  late TextEditingController _platinumCtrl;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _pointsCtrl = TextEditingController();
    _silverCtrl = TextEditingController();
    _goldCtrl = TextEditingController();
    _platinumCtrl = TextEditingController();
    _load();
  }

  Future<void> _load() async {
    final cfg = await widget.repo.getPointConfig();
    if (mounted) {
      setState(() {
        _pointsCtrl.text = cfg['pointsPerRupiah'].toString();
        _silverCtrl.text = cfg['silverThreshold'].toString();
        _goldCtrl.text = cfg['goldThreshold'].toString();
        _platinumCtrl.text = cfg['platinumThreshold'].toString();
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    await widget.repo.savePointConfig(
      pointsPerRupiah: int.tryParse(_pointsCtrl.text) ?? 100,
      silverThreshold: int.tryParse(_silverCtrl.text) ?? 0,
      goldThreshold: int.tryParse(_goldCtrl.text) ?? 1000,
      platinumThreshold: int.tryParse(_platinumCtrl.text) ?? 5000,
    );
  }

  @override
  void dispose() {
    _pointsCtrl.dispose();
    _silverCtrl.dispose();
    _goldCtrl.dispose();
    _platinumCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.8,
      expand: false,
      builder: (ctx, scrollCtrl) => Container(
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: _loading
            ? Center(child: CircularProgressIndicator())
            : Form(
                key: _formKey,
                child: ListView(
                  controller: scrollCtrl,
                  padding: EdgeInsets.fromLTRB(20, 10, 20, 40),
                  children: [
                    // Handle
                    Center(
                      child: Container(
                        width: 40, height: 4,
                        decoration: BoxDecoration(color: NusaConfig.dividerColor, borderRadius: BorderRadius.circular(2)),
                      ),
                    ),
                    SizedBox(height: 16),
                    Row(children: [
                      Container(
                        width: 38, height: 38,
                        decoration: BoxDecoration(
                          color: Colors.amber.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(Icons.stars_rounded, color: Colors.amber, size: 20),
                      ),
                      SizedBox(width: 12),
                      Text('Pengaturan Poin',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 17, fontWeight: FontWeight.w800,
                            color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary,
                          )),
                    ]),
                    SizedBox(height: 20),

                    // Points per Rupiah
                    Text('Poin per Rupiah',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary)),
                    SizedBox(height: 6),
                    TextFormField(
                      controller: _pointsCtrl,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        hintText: '100',
                        hintStyle: TextStyle(color: isDark ? NusaConfig.darkTextTertiary : Colors.grey.shade400),
                        helperText: 'Setiap Rp ? akan mendapat 1 poin',
                        helperStyle: TextStyle(fontSize: 11, color: isDark ? NusaConfig.darkTextTertiary : Colors.grey.shade500),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      ),
                    ),
                    SizedBox(height: 18),

                    // Thresholds
                    Text('Level Threshold (poin minimum)',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary)),
                    SizedBox(height: 8),
                    _thresholdField('Silver (default)', _silverCtrl, Colors.grey, isDark),
                    SizedBox(height: 10),
                    _thresholdField('Gold', _goldCtrl, Colors.amber.shade700, isDark),
                    SizedBox(height: 10),
                    _thresholdField('Platinum', _platinumCtrl, Colors.purple, isDark),
                    SizedBox(height: 24),

                    NusaButton('Simpan Pengaturan', onPressed: () {
                      _save().then((_) {
                        if (mounted) Navigator.pop(context);
                      });
                    }),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _thresholdField(String label, TextEditingController ctrl, Color color, bool isDark) {
    return Row(children: [
      Container(
        width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      SizedBox(width: 8),
      Text(label, style: TextStyle(fontSize: 13, color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary)),
      SizedBox(width: 12),
      SizedBox(
        width: 120,
        child: TextFormField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          style: TextStyle(fontWeight: FontWeight.w600, color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ),
    ]);
  }
}

