
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:barcode_widget/barcode_widget.dart';
import 'package:nusa_kasir/core/providers.dart';
import 'package:nusa_kasir/core/config/nusa_config.dart';
import 'package:nusa_kasir/core/services/image_storage_service.dart';
import 'package:nusa_kasir/core/services/delta_sync_service.dart';
import 'package:nusa_kasir/core/utils/format_rupiah.dart';
import 'package:nusa_kasir/core/utils/secure_storage.dart';
import 'package:nusa_kasir/data/database/app_database.dart';
import 'package:nusa_kasir/data/repositories/attendance_repository.dart';
import 'package:nusa_kasir/data/repositories/branch_repository.dart';
import 'package:nusa_kasir/data/repositories/product_repository.dart';
import 'package:nusa_kasir/data/repositories/role_repository.dart';
import 'package:nusa_kasir/features/auth/rbac.dart';
import 'package:nusa_kasir/features/auth/employee_session_provider.dart';
import 'package:mobile_scanner/mobile_scanner.dart' hide Barcode;
import 'package:nusa_kasir/shared/widgets/hid_barcode_listener.dart';
import 'package:nusa_kasir/shared/widgets/animated_scanner_overlay.dart';
import 'package:nusa_kasir/shared/widgets/nusa_card.dart';
import 'package:nusa_kasir/shared/widgets/nusa_input.dart';
import 'package:nusa_kasir/shared/widgets/nusa_search_bar.dart';
import 'package:nusa_kasir/shared/widgets/screen_scaffold.dart';
import 'package:nusa_kasir/shared/widgets/empty_state.dart';
import 'package:nusa_kasir/shared/services/nfc_tag_service.dart';
import 'package:nusa_kasir/core/utils/wa_phone.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import 'package:nusa_kasir/core/services/id_card_renderer.dart';
import 'package:nusa_kasir/shared/widgets/top_toast.dart';

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

const _roleColors = {
  'Owner': Color(0xFF8B5CF6),
  'Manager': Color(0xFF3B82F6),
  'Kasir': Color(0xFF10B981),
  'Gudang': Color(0xFFF59E0B),
  'Finance': Color(0xFFEC4899),
};

const _statusOptions = ['Aktif', 'Cuti', 'Nonaktif', 'Resign'];
const _statusColors = {
  'Aktif': Color(0xFF10B981),
  'Cuti': Color(0xFFF59E0B),
  'Nonaktif': Color(0xFF9CA3AF),
  'Resign': Color(0xFFE63946),
};

Widget _roleBadge(String role) {
  final color = _roleColors[role] ?? Color(0xFF3B82F6);
  return Container(
    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      role,
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
    ),
  );
}

Widget _statusBadge(String status) {
  final color = _statusColors[status] ?? Color(0xFF9CA3AF);
  return Container(
    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      status,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
    ),
  );
}

class EmployeesScreen extends ConsumerStatefulWidget {
  EmployeesScreen({super.key});
  @override
  ConsumerState<EmployeesScreen> createState() => _EmployeesScreenState();
}

class _EmployeesScreenState extends ConsumerState<EmployeesScreen> {
  List<String> _roles = ['Owner', 'Manager', 'Kasir', 'Gudang', 'Finance'];
  List<Employee> _employees = [];
  bool _loading = false;
  final _searchCtrl = TextEditingController();
  String _query = '';
  final _imagePicker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(
      () => setState(() => _query = _searchCtrl.text.toLowerCase()),
    );
    _load();
    _loadRoles();
  }

  Future<void> _loadRoles() async {
    final repo = RoleRepository(ref.read(databaseProvider));
    final roles = await repo.getRoles();
    if (mounted) {
      setState(() => _roles = roles.map((r) => r['name'] as String).toList());
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<Employee> get _filtered => _query.isEmpty
      ? _employees
      : _employees
            .where(
              (e) =>
                  e.name.toLowerCase().contains(_query) ||
                  e.role.toLowerCase().contains(_query),
            )
            .toList();

  Future<void> _load() async {
    setState(() => _loading = true);
    final repo = AttendanceRepository(ref.read(databaseProvider));
    final emps = await repo.getEmployees();
    if (mounted) {
      setState(() {
        _employees = emps;
        _loading = false;
      });
    }
  }

  Future<String?> _copyPhotoToStorage(String sourcePath) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final name = 'photo_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final dest = File('${dir.path}/$name');
      await File(sourcePath).copy(dest.path);
      return dest.path;
    } catch (e) {
      return null;
    }
  }

  Future<void> _showForm({Employee? employee}) async {
    // Preload branches SEBELUM membuka sheet (v2.2.35): FutureBuilder di
    // dalam modal yang rebuild setelah date picker adalah sumber layar
    // blank — fetch di sini, sheet pakai data polos.
    List<Branche> branches;
    try {
      branches = await BranchRepository(ref.read(databaseProvider)).getAll();
    } catch (_) {
      branches = [];
    }
    if (!mounted) return;

    final nameC = TextEditingController(text: employee?.name ?? '');
    final pinC = TextEditingController(text: employee?.pin ?? '');
    final phoneC = TextEditingController(text: employee?.phone ?? '');
    final barcodeC = TextEditingController(text: employee?.barcode ?? '');
    final salaryC = TextEditingController(
      text: employee?.baseSalary != null ? '${employee!.baseSalary}' : '',
    );
    // v2.2.57: komisi % staf layanan (default 10).
    final pct = employee?.commissionPercent;
    final commissionC = TextEditingController(
      text: pct == null ? '10' : (pct % 1 == 0 ? pct.truncate().toString() : '$pct'),
    );
    String role = employee?.role ?? _roles.first;
    String status = employee?.status ?? 'Aktif';
    DateTime? startDate = employee?.startDate;
    String? photoPath = employee?.photoPath;
    String? error;
    int? branchId = employee?.branchId;
    String workStart = employee?.workStart ?? '08:00';
    String workEnd = employee?.workEnd ?? '17:00';
    bool requiresCashOpen = employee?.requiresCashOpen ?? false;
    bool requiresCashClose = employee?.requiresCashClose ?? false;
    // v2.2.54: flag Staf Layanan — bisa dipilih sebagai stylist/Stylist saat
    // booking (checkout salon). Default true supaya karyawan lama tetap muncul.
    bool isServiceStaff = employee?.isServiceStaff ?? true;
    // v2.2.45: barcode id-card jadi TOGGLE (mirip form produk) — OFF default
    // supaya form lebih ringkas; scan HID tetap isi field saat ON.
    bool barcodeOn = employee?.barcode != null && employee!.barcode!.isNotEmpty;

    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          return HidBarcodeListener(
            onBarcode: (code) {
              final norm = ProductRepository.normalizeBarcode(code);
              if (norm.isEmpty) return;
              // Scan datang → toggle ON + isi field (id-card dulu, baru
              // inputan lain).
              setSt(() {
                barcodeOn = true;
                barcodeC.text = norm;
              });
            },
            child: Container(
              decoration: BoxDecoration(
                color: isDark
                    ? NusaConfig.darkSurface
                    : NusaConfig.surfaceColor,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              padding: EdgeInsets.fromLTRB(
                20,
                10,
                20,
                MediaQuery.of(ctx).viewInsets.bottom + 20,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Drag handle
                    Container(
                      margin: EdgeInsets.symmetric(vertical: 8),
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: isDark
                            ? NusaConfig.darkDivider
                            : NusaConfig.dividerColor,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    // Header with icon
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
                            Icons.person_add_outlined,
                            color: NusaConfig.activePrimary,
                            size: 20,
                          ),
                        ),
                        SizedBox(width: 12),
                        Text(
                          employee == null
                              ? 'Tambah Karyawan'
                              : 'Edit Karyawan',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            color: isDark
                                ? NusaConfig.darkTextPrimary
                                : NusaConfig.textPrimary,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 16),
                    // Photo picker
                    Center(
                      child: GestureDetector(
                        onTap: () async {
                          try {
                            final picked = await _imagePicker.pickImage(
                              source: ImageSource.gallery,
                              maxWidth: 512,
                              maxHeight: 512,
                            );
                            if (picked != null) {
                              final copied = await _copyPhotoToStorage(
                                picked.path,
                              );
                              if (copied != null)
                                setSt(() => photoPath = copied);
                            }
                          } catch (_) {}
                        },
                        child: Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            color: _avatarColor(
                              nameC.text.isNotEmpty ? nameC.text : '?',
                            ),
                            image: photoPath != null && photoPath!.isNotEmpty
                                ? DecorationImage(
                                    image: FileImage(
                                      File(photoPath!),
                                      scale: 1.0,
                                    ),
                                    fit: BoxFit.cover,
                                    filterQuality: FilterQuality.low,
                                  )
                                : null,
                          ),
                          alignment: Alignment.center,
                          child: photoPath == null || photoPath!.isEmpty
                              ? Text(
                                  nameC.text.isNotEmpty
                                      ? nameC.text[0].toUpperCase()
                                      : '?',
                                  style: TextStyle(
                                    fontSize: 28,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ),
                    SizedBox(height: 6),
                    TextButton.icon(
                      onPressed: () async {
                        try {
                          final picked = await _imagePicker.pickImage(
                            source: ImageSource.gallery,
                            maxWidth: 512,
                            maxHeight: 512,
                          );
                          if (picked != null) {
                            final copied = await _copyPhotoToStorage(
                              picked.path,
                            );
                            if (copied != null) setSt(() => photoPath = copied);
                          }
                        } catch (_) {}
                      },
                      icon: Icon(
                        Icons.camera_alt_outlined,
                        size: 16,
                        color: isDark
                            ? NusaConfig.darkTextSecondary
                            : NusaConfig.textSecondary,
                      ),
                      label: Text(
                        photoPath != null ? 'Ganti Foto' : 'Tambah Foto',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? NusaConfig.darkTextSecondary
                              : NusaConfig.textSecondary,
                        ),
                      ),
                    ),
                    SizedBox(height: 12),
                    NusaInput(
                      'Nama',
                      controller: nameC,
                      hint: NusaConfig.hintsFor('employeeName'),
                    ),
                    SizedBox(height: 12),
                    NusaInput(
                      'PIN (4-6 digit)',
                      controller: pinC,
                      type: TextInputType.number,
                      obscure: true,
                      hint: 'Cth: 123456',
                    ),
                    SizedBox(height: 12),
                    // Barcode id-card (B8) — TOGGLE (v2.2.45), mirip form produk.
                    // OFF default supaya form ringkas; saat ON scan HID + kamera
                    // otomatis isi field.
                    Container(
                      decoration: BoxDecoration(
                        color: isDark
                            ? NusaConfig.darkSurface
                            : NusaConfig.surfaceColor,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isDark
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
                              horizontal: 16,
                              vertical: 12,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.qr_code_2,
                                  size: 18,
                                  color: isDark
                                      ? NusaConfig.darkTextSecondary
                                      : NusaConfig.textSecondary,
                                ),
                                SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    'Barcode ID (id-card)',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: isDark
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
                                          : isDark
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
                                    onChanged: (v) =>
                                        setSt(() => barcodeOn = v),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (barcodeOn)
                            Container(
                              padding: EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: isDark
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
                                  // Scan kamera + input manual (pola form produk)
                                  Row(
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: barcodeC,
                                          autofocus: false,
                                          style: TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 14,
                                            color: isDark
                                                ? NusaConfig.darkTextPrimary
                                                : NusaConfig.textPrimary,
                                          ),
                                          decoration: InputDecoration(
                                            labelText: 'Kode barcode',
                                            hintText:
                                                'Scan id-card atau ketik manual',
                                            isDense: true,
                                            border: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                            ),
                                          ),
                                          onChanged: (_) => setSt(() {}),
                                        ),
                                      ),
                                      SizedBox(width: 8),
                                      IconButton.filledTonal(
                                        tooltip: 'Scan kamera',
                                        onPressed: () => _scanBarcodeFromCamera(
                                          ctx,
                                          setSt,
                                          (norm) => barcodeC.text = norm,
                                        ),
                                        icon: Icon(
                                          Icons.qr_code_scanner,
                                          size: 20,
                                          color: NusaConfig.activePrimary,
                                        ),
                                      ),
                                    ],
                                  ),
                                  // Generate barcode acak (pola form produk)
                                  SizedBox(height: 6),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: TextButton.icon(
                                      onPressed: () => setSt(() {
                                        barcodeC.text = _generateBarcode();
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
                                  // v2.2.46: preview barcode langsung di bawah
                                  // toggle (pola form produk).
                                  SizedBox(height: 6),
                                  if (barcodeC.text.trim().isNotEmpty) ...[
                                    BarcodeWidget(
                                      data: barcodeC.text.trim(),
                                      barcode: Barcode.code128(),
                                      width: double.infinity,
                                      height: 60,
                                    ),
                                    SizedBox(height: 4),
                                    Text(
                                      barcodeC.text.trim(),
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
                            ),
                        ],
                      ),
                    ),
                    SizedBox(height: 12),
                    NusaInput(
                      'No. WA (opsional)',
                      controller: phoneC,
                      type: TextInputType.phone,
                      hint: 'Cth: 08123456789',
                      prefixIcon: Icon(
                        Icons.phone,
                        size: 18,
                        color: isDark
                            ? NusaConfig.darkTextSecondary
                            : NusaConfig.textSecondary,
                      ),
                    ),
                    SizedBox(height: 12),
                    // Role dropdown
                    _buildDialogDropdown(
                      label: 'Role',
                      value: _roles.contains(role) ? role : _roles.first,
                      items: _roles,
                      isDark: isDark,
                      onChanged: (v) => setSt(() => role = v!),
                    ),
                    SizedBox(height: 12),
                    // Branch dropdown
                    _buildDialogDropdown(
                      label: 'Cabang',
                      value: branchId != null
                          ? branches
                                    .where((b) => b.id == branchId)
                                    .map((b) => b.name)
                                    .firstOrNull ??
                                'Semua Cabang'
                          : 'Semua Cabang',
                      items: ['Semua Cabang', ...branches.map((b) => b.name)],
                      isDark: isDark,
                      onChanged: (v) {
                        if (v == 'Semua Cabang' || v == null) {
                          setSt(() => branchId = null);
                        } else {
                          final b = branches
                              .where((b) => b.name == v)
                              .firstOrNull;
                          if (b != null) setSt(() => branchId = b.id);
                        }
                      },
                    ),
                    SizedBox(height: 12),
                    // Status dropdown
                    _buildDialogDropdown(
                      label: 'Status',
                      value: status,
                      items: _statusOptions,
                      isDark: isDark,
                      colorFn: (s) => _statusColors[s] ?? Colors.grey,
                      onChanged: (v) => setSt(() => status = v!),
                    ),
                    SizedBox(height: 12),
                    NusaInput(
                      'Gaji Pokok (opsional)',
                      controller: salaryC,
                      type: TextInputType.number,
                      hint: 'Cth: 2500000',
                    ),
                    SizedBox(height: 12),
                    // Start date picker
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Tanggal Mulai Kerja',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: isDark
                                ? NusaConfig.darkTextSecondary
                                : NusaConfig.textSecondary,
                          ),
                        ),
                        SizedBox(height: 6),
                        GestureDetector(
                          onTap: () async {
                            // Use the screen's context (not the sheet's `ctx`)
                            // with useRootNavigator so the picker renders over
                            // everything — avoids blank/freeze on slow devices
                            // when the sheet context is mid-build.
                            final picked = await showDatePicker(
                              context: context,
                              useRootNavigator: true,
                              initialDate: startDate ?? DateTime.now(),
                              firstDate: DateTime(2015),
                              lastDate: DateTime.now(),
                              helpText: 'Tanggal Mulai Kerja',
                              cancelText: 'BATAL',
                              confirmText: 'PILIH',
                            );
                            if (picked != null) setSt(() => startDate = picked);
                          },
                          child: Container(
                            width: double.infinity,
                            padding: EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? NusaConfig.darkInputFill
                                  : NusaConfig.inputFill,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isDark
                                    ? NusaConfig.darkInputBorder
                                    : NusaConfig.inputBorder,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.calendar_today_rounded,
                                  size: 18,
                                  color: isDark
                                      ? NusaConfig.darkTextSecondary
                                      : NusaConfig.textSecondary,
                                ),
                                SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    startDate != null
                                        ? DateFormat(
                                            'dd MMM yyyy',
                                            'id',
                                          ).format(startDate!)
                                        : 'Pilih tanggal (opsional)',
                                    style: TextStyle(
                                      fontSize: 15,
                                      color: startDate != null
                                          ? (isDark
                                                ? NusaConfig.darkTextPrimary
                                                : NusaConfig.textPrimary)
                                          : (isDark
                                                ? NusaConfig.darkTextTertiary
                                                : NusaConfig.textTertiary),
                                    ),
                                  ),
                                ),
                                if (startDate != null)
                                  GestureDetector(
                                    onTap: () => setSt(() => startDate = null),
                                    child: Icon(
                                      Icons.close,
                                      size: 18,
                                      color: isDark
                                          ? NusaConfig.darkTextTertiary
                                          : NusaConfig.textTertiary,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (error != null) ...[
                      SizedBox(height: 8),
                      Text(
                        error!,
                        style: TextStyle(
                          color: NusaConfig.activePrimary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                    SizedBox(height: 16),

                    // ── Jam Kerja ──
                    Row(
                      children: [
                        Icon(
                          Icons.schedule_outlined,
                          size: 16,
                          color: isDark
                              ? NusaConfig.darkTextSecondary
                              : NusaConfig.textSecondary,
                        ),
                        SizedBox(width: 6),
                        Text(
                          'Jam Kerja',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: isDark
                                ? NusaConfig.darkTextSecondary
                                : NusaConfig.textSecondary,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: _timeField(
                            label: 'Masuk',
                            value: workStart,
                            isDark: isDark,
                            onTap: () async {
                              final parts = workStart.split(':');
                              final now = TimeOfDay(
                                hour: int.tryParse(parts[0]) ?? 8,
                                minute: int.tryParse(parts[1]) ?? 0,
                              );
                              final picked = await showTimePicker(
                                context: context,
                                useRootNavigator: true,
                                initialTime: now,
                                helpText: 'Jam Masuk',
                                cancelText: 'BATAL',
                                confirmText: 'PILIH',
                              );
                              if (picked != null) {
                                setSt(
                                  () => workStart =
                                      '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}',
                                );
                              }
                            },
                          ),
                        ),
                        SizedBox(width: 10),
                        // "sampai" label
                        Padding(
                          padding: EdgeInsets.only(bottom: 12),
                          child: Text(
                            's.d',
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark
                                  ? NusaConfig.darkTextTertiary
                                  : NusaConfig.textTertiary,
                            ),
                          ),
                        ),
                        SizedBox(width: 10),
                        Expanded(
                          child: _timeField(
                            label: 'Pulang',
                            value: workEnd,
                            isDark: isDark,
                            onTap: () async {
                              final parts = workEnd.split(':');
                              final now = TimeOfDay(
                                hour: int.tryParse(parts[0]) ?? 17,
                                minute: int.tryParse(parts[1]) ?? 0,
                              );
                              final picked = await showTimePicker(
                                context: context,
                                useRootNavigator: true,
                                initialTime: now,
                                helpText: 'Jam Pulang',
                                cancelText: 'BATAL',
                                confirmText: 'PILIH',
                              );
                              if (picked != null) {
                                setSt(
                                  () => workEnd =
                                      '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}',
                                );
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    // late threshold info
                    Padding(
                      padding: EdgeInsets.only(top: 4, bottom: 8),
                      child: Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 13,
                            color: isDark
                                ? NusaConfig.darkTextTertiary
                                : NusaConfig.textTertiary,
                          ),
                          SizedBox(width: 4),
                          Text(
                            'Terlambat jika absen > 15 menit setelah jam masuk',
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

                    SizedBox(height: 12),

                    // ── Wajib Presensi Checkboxes (rounded, custom) ──
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Wajib Presensi',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? NusaConfig.darkTextPrimary
                              : NusaConfig.textPrimary,
                        ),
                      ),
                    ),
                    SizedBox(height: 4),
                    // Kas Awal
                    GestureDetector(
                      onTap: () =>
                          setSt(() => requiresCashOpen = !requiresCashOpen),
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          children: [
                            Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: requiresCashOpen
                                      ? NusaConfig.activePrimary
                                      : (isDark
                                            ? NusaConfig.darkDivider
                                            : NusaConfig.dividerColor),
                                  width: 2,
                                ),
                                color: requiresCashOpen
                                    ? NusaConfig.activePrimary
                                    : Colors.transparent,
                              ),
                              child: requiresCashOpen
                                  ? Icon(
                                      Icons.check,
                                      size: 14,
                                      color: Colors.white,
                                    )
                                  : null,
                            ),
                            SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Kas Awal',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: isDark
                                          ? NusaConfig.darkTextSecondary
                                          : NusaConfig.textSecondary,
                                    ),
                                  ),
                                  Text(
                                    'Karyawan wajib isi kas awal saat presensi masuk',
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
                    ),
                    // Kas Akhir
                    GestureDetector(
                      onTap: () =>
                          setSt(() => requiresCashClose = !requiresCashClose),
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          children: [
                            Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: requiresCashClose
                                      ? NusaConfig.activePrimary
                                      : (isDark
                                            ? NusaConfig.darkDivider
                                            : NusaConfig.dividerColor),
                                  width: 2,
                                ),
                                color: requiresCashClose
                                    ? NusaConfig.activePrimary
                                    : Colors.transparent,
                              ),
                              child: requiresCashClose
                                  ? Icon(
                                      Icons.check,
                                      size: 14,
                                      color: Colors.white,
                                    )
                                  : null,
                            ),
                            SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Kas Akhir',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: isDark
                                          ? NusaConfig.darkTextSecondary
                                          : NusaConfig.textSecondary,
                                    ),
                                  ),
                                  Text(
                                    'Karyawan wajib isi kas akhir saat presensi pulang',
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
                    ),

                    // ── Staf Layanan (v2.2.54) ──
                    // v2.2.55: toggle hanya tampil di varian salon.
                    if (NusaConfig.isSalonVariant)
                      GestureDetector(
                        onTap: () =>
                            setSt(() => isServiceStaff = !isServiceStaff),
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 10),
                          child: Row(
                            children: [
                              Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: isServiceStaff
                                        ? NusaConfig.activePrimary
                                        : (isDark
                                              ? NusaConfig.darkDivider
                                              : NusaConfig.dividerColor),
                                    width: 2,
                                  ),
                                  color: isServiceStaff
                                      ? NusaConfig.activePrimary
                                      : Colors.transparent,
                                ),
                                child: isServiceStaff
                                    ? Icon(
                                        Icons.check,
                                        size: 14,
                                        color: Colors.white,
                                      )
                                    : null,
                              ),
                              SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Staf Layanan',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: isDark
                                            ? NusaConfig.darkTextSecondary
                                            : NusaConfig.textSecondary,
                                      ),
                                    ),
                                    Text(
                                      'Bisa dipilih sebagai stylist/Stylist saat booking layanan',
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
                      ),

                    // ── Komisi (%) v2.2.57 — hanya staf layanan (salon) ──
                    if (NusaConfig.isSalonVariant && isServiceStaff)
                      Padding(
                        padding: EdgeInsets.only(bottom: 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Komisi (%)',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: isDark
                                          ? NusaConfig.darkTextSecondary
                                          : NusaConfig.textSecondary,
                                    ),
                                  ),
                                  Text(
                                    '% omset booking yang jadi hak staf ini',
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
                            SizedBox(width: 12),
                            SizedBox(
                              width: 90,
                              child: TextFormField(
                                controller: commissionC,
                                keyboardType: TextInputType.numberWithOptions(
                                  decimal: true,
                                ),
                                inputFormatters: [
                                  FilteringTextInputFormatter.allow(
                                    RegExp(r'^\d{0,2}[.,]?\d{0,1}'),
                                  ),
                                ],
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: isDark
                                      ? NusaConfig.darkTextPrimary
                                      : NusaConfig.textPrimary,
                                ),
                                decoration: InputDecoration(
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 10,
                                  ),
                                  suffixText: '%',
                                  suffixStyle: TextStyle(fontSize: 12),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                    // ── NFC Tag Registration ──
                    _NfcRegisterButton(
                      isDark: isDark,
                      employeeId: employee?.id,
                      onRegistered: (tagHash) {
                        // NFC tag registered — reload will pick up the tag
                      },
                    ),

                    SizedBox(height: 20),
                    // Action buttons
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.of(context).pop(),
                            style: OutlinedButton.styleFrom(
                              padding: EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              side: BorderSide(
                                color: isDark
                                    ? NusaConfig.darkInputBorder
                                    : NusaConfig.inputBorder,
                              ),
                            ),
                            child: Text(
                              'Batal',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: isDark
                                    ? NusaConfig.darkTextSecondary
                                    : NusaConfig.textSecondary,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () async {
                              final name = nameC.text.trim();
                              final pin = pinC.text.trim();
                              if (name.isEmpty || pin.isEmpty) {
                                setSt(() => error = 'Nama dan PIN wajib diisi');
                                return;
                              }
                              if (pin.length < 4 ||
                                  pin.length > 6 ||
                                  int.tryParse(pin) == null) {
                                setSt(
                                  () => error = 'PIN harus 4-6 digit angka',
                                );
                                return;
                              }
                              final phone = phoneC.text.trim();
                              if (phone.isNotEmpty) {
                                final clean = phone.replaceAll(
                                  RegExp(r'[^0-9]'),
                                  '',
                                );
                                if (clean.length < 10 ||
                                    !clean.startsWith('0')) {
                                  setSt(
                                    () => error =
                                        'No. WA harus valid (08xx, min 10 digit)',
                                  );
                                  return;
                                }
                              }
                              final salary = int.tryParse(salaryC.text.trim());
                              final repo = AttendanceRepository(
                                ref.read(databaseProvider),
                              );
                              // PIN harus UNIK — dua karyawan/role tidak boleh pakai
                              // PIN sama (kalau sama, login bakal tabrakan).
                              final all = await repo.getEmployees();
                              final clash = all.cast<Employee?>().firstWhere(
                                (e) =>
                                    e!.pin == pin &&
                                    e.id != (employee?.id ?? -1),
                                orElse: () => null,
                              );
                              if (clash != null) {
                                setSt(
                                  () => error =
                                      'PIN sudah dipakai ${clash.name} (${clash.role}). Gunakan PIN lain.',
                                );
                                return;
                              }
                              // Barcode id-card (B8): juga harus unik kalau
                              // diisi. Toggle OFF → tidak disimpan.
                              final barcode = barcodeOn
                                  ? (barcodeC.text.trim().isEmpty
                                        ? null
                                        : ProductRepository.normalizeBarcode(
                                            barcodeC.text.trim(),
                                          ))
                                  : null;
                              if (barcode != null) {
                                final sameBarcode = all.cast<Employee?>()
                                    .firstWhere(
                                      (e) =>
                                          e!.barcode != null &&
                                          e.barcode == barcode &&
                                          e.id != (employee?.id ?? -1),
                                      orElse: () => null,
                                    );
                                if (sameBarcode != null) {
                                  setSt(
                                    () => error =
                                        'Barcode sudah dipakai ${sameBarcode.name} (${sameBarcode.role}). Gunakan barcode lain.',
                                  );
                                  return;
                                }
                              }
                              // v2.2.57+130 (A1.3): JANGAN simpan foto sebagai
                              // BASE64 lagi — kolom photo_base64 membengkakkan
                              // DB + arsip backup (OOM + bom egress). Foto
                              // file-first: file lokal; pemulihan setelah
                              // restore lewat base64 legacy yang masih ada
                              // di DB lama (hydrate) atau sync gambar cloud.
                              const photoBase64 = null;
                              if (employee == null) {
                                final newId = await repo.addEmployee(
                                  name: name,
                                  pin: pin,
                                  role: role,
                                  phone: phone.isNotEmpty ? phone : null,
                                  photoPath: photoPath,
                                  photoBase64: photoBase64,
                                  baseSalary: salary,
                                  startDate: startDate,
                                  status: status,
                                  branchId: branchId,
                                  workStart: workStart,
                                  workEnd: workEnd,
                                  requiresCashOpen: requiresCashOpen,
                                  requiresCashClose: requiresCashClose,
                                  barcode: barcode,
                                  isServiceStaff: isServiceStaff,
                                  commissionPercent:
                                      double.tryParse(
                                        commissionC.text.replaceAll(',', '.'),
                                      ) ??
                                      10.0,
                                );
                                // Delta sync: announce new employee
                                DeltaSyncService.I.pushDelta(
                                  table: 'employees',
                                  recordId: newId.toString(),
                                  operation: 'INSERT',
                                  data: {'id': newId, 'name': name, 'role': role, 'status': status},
                                );
                              } else {
                                await repo.updateEmployee(
                                  id: employee.id,
                                  name: name,
                                  pin: pin,
                                  role: role,
                                  phone: phone.isNotEmpty ? phone : null,
                                  photoPath: photoPath,
                                  photoBase64: photoBase64,
                                  baseSalary: salary,
                                  startDate: startDate,
                                  status: status,
                                  branchId: branchId,
                                  workStart: workStart,
                                  workEnd: workEnd,
                                  requiresCashOpen: requiresCashOpen,
                                  requiresCashClose: requiresCashClose,
                                  barcode: barcode,
                                  isServiceStaff: isServiceStaff,
                                  commissionPercent:
                                      double.tryParse(
                                        commissionC.text.replaceAll(',', '.'),
                                      ),
                                );
                                // Delta sync: announce employee update
                                DeltaSyncService.I.pushDelta(
                                  table: 'employees',
                                  recordId: employee.id.toString(),
                                  operation: 'UPDATE',
                                  data: {'id': employee.id, 'name': name, 'role': role, 'status': status},
                                );
                              }
                              // Upload photo to cloud in background
                              if (photoPath != null) {
                                try {
                                  // v2.2.38: path cloud pakai Google UID,
                                  // bukan Supabase anon UID.
                                  // v2.2.57+115 (Area I): canonical UID — sama
                                  // dengan path backup supaya foto karyawan
                                  // tidak pecah antara akun email vs Google.
                                  final uid = await SecureStore
                                      .resolveCanonicalUid();
                                  if (uid != null) {
                                    ImageStorageService(
                                      uid,
                                    ).uploadImage('employees', photoPath!);
                                  }
                                } catch (_) {}
                              }
                              if (mounted) Navigator.of(context).pop();
                              _load();
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: NusaConfig.activePrimary,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Text(
                              'Simpan',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ), // Container
          ); // HidBarcodeListener + return
        }, // StatefulBuilder builder
      ), // StatefulBuilder
    ); // showModalBottomSheet
  }

  Widget _buildDialogDropdown({
    required String label,
    required String value,
    required List<String> items,
    required bool isDark,
    Color? Function(String)? colorFn,
    required ValueChanged<String?> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isDark
                ? NusaConfig.darkTextSecondary
                : NusaConfig.textSecondary,
          ),
        ),
        SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: isDark ? NusaConfig.darkInputFill : NusaConfig.inputFill,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isDark
                  ? NusaConfig.darkInputBorder
                  : NusaConfig.inputBorder,
            ),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: items.contains(value) ? value : items.first,
              isExpanded: true,
              isDense: true,
              icon: Icon(
                Icons.expand_more,
                size: 20,
                color: isDark
                    ? NusaConfig.darkTextSecondary
                    : NusaConfig.textSecondary,
              ),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: isDark
                    ? NusaConfig.darkTextPrimary
                    : NusaConfig.textPrimary,
              ),
              dropdownColor: isDark ? NusaConfig.darkSurface : Colors.white,
              borderRadius: BorderRadius.circular(14),
              underline: SizedBox.shrink(),
              items: items.map((r) {
                final c = colorFn?.call(r);
                return DropdownMenuItem(
                  value: r,
                  child: Row(
                    children: [
                      if (c != null) ...[
                        Container(
                          width: 10,
                          height: 10,
                          margin: EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                      Text(r),
                    ],
                  ),
                );
              }).toList(),
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }

  Widget _timeField({
    required String label,
    required String value,
    required VoidCallback onTap,
    bool isDark = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkInputFill : NusaConfig.inputFill,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isDark ? NusaConfig.darkInputBorder : NusaConfig.inputBorder,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.access_time, size: 15, color: NusaConfig.activePrimary),
            SizedBox(width: 8),
            Text(
              value,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: NusaConfig.activePrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Generate kode id-card acak (alfanumerik aman untuk code128 + mudah
  /// diketik manual) — pola sama dengan generate barcode member/produk.
  String _generateBarcode() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final seed = DateTime.now().microsecondsSinceEpoch.toString().codeUnits;
    final buf = StringBuffer();
    for (var i = 0; i < 8; i++) {
      buf.write(alphabet[(seed[i % seed.length] ^ (i * 31 + 7)) %
          alphabet.length]);
    }
    return 'KRY-$buf';
  }

  /// Scan barcode ke search field — populates search + filters list.
  /// v2.2.47 revisi: scanner icon di search bar karyawan.
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
      _searchCtrl.text = scannedCode!;
      setState(() => _query = scannedCode!);
    }
  }

  /// Scan barcode id-card via kamera (pola sama dengan scanner POS/produk).
  /// Hasil dipakai [onResult] — biasanya isi [barcodeC] di form karyawan.
  Future<void> _scanBarcodeFromCamera(
    BuildContext ctx,
    StateSetter setSt,
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
              Text('Pindai Barcode ID'),
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
                    debugPrint('[Karyawan] scanner error: $error');
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
    final norm = ProductRepository.normalizeBarcode(scannedCode!);
    if (norm.isEmpty) return;
    onResult(norm);
  }

  Future<void> _delete(Employee e) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Hapus Karyawan'),
        content: Text('Hapus ${e.name}? Data presensi tetap tersimpan.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Batal'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              'Hapus',
              style: TextStyle(color: NusaConfig.activePrimary),
            ),
          ),
        ],
      ),
    );
    if (confirm == true) {
      final repo = AttendanceRepository(ref.read(databaseProvider));
      await repo.deleteEmployee(e.id);
      _load();
    }
  }

  Future<void> _shareEmployeeCard(Employee e) async {
    try {
      TopToast.info(context, 'Menyiapkan kartu ID…');
      final settingsRepo = ref.read(settingsRepoProvider);
      final storeName = await settingsRepo.getStoreName();
      final effectiveStoreName = storeName.isNotEmpty ? storeName : 'NUSA Store';
      final cardWidget = IdCardRenderer.employeeCard(
        storeName: effectiveStoreName,
        name: e.name,
        role: e.role,
        id: e.id,
        barcode: e.barcode ?? 'EMP-${e.id}',
        phone: e.phone,
        photoBytes: photoToImage(e.photoPath),
      );
      final file = await IdCardRenderer.renderSingle(
        card: cardWidget,
        fileName: 'kartu_${e.name.toLowerCase().replaceAll(' ', '_')}',
      );
      if (mounted) {
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path)],
            subject: 'Kartu ID - ${e.name}',
            text: 'Kartu ID Karyawan ${e.name} (${e.role}) - $effectiveStoreName',
          ),
        );
      }
    } catch (err) {
      if (mounted) TopToast.error(context, 'Gagal membuat kartu ID: $err');
    }
  }

  Future<void> _openWA(Employee e) async {
    if (e.phone == null || e.phone!.isEmpty) return;
    // Normalisasi via helper (v2.2.35): 08xx → 628xx.
    final uri = waLink(e.phone!);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  String _fmtDate(DateTime? d) {
    if (d == null) return '';
    return DateFormat('dd MMM yyyy', 'id').format(d);
  }

  // ═══════════════════════════════════════════════════════════
  //  Role & Jabatan Management
  // ═══════════════════════════════════════════════════════════

  Widget _buildRoleRow(bool isDark) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16),
      child: InkWell(
        onTap: () => _showManageRoles(),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isDark ? NusaConfig.darkSurface2 : NusaConfig.surfaceColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isDark ? NusaConfig.darkBorder : NusaConfig.borderColor,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: NusaConfig.accentPurple.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.admin_panel_settings,
                  size: 18,
                  color: NusaConfig.accentPurple,
                ),
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Role & Jabatan',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: isDark
                        ? NusaConfig.darkTextPrimary
                        : NusaConfig.textPrimary,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 20,
                color: isDark
                    ? NusaConfig.darkTextSecondary
                    : NusaConfig.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showManageRoles() async {
    final roleRepo = RoleRepository(ref.read(databaseProvider));
    final roles = await roleRepo.getRoles();
    if (!mounted) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text(
            'Kelola Role & Jabatan',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...roles.map((r) {
                    final name = r['name'] as String;
                    final color = Color(r['color'] as int);
                    final isDefault = RoleRepository.defaultRoleNames.contains(
                      name,
                    );
                    return Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: isDark
                              ? NusaConfig.darkSurface2
                              : NusaConfig.backgroundColor,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isDark
                                ? NusaConfig.darkBorder
                                : NusaConfig.borderColor,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: color.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(Icons.badge, size: 18, color: color),
                            ),
                            SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                name,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            GestureDetector(
                              onTap: () async {
                                Navigator.of(ctx).pop();
                                await _showRoleForm(roleRepo, existing: r);
                              },
                              child: Padding(
                                padding: EdgeInsets.all(8),
                                child: Icon(
                                  Icons.edit,
                                  size: 18,
                                  color: isDark
                                      ? NusaConfig.darkTextSecondary
                                      : NusaConfig.textSecondary,
                                ),
                              ),
                            ),
                            if (!isDefault)
                              GestureDetector(
                                onTap: () async {
                                  final confirm = await showDialog<bool>(
                                    context: ctx,
                                    builder: (_) => AlertDialog(
                                      title: Text('Hapus Role'),
                                      content: Text(
                                        'Hapus role "$name"? Karyawan dengan role ini akan perlu diubah manual.',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.of(ctx).pop(false),
                                          child: Text('Batal'),
                                        ),
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.of(ctx).pop(true),
                                          child: Text(
                                            'Hapus',
                                            style: TextStyle(
                                              color: NusaConfig.activePrimary,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (confirm == true) {
                                    await roleRepo.deleteRole(name);
                                    // Refresh RBAC provider after deletion
                                    await loadRoleAccess(ref);
                                    if (mounted) {
                                      Navigator.of(ctx).pop();
                                      _loadRoles();
                                    }
                                  }
                                },
                                child: Padding(
                                  padding: EdgeInsets.all(8),
                                  child: Icon(
                                    Icons.delete_outline,
                                    size: 18,
                                    color: NusaConfig.activePrimary,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('Tutup'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                await _showRoleForm(roleRepo);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: NusaConfig.activePrimary,
                foregroundColor: Colors.white,
                minimumSize: Size(120, 44),
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(
                'Tambah Role',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showRoleForm(
    RoleRepository roleRepo, {
    Map<String, dynamic>? existing,
  }) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isEdit = existing != null;
    final nameCtrl = TextEditingController(text: existing?['name'] as String?);
    var selectedColor = existing != null
        ? (existing['color'] as int)
        : 0xFF3B82F6;
    final accessList = <String>[];
    if (existing != null)
      accessList.addAll((existing['access'] as List).cast<String>());

    // Only show menus relevant to this variant
    final hidden = NusaConfig.hiddenMenus;
    const allScreens = [
      'home',
      'kasir',
      'produk',
      'stok',
      'transaksi',
      'pelanggan',
      'promo',
      'laporan',
      'presensi',
      'karyawan',
      'keuangan',
      'pengaturan',
      'supplier',
      'spreadsheet',
      'pesanan_online',
      'ai_chat',
      'piutang',
      'cabang',
      'meja',
      'laundry_status',
      'servis',
      'booking',
      'resep',
      'print_order',
    ];
    final visibleScreens = allScreens
        .where((s) => !hidden.contains(s))
        .toList();

    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text(
            isEdit ? 'Edit Role' : 'Tambah Role Baru',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                NusaInput('Nama Role', controller: nameCtrl, hint: 'Cth: Kasir'),
                SizedBox(height: 12),
                Text(
                  'Warna',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
                SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children:
                      [
                            0xFFE63946,
                            0xFF3B82F6,
                            0xFF10B981,
                            0xFF8B5CF6,
                            0xFFF59E0B,
                            0xFFEC4899,
                            0xFF6366F1,
                            0xFF14B8A6,
                          ]
                          .map(
                            (c) => GestureDetector(
                              onTap: () => setSt(() => selectedColor = c),
                              child: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: Color(c),
                                  borderRadius: BorderRadius.circular(10),
                                  border: selectedColor == c
                                      ? Border.all(
                                          color: isDark
                                              ? Colors.white
                                              : Colors.black,
                                          width: 3,
                                        )
                                      : null,
                                ),
                              ),
                            ),
                          )
                          .toList(),
                ),
                SizedBox(height: 16),
                Text(
                  'Akses Menu',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
                SizedBox(height: 8),
                ...visibleScreens.map(
                  (s) => CheckboxListTile(
                    title: Text(s, style: TextStyle(fontSize: 13)),
                    value: accessList.contains(s),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    onChanged: (v) => setSt(() {
                      v == true ? accessList.add(s) : accessList.remove(s);
                    }),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('Batal'),
            ),
            ElevatedButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;
                if (isEdit) {
                  await roleRepo.updateRole(
                    existing['name'] as String,
                    name,
                    selectedColor,
                    accessList,
                  );
                } else {
                  await roleRepo.addRole(name, selectedColor, accessList);
                }
                // Refresh RBAC provider so new access lists take effect immediately
                await loadRoleAccess(ref);
                if (mounted) {
                  Navigator.of(ctx).pop();
                  _loadRoles();
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: NusaConfig.activePrimary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text('Simpan'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final employees = _filtered;

    return ScreenScaffold(
      'Karyawan',
      onBarcode: (code) {
        final norm = ProductRepository.normalizeBarcode(code);
        if (norm.isEmpty) return;
        _searchCtrl.text = norm;
        if (mounted) setState(() => _query = norm);
      },
      Column(
        children: [
          // Search bar standar (v2.2.54)
          Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: NusaSearchBar(
              controller: _searchCtrl,
              hint: 'Cari karyawan...',
              showScanner: true,
              onScan: () => _scanBarcodeToSearch(context),
            ),
          ),
          // ── Role manager row (Owner only) ──
          if (ref.read(employeeSessionProvider)?.role == 'Owner')
            _buildRoleRow(isDark),
          Expanded(
            child: _loading
                ? Center(child: CircularProgressIndicator())
                : _employees.isEmpty
                ? EmptyState(
                    icon: Icons.people_outline,
                    message: 'Belum ada karyawan. Tambah lewat tombol +',
                  )
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView.separated(
                      padding: EdgeInsets.all(16),
                      itemCount: employees.length,
                      separatorBuilder: (_, _) => SizedBox(height: 12),
                      itemBuilder: (_, i) {
                        final e = employees[i];
                        final hasPhoto =
                            e.photoPath != null && e.photoPath!.isNotEmpty;
                        final statusColor =
                            _statusColors[e.status ?? 'Aktif'] ??
                            NusaConfig.accentGreen;
                        return NusaCard(
                          Padding(
                            padding: EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    // Photo / Avatar
                                    Container(
                                      width: 52,
                                      height: 52,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(16),
                                        color: _avatarColor(e.name),
                                        image: hasPhoto
                                            ? DecorationImage(
                                                image: FileImage(
                                                  File(e.photoPath!),
                                                  scale: 1.0,
                                                ),
                                                fit: BoxFit.cover,
                                                filterQuality:
                                                    FilterQuality.low,
                                              )
                                            : null,
                                        border: Border.all(
                                          color: statusColor,
                                          width: 2,
                                        ),
                                      ),
                                      alignment: Alignment.center,
                                      child: hasPhoto
                                          ? null
                                          : Text(
                                              e.name.isNotEmpty
                                                  ? e.name[0].toUpperCase()
                                                  : '?',
                                              style: TextStyle(
                                                fontSize: 22,
                                                fontWeight: FontWeight.w700,
                                                color: Colors.white,
                                              ),
                                            ),
                                    ),
                                    SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            e.name,
                                            style: TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w700,
                                              color: isDark
                                                  ? NusaConfig.darkTextPrimary
                                                  : NusaConfig.textPrimary,
                                            ),
                                          ),
                                          SizedBox(height: 4),
                                          Row(
                                            children: [
                                              _roleBadge(e.role),
                                              if (e.status != null &&
                                                  e.status != 'Aktif') ...[
                                                SizedBox(width: 6),
                                                _statusBadge(e.status!),
                                              ],
                                            ],
                                          ),
                                          if (e.startDate != null) ...[
                                            SizedBox(height: 4),
                                            Row(
                                              children: [
                                                Icon(
                                                  Icons.calendar_today,
                                                  size: 13,
                                                  color: isDark
                                                      ? NusaConfig
                                                            .darkTextTertiary
                                                      : NusaConfig.textTertiary,
                                                ),
                                                SizedBox(width: 4),
                                                Text(
                                                  'Mulai: ${_fmtDate(e.startDate)}',
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    color: isDark
                                                        ? NusaConfig
                                                              .darkTextTertiary
                                                        : NusaConfig
                                                              .textTertiary,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    PopupMenuButton<String>(
                                      color: isDark
                                          ? NusaConfig.darkSurface
                                          : null,
                                      onSelected: (v) {
                                        if (v == 'card') _shareEmployeeCard(e);
                                        if (v == 'edit') _showForm(employee: e);
                                        if (v == 'delete') _delete(e);
                                      },
                                      itemBuilder: (_) => [
                                        PopupMenuItem(
                                          value: 'card',
                                          child: Row(
                                            children: [
                                              Icon(Icons.badge_outlined, size: 16, color: NusaConfig.activePrimary),
                                              const SizedBox(width: 8),
                                              const Text('Cetak Kartu ID'),
                                            ],
                                          ),
                                        ),
                                        PopupMenuItem(
                                          value: 'edit',
                                          child: Text('Edit'),
                                        ),
                                        PopupMenuItem(
                                          value: 'delete',
                                          child: Text('Hapus'),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                // Bottom row: salary + WA
                                if (e.baseSalary != null ||
                                    (e.phone != null &&
                                        e.phone!.isNotEmpty)) ...[
                                  SizedBox(height: 10),
                                  Divider(height: 1),
                                  SizedBox(height: 8),
                                  Row(
                                    children: [
                                      if (e.baseSalary != null) ...[
                                        Icon(
                                          Icons.payments_outlined,
                                          size: 14,
                                          color: isDark
                                              ? NusaConfig.darkTextSecondary
                                              : NusaConfig.textSecondary,
                                        ),
                                        SizedBox(width: 4),
                                        Text(
                                          'Gaji: ${formatRupiah(e.baseSalary!)}',
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            color: NusaConfig.accentGreenDark,
                                          ),
                                        ),
                                      ],
                                      if (e.baseSalary != null &&
                                          e.phone != null &&
                                          e.phone!.isNotEmpty)
                                        Spacer(),
                                      if (e.phone != null &&
                                          e.phone!.isNotEmpty)
                                        GestureDetector(
                                          onTap: () => _openWA(e),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.phone_android,
                                                size: 14,
                                                color: Color(0xFF25D366),
                                              ),
                                              SizedBox(width: 4),
                                              Text(
                                                e.phone!,
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  color: isDark
                                                      ? NusaConfig
                                                            .darkTextSecondary
                                                      : NusaConfig
                                                            .textSecondary,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
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
        elevation: 4,
        icon: Icon(Icons.add),
        label: Text(
          'Tambah Karyawan',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        onPressed: () => _showForm(),
      ),
    );
  }
}

// ── NFC Tag Registration Widget ───────────────────────────────────────

class _NfcRegisterButton extends StatefulWidget {
  final bool isDark;
  final int? employeeId;
  final void Function(String tagHash)? onRegistered;

  _NfcRegisterButton({
    required this.isDark,
    this.employeeId,
    this.onRegistered,
  });

  @override
  State<_NfcRegisterButton> createState() => _NfcRegisterButtonState();
}

class _NfcRegisterButtonState extends State<_NfcRegisterButton> {
  bool _writing = false;
  bool _done = false;
  String? _error;

  Future<void> _startWrite() async {
    setState(() {
      _writing = true;
      _error = null;
    });

    if (widget.employeeId == null) {
      // Employee not saved yet — show message to save first
      setState(() {
        _writing = false;
        _error = 'Simpan karyawan dulu, lalu daftarkan NFC';
      });
      return;
    }

    final ok = await NfcTagService.writeEmployeeTag(widget.employeeId!);

    if (mounted) {
      setState(() {
        _writing = false;
        if (ok) {
          _done = true;
          widget.onRegistered?.call('nfc_registered');
        } else {
          _error = 'Gagal menulis tag. Coba lagi.';
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final borderColor = _done
        ? NusaConfig.accentGreen
        : widget.isDark
        ? NusaConfig.darkBorder
        : NusaConfig.borderColor;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
        color: widget.isDark
            ? NusaConfig.darkSurface2
            : NusaConfig.backgroundColor,
      ),
      child: Row(
        children: [
          AnimatedContainer(
            duration: Duration(milliseconds: 400),
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _done
                  ? NusaConfig.accentGreen.withValues(alpha: 0.12)
                  : NusaConfig.accentPurple.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: _writing
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : Icon(
                    _done ? Icons.check_circle : Icons.nfc,
                    size: 22,
                    color: _done
                        ? NusaConfig.accentGreen
                        : NusaConfig.accentPurple,
                  ),
          ),
          SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _done ? 'NFC Tag Terdaftar ✅' : 'Daftarkan NFC Tag',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: _done
                        ? NusaConfig.accentGreen
                        : widget.isDark
                        ? NusaConfig.darkTextPrimary
                        : NusaConfig.textPrimary,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  _error ??
                      (_done
                          ? 'Karyawan bisa login dengan tap kartu'
                          : 'Tempelkan kartu NFC untuk daftar'),
                  style: TextStyle(
                    fontSize: 12,
                    color: _error != null
                        ? NusaConfig.activePrimary
                        : widget.isDark
                        ? NusaConfig.darkTextSecondary
                        : NusaConfig.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (!_done)
            GestureDetector(
              onTap: _writing ? null : _startWrite,
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: NusaConfig.accentPurple,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'Daftarkan',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
