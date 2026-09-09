import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nusa_kasir/core/theme/nusa_theme.dart';
import 'package:nusa_kasir/core/providers.dart';
import 'package:nusa_kasir/core/config/nusa_config.dart';
import 'package:nusa_kasir/core/utils/secure_storage.dart';
import 'package:nusa_kasir/core/services/realtime_sync_service.dart';
import 'package:nusa_kasir/core/services/realtime_order_service.dart';
import 'package:nusa_kasir/core/services/delta_sync_service.dart';
import 'package:nusa_kasir/shared/widgets/call_receiver_overlay.dart';
import 'package:nusa_kasir/features/auth/rbac.dart';
import 'package:nusa_kasir/features/auth/employee_session_provider.dart';
import 'package:nusa_kasir/core/activation/activation_screen.dart';
import 'package:nusa_kasir/core/widgets/splash_screen.dart';
import 'package:nusa_kasir/features/auth/login_screen.dart';
import 'package:nusa_kasir/features/onboarding/onboarding_screen.dart';
import 'package:nusa_kasir/features/dashboard/dashboard_screen.dart';
import 'package:nusa_kasir/features/settings/settings_screen.dart';
import 'package:nusa_kasir/features/products/products_screen.dart';
import 'package:nusa_kasir/features/products/product_form_screen.dart';
import 'package:nusa_kasir/features/products/kategori_list_screen.dart';
import 'package:nusa_kasir/features/products/products_by_category_screen.dart';
import 'package:nusa_kasir/features/stock/stock_screen.dart';
import 'package:nusa_kasir/features/pos/pos_screen.dart';
import 'package:nusa_kasir/features/checkout/checkout_screen.dart';
import 'package:nusa_kasir/features/transactions/transactions_screen.dart';
import 'package:nusa_kasir/features/customers/customers_screen.dart';
import 'package:nusa_kasir/features/promo/promo_screen.dart';
import 'package:nusa_kasir/features/reports/reports_screen.dart';
import 'package:nusa_kasir/features/attendance/attendance_screen.dart';
import 'package:nusa_kasir/features/employees/employees_screen.dart';
import 'package:nusa_kasir/features/finance/finance_screen.dart';
import 'package:nusa_kasir/features/suppliers/suppliers_screen.dart';
import 'package:nusa_kasir/features/purchase/purchase_screen.dart';
import 'package:nusa_kasir/features/spreadsheet/spreadsheet_screen.dart';
import 'package:nusa_kasir/features/branches/branch_screen.dart';
import 'package:nusa_kasir/features/setup/setup_screen.dart';
import 'package:nusa_kasir/features/online_orders/online_orders_screen.dart';
import 'package:nusa_kasir/features/online_orders/online_store_setup_screen.dart';
import 'package:nusa_kasir/features/settings/payment_settings_screen.dart';
import 'package:nusa_kasir/features/ai_assistant/ai_chat_screen.dart';
import 'package:nusa_kasir/features/toko_online/storefront_screen.dart';
import 'package:nusa_kasir/features/debts/debt_screen.dart';
import 'package:nusa_kasir/features/domain/meja_screen.dart';
import 'package:nusa_kasir/features/domain/laundry_status_screen.dart';
import 'package:nusa_kasir/features/domain/servis_screen.dart';
import 'package:nusa_kasir/features/domain/booking_screen.dart';
import 'package:nusa_kasir/features/domain/resep_screen.dart';
import 'package:nusa_kasir/features/domain/print_order_screen.dart';
import 'package:nusa_kasir/features/reports/stylist_reports_screen.dart';
import 'package:nusa_kasir/core/dev/variant_picker_screen.dart';
import 'package:nusa_kasir/features/settings/store_data_screen.dart';

const _publicRoutes = {
  '/splash',
  '/activation',
  '/login',
  '/onboarding',
  '/setup',
  '/variant-picker',
};

/// Menu routes are protected centrally so deep links cannot bypass Dashboard's
/// menu-level RBAC checks. Route keys intentionally match NusaConfig.roleAccess.
const _protectedRouteKeys = {
  '/home': 'home',
  '/kasir': 'kasir',
  '/checkout': 'kasir',
  '/produk': 'produk',
  '/produk/kategori': 'produk',
  '/produk/kategori/': 'produk',
  '/stok': 'stok',
  '/transaksi': 'transaksi',
  '/pelanggan': 'pelanggan',
  '/piutang': 'piutang',
  '/promo': 'promo',
  '/laporan': 'laporan',
  '/karyawan': 'karyawan',
  '/presensi': 'presensi',
  '/keuangan': 'keuangan',
  '/pengaturan': 'pengaturan',
  '/supplier': 'supplier',
  '/spreadsheet': 'spreadsheet',
  '/cabang': 'cabang',
  '/pesanan_online': 'pesanan_online',
  '/toko_online_setup': 'pesanan_online',
  '/ai_chat': 'ai_chat',
  '/toko': 'pesanan_online',
  '/pengaturan_pembayaran': 'pengaturan',
  '/data_toko': 'pengaturan',
  '/meja': 'meja',
  '/laundry_status': 'laundry_status',
  '/servis': 'servis',
  '/booking': 'booking',
  '/resep': 'resep',
  '/print_order': 'print_order',
};

String? _protectedRouteKey(String location) {
  final path = Uri.parse(location).path;
  for (final entry in _protectedRouteKeys.entries) {
    if (path == entry.key ||
        (entry.key.endsWith('/') && path.startsWith(entry.key))) {
      return entry.value;
    }
  }
  return null;
}

Future<String?> _redirectForAuth(WidgetRef ref, GoRouterState state) async {
  final path = state.uri.path;
  if (_publicRoutes.contains(path)) return null;

  // Every non-public route requires activation and a valid employee session.
  // Route keys additionally apply menu visibility and role-based access.
  final routeKey = _protectedRouteKey(state.uri.toString());

  final activated = await SecureStore.getActivation() != null;
  if (!activated) return '/activation';

  var session = ref.read(employeeSessionProvider);
  if (session == null) {
    await ref.read(employeeSessionProvider.notifier).restore();
    session = ref.read(employeeSessionProvider);
  }

  if (session == null || session.isExpired) return '/login';

  if (routeKey != null &&
      (NusaConfig.hiddenMenus.contains(routeKey) ||
          !hasAccess(ref, session.role, routeKey))) {
    return '/home';
  }
  return null;
}

GoRouter buildRouter(String initialLocation, WidgetRef ref) => GoRouter(
  initialLocation: '/splash',
  redirect: (_, state) => _redirectForAuth(ref, state),
  routes: [
    GoRoute(
      path: '/splash',
      pageBuilder: (_, state) => CustomTransitionPage(
        key: state.pageKey,
        child: SplashScreen(onDone: (context) => context.go(initialLocation)),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    ),
    GoRoute(
      path: '/variant-picker',
      pageBuilder: (_, __) => _slidePage(VariantPickerScreen()),
    ),
    GoRoute(
      path: '/activation',
      pageBuilder: (_, __) => _slidePage(ActivationScreen()),
    ),
    GoRoute(path: '/login', pageBuilder: (_, __) => _slidePage(LoginScreen())),
    GoRoute(
      path: '/onboarding',
      pageBuilder: (_, __) => _slidePage(OnboardingScreen()),
    ),
    GoRoute(path: '/setup', pageBuilder: (_, __) => _slidePage(SetupScreen())),
    GoRoute(
      path: '/home',
      pageBuilder: (_, __) => _slidePage(DashboardScreen()),
    ),
    GoRoute(
      path: '/kasir',
      pageBuilder: (_, state) => _slidePage(
        PosScreen(
          sessionId: int.tryParse(state.uri.queryParameters['sessionId'] ?? ''),
        ),
      ),
    ),
    GoRoute(
      path: '/checkout',
      pageBuilder: (_, state) => _slidePage(
        CheckoutScreen(
          sessionId: int.tryParse(state.uri.queryParameters['sessionId'] ?? ''),
        ),
      ),
    ),
    GoRoute(
      path: '/produk',
      pageBuilder: (_, __) => _slidePage(ProductsScreen()),
    ),
    GoRoute(
      path: '/produk/kategori',
      pageBuilder: (_, __) => _slidePage(KategoriListScreen()),
    ),
    GoRoute(
      path: '/produk/kategori/:category',
      pageBuilder: (_, state) => _slidePage(
        ProductsByCategoryScreen(category: state.pathParameters['category']!),
      ),
    ),
    GoRoute(
      path: '/stok',
      pageBuilder: (_, state) => _slidePage(
        StockScreen(
          lowStockOnly: state.uri.queryParameters['lowStock'] == 'true',
        ),
      ),
    ),
    GoRoute(
      path: '/transaksi',
      pageBuilder: (_, __) => _slidePage(TransactionsScreen()),
    ),
    GoRoute(
      path: '/pelanggan',
      pageBuilder: (_, __) => _slidePage(CustomersScreen()),
    ),
    GoRoute(path: '/piutang', pageBuilder: (_, __) => _slidePage(DebtScreen())),
    GoRoute(path: '/promo', pageBuilder: (_, __) => _slidePage(PromoScreen())),
    GoRoute(
      path: '/laporan',
      pageBuilder: (_, __) => _slidePage(ReportsScreen()),
    ),
    // v2.2.57: laporan kinerja Stylist (salon variant).
    GoRoute(
      path: '/laporan/stylist',
      pageBuilder: (_, __) => _slidePage(KinerjaStylistScreen()),
    ),
    // v2.2.57: stylist login lihat omset/komisi sendiri.
    GoRoute(
      path: '/pendapatan-saya',
      pageBuilder: (_, __) => _slidePage(PendapatanSayaScreen()),
    ),
    GoRoute(
      path: '/karyawan',
      pageBuilder: (_, __) => _slidePage(EmployeesScreen()),
    ),
    GoRoute(
      path: '/presensi',
      pageBuilder: (_, __) => _slidePage(AttendanceScreen()),
    ),
    GoRoute(
      path: '/keuangan',
      pageBuilder: (_, __) => _slidePage(FinanceScreen()),
    ),
    GoRoute(
      path: '/pengaturan',
      pageBuilder: (_, __) => _slidePage(SettingsScreen()),
    ),
    GoRoute(
      path: '/supplier',
      pageBuilder: (_, __) => _slidePage(SuppliersScreen()),
    ),
    GoRoute(
      path: '/pembelian',
      pageBuilder: (_, __) => _slidePage(PurchaseScreen()),
    ),
    GoRoute(
      path: '/spreadsheet',
      pageBuilder: (_, __) => _slidePage(SpreadsheetScreen()),
    ),
    GoRoute(
      path: '/cabang',
      pageBuilder: (_, __) => _slidePage(BranchScreen()),
    ),
    GoRoute(
      path: '/pesanan_online',
      pageBuilder: (_, __) => _slidePage(OnlineOrdersScreen()),
    ),
    GoRoute(
      path: '/toko_online_setup',
      pageBuilder: (_, __) => _slidePage(OnlineStoreSetupScreen()),
    ),
    GoRoute(
      path: '/ai_chat',
      pageBuilder: (_, __) => _slidePage(AiChatScreen()),
    ),
    GoRoute(
      path: '/toko',
      pageBuilder: (_, __) => _slidePage(StorefrontScreen()),
    ),
    GoRoute(
      path: '/pengaturan_pembayaran',
      pageBuilder: (_, __) => _slidePage(PaymentSettingsScreen()),
    ),
    GoRoute(
      path: '/data_toko',
      pageBuilder: (_, __) => _slidePage(StoreDataScreen()),
    ),
    // ── Domain-specific screens (F&B, Laundry, Bengkel, Salon, Apotek, Fotocopy, Servis) ──
    GoRoute(path: '/meja', pageBuilder: (_, __) => _slidePage(MejaScreen())),
    GoRoute(
      path: '/laundry_status',
      pageBuilder: (_, __) => _slidePage(LaundryStatusScreen()),
    ),
    GoRoute(
      path: '/servis',
      pageBuilder: (_, __) => _slidePage(ServisScreen()),
    ),
    GoRoute(
      path: '/booking',
      pageBuilder: (_, __) => _slidePage(BookingScreen()),
    ),
    GoRoute(path: '/resep', pageBuilder: (_, __) => _slidePage(ResepScreen())),
    GoRoute(
      path: '/print_order',
      pageBuilder: (_, __) => _slidePage(PrintOrderScreen()),
    ),
  ],
);

CustomTransitionPage _slidePage(Widget child) => CustomTransitionPage(
  child: child,
  transitionsBuilder: (context, animation, secondaryAnimation, child) =>
      SlideTransition(
        position: Tween<Offset>(begin: const Offset(0.3, 0), end: Offset.zero)
            .animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            ),
        child: child,
      ),
);

class NusaApp extends ConsumerStatefulWidget {
  final String initialLocation;
  const NusaApp({required this.initialLocation, super.key});

  @override
  ConsumerState<NusaApp> createState() => _NusaAppState();
}

class _NusaAppState extends ConsumerState<NusaApp> with WidgetsBindingObserver {
  late final GoRouter _router = buildRouter(widget.initialLocation, ref);

  @override
  void initState() {
    super.initState();
    // Start auto cloud sync (upload side) for the whole app lifetime.
    WidgetsBinding.instance.addObserver(this);
    try {
      ref.read(autoSyncProvider);
    } catch (_) {}
    // v2.2.57: subscribe realtime channel for delta "another device just
    // uploaded" notifications. On receipt → trigger immediate pull (soft
    // adopt if we can't safely hot-apply, otherwise close+restore+login).
    try {
      RealtimeBackupNotifier.I.start();
      RealtimeSyncService.I.stream.listen((_) {
        // Soft pull: just adopt cloud time. Hot-apply on push event would
        // clobber unsaved UI state; next natural launch picks up via
        // _applyPendingRestore. This still brings "another device updated"
        // to within ~1s perceived latency for read-only screens (dashboard,
        // reports) since they refetch on each rebuild.
        try {
          ref.read(autoSyncProvider).pullNow();
        } catch (_) {}
      });
    } catch (_) {}

    // v2.2.57+131: global orders listener — subscribe once at app lifetime
    // so order_new/order_updated events arrive regardless of which screen
    // is open (previously only OnlineOrdersScreen subscribed, and only
    // while mounted). This makes online orders realtime everywhere.
    try {
      RealtimeOrderService.I.start(ref.read(databaseProvider));
    } catch (_) {}

    // v2.2.57+131: delta sync service — row-level sync between devices
    // on the same account. Pushes local changes, pulls remote deltas.
    try {
      DeltaSyncService.I.start(ref.read(databaseProvider));
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    try {
      RealtimeBackupNotifier.I.stop();
    } catch (_) {}
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Flush pending upload when the app goes to background — data leaves the
    // device as soon as possible without waiting for the next debounce tick.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      try {
        ref.read(autoSyncProvider).flushNow();
      } catch (_) {}
    }
    // v2.2.57: on resume, pull immediately so devices that were idle on a
    // different network catch up within milliseconds instead of waiting for
    // the 30s periodic timer.
    if (state == AppLifecycleState.resumed) {
      try {
        ref.read(autoSyncProvider).pullNow();
      } catch (_) {}
    }
  }

  ThemeMode _toThemeMode(String mode) {
    switch (mode) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeModeStr = ref.watch(themeModeProvider);
    final themePreset = ref.watch(
      themePresetProvider,
    ); // watch for rebuild on theme change
    return MaterialApp.router(
      key: ValueKey('nusa_$themePreset'), // force rebuild when theme changes
      title: 'NUSA Kasir',
      theme: NusaTheme.light,
      darkTheme: NusaTheme.dark,
      themeMode: _toThemeMode(themeModeStr),
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
      // v2.2.54: overlay global penerima "Panggil Karyawan" (Realtime).
      builder: (context, child) =>
          CallReceiverOverlay(child: child ?? const SizedBox.shrink()),
    );
  }
}
