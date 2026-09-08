import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nusa_kasir/core/config/nusa_config.dart';
import 'package:nusa_kasir/core/services/google_auth_service.dart';
import 'package:nusa_kasir/core/services/account_auth_service.dart';
import 'package:nusa_kasir/core/utils/icon_loader.dart';
import 'package:nusa_kasir/core/utils/permission_helper.dart';
import 'package:nusa_kasir/core/providers.dart';
import 'package:nusa_kasir/core/auth/employee_session.dart';
import 'package:nusa_kasir/core/activation/activation_key.dart';
import 'package:nusa_kasir/core/activation/activation_public_key.dart';
import 'package:nusa_kasir/core/activation/activation_repository.dart';
import 'package:nusa_kasir/core/utils/secure_storage.dart';
import 'package:nusa_kasir/data/database/app_database.dart';
import 'package:nusa_kasir/data/repositories/attendance_repository.dart';
import 'package:nusa_kasir/data/repositories/product_repository.dart';
import 'package:nusa_kasir/data/repositories/settings_repository.dart';
import 'package:nusa_kasir/features/auth/employee_session_provider.dart';
import 'package:nusa_kasir/shared/widgets/top_toast.dart';
import 'package:nusa_kasir/shared/widgets/restore_backup_flow.dart';
import 'package:nusa_kasir/shared/widgets/pin_keypad.dart';
import 'package:nusa_kasir/shared/widgets/animated_scanner_overlay.dart';
import 'package:nusa_kasir/shared/services/biometric_service.dart';
import 'package:nusa_kasir/shared/services/nfc_tag_service.dart';
import 'package:nusa_kasir/core/payment/payment_sheet.dart';
import 'package:nusa_kasir/core/payment/payment_webview.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:nusa_kasir/core/cloud/cloud_gateway.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:url_launcher/url_launcher.dart';

/// Activation & auth screen with 4 branches:
///
///   1. Welcome Screen — user memilih "Masuk dengan Google" secara manual
///   2. Setelah Google ID didapat:
///      a. Sudah aktivasi key → minta PIN untuk sign in
///      b. Belum aktivasi → tampilkan 2 pilihan:
///         "Sudah punya lisensi key" → key input (beli dari e-commerce)
///         "Belum punya lisensi" → PaymentSheet → WebView Midtrans → auto-activate
///   3. PIN → cek role → auto check-in attendance → dashboard
///   4. Restore prompt for cloud backup
///
/// Tidak ada auto-trigger Google sign-in — user memilih sendiri.
class ActivationScreen extends ConsumerStatefulWidget {
  ActivationScreen({super.key});
  @override
  ConsumerState<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends ConsumerState<ActivationScreen> {
  // Google Sign-In state
  bool _googleLoading = false;
  String? _googleError;
  String? _googleId;

  // Email/password auth (v2.2.57+112)
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _signupEmailCtrl = TextEditingController();
  final _signupPassCtrl = TextEditingController();
  final _signupPass2Ctrl = TextEditingController();
  bool _obscurePass = true;
  bool _obscurePass2 = true;
  bool _rememberEmail = true;
  bool _authLoading = false;
  String? _authError;

  // Activation key input (new user)
  final _keyCtrl = TextEditingController();
  bool _keyLoading = false;
  String? _keyError;

  // PIN input (returning user)
  bool _pinLoading = false;
  String? _pinError;
  bool _nfcAvailable = false;
  final _keypadKey = GlobalKey<PinKeypadState>();
  // v2.2.43: panjang PIN dari settings (4/6) — jangan hardcode 6, supaya user
  // yang PIN-nya 4 digit tidak stuck selamanya.
  int _pinLength = 6;

  // Lite activation (v2.2.57+130): email + key, tanpa Google Sign-In
  final _liteEmailCtrl = TextEditingController();
  final _liteKeyCtrl = TextEditingController();
  bool _liteLoading = false;
  String? _liteError;

  // Screen state: 'auth' (login) | 'signup' | 'google_loading' | 'decision' | 'pin' | 'key' | 'trial_expired' | 'lite'
  String _screen = 'auth';

  // v2.2.44 (L2/L3): expires_at lisensi yang habis — untuk countdown grace
  // 7 hari (H-7 diterima server; H+7 key di-revoke) di layar blokir.
  DateTime? _licenseExpiry;

  @override
  void initState() {
    super.initState();
    // v2.2.57+116: dialog izin pertama kali di layar LOGIN (aktivasi) — bukan
    // nunggu setup. User yang baru install langsung ditanya sekali (kamera,
    // notifikasi, penyimpanan, bluetooth) saat membuka aplikasi pertama kali.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      requestFirstInstallPermissions();
    });
    _initAutoSignIn();
    NfcTagService.isAvailable().then((ok) {
      if (mounted) setState(() => _nfcAvailable = ok);
    });
    ref.read(settingsRepoProvider).getPinLength().then((len) {
      if (mounted && len != _pinLength) setState(() => _pinLength = len);
    });
  }

  /// Auto sign-in: akun email/password dulu (kalau "Ingat saya" dicentang),
  /// lalu fallback ke Google seperti sebelumnya. Keduanya berujung pada
  /// `_checkLicenseStatus`.
  ///
  /// v2.2.57+130 Lite: skip auto-sign-in kalau Lite — user akan langsung ke
  /// Lite screen (email + key) atau langsung ke quick setup kalau sudah aktivasi.
  Future<void> _initAutoSignIn() async {
    final activated = (await SecureStore.getActivation()) != null;
    if (!activated) {
      // Lite: belum aktivasi → langsung ke Lite screen (email + key)
      if (NusaConfig.isLite && mounted) {
        setState(() => _screen = 'lite');
      }
      return;
    }
    // Lite yang sudah aktivasi: cek cloud via Lite email → langsung ke setup/PIN
    if (NusaConfig.isLite) {
      final liteEmail = await SecureStore.getLiteEmail();
      if (liteEmail != null && liteEmail.isNotEmpty && mounted) {
        _googleId = liteEmail;
        await _checkLicenseStatus(liteEmail);
      }
      return;
    }
    final accountUid = await AccountAuthService.getStoredUid();
    if (accountUid != null && await AccountAuthService.shouldRemember()) {
      if (!mounted) return;
      _googleId = accountUid;
      if (mounted) await _checkLicenseStatus(accountUid);
      return;
    }
    final linked = await GoogleAuthService.isLinked();
    if (!linked) return;
    if (!mounted) return;
    _startGoogleSignIn();
  }

  Future<void> _startGoogleSignIn() async {
    if (_googleLoading) return;
    setState(() {
      _googleLoading = true;
      _googleError = null;
      _screen = 'google_loading';
    });
    try {
      final googleAuth = GoogleAuthService();
      final googleId = await googleAuth.signIn();
      if (googleId == null) {
        setState(() {
          _googleLoading = false;
          _googleError = 'Login Google diperlukan untuk menggunakan NUSA Kasir';
          _screen = 'auth';
        });
        return;
      }
      _googleId = googleId;
      await GoogleAuthService.ensureStored(googleId);

      // Show "checking license" state — keep spinner active during cloud call
      setState(() => _googleLoading = false);
      if (mounted) await _checkLicenseStatus(googleId);
    } catch (e) {
      setState(() {
        _googleLoading = false;
        _googleError = 'Gagal login Google: $e';
        _screen = 'auth';
      });
    }
  }

  /// v2.2.53: Ganti akun Google. google_sign_in menyimpan sesi akun lama di OS,
  /// jadi signIn() biasa hanya mengembalikan akun yang sama tanpa memunculkan
  /// pemilih akun. Untuk beneran ganti: disconnect dulu, lalu sign in ulang.
  Future<void> _switchGoogleAccount() async {
    if (_googleLoading) return;
    try {
      await GoogleAuthService().signOut();
    } catch (_) {
      // disconnect bisa gagal kalau belum pernah login — abaikan, lanjut login.
    }
    await _startGoogleSignIn();
  }

  // ── Email/password (v2.2.57+112) ────────────────────────────────────

  /// Login pakai email + password (Supabase Auth). Setelah uid didapat,
  /// jalankan `_checkLicenseStatus` — alur identik dengan jalur Google.
  ///
  /// Catatan "Ingat saya": UID akun SELALU disimpan — dia anchor identitas
  /// backup (path + kunci enkripsi, sama persis dengan peran Google UID).
  /// Yang dikontrol checkbox hanya auto-login di pembukaan app berikutnya.
  Future<void> _submitEmailLogin() async {
    final email = _emailCtrl.text.trim();
    final pass = _passCtrl.text;
    if (email.isEmpty || pass.isEmpty) {
      setState(() => _authError = 'Masukkan email dan password');
      return;
    }
    if (!_isEmail(email)) {
      setState(() => _authError = 'Format email tidak valid');
      return;
    }
    setState(() {
      _authLoading = true;
      _authError = null;
    });
    final uid = await AccountAuthService().signIn(email, pass);
    if (!mounted) return;
    if (uid == null) {
      setState(() {
        _authLoading = false;
        _authError = 'Email atau password salah';
      });
      return;
    }
    _googleId = uid;
    await AccountAuthService.saveRemember(_rememberEmail);
    if (!mounted) return;
    setState(() => _authLoading = false);
    await _checkLicenseStatus(uid);
  }

  /// Daftar akun baru (email + password + konfirmasi password).
  Future<void> _submitSignup() async {
    final email = _signupEmailCtrl.text.trim();
    final pass = _signupPassCtrl.text;
    final pass2 = _signupPass2Ctrl.text;
    if (email.isEmpty || pass.isEmpty || pass2.isEmpty) {
      setState(() => _authError = 'Lengkapi semua kolom');
      return;
    }
    if (!_isEmail(email)) {
      setState(() => _authError = 'Format email tidak valid');
      return;
    }
    if (pass.length < 6) {
      setState(() => _authError = 'Password minimal 6 karakter');
      return;
    }
    if (pass != pass2) {
      setState(() => _authError = 'Password tidak sama');
      return;
    }
    setState(() {
      _authLoading = true;
      _authError = null;
    });
    final result = await AccountAuthService().signUp(email, pass);
    if (!mounted) return;
    setState(() => _authLoading = false);
    switch (result) {
      case 'ok':
        final uid = await AccountAuthService.getStoredUid();
        if (uid != null) {
          _googleId = uid;
          await _checkLicenseStatus(uid);
        } else {
          setState(() => _screen = 'auth');
        }
        return;
      case 'confirm_email':
        setState(() {
          _screen = 'auth';
          _authError = 'Cek email kamu untuk konfirmasi, lalu login.';
        });
        return;
      case 'exists':
        setState(() {
          _authError = 'Email sudah terdaftar. Silakan login.';
        });
        return;
      default:
        setState(() {
          _authError = 'Gagal mendaftar. Periksa koneksi, coba lagi.';
        });
        return;
    }
  }

  /// Lupa password → kirim email reset (link ke nusa-online /reset-password).
  Future<void> _forgotPassword() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) {
      setState(() => _authError = 'Masukkan email dulu untuk reset password');
      return;
    }
    setState(() {
      _authLoading = true;
      _authError = null;
    });
    final ok = await AccountAuthService().resetPassword(email);
    if (!mounted) return;
    setState(() => _authLoading = false);
    TopToast.success(
      context,
      ok ? 'Link reset password terkirim ke email' : 'Gagal kirim link reset',
    );
  }

  bool _isEmail(String s) => RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s);

  /// Lite activation (v2.2.57+130): email + license key only.
  ///
  /// Alur:
  /// 1. Verifikasi key signature lokal (cek format)
  /// 2. Panggil ActivationRepository.activateLite() → worker endpoint
  ///    `license-manager/activate_lite` yang validasi email cocok dengan key
  /// 3. Kalau sukses → _checkLicenseStatus(email) → quick setup atau PIN
  Future<void> _submitLiteActivation() async {
    final email = _liteEmailCtrl.text.trim();
    final key = _liteKeyCtrl.text.trim();
    if (email.isEmpty || key.isEmpty) {
      setState(() => _liteError = 'Email dan key wajib diisi');
      return;
    }
    if (!_isEmail(email)) {
      setState(() => _liteError = 'Format email tidak valid');
      return;
    }
    setState(() {
      _liteLoading = true;
      _liteError = null;
    });
    final repo = ref.read(activationRepoProvider);
    final res = await repo.activateLite(key, email);
    if (!mounted) return;
    setState(() => _liteLoading = false);
    if (!res.ok) {
      setState(() => _liteError = res.error ?? 'Aktivasi gagal');
      return;
    }
    _googleId = email.toLowerCase();
    await _checkLicenseStatus(email.toLowerCase());
  }

  Future<void> _openLandingPage() async {
    final uri = Uri.parse(NusaConfig.landingPageUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// v2.2.44 (L4): buka halaman pembayaran /pay (abstrak — gateway bisa
  /// diganti di web tanpa menyentuh app). Kalau belum login Google, pakai
  /// _googleId kalau ada; kalau kosong, buka tanpa google_id (web minta login).
  Future<void> _openPayPage() async {
    final googleId = _googleId;
    final uri = Uri.parse(
      googleId != null && googleId.isNotEmpty
          ? NusaConfig.paymentLink(googleId, 'lifetime')
          : '${NusaConfig.paymentUrl}?product=${NusaConfig.productId}',
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// Check if employees exist. If not, try cloud restore first, then redirect to /setup.
  /// If employees exist, directly show PIN dialog.
  ///
  /// v2.2.39: restore/pin DIPUTUSKAN SEKARANG, bukan setelahnya. Sebelumnya
  /// alur `_goToPinOrSetup` → `_autoRestoreIfNeeded` mengecek backup TANPA
  /// menutup koneksi drift → `restoreDirect()` swap live sqlite saat drift
  /// masih terbuka = korupsi. Kali ini tutup DB dulu sebelum restore, supaya
  /// login pertama setelah install bisa langsung restore (tanpa hapus data).
  Future<void> _goToPinOrSetup() async {
    try {
      final db = ref.read(databaseProvider);
      final repo = AttendanceRepository(db);
      final emps = await repo.getEmployees();
      if (emps.isEmpty) {
        // Tidak ada karyawan — cek backup cloud DULU. Tutup koneksi drift
        // sebelum restore supaya swap aman (v2.2.39).
        try {
          await db.close();
        } catch (_) {}
        ref.invalidate(databaseProvider);
        final restored = await _autoRestoreIfNeeded();
        if (restored) return; // app akan restart / pindah ke login
        // v2.2.43: backup ADA tapi isinya varian lain → JANGAN langsung
        // /setup (impresi "dipaksa setup ulang"). Tampilkan dialog jelas;
        // user bisa kembali atau lanjut setup secara eksplisit.
        final actRepo = ref.read(activationRepoProvider);
        final variantStatus = await actRepo.checkBackupVariant();
        if (variantStatus == BackupVariantStatus.wrongVariant && mounted) {
          final goSetup = await _showWrongVariantDialog();
          if (goSetup == true && mounted) {
            context.go('/setup');
          }
          // Kembali → tetap di decision (bukan setup ulang paksa).
          if (mounted) setState(() => _screen = 'decision');
          return;
        }
        // Tidak ada backup atau restore gagal — setup dari nol.
        if (mounted) context.go('/setup');
        return;
      }
      // DB lokal punya karyawan → PIN pad. Ganti akun ditangani di
      // `_checkLicenseStatus` (sebelum _goToPinOrSetup dipanggil).
    } catch (_) {
      // DB rusak / query gagal — JANGAN langsung pinpad (PIN pasti gagal
      // karena tabel kosong/rusak). Coba pulihkan dari cloud dulu; setup
      // hanya fallback kalau memang tidak ada backup (v2.2.36).
      debugPrint('[Activation] _goToPinOrSetup error — coba restore cloud');
      try {
        final db = ref.read(databaseProvider);
        await db.close();
      } catch (_) {}
      ref.invalidate(databaseProvider);
      final restored = await _autoRestoreIfNeeded();
      if (restored) return; // app restart
      if (mounted && context.mounted) context.go('/setup');
      return;
    }
    if (mounted) setState(() => _screen = 'pin');
  }

  /// Check for cloud backup, show preview dialog, and restore if user confirms.
  /// Uses metadata.json for preview so user can see store/owner BEFORE restoring.
  /// Returns true if restore was performed and user was redirected.
  Future<bool> _autoRestoreIfNeeded() async {
    final repo = ref.read(activationRepoProvider);
    final hasBak = await repo.hasBackup();
    if (!hasBak) return false;

    // Fetch metadata for preview (non-sensitive, non-encrypted)
    final meta = await repo.getBackupMetadata();
    final storeName = meta?['storeName'] as String? ?? '';
    final ownerName = meta?['ownerName'] as String? ?? '';
    final backupTimeStr = meta?['backupTime'] as String?;
    DateTime? backupTime;
    if (backupTimeStr != null) {
      backupTime = DateTime.tryParse(backupTimeStr);
    }

    if (!mounted) return false;

    // Show preview dialog so user knows what data they're restoring
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              Icon(Icons.cloud_done_outlined, color: NusaConfig.activePrimary, size: 28),
              SizedBox(width: 10),
              Text('Data Ditemukan', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Data toko tersimpan di cloud. Ingin membukanya sekarang?',
                style: TextStyle(fontSize: 14, height: 1.5,
                  color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary),
              ),
              if (storeName.isNotEmpty || ownerName.isNotEmpty || backupTime != null) ...[
                SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: isDark ? NusaConfig.darkBackground : Color(0xFFF5F5F5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (storeName.isNotEmpty)
                        _metaRow('Nama Toko', storeName, isDark),
                      if (ownerName.isNotEmpty)
                        _metaRow('Pemilik', ownerName, isDark),
                      if (backupTime != null)
                        _metaRow(
                          'Terakhir Backup',
                          '${backupTime.day}/${backupTime.month}/${backupTime.year} '
                          '${backupTime.hour.toString().padLeft(2, '0')}:${backupTime.minute.toString().padLeft(2, '0')}',
                          isDark,
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          actions: [
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary,
                side: BorderSide(color: isDark ? NusaConfig.darkBorder : Color(0xFFEDEDEF)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Batal'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: NusaConfig.activePrimary,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Ya, Buka Toko Ini'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) return false;

    // User confirmed — download and restore the DB directly.
    // v2.2.37: restoreDirect() swap LANGSUNG ke sqlite live (drift sudah
    // ditutup di atas) → data berlaku seketika, TIDAK perlu restart. Setelah
    // restore sukses, langsung arahkan ke /login supaya user masuk dengan PIN
    // dari data hasil restore (kalau masih di activation, PIN pad yang lama
    // masih memegang state DB kosong).
    try {
      final db = ref.read(databaseProvider);
      await db.close();
    } catch (_) {}
    ref.invalidate(databaseProvider);

    final ok = await repo.restoreDirect();
    if (ok && mounted) {
      TopToast.success(context, 'Data berhasil dipulihkan');
      if (context.canPop()) {
        Navigator.of(context).popUntil((r) => r.isFirst);
      }
      if (mounted && context.mounted) context.go('/login');
      return true;
    }
    if (mounted) {
      // ── v2.2.57+115 (Area J): backup dari versi lebih baru ──
      final newerVersion = repo.lastBackupVersionError;
      if (newerVersion != null) {
        TopToast.error(
          context,
          'Backup dibuat dengan versi lebih baru ($newerVersion). '
          'Update aplikasi dulu, lalu restore lagi.',
        );
      } else {
        TopToast.error(context, 'Gagal memulihkan data dari cloud');
      }
    }
    return false;
  }

    /// Dialog "backup milik varian lain" — v2.2.43. Folder cloud bisa tercemar
  /// (mis. folder nusa-fnb berisi data servis). JANGAN diam-diam paksa setup
  /// ulang: tampilkan pesan jelas, user memilih kembali (ke decision) atau
  /// lanjut setup baru secara eksplisit. Return true = user pilih Setup Baru.
  Future<bool?> _showWrongVariantDialog() async {
    final actRepo = ref.read(activationRepoProvider);
    final meta = await actRepo.getBackupMetadata();
    final otherVariant = meta?['variantKey'] as String? ?? 'varian lain';
    if (!mounted) return null;
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  color: Colors.orange.shade700, size: 26),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Data Cloud Beda Varian',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Backup cloud untuk aplikasi ini berisi data dari "$otherVariant", '
                'bukan "${NusaConfig.appName}".',
                style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: isDark
                      ? NusaConfig.darkTextSecondary
                      : NusaConfig.textSecondary,
                ),
              ),
              SizedBox(height: 10),
              Text(
                'Data Anda tidak akan rusak atau terhapus. Anda bisa kembali '
                'atau memulai setup baru (data cloud lama tetap aman).',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: isDark
                      ? NusaConfig.darkTextTertiary
                      : NusaConfig.textTertiary,
                ),
              ),
            ],
          ),
          actions: [
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor:
                    isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary,
                side: BorderSide(
                    color:
                        isDark ? NusaConfig.darkBorder : Color(0xFFEDEDEF)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Kembali'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: NusaConfig.activePrimary,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Lanjut Setup Baru'),
            ),
          ],
        );
      },
    );
  }

  Widget _metaRow(String label, String value, bool isDark) {
    return Padding(
      padding: EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Check if this Google account already has an activated license.
  ///
  /// v2.2.40: SETELAH login Google (termasuk ganti akun / install ulang di
  /// atas data lama), SELALU cek backup cloud DULU sebelum menampilkan PIN
  /// pad. Sebelumnya kalau key aktivasi lokal masih ada (`isActivated`),
  /// langsung `_goToPinOrSetup()` → PIN pad tanpa cek backup → user yang
  /// ganti akun / install ulang tidak pernah melihat "Data Ditemukan"
  /// (harus hapus data aplikasi dulu). Key aktivasi berlaku per-varian,
  /// bukan per-akun — jadi key lama tidak menjamin backup akun baru sudah
  /// di-restore.
  ///
  /// v2.2.44 (L2): CEK CLOUD SELALU (sekali per session), bukan cuma saat
  /// belum aktivasi. Sebelumnya `isActivated` early-return → user yang sudah
  /// aktivasi TIDAK PERNAH diblokir walau lisensi (mis. 1 bulan) sudah habis.
  /// register_activation CHECK sekarang mengembalikan has_license=false +
  /// is_expired=true untuk Active yang expires_at lewat (server fix L1) —
  /// jadi di sini tinggal percaya pada respon cloud. Grace 7 hari = app
  /// LANGSUNG terkunci sejak expires_at lewat; countdown ditampilkan di
  /// layar blokir (L3).
  Future<void> _checkLicenseStatus(String googleUserId) async {
    // ── v2.2.40: catat akun yang baru login. Kalau akun ini BEDA dari yang
    // terakhir tersimpan → data lokal milik akun lain / fresh install di atas
    // data lama → backup cloud akun ini harus ditawarkan SEBELUM PIN pad.
    final prevLinked = await SecureStore.getLinkedAccountId();
    final accountSwitched = (prevLinked != null && prevLinked != googleUserId);
    await SecureStore.setLinkedAccountId(googleUserId);

    // ── v2.2.44 (L2): cek cloud DULU (sekali per session). Ini jalur SATU
    // sumber kebenaran untuk status lisensi — expired Active/Trial diblokir
    // server, jadi user yang sudah aktivasi pun tetap terkunci kalau lisensi
    // kedaluwarsa. Kalau offline → fallback ke key lokal (jangan blokir
    // user yang sah karena jaringan).
    try {
      final res = await CloudGateway.shared.invoke(
        'register_activation',
        body: {'googleUserId': googleUserId, 'product': NusaConfig.productId},
      );
      final data = res.data as Map<String, dynamic>?;
      if (data?['has_license'] == false) {
        final cloudStatus = data!['status'] as String?;
        final isExpired = data['is_expired'] == true;

        if (isExpired || cloudStatus == 'Expired' ||
            cloudStatus == 'Cancelled') {
          if (mounted) {
            // v2.2.57+112: akun yang lisensinya DIBATALKAN (Cancelled) kembali
            // ke layar status lisensi (decision — "sudah punya / belum punya
            // lisensi"), BUKAN layar perpanjangan.
            // Layar trial_expired (perpanjangan) hanya untuk status Expired.
            if (cloudStatus == 'Cancelled') {
              setState(() {
                _googleLoading = false;
                _googleError = data['message'] as String? ??
                    'Lisensi Anda tidak aktif lagi.\nHubungi admin untuk bantuan.';
                _licenseExpiry = data['expires_at'] != null
                    ? DateTime.tryParse(data['expires_at'] as String)
                    : null;
                _screen = 'decision';
              });
              return;
            }
            setState(() {
              _googleLoading = false;
              _googleError = data['message'] as String? ??
                  (cloudStatus == 'Expired'
                      ? 'Lisensi Anda telah kedaluwarsa.\nPerpanjang untuk melanjutkan.'
                      : 'Lisensi Anda tidak aktif lagi.\nHubungi admin untuk bantuan.');
              _licenseExpiry = data['expires_at'] != null
                  ? DateTime.tryParse(data['expires_at'] as String)
                  : null;
              _screen = 'trial_expired';
            });
          }
          return;
        }
      }
    } catch (_) {
      // Offline / Supabase error → fall through ke jalur lokal di bawah.
    }

    // First check local storage
    final isActivated = await ref.read(activationRepoProvider).isActivated;

    if (isActivated) {
      // ── v2.2.40: ganti akun / install ulang → key masih ada, tapi DB lokal
      // bisa kosong (fresh) atau milik akun lain. Kalau akun berubah ATAU DB
      // lokal tidak punya karyawan → cek backup cloud DULU (dialog "Data
      // Ditemukan" tampil) sebelum PIN pad. `_goToPinOrSetup` sendiri sudah
      // mengecek karyawan + restore saat DB kosong, tapi kita panggil
      // hasBackup eksplisit supaya dialog muncul meski DB lokal masih punya
      // karyawan milik akun LAMA (ganti akun) — restore hanya menimpa DB
      // kalau user setuju (dialog). Kalau user batal, PIN pad pakai data lama.
      if (accountSwitched) {
        final hasBak = await ref.read(activationRepoProvider).hasBackup();
        if (hasBak) {
          // Tutup koneksi drift SEBELUM restore supaya swap aman, lalu
          // tampilkan dialog "Data Ditemukan" → restore → redirect login.
          try {
            final db = ref.read(databaseProvider);
            await db.close();
          } catch (_) {}
          ref.invalidate(databaseProvider);
          final restored = await _autoRestoreIfNeeded();
          if (restored) return; // redirect ke /login
        }
      }
      if (mounted) {
        _goToPinOrSetup();
      }
      return;
    }

    // Try cloud check — user might have a license from another device
    try {
      final res = await CloudGateway.shared.invoke(
        'register_activation',
        body: {'googleUserId': googleUserId, 'product': NusaConfig.productId},
      );
      final data = res.data as Map<String, dynamic>?;
      if (data?['has_license'] == true) {
        // Check if trial expired
        final isExpired = data!['is_expired'] == true;

        if (isExpired) {
          setState(() {
            _googleLoading = false;
            _googleError = 'Masa trial Anda telah habis.\nBeli lisensi untuk melanjutkan.';
            _licenseExpiry = data['expires_at'] != null
                ? DateTime.tryParse(data['expires_at'] as String)
                : null;
            _screen = 'trial_expired';
          });
          return;
        }

        // Verify the returned key is valid locally
        final key = data['key'] as String;
        final keyValid = await ActivationKey.verify(
          key, nusaActivationPublicKey,
        );
        if (!keyValid) {
          if (mounted) {
            setState(() {
              _googleLoading = false;
              _googleError = 'Lisensi tidak valid untuk aplikasi ini.';
              _screen = 'decision';
            });
          }
          return;
        }

        await SecureStore.saveActivation(key);
        // v2.2.44 (L3/L5): simpan metadata lisensi (expiry/tier/status) supaya
        // dashboard bisa tampilkan banner perpanjang & settings tampil status.
        await SecureStore.saveLicenseInfo(
          expiresAt: data['expires_at'] != null
              ? DateTime.tryParse(data['expires_at'] as String)
              : null,
          tier: (data['tier'] as String?) ?? 'lifetime',
          status: (data['status'] as String?) ?? 'Active',
        );
        _goToPinOrSetup();
        return;
      }
    } catch (_) {
      // Offline / Supabase error — show decision screen, don't bypass activation
    }

    // No license at all — show the 2-button decision screen
    setState(() => _screen = 'decision');
  }


  // ── Key Activation Submit ──────────────────────────────────────────

  Future<void> _submitKey() async {
    final key = _keyCtrl.text.trim().toUpperCase();
    if (key.isEmpty) {
      setState(() => _keyError = 'Masukkan key aktivasi');
      return;
    }

    setState(() {
      _keyLoading = true;
      _keyError = null;
    });

    final googleId = _googleId ?? await GoogleAuthService.getStoredUserId();
    if (googleId == null) {
      setState(() {
        _keyLoading = false;
        _keyError = 'Login Google dulu';
      });
      return;
    }

    final repo = ref.read(activationRepoProvider);
    final r = await repo.activate(key, googleId);
    setState(() => _keyLoading = false);

    if (!r.ok) {
      setState(() => _keyError = r.error);
      return;
    }

    // Activation success → go to setup (atau restore cloud bila ada)
    // v2.2.43: JANGAN langsung /setup — akun yang sudah punya data cloud
    // varian ini harus di-restore DULU (dialog Data Ditemukan), bukan dibuat
    // setup dari nol. Kalau ada backup valid → preview → restoreDirect →
    // /login. Tidak ada backup → /setup (seperti sebelumnya).
    if (!mounted) return;
    TopToast.success(context, 'Aktivasi berhasil');
    final actRepo = ref.read(activationRepoProvider);
    final variantStatus = await actRepo.checkBackupVariant();
    if (!mounted) return;
    if (variantStatus == BackupVariantStatus.matches) {
      // Backup valid varian ini → tutup DB lalu restore langsung (aman,
      // drift belum dibuka di titik activation; _autoRestoreIfNeeded sudah
      // menutup). Setelah sukses arahkan ke /login (PIN data restore).
      final restored = await _autoRestoreIfNeeded();
      if (restored || !mounted) return;
      // Restore gagal → tetap ke setup (data tidak hilang, cuma tidak dipakai).
      if (mounted) context.go('/setup');
      return;
    }
    if (variantStatus == BackupVariantStatus.wrongVariant && mounted) {
      final goSetup = await _showWrongVariantDialog();
      if (goSetup == true && mounted) {
        context.go('/setup');
      }
      if (mounted) setState(() => _screen = 'decision');
      return;
    }
    // none → setup dari nol.
    if (mounted) context.go('/setup');
  }

  // ── Scan / NFC ─────────────────────────────────────────────────────

  Future<void> _scan() async {
    // Modal popup — consistent with all barcode scanners across the app
    final controller = MobileScannerController();
    String? scanned;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          Icon(Icons.qr_code_scanner, size: 22, color: NusaConfig.activePrimary),
          SizedBox(width: 8),
          Text('Scan Key Aktivasi'),
        ]),
        content: AnimatedScannerOverlay(
          size: 280,
          child: MobileScanner(
            controller: controller,
            onDetect: (c) {
              final raw = c.barcodes.firstOrNull?.rawValue;
              if (raw != null) {
                scanned = raw;
                Navigator.pop(ctx);
              }
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Batal'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (scanned != null) {
      _keyCtrl.text = scanned!;
      await _submitKey();
    }
  }

  Future<void> _tapNfc() async {
    if (!await NfcManager.instance.isAvailable()) {
      setState(() => _keyError = 'NFC tidak tersedia');
      return;
    }
    await NfcManager.instance.startSession(onDiscovered: (tag) async {
      final ndef = Ndef.from(tag);
      final msg = ndef?.cachedMessage;
      String? key;
      if (msg != null) {
        for (final record in msg.records) {
          if (record.typeNameFormat == NdefTypeNameFormat.nfcWellknown &&
              record.type.isNotEmpty &&
              record.type.first == 0x54) {
            final payload = record.payload;
            if (payload.isNotEmpty) {
              final langLen = payload.first & 0x3F;
              key = String.fromCharCodes(payload.sublist(1 + langLen));
            }
          }
        }
      }
      await NfcManager.instance.stopSession();
      if (key != null) {
        _keyCtrl.text = key;
        await _submitKey();
      }
    });
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _signupEmailCtrl.dispose();
    _signupPassCtrl.dispose();
    _signupPass2Ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    switch (_screen) {
      case 'auth':
        return _buildAuthScreen(isDark);
      case 'signup':
        return _buildSignupScreen(isDark);
      case 'google_loading':
        return _buildGoogleLoadingScreen(isDark);
      case 'trial_expired':
        return _buildTrialExpiredScreen(isDark);
      case 'decision':
        return _buildDecisionScreen(isDark);
      case 'pin':
        return _buildPinScreen(isDark);
      case 'key':
        return _buildKeyScreen(isDark);
      case 'lite':
        return _buildLiteScreen(isDark);
      default:
        return _buildAuthScreen(isDark);
    }
  }

  // ── Welcome Screen ──────────────────────────────────────────────────

  // ── Auth Screen (login: email/password + Google) ─────────────────────
  //
  // v2.2.57+112: redesign total. Satu aset logo konsisten per varian
  // (splashLogoPath → app_logo_{variant} {HEX}.png) — TANPA circle/gradient
  // dan TANPA icon toko/roket. Form email+password + ingat saya + lupa
  // password, card daftar, lalu card login Google di paling bawah.

  Widget _buildAuthScreen(bool isDark) {
    return Scaffold(
      backgroundColor: isDark ? NusaConfig.darkBackground : Color(0xFFF5F5F5),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 32),
            child: Column(
              children: [
                // ── Logo (1 aset konsisten, tanpa lingkaran) ──
                Image.asset(
                  splashLogoPath(),
                  width: 96,
                  height: 96,
                  errorBuilder: (_, __, ___) => Text(
                    'NUSA',
                    style: TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w800,
                      color: NusaConfig.activePrimary,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text('NUSA',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      color: NusaConfig.activePrimary,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1,
                    )),
                const SizedBox(height: 6),
                // Subtitle — kontras dinaikkan (abu gelap + weight medium).
                Text(
                  NusaConfig.appSubtitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: isDark
                        ? NusaConfig.darkTextSecondary
                        : const Color(0xFF3F3F46),
                  ),
                ),
                const SizedBox(height: 32),

                // ── Card: form masuk ──
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: isDark ? NusaConfig.darkSurface : Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.05),
                        blurRadius: 20,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Masuk',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: isDark
                                ? NusaConfig.darkTextPrimary
                                : Color(0xFF151717),
                          )),
                      const SizedBox(height: 4),
                      Text('Masuk untuk lanjut ke aplikasi',
                          style: TextStyle(
                            fontSize: 13,
                            color: isDark
                                ? NusaConfig.darkTextSecondary
                                : const Color(0xFF3F3F46),
                          )),
                      const SizedBox(height: 20),

                      // Email
                      TextField(
                        controller: _emailCtrl,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        style: TextStyle(fontSize: 14),
                        decoration: _authInputDecoration(
                          label: 'Email',
                          icon: Icons.mail_outline,
                          isDark: isDark,
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Password + visibility toggle
                      TextField(
                        controller: _passCtrl,
                        obscureText: _obscurePass,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _submitEmailLogin(),
                        style: TextStyle(fontSize: 14),
                        decoration: _authInputDecoration(
                          label: 'Password',
                          icon: Icons.lock_outline,
                          isDark: isDark,
                        ).copyWith(
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePass
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              size: 20,
                              color: isDark
                                  ? NusaConfig.darkTextSecondary
                                  : NusaConfig.textSecondary,
                            ),
                            onPressed: () =>
                                setState(() => _obscurePass = !_obscurePass),
                          ),
                        ),
                      ),

                      // ── Ingat saya + Lupa password ──
                      Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: () => setState(
                                  () => _rememberEmail = !_rememberEmail),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 20,
                                    height: 20,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: _rememberEmail
                                            ? NusaConfig.activePrimary
                                            : (isDark
                                                ? NusaConfig.darkDivider
                                                : NusaConfig.dividerColor),
                                        width: 2,
                                      ),
                                      color: _rememberEmail
                                          ? NusaConfig.activePrimary
                                          : Colors.transparent,
                                    ),
                                    child: _rememberEmail
                                        ? Icon(Icons.check,
                                            size: 14, color: Colors.white)
                                        : null,
                                  ),
                                  const SizedBox(width: 8),
                                  Text('Ingat saya',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: isDark
                                            ? NusaConfig.darkTextSecondary
                                            : const Color(0xFF3F3F46),
                                      )),
                                ],
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: _authLoading ? null : _forgotPassword,
                            style: TextButton.styleFrom(
                              foregroundColor: NusaConfig.activePrimary,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                            ),
                            child: const Text(
                              'Lupa password?',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),

                      if (_authError != null) ...[
                        const SizedBox(height: 4),
                        _authErrorBox(_authError!, isDark),
                      ],

                      const SizedBox(height: 16),

                      // Tombol masuk
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
                          onPressed: _authLoading ? null : _submitEmailLogin,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: NusaConfig.activePrimary,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            disabledBackgroundColor:
                                NusaConfig.activePrimary.withValues(alpha: 0.5),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          child: _authLoading
                              ? SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text('Masuk',
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 14),

                // ── Card: belum punya akun → daftar ──
                OutlinedButton(
                  onPressed: () => setState(() {
                    _screen = 'signup';
                    _authError = null;
                  }),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 50),
                    foregroundColor:
                        isDark ? NusaConfig.darkTextPrimary : Color(0xFF151717),
                    side: BorderSide(
                        color: isDark ? NusaConfig.darkBorder : Color(0xFFD1D5DB)),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Belum punya akun? Daftar',
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                ),

                // ── Google Sign-In — cloud-only (hidden in NUSA Lite) ──
                if (NusaConfig.cloudEnabled) ...[
                  const SizedBox(height: 14),

                  // ── Divider "atau" ──
                  Row(children: [
                    Expanded(
                        child: Divider(
                            color: isDark ? NusaConfig.darkBorder : Color(0xFFE5E7EB))),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text('atau',
                          style: TextStyle(
                              fontSize: 12,
                              color: isDark
                                  ? NusaConfig.darkTextTertiary
                                  : NusaConfig.textTertiary)),
                    ),
                    Expanded(
                        child: Divider(
                            color: isDark ? NusaConfig.darkBorder : Color(0xFFE5E7EB))),
                  ]),

                  const SizedBox(height: 14),

                  // ── Card: masuk dengan Google ──
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: isDark ? 0.30 : 0.10),
                            blurRadius: 10,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: OutlinedButton.icon(
                        onPressed: _startGoogleSignIn,
                        icon: Image.asset(
                          'assets/icons/google_logo.png',
                          width: 20,
                          height: 20,
                          errorBuilder: (_, __, ___) => Icon(Icons.g_mobiledata,
                              size: 24, color: Color(0xFF4285F4)),
                        ),
                        label: const Text('Masuk dengan Google',
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor:
                              isDark ? NusaConfig.darkTextPrimary : Color(0xFF151717),
                          backgroundColor: isDark
                              ? NusaConfig.darkSurface
                              : Colors.white,
                          elevation: 3,
                          shadowColor: Colors.black.withValues(alpha: 0.20),
                          side: BorderSide(
                              color: isDark
                                  ? NusaConfig.darkBorder
                                  : Color(0xFFDADCE0)),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 32),
                ],
                Text(
                    'v${NusaConfig.appVersion}+${NusaConfig.appBuildNumber}',
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark
                          ? NusaConfig.darkTextTertiary
                          : NusaConfig.textTertiary,
                    )),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Lite Screen (email + license key — tanpa Google/Auth) ────────────
  //
  // v2.2.57+130 Lite: login screen disederhanakan jadi form email + key.
  // - Tidak ada Google Sign-In
  // - Tidak ada password
  // - Tidak ada signup
  // User tinggal input email yg didaftarkan admin di dashboard + key yang
  // dikirim (via e-commerce / WA). Server (worker license-manager) yang
  // validasi email cocok dengan key.

  Widget _buildLiteScreen(bool isDark) {
    return Scaffold(
      backgroundColor: isDark ? NusaConfig.darkBackground : Color(0xFFF5F5F5),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 32),
            child: Column(
              children: [
                Image.asset(
                  splashLogoPath(),
                  width: 96,
                  height: 96,
                  errorBuilder: (_, __, ___) => Text(
                    'NUSA',
                    style: TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w800,
                      color: NusaConfig.activePrimary,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text('NUSA Lite',
                    style: Theme.of(context)
                        .textTheme
                        .headlineMedium
                        ?.copyWith(
                          color: NusaConfig.activePrimary,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -1,
                        )),
                const SizedBox(height: 6),
                Text(
                  'Aktivasi NUSA Lite — masukkan email & key yang diberikan admin',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: isDark
                        ? NusaConfig.darkTextSecondary
                        : const Color(0xFF3F3F46),
                  ),
                ),
                const SizedBox(height: 28),

                // ── Card: form email + key ──
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: isDark ? NusaConfig.darkSurface : Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color:
                            Colors.black.withValues(alpha: isDark ? 0.2 : 0.05),
                        blurRadius: 20,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Aktivasi',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: isDark
                                ? NusaConfig.darkTextPrimary
                                : const Color(0xFF151717),
                          )),
                      const SizedBox(height: 4),
                      Text('Email harus cocok dengan yang didaftarkan admin',
                          style: TextStyle(
                            fontSize: 13,
                            color: isDark
                                ? NusaConfig.darkTextSecondary
                                : const Color(0xFF3F3F46),
                          )),
                      const SizedBox(height: 20),

                      // Email
                      TextField(
                        controller: _liteEmailCtrl,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        style: TextStyle(fontSize: 14),
                        decoration: _authInputDecoration(
                          label: 'Email',
                          icon: Icons.mail_outline,
                          isDark: isDark,
                        ),
                      ),
                      const SizedBox(height: 16),

                      // License key
                      TextField(
                        controller: _liteKeyCtrl,
                        keyboardType: TextInputType.visiblePassword,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _submitLiteActivation(),
                        style: TextStyle(
                          fontSize: 14,
                          letterSpacing: 1.0,
                          fontFamily: 'monospace',
                        ),
                        decoration: _authInputDecoration(
                          label: 'License Key',
                          icon: Icons.key_outlined,
                          isDark: isDark,
                        ),
                      ),

                      if (_liteError != null) ...[
                        const SizedBox(height: 12),
                        _authErrorBox(_liteError!, isDark),
                      ],

                      const SizedBox(height: 20),

                      // Tombol Aktivasi
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
                          onPressed:
                              _liteLoading ? null : _submitLiteActivation,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: NusaConfig.activePrimary,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            disabledBackgroundColor:
                                NusaConfig.activePrimary.withValues(alpha: 0.5),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          child: _liteLoading
                              ? SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text('Aktivasi',
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // Footer kecil: ke mana user beli & tanya admin
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: (isDark
                            ? NusaConfig.darkSurface2
                            : const Color(0xFFFFF7ED))
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isDark
                          ? NusaConfig.darkBorder.withValues(alpha: 0.5)
                          : const Color(0xFFFED7AA),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline,
                          size: 16,
                          color: isDark
                              ? NusaConfig.darkTextTertiary
                              : const Color(0xFF9A3412)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Belum punya key? Hubungi admin atau beli paket '
                          'NUSA Lite di e-commerce. Email yg diinput di sini '
                          'harus sama dengan yg didaftarkan admin.',
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark
                                ? NusaConfig.darkTextSecondary
                                : const Color(0xFF7C2D12),
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),
                Text(
                    'v${NusaConfig.appVersion}+${NusaConfig.appBuildNumber}',
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark
                          ? NusaConfig.darkTextTertiary
                          : NusaConfig.textTertiary,
                    )),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Signup Screen (email + password baru) ────────────────────────────

  Widget _buildSignupScreen(bool isDark) {
    return Scaffold(
      backgroundColor: isDark ? NusaConfig.darkBackground : Color(0xFFF5F5F5),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 32),
            child: Column(
              children: [
                Image.asset(
                  splashLogoPath(),
                  width: 88,
                  height: 88,
                  errorBuilder: (_, __, ___) => Text(
                    'NUSA',
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w800,
                      color: NusaConfig.activePrimary,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text('Buat Akun',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: isDark
                          ? NusaConfig.darkTextPrimary
                          : Color(0xFF151717),
                    )),
                const SizedBox(height: 6),
                Text('Daftar dengan email untuk mulai',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: isDark
                          ? NusaConfig.darkTextSecondary
                          : const Color(0xFF3F3F46),
                    )),
                const SizedBox(height: 28),

                // ── Card: form daftar ──
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: isDark ? NusaConfig.darkSurface : Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.05),
                        blurRadius: 20,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _signupEmailCtrl,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        style: const TextStyle(fontSize: 14),
                        decoration: _authInputDecoration(
                          label: 'Email',
                          icon: Icons.mail_outline,
                          isDark: isDark,
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _signupPassCtrl,
                        obscureText: _obscurePass,
                        textInputAction: TextInputAction.next,
                        style: const TextStyle(fontSize: 14),
                        decoration: _authInputDecoration(
                          label: 'Password (min. 6 karakter)',
                          icon: Icons.lock_outline,
                          isDark: isDark,
                        ).copyWith(
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePass
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              size: 20,
                              color: isDark
                                  ? NusaConfig.darkTextSecondary
                                  : NusaConfig.textSecondary,
                            ),
                            onPressed: () =>
                                setState(() => _obscurePass = !_obscurePass),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _signupPass2Ctrl,
                        obscureText: _obscurePass2,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _submitSignup(),
                        style: const TextStyle(fontSize: 14),
                        decoration: _authInputDecoration(
                          label: 'Ulangi password',
                          icon: Icons.lock_outline,
                          isDark: isDark,
                        ).copyWith(
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePass2
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              size: 20,
                              color: isDark
                                  ? NusaConfig.darkTextSecondary
                                  : NusaConfig.textSecondary,
                            ),
                            onPressed: () =>
                                setState(() => _obscurePass2 = !_obscurePass2),
                          ),
                        ),
                      ),

                      if (_authError != null) ...[
                        const SizedBox(height: 12),
                        _authErrorBox(_authError!, isDark),
                      ],

                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
                          onPressed: _authLoading ? null : _submitSignup,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: NusaConfig.activePrimary,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            disabledBackgroundColor:
                                NusaConfig.activePrimary.withValues(alpha: 0.5),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          child: _authLoading
                              ? SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text('Daftar',
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ],
                  ),
                ),

                // ── Google Sign-Up — cloud-only (hidden in NUSA Lite) ──
                if (NusaConfig.cloudEnabled) ...[
                  const SizedBox(height: 14),

                  // ── Divider "atau" ──
                  Row(children: [
                    Expanded(
                        child: Divider(
                            color: isDark ? NusaConfig.darkBorder : Color(0xFFE5E7EB))),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text('atau',
                          style: TextStyle(
                              fontSize: 12,
                              color: isDark
                                  ? NusaConfig.darkTextTertiary
                                  : NusaConfig.textTertiary)),
                    ),
                    Expanded(
                        child: Divider(
                            color: isDark ? NusaConfig.darkBorder : Color(0xFFE5E7EB))),
                  ]),

                  const SizedBox(height: 14),

                  // ── Card: daftar dengan Google ──
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: isDark ? 0.30 : 0.10),
                            blurRadius: 10,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: OutlinedButton.icon(
                        onPressed: _startGoogleSignIn,
                        icon: Image.asset(
                          'assets/icons/google_logo.png',
                          width: 20,
                          height: 20,
                          errorBuilder: (_, __, ___) => Icon(Icons.g_mobiledata,
                              size: 24, color: Color(0xFF4285F4)),
                        ),
                        label: const Text('Daftar dengan Google',
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor:
                              isDark ? NusaConfig.darkTextPrimary : Color(0xFF151717),
                          backgroundColor: isDark
                              ? NusaConfig.darkSurface
                              : Colors.white,
                          elevation: 3,
                          shadowColor: Colors.black.withValues(alpha: 0.20),
                          side: BorderSide(
                              color: isDark
                                  ? NusaConfig.darkBorder
                                  : Color(0xFFDADCE0)),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),
                ],
                TextButton(
                  onPressed: () => setState(() {
                    _screen = 'auth';
                    _authError = null;
                  }),
                  child: Text('Sudah punya akun? Masuk',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: NusaConfig.activePrimary,
                      )),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Input decoration seragam untuk form auth (label floating + icon prefix).
  InputDecoration _authInputDecoration({
    required String label,
    required IconData icon,
    required bool isDark,
  }) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon,
          size: 20,
          color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary),
      labelStyle: TextStyle(
        fontSize: 13,
        color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary,
      ),
      filled: true,
      fillColor: isDark ? NusaConfig.darkBackground : Color(0xFFF9FAFB),
      contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(
            color: isDark ? NusaConfig.darkBorder : Color(0xFFECEDEC)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(
            color: isDark ? NusaConfig.darkBorder : Color(0xFFECEDEC)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide:
            BorderSide(color: NusaConfig.activePrimary, width: 1.5),
      ),
    );
  }

  /// Kotak error seragam untuk form auth.
  Widget _authErrorBox(String message, bool isDark) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: NusaConfig.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: NusaConfig.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                  fontSize: 12,
                  color:
                      isDark ? NusaConfig.darkTextSecondary : Color(0xFF3F3F46)),
            ),
          ),
        ],
      ),
    );
  }

  // ── Google Sign-In Loading Screen ─────────────────────────────────────

  Widget _buildGoogleLoadingScreen(bool isDark) {
    final statusText = _googleLoading
        ? 'Menghubungkan ke Google...'
        : _googleError != null
            ? null
            : 'Memeriksa lisensi...';

    return Scaffold(
      backgroundColor: isDark ? NusaConfig.darkBackground : Color(0xFFF5F5F5),
      body: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(24),
          child: Column(
            children: [
              SizedBox(height: 60),
              if (_googleError != null) ...[
                // Card error state
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    color: isDark ? NusaConfig.darkSurface : Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 20,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      Icon(Icons.error_outline, size: 40,
                        color: NusaConfig.activePrimary.withValues(alpha: 0.7)),
                      SizedBox(height: 12),
                      Text(_googleError!, textAlign: TextAlign.center,
                        style: TextStyle(color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary, fontSize: 14)),
                      SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _startGoogleSignIn,
                          icon: Icon(Icons.login, size: 20),
                          label: Text('Login Google'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Color(0xFF151717),
                            foregroundColor: Colors.white,
                            padding: EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _BouncingDots(),
                    SizedBox(height: 16),
                    Text(
                      statusText!,
                      style: TextStyle(
                        color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ── License Expired / Block Screen ──────────────────────────────────
  //
  // v2.2.44 (L2/L3): layar ini = app TERKUNCI setelah lisensi (trial ATAU
  // aktif 1-bulan) kedaluwarsa. Grace 7 hari ditampilkan sebagai countdown
  // (H-7 terima di sini; H+7 key di-revoke server oleh cron). User harus
  // memperpanjang (buka /pay) — kalau cuma ganti akun, tidak bisa lewat.

  Widget _buildTrialExpiredScreen(bool isDark) {
    // Grace 7 hari dihitung dari expires_at. Kalau expires_at tidak ada
    // (mis. di-revoke), tampilkan tanpa countdown.
    final now = DateTime.now();
    final expiry = _licenseExpiry;
    final graceEnd = expiry != null ? expiry.add(const Duration(days: 7)) : null;
    final daysLeft = graceEnd != null ? graceEnd.difference(now).inDays : null;
    final inGrace = expiry != null && daysLeft != null && daysLeft >= 0;

    return Scaffold(
      backgroundColor: isDark ? NusaConfig.darkBackground : Color(0xFFF5F5F5),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 32),
            child: Column(
              children: [
                SizedBox(height: 32),
                // Logo konsisten — tanpa lingkaran, tanpa icon timer/block.
                Image.asset(
                  splashLogoPath(),
                  width: 96,
                  height: 96,
                  errorBuilder: (_, __, ___) => Text(
                    'NUSA',
                    style: TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w800,
                      color: NusaConfig.activePrimary,
                    ),
                  ),
                ),
                SizedBox(height: 20),
                Text(_googleError?.contains('trial') == true ? 'Masa Trial Habis' : 'Lisensi Kedaluwarsa',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary)),
                SizedBox(height: 28),
                // Card
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    color: isDark ? NusaConfig.darkSurface : Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 20,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      Text(
                        _googleError ?? 'Masa aktivasi Anda telah berakhir.\nPerpanjang untuk melanjutkan.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, height: 1.6,
                          color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary)),
                      if (inGrace) ...[
                        SizedBox(height: 20),
                        // Countdown grace
                        Container(
                          width: double.infinity,
                          padding: EdgeInsets.symmetric(vertical: 14),
                          decoration: BoxDecoration(
                            color: Colors.amber.withValues(alpha: isDark ? 0.12 : 0.08),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.amber.withValues(alpha: 0.4)),
                          ),
                          child: Column(
                            children: [
                              Text(
                                daysLeft <= 0
                                    ? 'Masa tenggang berakhir hari ini'
                                    : 'Sisa masa tenggang: $daysLeft hari',
                                style: TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w700,
                                  color: Colors.amber.shade800),
                              ),
                              SizedBox(height: 4),
                              Text(
                                'Lisensi berakhir ${expiry.day}/${expiry.month}/${expiry.year}. '
                                'Lengah selama grace 7 hari → lisensi dicabut permanen.',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 12,
                                  color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary),
                              ),
                            ],
                          ),
                        ),
                      ],
                      SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _openPayPage,
                          icon: Icon(Icons.credit_card_rounded, size: 18),
                          label: Text('Perpanjang / Beli Lisensi'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: NusaConfig.activePrimary,
                            foregroundColor: Colors.white,
                            padding: EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                      // Ganti Akun Google — cloud-only (hidden in NUSA Lite)
                      if (NusaConfig.cloudEnabled) ...[
                        SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton(
                            onPressed: _switchGoogleAccount,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary,
                              side: BorderSide(color: Color(0xFFEDEDEF)),
                              padding: EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            child: Text('Ganti Akun Google'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Decision Screen (no license — 2 options) ─────────────────────

  // ── Decision Screen (no license / canceled — 2 options) ─────────────

  Widget _buildDecisionScreen(bool isDark) {
    return Scaffold(
      backgroundColor: isDark ? NusaConfig.darkBackground : Color(0xFFF5F5F5),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 32),
            child: Column(
              children: [
                SizedBox(height: 32),
                // Logo konsisten — tanpa lingkaran, tanpa icon roket.
                Image.asset(
                  splashLogoPath(),
                  width: 96,
                  height: 96,
                  errorBuilder: (_, __, ___) => Text(
                    'NUSA',
                    style: TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w800,
                      color: NusaConfig.activePrimary,
                    ),
                  ),
                ),
                SizedBox(height: 20),
                Text('NUSA',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      color: NusaConfig.activePrimary,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1,
                    )),
                SizedBox(height: 6),
                Text(NusaConfig.appSubtitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: isDark
                          ? NusaConfig.darkTextSecondary
                          : const Color(0xFF3F3F46),
                    )),

                // Banner alasan (akun dibatalkan / suspended) bila ada.
                if (_googleError != null) ...[
                  SizedBox(height: 20),
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: NusaConfig.warning.withValues(alpha: isDark ? 0.12 : 0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: NusaConfig.warning.withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline,
                            size: 18, color: NusaConfig.warning),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _googleError!,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: isDark
                                  ? NusaConfig.darkTextSecondary
                                  : const Color(0xFF3F3F46),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                SizedBox(height: 28),

                // ── Dua pilihan lisensi ──
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: isDark ? NusaConfig.darkSurface : Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.05),
                        blurRadius: 20,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Aktivasi Lisensi',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: isDark
                                ? NusaConfig.darkTextPrimary
                                : Color(0xFF151717),
                          )),
                      SizedBox(height: 4),
                      Text('Pilih salah satu untuk melanjutkan',
                          style: TextStyle(
                            fontSize: 13,
                            color: isDark
                                ? NusaConfig.darkTextSecondary
                                : const Color(0xFF3F3F46),
                          )),
                      SizedBox(height: 20),

                      // Option 1: Sudah punya key
                      SizedBox(
                        height: 56,
                        child: OutlinedButton(
                          onPressed: () => setState(() => _screen = 'key'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: isDark
                                ? NusaConfig.darkTextPrimary
                                : Color(0xFF151717),
                            side: BorderSide(
                                color: isDark
                                    ? NusaConfig.darkBorder
                                    : Color(0xFFD1D5DB),
                                width: 1.5),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                          child: Text('Sudah punya lisensi key',
                              style: TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w600)),
                        ),
                      ),
                      SizedBox(height: 6),
                      Text(
                        'Aktivasi dengan key dari seller',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w400,
                          color: isDark
                              ? NusaConfig.darkTextTertiary
                              : NusaConfig.textTertiary,
                        ),
                      ),

                      SizedBox(height: 16),

                      // Divider "atau"
                      Row(children: [
                        Expanded(
                            child: Divider(
                                color: isDark
                                    ? NusaConfig.darkBorder
                                    : Color(0xFFE5E7EB))),
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: Text('atau',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: isDark
                                      ? NusaConfig.darkTextTertiary
                                      : NusaConfig.textTertiary)),
                        ),
                        Expanded(
                            child: Divider(
                                color: isDark
                                    ? NusaConfig.darkBorder
                                    : Color(0xFFE5E7EB))),
                      ]),

                      SizedBox(height: 16),

                      // Option 2: Belum punya lisensi
                      SizedBox(
                        height: 56,
                        child: ElevatedButton(
                          onPressed: () => _openPayment(),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: NusaConfig.activePrimary,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                          child: const Text('Belum punya lisensi',
                              style: TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w600)),
                        ),
                      ),
                      SizedBox(height: 6),
                      Text(
                        'Beli langsung dalam aplikasi',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w400,
                          color: isDark
                              ? NusaConfig.darkTextTertiary
                              : NusaConfig.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),

                if (NusaConfig.cloudEnabled) ...[
                  SizedBox(height: 16),
                  TextButton(
                    onPressed: _startGoogleSignIn,
                    child: Text('Ganti akun Google',
                        style: TextStyle(
                            color: isDark
                                ? NusaConfig.darkTextSecondary
                                : NusaConfig.textSecondary,
                            fontSize: 13)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openPayment() async {
    final googleId = _googleId;
    if (googleId == null) return;

    final url = await PaymentSheet.show(context, googleId: googleId);
    if (url == null || !mounted) return;

    // Open WebView for Midtrans payment
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PaymentWebView(
          paymentUrl: url,
          googleId: googleId,
        ),
      ),
    );
  }

  // ── PIN Screen (returning user) ────────────────────────────────────

  Widget _buildPinScreen(bool isDark) {
    return Scaffold(
      backgroundColor: isDark ? NusaConfig.darkBackground : Color(0xFFF5F5F5),
      body: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 32),
            child: Column(
              children: [
                SizedBox(height: 32),
                Image.asset(
                  splashLogoPath(),
                  width: 88,
                  height: 88,
                  errorBuilder: (_, __, ___) => Text(
                    'NUSA',
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w800,
                      color: NusaConfig.activePrimary,
                    ),
                  ),
                ),
                SizedBox(height: 28),
                // Card
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    color: isDark ? NusaConfig.darkSurface : Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 20,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      Text('Masuk', style: TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w700,
                      color: isDark ? NusaConfig.darkTextPrimary : Color(0xFF151717))),
                    SizedBox(height: 4),
                    Text('Masukkan PIN untuk melanjutkan',
                      style: TextStyle(fontSize: 13,
                        color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary)),
                    SizedBox(height: 16),
                    PinKeypad(
                      key: _keypadKey,
                      length: _pinLength,
                      error: _pinError,
                      showFingerprint: true,
                      showNfc: _nfcAvailable,
                      showBarcode: true,
                      showCancel: false,
                      onFingerprint: () async => await _authFingerprint(),
                      onFingerprintSuccess: () => _fingerprintLogin(),
                      onBarcode: (code) async {
                        await _barcodeLogin(code);
                        return null;
                      },
                      onNfc: () async {
                        final id = await NfcTagService.readEmployeeTag();
                        if (id == null || !mounted) return null;
                        // NFC login: lookup employee, create session, navigate
                        final db = ref.read(databaseProvider);
                        final repo = AttendanceRepository(db);
                        final emp = await repo.getEmployee(id);
                        if (emp == null || !mounted) return null;
                        final session = EmployeeSession(
                          employeeId: emp.id, name: emp.name, role: emp.role, remember: false,
                        );
                        ref.read(employeeSessionProvider.notifier).login(session, remember: false);
                        ref.read(authProvider.notifier).state = emp.role;
                        try { await AttendanceRepository(ref.read(databaseProvider)).checkIn(emp.id); } catch (_) {}
                        final storeName = await SettingsRepository(ref.read(databaseProvider)).getStoreName();
                        if (mounted) context.go(storeName.isEmpty ? '/setup' : '/home');
                        return null; // already handled
                      },
                      onComplete: (pin) async {
                        setState(() => _pinLoading = true);
                        try {
                          final db = ref.read(databaseProvider);
                          final repo = AttendanceRepository(db);
                          final List<Employee> emps;
                          try {
                            emps = await repo.getEmployees();
                          } catch (e) {
                            // DB rusak → jangan diam (6 dot penuh tanpa getar).
                            // Coba pulihkan data dari cloud dulu.
                            debugPrint('[Activation] getEmployees error: $e');
                            if (!mounted) return;
                            setState(() {
                              _pinLoading = false;
                              _pinError = null;
                            });
                            _keypadKey.currentState?.clear();
                            final restored =
                                await RestoreBackupFlow.runIfNeeded(ref, context);
                            if (!restored && mounted) context.go('/setup');
                            return;
                          }
                          if (emps.isEmpty) {
                            // Varian baru / DB kosong: tawarkan restore cloud,
                            // setup hanya kalau memang tidak ada backup.
                            if (!mounted) return;
                            setState(() {
                              _pinLoading = false;
                              _pinError = null;
                            });
                            _keypadKey.currentState?.clear();
                            final restored =
                                await RestoreBackupFlow.runIfNeeded(ref, context);
                            if (!restored && mounted) context.go('/setup');
                            return;
                          }
                          final emp = emps.cast<Employee?>().firstWhere(
                                (e) => e!.pin == pin,
                                orElse: () => null,
                              );
                        if (emp != null) {
                          if (mounted) setState(() => _pinLoading = false);
                          // Create session
                          final session = EmployeeSession(
                            employeeId: emp.id,
                            name: emp.name,
                            role: emp.role,
                            remember: false,
                          );
                          ref.read(employeeSessionProvider.notifier).login(session, remember: false);
                          ref.read(authProvider.notifier).state = emp.role;

                          // Auto check-in
                          try {
                            final db = ref.read(databaseProvider);
                            final repo = AttendanceRepository(db);
                            await repo.checkIn(emp.id);
                          } catch (_) {}

                          final settingsRepo = SettingsRepository(ref.read(databaseProvider));
                          final storeName = await settingsRepo.getStoreName();
                          if (mounted) context.go(storeName.isEmpty ? '/setup' : '/home');
                        } else {
                          if (mounted) {
                            setState(() {
                              _pinLoading = false;
                              _pinError = 'PIN salah';
                            });
                            _keypadKey.currentState?.clear();
                          }
                        }
                        } catch (e) {
                          // Safety net — jangan pernah biarkan pinpad diam di
                          // 6 dot penuh tanpa umpan balik apa pun.
                          debugPrint('[Activation] onComplete error: $e');
                          if (!mounted) return;
                          setState(() {
                            _pinLoading = false;
                            _pinError = null;
                          });
                          _keypadKey.currentState?.clear();
                          final restored =
                              await RestoreBackupFlow.runIfNeeded(ref, context);
                          if (!restored && mounted) context.go('/setup');
                        }
                      },
                    ),
                  ],
                ),
              ),
              SizedBox(height: 12),
              // v2.2.50 (A5): "Lupa PIN?"
              GestureDetector(
                onTap: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      title: const Text('Lupa PIN?'),
                      content: const Text(
                        'Login ulang dengan akun Google pemilik toko untuk mengatur PIN baru. Lanjutkan?',
                        style: TextStyle(fontSize: 14, height: 1.5),
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
                        FilledButton(
                          style: FilledButton.styleFrom(backgroundColor: NusaConfig.activePrimary, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Lanjut'),
                        ),
                      ],
                    ),
                  );
                  if (confirm != true || !mounted) return;
                  final currentUid = await GoogleAuthService.getStoredUserId();
                  final newUid = await GoogleAuthService().signIn();
                  if (!mounted || newUid == null) return;
                  if (currentUid != null && newUid != currentUid) {
                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Akun Google berbeda.')));
                    return;
                  }
                  await GoogleAuthService.ensureStored(newUid);
                  final db = ref.read(databaseProvider);
                  final repo = AttendanceRepository(db);
                  final emps = await repo.getEmployees();
                  final owner = emps.cast<Employee?>().firstWhere((Employee? e) => e!.role == 'Owner' || e.role == 'Manager', orElse: () => null);
                  if (owner == null) return;
                  // Show PIN prompt dialog
                  final ctrl = TextEditingController();
                  final newPin = await showDialog<String>(
                    context: context,
                    barrierDismissible: false,
                    builder: (ctx) => AlertDialog(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      title: const Text('PIN Baru'),
                      content: TextField(
                        controller: ctrl,
                        keyboardType: TextInputType.number,
                        maxLength: 6,
                        obscureText: true,
                        autofocus: true,
                        decoration: const InputDecoration(hintText: 'Masukkan PIN baru (4–6 digit)', counterText: ''),
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
                        FilledButton(
                          style: FilledButton.styleFrom(backgroundColor: NusaConfig.activePrimary, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                          onPressed: () {
                            final v = ctrl.text.trim();
                            if (v.length < 4 || !RegExp(r'^\d+$').hasMatch(v)) return;
                            Navigator.pop(ctx, v);
                          },
                          child: const Text('Simpan'),
                        ),
                      ],
                    ),
                  );
                  if (!mounted || newPin == null) return;
                  await repo.updateEmployee(id: owner.id, name: owner.name, pin: newPin, role: owner.role, status: owner.status);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN berhasil diubah')));
                    setState(() => _pinError = null);
                    _keypadKey.currentState?.clear();
                  }
                },
                child: Text(
                  'Lupa PIN?',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: NusaConfig.activePrimary,
                  ),
                ),
              ),
              // Ganti akun Google — cloud-only (hidden in NUSA Lite)
              if (NusaConfig.cloudEnabled) ...[
                SizedBox(height: 8),
                TextButton(
                  onPressed: _startGoogleSignIn,
                  child: Text('Ganti akun Google', style: TextStyle(color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary, fontSize: 13)),
                ),
              ],
              if (NusaConfig.isDevBuild)
                TextButton.icon(
                  onPressed: () => context.go('/variant-picker'),
                  icon: Icon(Icons.apps_rounded, size: 16),
                  label: Text('Pilih Varian Lain', style: TextStyle(fontSize: 13)),
                  style: TextButton.styleFrom(foregroundColor: NusaConfig.activePrimary),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _authFingerprint() async {
    return BiometricService.authenticate(
      reason: 'Verifikasi biometrik untuk melanjutkan',
    );
  }

  /// Login as Owner via fingerprint — bypass PIN.
  Future<void> _fingerprintLogin() async {
    try {
      final db = ref.read(databaseProvider);
      final repo = AttendanceRepository(db);
      final List<Employee> emps;
      try {
        emps = await repo.getEmployees();
      } catch (e) {
        debugPrint('[Activation] fingerprint getEmployees error: $e');
        if (mounted) {
          final restored =
              await RestoreBackupFlow.runIfNeeded(ref, context);
          if (!restored && mounted) context.go('/setup');
        }
        return;
      }
      if (emps.isEmpty) {
        if (mounted) {
          final restored =
              await RestoreBackupFlow.runIfNeeded(ref, context);
          if (!restored && mounted) context.go('/setup');
        }
        return;
      }
      final owner = emps.cast<Employee?>().firstWhere(
            (e) => e!.role == 'Owner',
            orElse: () => null,
          );
      if (owner == null || !mounted) return;

      final session = EmployeeSession(
        employeeId: owner.id,
        name: owner.name,
        role: owner.role,
        remember: false,
      );
      ref.read(employeeSessionProvider.notifier).login(session, remember: false);
      ref.read(authProvider.notifier).state = owner.role;

      try { await AttendanceRepository(db).checkIn(owner.id); } catch (_) {}

      final storeName = await SettingsRepository(db).getStoreName();
      if (mounted) context.go(storeName.isEmpty ? '/setup' : '/home');
    } catch (_) {
      // Fingerprint succeeded but employee lookup failed — fall through
    }
  }

  /// Login via barcode id-card (B8) — jalur auth ke-4. Scan id-card karyawan
  /// → lookup by barcode (status Aktif) → buat session → auto check-in → masuk.
  Future<void> _barcodeLogin(String code) async {
    final norm = ProductRepository.normalizeBarcode(code);
    if (norm.isEmpty) return;
    try {
      final db = ref.read(databaseProvider);
      final repo = AttendanceRepository(db);
      final emp = await repo.getByBarcode(norm, status: 'Aktif');
      if (emp == null) {
        if (mounted) {
          setState(() => _pinError = 'Barcode tidak terdaftar');
          _keypadKey.currentState?.clear();
        }
        return;
      }
      if (!mounted) return;
      final session = EmployeeSession(
        employeeId: emp.id,
        name: emp.name,
        role: emp.role,
        remember: false,
      );
      ref.read(employeeSessionProvider.notifier).login(session, remember: false);
      ref.read(authProvider.notifier).state = emp.role;
      try { await AttendanceRepository(db).checkIn(emp.id); } catch (_) {}
      final settingsRepo = SettingsRepository(db);
      final storeName = await settingsRepo.getStoreName();
      if (mounted) context.go(storeName.isEmpty ? '/setup' : '/home');
    } catch (_) {
      if (mounted) {
        setState(() => _pinError = 'Gagal verifikasi barcode');
        _keypadKey.currentState?.clear();
      }
    }
  }

  // ── Key Activation Screen (new user) ───────────────────────────────

  Widget _buildKeyScreen(bool isDark) {
    return Scaffold(
      backgroundColor: isDark ? NusaConfig.darkBackground : Color(0xFFF5F5F5),
      body: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 32),
            child: Column(
              children: [
                SizedBox(height: 32),
                Image.asset(
                  splashLogoPath(),
                  width: 88,
                  height: 88,
                  errorBuilder: (_, __, ___) => Text(
                    'NUSA',
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w800,
                      color: NusaConfig.activePrimary,
                    ),
                  ),
                ),
                SizedBox(height: 28),
                // Card
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    color: isDark ? NusaConfig.darkSurface : Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 20,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      Text('Aktivasi NUSA', style: TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w700,
                      color: isDark ? NusaConfig.darkTextPrimary : Color(0xFF151717))),
                    SizedBox(height: 4),
                    Text('Masukkan key aktivasi dari seller',
                      style: TextStyle(fontSize: 13,
                        color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary)),
                    SizedBox(height: 24),
                    // Key input
                    TextField(
                      controller: _keyCtrl,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, fontFamily: 'monospace', letterSpacing: 0.5),
                      decoration: InputDecoration(
                        hintText: 'NUSA-XXXX-XXXX-...',
                        hintStyle: TextStyle(fontSize: 13,
                          color: isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary),
                        filled: true,
                        fillColor: isDark ? NusaConfig.darkBackground : Color(0xFFF9FAFB),
                        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(color: Color(0xFFECEDEC)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(color: Color(0xFFECEDEC)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(color: Color(0xFF2D79F3), width: 1.5),
                        ),
                      ),
                    ),
                    if (_keyError != null)
                      Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(_keyError!,
                          style:  TextStyle(color: NusaConfig.activePrimary, fontSize: 13)),
                      ),
                    SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        onPressed: _keyLoading ? null : _submitKey,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Color(0xFF151717),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        child: Text(
                          _keyLoading ? 'Memproses...' : 'Aktivasi',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 12),
              // Scan / NFC
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: _scan,
                    icon: Icon(Icons.qr_code_scanner, size: 18),
                    label: Text('Scan', style: TextStyle(fontSize: 13)),
                    style: TextButton.styleFrom(foregroundColor: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary),
                  ),
                  TextButton.icon(
                    onPressed: _tapNfc,
                    icon: Icon(Icons.nfc, size: 18),
                    label: Text('NFC', style: TextStyle(fontSize: 13)),
                    style: TextButton.styleFrom(foregroundColor: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary),
                  ),
                ],
              ),
              SizedBox(height: 4),
              TextButton(
                onPressed: _openLandingPage,
                child: Text('Belum punya key aktivasi?',
                  style: TextStyle(fontSize: 13, color: Color(0xFF2D79F3), fontWeight: FontWeight.w500)),
              ),
              // Ganti akun Google — cloud-only (hidden in NUSA Lite)
              if (NusaConfig.cloudEnabled)
                TextButton(
                  onPressed: _startGoogleSignIn,
                  child: Text('Ganti akun Google', style: TextStyle(color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary, fontSize: 13)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bouncing 3-dot loading indicator — matches splash screen rhythm.
class _BouncingDots extends StatefulWidget {
  final double size;
  final double spacing;
  _BouncingDots({this.size = 10, this.spacing = 5});

  @override
  State<_BouncingDots> createState() => _BouncingDotsState();
}

class _BouncingDotsState extends State<_BouncingDots>
    with TickerProviderStateMixin {
  late final List<AnimationController> _ctrls;
  late final List<Animation<double>> _anims;

  @override
  void initState() {
    super.initState();
    _ctrls = List.generate(3, (_) {
      return AnimationController(
        vsync: this,
        duration: Duration(milliseconds: 600),
      );
    });
    _anims = List.generate(3, (i) {
      return Tween<double>(begin: 0, end: -12).animate(
        CurvedAnimation(
          parent: _ctrls[i],
          curve: Interval(0, 0.5, curve: Curves.easeOut),
        ),
      );
    });
    for (var i = 0; i < 3; i++) {
      Future.delayed(Duration(milliseconds: i * 150), () => _loop(i));
    }
  }

  void _loop(int i) {
    if (!mounted) return;
    _ctrls[i].forward().then((_) => _ctrls[i].reverse()).then((_) => _loop(i));
  }

  @override
  void dispose() {
    for (final c in _ctrls) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        return _AnimatedBuilder(
          animation: _anims[i],
          builder: (context, child) {
            return Transform.translate(
              offset: Offset(0, _anims[i].value),
              child: child,
            );
          },
          child: Container(
            width: widget.size,
            height: widget.size,
            margin: EdgeInsets.symmetric(horizontal: widget.spacing),
            decoration: BoxDecoration(
              color: NusaConfig.activePrimary,
              shape: BoxShape.circle,
            ),
          ),
        );
      }),
    );
  }
}

// Reuse AnimatedBuilder from splash screen
class _AnimatedBuilder extends AnimatedWidget {
  final Widget Function(BuildContext, Widget?) builder;
  final Widget? child;

  _AnimatedBuilder({
    super.key,
    required Animation<double> animation,
    required this.builder,
    this.child,
  }) : super(listenable: animation);

  Animation<double> get animation => listenable as Animation<double>;

  @override
  Widget build(BuildContext context) => builder(context, child);
}
