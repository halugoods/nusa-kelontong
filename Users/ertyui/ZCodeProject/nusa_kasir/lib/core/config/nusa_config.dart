import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:nusa_kasir/core/dev/variant_data.dart';

abstract class NusaConfig {
  static const String appName = "NUSA";
  static const String brandName = "NUSA";
		static String _productId = "nusa-apotek";
		static String _appSubtitle = "Aplikasi Kasir untuk Apotek & Farmasi";
  static const String appVersion = "2.2.57";
  /// v2.2.57+130 (A1.6): build number kini SEEDABLE saat runtime dari
  /// PackageInfo (dipanggil main() sebelum UI). Dulu const int — dibump saat
  /// prep rilis sebelum APK terpasang, sehingga label "Terpasang" dan
  /// force-update salah membandingkan (konstanta build baru > APK terpasang
  /// build lama). Fallback: nilai compile-time (paket gagal di platform).
  static int appBuildNumber = 130;
  static void seedBuildNumber(int build) {
    if (build > 0) appBuildNumber = build;
  }
		static String _githubRepo = "halugoods/nusa-apotek";
		static const String landingPageUrl = "https://nusa-online.vercel.app";
		static String _whatsappOrder = "https://wa.me/628976280303?text=Halo%2C%20saya%20mau%20beli%20NUSA%20Apotek";
		static String _applicationId = "com.nusa.apotek";
  // v2.2.57+130: Supabase diganti Cloudflare worker (CloudGateway).
  // cloudBaseUrl overridable per-varian via --dart-define (_build_all.py).
  static const String cloudBaseUrl = String.fromEnvironment('NUSA_CLOUD_BASE', defaultValue: 'https://nusa-cloud.halugoods-indonesia.workers.dev');
  /// v2.2.57+130: NUSA Lite mode — offline only. When false, cloud features
  /// (AI chat, spreadsheet, online store, cloud sync, panggil karyawan) are
  /// hidden/disabled. Overridable via --dart-define=CLOUD_ENABLED=false.
  static const bool cloudEnabled = bool.fromEnvironment('CLOUD_ENABLED', defaultValue: true);
  /// Admin key untuk endpoint admin dari app (sama dgn NUSA_ADMIN_KEY worker).
  /// Dipakai juga sbg fallback auth license-manager (satu key global).
  static const String nusaAdminKey = String.fromEnvironment('NUSA_ADMIN_KEY', defaultValue: '280303');
  // DEPRECATED — masih dipakai beberapa file sampai refactor C selesai.
  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL', defaultValue: 'https://sakeuhcbcnueplzlkltm.supabase.co');
  static const String supabaseAnon = String.fromEnvironment('SUPABASE_ANON', defaultValue: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNha2V1aGNiY251ZXBsemxrbHRtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM2ODIzMDEsImV4cCI6MjA5OTI1ODMwMX0.WvjZJ8Sd3o5T8a4vMApyvoCoS01Qv493mo1PxyWO06M');

  /// Running on Android emulator? (10.0.2.2 maps to host loopback.)
  static bool get isEmulator =>
      !kIsWeb && Platform.isAndroid && (Platform.environment['ANDROID_EMULATOR'] ?? '').isEmpty;

  /// IP LAN PC (untuk Nusa CS server di port 8790). Fallback: localhost.
  static Future<String> lanIp() async {
    if (kIsWeb) return 'localhost';
    try {
      final interfaces = await NetworkInterface.list();
      for (final i in interfaces) {
        for (final a in i.addresses) {
          if (a.type == InternetAddressType.IPv4 &&
              !a.isLoopback &&
              a.address.startsWith('192.168.')) {
            return a.address;
          }
        }
      }
    } catch (_) {}
    return 'localhost';
  }


  // ── Dev mode flag — compile-time constant, tree-shaken in production ──
  static const bool isDevBuild = bool.fromEnvironment('NUSA_DEV', defaultValue: false);

  /// Whether this is the FnB (restaurant/cafe) variant — gates FnB-specific features.
  static bool get isFnbVariant => productId == 'nusa-fnb';

  /// Whether this is the Laundry variant — gates laundry-specific features.
  static bool get isLaundryVariant => productId == 'nusa-laundry';

  /// Whether this is the Salon variant — gates salon-specific features.
  static bool get isSalonVariant => productId == 'nusa-salon';

  /// Whether this is the Bengkel variant — gates workshop/vehicle-service features.
  static bool get isBengkelVariant => productId == 'nusa-bengkel';

  /// Whether this is the Apotek variant — gates pharmacy features.
  static bool get isApotekVariant => productId == 'nusa-apotek';

  /// Whether this is the Fotocopy variant — gates photocopy/printing features.
  static bool get isFotocopyVariant => productId == 'nusa-fotocopy';

  /// Whether this is the Servis variant — gates repair-service features.
  static bool get isServisVariant => productId == 'nusa-servis';

  /// Whether this is the Kelontong variant — gates grocery-store features.
  static bool get isKelontongVariant => productId == 'nusa-kelontong';

  /// Whether this is a JASA (service) variant — gates Tab Layanan (B10):
  /// salon, bengkel, servis, laundry, fotocopy. Varian barang (kelontong,
  /// fnb, apotek) tidak wajib layanan — tab disembunyikan bila tidak dipakai.
  static bool get isJasaVariant =>
      isSalonVariant ||
      isBengkelVariant ||
      isServisVariant ||
      isLaundryVariant ||
      isFotocopyVariant;

  // ── Dev variant runtime overrides (null in production, set by VariantNotifier in dev) ──
  static VariantData? _devVariant;
  static Map<String, String>? _devCatEmoji;
  static Map<String, List<Color>>? _devCatGradients;
  static Map<String, IconData>? _devCatIcons;
  static List<String>? _devHiddenMenus;
  static Map<String, String>? _devHints;

  /// Apply a full VariantData override at runtime (dev mode only).
  static void applyDevVariant(VariantData v) {
    _devVariant = v;
    _devCatEmoji = v.catEmoji;
    _devCatGradients = v.catGradients;
    _devCatIcons = v.catIcons;
    _devHiddenMenus = v.hiddenMenus;
    _devHints = v.hints;
    // Also apply theme preset
    applyTheme(v.id);
  }

  /// Clear all dev variant overrides.
  static void clearDevVariant() {
    _devVariant = null;
    _devCatEmoji = null;
    _devCatGradients = null;
    _devCatIcons = null;
    _devHiddenMenus = null;
    _devHints = null;
    _primaryOverride = null;
    _darkOverride = null;
    _softOverride = null;
  }

  // ── Public getters — dev override takes priority over build-time value ──

  static String get productId => _devVariant?.productId ?? _productId;
  static String get appSubtitle => _devVariant?.subtitle ?? _appSubtitle;
  static String get githubRepo => _devVariant?.repo ?? _githubRepo;
  static String get whatsappOrder => _devVariant != null
      ? 'https://wa.me/628976280303?text=Halo%2C%20saya%20mau%20beli%20${Uri.encodeComponent(_devVariant!.name)}'
      : _whatsappOrder;
  static String get applicationId => _devVariant?.pkg ?? _applicationId;

  // ── Midtrans / Payment config ──
  static const String paymentUrl = "https://nusa-online.vercel.app/pay";
  static const double price1Bulan = 49000;
  static const double priceLifetime = 249000;

  /// Get the Midtrans payment URL for the current variant + Google user.
  static String paymentLink(String googleId, String package) =>
      '$paymentUrl?product=$productId&package=$package&google_id=${Uri.encodeComponent(googleId)}';

  // ═══════════════════════════════════════════
  //  DESIGN TOKENS — Single source of truth
  // ═══════════════════════════════════════════

  // ── Brand colors (build-time defaults, patched by _build_all.py) ──
  // These remain const for broad compatibility with const constructors
  // across 50+ widget files. Theme switching uses overrides below.
  static const Color primaryColor = const Color(0xFF10B981);
  static const Color primaryDark = const Color(0xFF059669);
  static const Color primarySoft = const Color(0xFFECFDF5);
  static const Color backgroundColor = const Color(0xFFF7F7F9);

  // ── Runtime theme override (set by user via Settings → Tema Warna) ──
  static Color? _primaryOverride;
  static Color? _darkOverride;
  static Color? _softOverride;

  /// Active primary color: user override or build-time default.
  static Color get activePrimary => _primaryOverride ?? primaryColor;
  static Color get activeDark => _darkOverride ?? primaryDark;
  static Color get activeSoft => _softOverride ?? primarySoft;

  /// 8 preset theme color schemes — one per product variant.
  /// Users can switch between them in Settings → Tema Warna.
  static const Map<String, Map<String, Color>> themePresets = {
    'kelontong': {
      'primary': Color(0xFFF97316), // Orange
      'dark': Color(0xFFEA580C),
      'soft': Color(0xFFFFF7ED),
    },
    'fnb': {
      'primary': Color(0xFFDC2626), // Red
      'dark': Color(0xFF991B1B),
      'soft': Color(0xFFFEF2F2),
    },
    'laundry': {
      'primary': Color(0xFFEC4899), // Pink (was Cyan — aligned with _build_all.py)
      'dark': Color(0xFFDB2777),
      'soft': Color(0xFFFDF2F8),
    },
    'bengkel': {
      'primary': Color(0xFFEAB308), // Yellow
      'dark': Color(0xFFCA8A04),
      'soft': Color(0xFFFEF9C3),
    },
    'salon': {
      'primary': Color(0xFF3B82F6), // Blue
      'dark': Color(0xFF2563EB),
      'soft': Color(0xFFEFF6FF),
    },
    'apotek': {
      'primary': Color(0xFF10B981), // Green
      'dark': Color(0xFF059669),
      'soft': Color(0xFFECFDF5),
    },
    'fotocopy': {
      'primary': Color(0xFF8B5CF6), // Purple
      'dark': Color(0xFF7C3AED),
      'soft': Color(0xFFF5F3FF),
    },
    'servis': {
      'primary': Color(0xFF152C63), // Deep Navy
      'dark': Color(0xFF0F1E47),
      'soft': Color(0xFFDBEAFE),
    },
  };

  /// Human-readable labels for theme presets — color only (no variant name).
  static const Map<String, String> themeNames = {
    'kelontong': 'Orange',
    'fnb': 'Merah',
    'laundry': 'Pink',
    'bengkel': 'Kuning',
    'salon': 'Biru',
    'apotek': 'Hijau',
    'fotocopy': 'Ungu',
    'servis': 'Navy',
  };

  /// Apply a theme preset at runtime. Saves to SecureStore.
  static void applyTheme(String themeId) {
    final preset = themePresets[themeId];
    if (preset == null) {
      _primaryOverride = null;
      _darkOverride = null;
      _softOverride = null;
      return;
    }
    _primaryOverride = preset['primary']!;
    _darkOverride = preset['dark']!;
    _softOverride = preset['soft']!;
  }
  static const Color surfaceColor = Color(0xFFFFFFFF);
  static const Color textPrimary = Color(0xFF1F2937);
  static const Color textSecondary = Color(0xFF6B7280);
  static const Color textTertiary = Color(0xFF9CA3AF);
  static const Color dividerColor = Color(0xFFE5E7EB);
  static const Color borderColor = Color(0xFFF3F4F6);
  static const Color inputFill = Color(0xFFF9FAFB);
  static const Color inputBorder = Color(0xFFE5E7EB);

  // ── Semantic colors ──
  static const Color success = Color(0xFF10B981);
  static const Color successSoft = Color(0xFFD1FAE5);
  static const Color successText = Color(0xFF065F46);
  static const Color error = Color(0xFFEF4444);
  static const Color errorSoft = Color(0xFFFEE2E2);
  static const Color errorText = Color(0xFFDC2626);
  static const Color warning = Color(0xFFF59E0B);
  static const Color warningSoft = Color(0xFFFEF3C7);
  static const Color warningText = Color(0xFFD97706);
  static const Color info = Color(0xFF3B82F6);
  static const Color infoSoft = Color(0xFFDBEAFE);
  static const Color infoText = Color(0xFF1E40AF);

  // ── Stock status colors ──
  static const Color stockActive = Color(0xFFDCFCE7);
  static const Color stockActiveText = Color(0xFF16A34A);
  static const Color stockLow = Color(0xFFFEF3C7);
  static const Color stockLowText = Color(0xFFD97706);
  static const Color stockOut = Color(0xFFFEE2E2);
  static const Color stockOutText = Color(0xFFDC2626);

  // ── Accent ──
  static const Color accentGreen = Color(0xFF10B981);
  static const Color accentGreenDark = Color(0xFF059669);
  static const Color accentPurple = Color(0xFF8B5CF6);
  static const Color accentPurpleDark = Color(0xFF7C3AED);
  static const Color accentGold = Color(0xFFF59E0B);

  // ── Payment method colors ──
  static const Color payCash = Color(0xFF10B981);
  static const Color payQris = Color(0xFF3B82F6);
  static const Color payTransfer = Color(0xFF8B5CF6);

  // ── Dark mode palette ──
  static const Color darkBackground = Color(0xFF0F0F1A);
  static const Color darkSurface = Color(0xFF1A1A2E);
  static const Color darkSurface2 = Color(0xFF252540);
  static const Color darkTextPrimary = Color(0xFFFFFFFF);
  static const Color darkTextSecondary = Color(0xFFE2E8F0);
  static const Color darkTextTertiary = Color(0xFFCBD5E1);
  static const Color darkDivider = Color(0xFF2D2D44);
  static const Color darkBorder = Color(0xFF3A3A52);
  static const Color darkCardShadow = Color(0x1A000000);
  static const Color darkInputFill = Color(0xFF252540);
  static const Color darkInputBorder = Color(0xFF3A3A52);

  // ── Spacing scale (4pt grid) ──
  static const double spaceXXS = 4;
  static const double spaceXS = 8;
  static const double spaceSM = 12;
  static const double spaceMD = 16;
  static const double spaceLG = 20;
  static const double spaceXL = 24;
  static const double spaceXXL = 32;

  // ── Radius scale ──
  static const double radiusSM = 8;
  static const double radiusMD = 12;
  static const double radiusLG = 16;
  static const double radiusXL = 20;
  static const double radiusFull = 999;

  // ── Responsive breakpoints ──
  static const double bpPhone = 600;
  static const double bpTablet = 900;
  static bool isWide(BuildContext context) => MediaQuery.of(context).size.width > 720;
  static bool isTablet(BuildContext context) => MediaQuery.of(context).size.width >= 600;

  /// Scale animation durations for high-refresh-rate displays.
  /// 120 Hz panels render twice as many frames, making animations feel perceptually
  /// faster. This returns a multiplier to stretch short durations back to normal.
  static double get animationScale {
    try {
      final rate = WidgetsBinding.instance.platformDispatcher.displays.first.refreshRate;
      if (rate >= 120) return 1.5;
      if (rate >= 90) return 1.3;
    } catch (_) {}
    return 1.0;
  }

  // ── Category maps (single source across all screens) ──
  // Build-time defaults (patched by _build_all.py)
		static Map<String, String> _catEmoji = {
		  'Obat Bebas': '💊',
		  'Obat Resep': '📋',
		  'Vitamin': '💪',
		  'Alkes': '🩺',
		  'Lainnya': '📦',
		};
		  static Map<String, List<Color>> _catGradients = {
		    'Obat Bebas': [Color(0xFFDCFCE7), Color(0xFFBBF7D0), Color(0xFFF0FDF4)],
		    'Obat Resep': [Color(0xFFDBEAFE), Color(0xFFBFDBFE), Color(0xFFEFF6FF)],
		    'Vitamin': [Color(0xFFFEF3C7), Color(0xFFFDE68A), Color(0xFFFEF9C3)],
		    'Alkes': [Color(0xFFFEE2E2), Color(0xFFFECACA), Color(0xFFFEF2F2)],
		    'Lainnya': [Color(0xFFF3E8FF), Color(0xFFE9D5FF), Color(0xFFFAF5FF)],
		  };
		  static Map<String, IconData> _catIcons = {
		    'Semua': Icons.grid_view_rounded,
		    'Obat Bebas': Icons.medication_rounded,
		    'Obat Resep': Icons.description_rounded,
		    'Vitamin': Icons.fitness_center_rounded,
		    'Alkes': Icons.monitor_heart_rounded,
		    'Lainnya': Icons.category_rounded,
		  };

  // Public getters — dev override first, then build-time default
  static Map<String, String> get catEmoji => _devCatEmoji ?? _catEmoji;
  static Map<String, List<Color>> get catGradients => _devCatGradients ?? _catGradients;
  static Map<String, IconData> get catIcons => _devCatIcons ?? _catIcons;

  static String catEmojiFor(String cat) => catEmoji[cat] ?? '📦';
  static List<Color> catGradientFor(String cat) => catGradients[cat] ?? catGradients['Lainnya']!;

  /// Helper: resolve light/dark color from context
  static Color resolve(BuildContext context, {required Color light, required Color dark}) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  // ── Feature flags ──
  static const bool enableBarcode = true;
  static const bool enableQRIS = true;
  static const bool enableSpreadsheet = true;
  static const bool enableWhatsApp = true;
  static const int maxDevicesPerKey = 2;

  // ── Business constants ──
  static const List<String> roles = ["Owner", "Manager", "Kasir", "Gudang", "Finance"];
  static const List<String> productTypes = ["Regular", "Varian", "Grosir"];
		  static const Map<String, List<String>> roleAccess = {
			    "Owner": ["home","kasir","produk","stok","transaksi","pelanggan","promo","laporan","presensi","karyawan","keuangan","pengaturan","supplier","spreadsheet","pesanan_online","cabang","ai_chat","piutang","meja","laundry_status","servis","booking","resep","print_order"],
			    "Manager": ["home","kasir","produk","stok","transaksi","pelanggan","promo","laporan","presensi","karyawan","keuangan","pengaturan","supplier","spreadsheet","pesanan_online","cabang","ai_chat","piutang","meja","laundry_status","servis","booking","resep","print_order"],
		    "Kasir": ["home","kasir","produk","stok","transaksi","pelanggan","ai_chat"],
		    "Gudang": ["home","produk","stok","laporan","supplier"],
		    "Finance": ["home","transaksi","keuangan","laporan","presensi","karyawan","supplier"],
	  };

  /// Menu yang perlu PIN re-entry untuk keamanan (POS/Kasir).
  static const List<String> pinGuardScreens = ['kasir'];

  /// Menu yang HANYA bisa dibuka Owner (block dengan dialog).
  static const List<String> ownerOnlyScreens = [
    'laporan', 'promo', 'pesanan_online', 'karyawan',
    'keuangan', 'spreadsheet', 'supplier', 'pengaturan', 'cabang', 'piutang',
  ];

  /// Menu yang disembunyikan secara default per dominio.
  /// Owner tetap bisa mengaktifkan kembali via Kelola Fitur.
  static const Map<String, List<String>> variantHiddenMenus = {
    'kelontong': ['meja', 'laundry_status', 'servis', 'booking', 'resep', 'print_order'],
    'fnb': ['spreadsheet', 'laundry_status', 'servis', 'booking', 'resep', 'print_order'],
    'laundry': ['promo', 'meja', 'servis', 'booking', 'resep', 'print_order'],
    'bengkel': ['meja', 'laundry_status', 'booking', 'resep', 'print_order'],
    'salon': ['cabang', 'meja', 'laundry_status', 'servis', 'resep', 'print_order'],
    'apotek': ['promo', 'meja', 'laundry_status', 'servis', 'booking', 'print_order'],
    'fotocopy': ['cabang', 'meja', 'laundry_status', 'servis', 'booking', 'resep'],
    'servis': ['meja', 'laundry_status', 'booking', 'resep', 'print_order'],
  };

  /// Convenience getter: hidden menus for current variant (productId).
  /// Strips the `nusa-` prefix from productId to match variant keys in [variantHiddenMenus].
  static List<String> get hiddenMenus {
    if (_devHiddenMenus != null) return _devHiddenMenus!;
    final variantId = productId.startsWith('nusa-') ? productId.substring(5) : productId;
    return variantHiddenMenus[variantId] ?? [];
  }

  /// Field hint per varian (placeholder "Cth: ..." sesuai industri).
  /// Prod build: pakai [variantHints] yang di-patch _build_all.py per varian;
  /// Dev build: override dari VariantData (VariantNotifier).
  static String hintsFor(String key) => (_devHints ?? variantHints)[key] ?? '';

  /// Build-time hints (patched by _build_all.py per variant).
  static Map<String, dynamic> variantHints = {
    'productName': 'Cth: Paracetamol 500mg',
    'productCategory': 'Cth: Obat',
    'barcode': 'contoh: 8991002101234',
    'employeeName': 'Cth: Apoteker Dewi',
  };

  /// Menu tambahan spesifik domain (bersifat aditif ke dashboard grid).
  /// Format: {'id', 'label', 'icon'}
  static const List<Map<String, String>> extraMenus = [];
}
