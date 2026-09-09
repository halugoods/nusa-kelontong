import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'tables.dart';
part 'app_database.g.dart';

@DriftDatabase(
  tables: [
    Categories,
    Products,
    StockMovements,
    Transactions,
    Customers,
    Promos,
    Employees,
    Attendance,
    Expenses,
    ExpenseCategories,
    RecurringExpenses,
    Payroll,
    Waste,
    Liquidity,
    Suppliers,
    Branches,
    Settings,
    ActivationsLocal,
    SyncQueue,
    CashierSessions,
    OnlineOrders,
    CustomerDebts,
    DebtPayments,
    StockCounts,
    StockCountItems,
    ChatSessions,
    DiningTables,
    LaundryOrders,
    ServiceTickets,
    Appointments,
    Prescriptions,
    PrintOrders,
    PrintServiceTypes,
    OpenTabs,
    Roles,
    Refunds,
    PointHistories,
    PurchaseOrders,
    PurchaseOrderItems,
    MaterialPrices,
    InstallmentOptions,
    EstimateOptions,
    Units,
    ProductUnits,
    RawMaterials,
    Recipes,
    IngredientStocks,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());
  AppDatabase.test() : super(NativeDatabase.memory());

  /// Buka koneksi ke file SQLite tertentu (bukan file live default).
  /// Dipakai _migrateSqliteBytes untuk memigrasi bytes hasil decrypt sebelum
  /// ditulis ke live — AppDatabase() normal selalu pakai nusa_kasir.sqlite.
  AppDatabase.at(String path) : super(_openConnectionAt(path));

  @override
  int get schemaVersion => 49;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    // ── v2.2.41: repair schema SETIAP buka (bukan hanya saat upgrade) ──
    // Backup cloud lama (mis. dari varian lain / app versi lama) bisa punya
    // user_version == schemaVersion (44) tapi kolom-kolomnya NULL — contoh
    // nyata: products.discount_percent/discount_type dibuat TANPA DEFAULT oleh
    // app versi lama, jadi semua baris NULL. Drift hanya menjalankan onUpgrade
    // saat user_version BERUBAH; kalau sudah 44, onUpgrade di-skip → NULL
    // tidak pernah diisi → SELECT products melempar "Null check operator used
    // on a null value" → dashboard kosong / loading abadi setelah restore.
    // beforeOpen jalan SETIAP open, jadi perbaikan ini berlaku untuk SEMUA
    // user, termasuk yang DB-nya hasil restore cloud. Idempoten & ringan.
    beforeOpen: (details) async {
      try {
        await _repairNullDefaults(this);
      } catch (e) {
        debugPrint('[DB] beforeOpen repair error (non-fatal): $e');
      }
    },
    onUpgrade: (m, from, to) async {
      // ── v2.2.39: migrasi LENGKAP selalu dijalankan (bukan hanya delta) ──
      // DB hasil restore cloud bisa membawa user_version TUA (26-30) padahal
      // beberapa kolom/tabel sudah ada. Drift hanya memanggil onUpgrade sekali
      // dengan `from` = user_version saat file dibuka; kalau ada tabel yang
      // hilang (mis. open_tabs, roles), query selanjutnya error. Guard
      // _createTableIfMissing/_addColumnIfMissing idempoten → aman jalan semua.
      // Jalankan semua langkah migrasi tanpa syarat `if (from < N)` supaya DB
      // yang sebagian ter-migrasi tetap bisa dilengkapi.
      if (from < 2 || from == 0) {
        await _createTableIfMissing(
          m,
          'cashier_sessions',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'employee_id INTEGER, '
              'opened_at INTEGER, '
              'closed_at INTEGER, '
              'opening_cash INTEGER, '
              'closing_cash INTEGER, '
              'expected_cash INTEGER, '
              'notes TEXT, '
              'status TEXT',
        );
      }
      if (from < 3) {
        await _addColumnIfMissing(m, 'attendance', 'final_cash', 'INTEGER');
      }
      if (from < 4) {
        await _addColumnIfMissing(m, 'products', 'is_online', 'INTEGER');
        await _createTableIfMissing(
          m,
          'online_orders',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'invoice TEXT NOT NULL, '
              'customer_name TEXT NOT NULL, '
              'customer_phone TEXT NOT NULL, '
              'items TEXT NOT NULL, '
              'subtotal INTEGER DEFAULT 0, '
              'discount INTEGER DEFAULT 0, '
              'handling_fee INTEGER DEFAULT 0, '
              'total INTEGER NOT NULL, '
              'payment_method TEXT DEFAULT \'Tunai\', '
              'pickup_time TEXT, '
              'branch TEXT DEFAULT \'Pusat\', '
              'notes TEXT, '
              'status TEXT DEFAULT \'Online Baru\', '
              'processed_by TEXT, '
              'created_at INTEGER',
        );
      }
      if (from < 5) {
        await _addColumnIfMissing(m, 'transactions', 'status', 'TEXT');
        await _addColumnIfMissing(m, 'transactions', 'void_reason', 'TEXT');
        await _addColumnIfMissing(m, 'transactions', 'voided_at', 'INTEGER');
      }
      if (from < 6) {
        await _addColumnIfMissing(m, 'settings', 'pos_grid_columns', 'INTEGER');
        await _addColumnIfMissing(m, 'settings', 'bank_name', 'TEXT');
        await _addColumnIfMissing(m, 'settings', 'bank_account', 'TEXT');
        await _addColumnIfMissing(m, 'settings', 'bank_holder', 'TEXT');
      }
      if (from < 7) {
        await _addColumnIfMissing(m, 'products', 'expiry_date', 'INTEGER');
        await _addColumnIfMissing(m, 'products', 'product_type', 'TEXT');
      }
      if (from < 8) {
        await _addColumnIfMissing(m, 'products', 'variants_json', 'TEXT');
        await _addColumnIfMissing(m, 'products', 'wholesale_json', 'TEXT');
      }
      if (from < 9) {
        await _createTableIfMissing(
          m,
          'categories',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'name TEXT NOT NULL, '
              'created_at INTEGER',
        );
      }
      if (from < 10) {
        await _addColumnIfMissing(m, 'settings', 'receipt_footer', 'TEXT');
        await _addColumnIfMissing(m, 'settings', 'store_logo_path', 'TEXT');
      }
      if (from < 11) {
        await _addColumnIfMissing(m, 'settings', 'wa_templates', 'TEXT');
        await _addColumnIfMissing(m, 'settings', 'points_per_rupiah', 'INTEGER');
        await _addColumnIfMissing(m, 'settings', 'silver_threshold', 'INTEGER');
        await _addColumnIfMissing(m, 'settings', 'gold_threshold', 'INTEGER');
        await _addColumnIfMissing(m, 'settings', 'platinum_threshold', 'INTEGER');
      }
      if (from < 12) {
        await _addColumnIfMissing(m, 'employees', 'phone', 'TEXT');
        await _addColumnIfMissing(m, 'attendance', 'status', 'TEXT');
      }
      if (from < 13) {
        await _addColumnIfMissing(m, 'employees', 'photo_path', 'TEXT');
        await _addColumnIfMissing(m, 'employees', 'base_salary', 'INTEGER');
        await _addColumnIfMissing(m, 'employees', 'start_date', 'INTEGER');
      }
      if (from < 14) {
        await _addColumnIfMissing(m, 'expenses', 'branch_id', 'INTEGER');
        await _addColumnIfMissing(m, 'liquidity', 'branch_id', 'INTEGER');
        await _createTableIfMissing(
          m,
          'expense_categories',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'name TEXT NOT NULL, '
              'created_at INTEGER',
        );
        await _createTableIfMissing(
          m,
          'recurring_expenses',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'name TEXT NOT NULL, '
              'amount INTEGER NOT NULL, '
              'frequency TEXT, '
              'start_date INTEGER, '
              'end_date INTEGER, '
              'category_id INTEGER, '
              'status TEXT, '
              'created_at INTEGER',
        );
      }
      if (from < 15) {
        await _createTableIfMissing(
          m,
          'customer_debts',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'customer_id INTEGER NOT NULL, '
              'customer_name TEXT NOT NULL, '
              'amount INTEGER NOT NULL, '
              'paid INTEGER DEFAULT 0, '
              'description TEXT, '
              'status TEXT, '
              'created_at INTEGER',
        );
        await _createTableIfMissing(
          m,
          'debt_payments',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'debt_id INTEGER NOT NULL, '
              'amount INTEGER NOT NULL, '
              'note TEXT, '
              'created_at INTEGER',
        );
      }
      if (from < 16) {
        // ShiftSessions was added in v16 but has been removed & merged into Presensi
        // (columns now in attendance table via v18 migration below)
      }
      if (from < 17) {
        await _createTableIfMissing(
          m,
          'stock_counts',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'name TEXT, '
              'status TEXT, '
              'created_at INTEGER, '
              'counted_by TEXT',
        );
        await _createTableIfMissing(
          m,
          'stock_count_items',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'stock_count_id INTEGER NOT NULL, '
              'product_id INTEGER, '
              'product_name TEXT, '
              'system_stock INTEGER, '
              'actual_stock INTEGER, '
              'difference INTEGER, '
              'note TEXT',
        );
      }
      if (from < 18) {
        await _addColumnIfMissing(m, 'attendance', 'expected_cash', 'INTEGER');
        await _addColumnIfMissing(m, 'attendance', 'shift_notes', 'TEXT');
      }
      if (from < 19) {
        await _addColumnIfMissing(m, 'branches', 'address', 'TEXT');
        await _addColumnIfMissing(m, 'branches', 'phone', 'TEXT');
        await _addColumnIfMissing(m, 'branches', 'status', 'TEXT');
        await _addColumnIfMissing(m, 'settings', 'qris_image_path', 'TEXT');
        await _addColumnIfMissing(m, 'settings', 'receipt_header', 'TEXT');
        await _addColumnIfMissing(m, 'settings', 'receipt_paper_size', 'TEXT');
        await _addColumnIfMissing(m, 'settings', 'receipt_show_logo', 'INTEGER');
        await _addColumnIfMissing(m, 'settings', 'receipt_show_cashier', 'INTEGER');
        await _addColumnIfMissing(m, 'settings', 'receipt_show_invoice', 'INTEGER');
        await _addColumnIfMissing(m, 'settings', 'receipt_show_date', 'INTEGER');
        await _addColumnIfMissing(m, 'settings', 'receipt_show_barcode', 'INTEGER');
      }
      if (from < 20) {
        await _addColumnIfMissing(m, 'employees', 'nfc_tag', 'TEXT');
      }
      if (from < 21) {
        await _addColumnIfMissing(m, 'settings', 'pin_length', 'INTEGER');
      }
      if (from < 22) {
        await _addColumnIfMissing(m, 'employees', 'work_start', 'TEXT');
        await _addColumnIfMissing(m, 'employees', 'work_end', 'TEXT');
      }
      if (from < 23) {
        await _createTableIfMissing(
          m,
          'chat_sessions',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'title TEXT, '
              'created_at INTEGER, '
              'updated_at INTEGER, '
              'messages TEXT',
        );
      }
      if (from < 24) {
        await _createTableIfMissing(
          m,
          'dining_tables',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'name TEXT NOT NULL, '
              'status TEXT, '
              'created_at INTEGER',
        );
        await _createTableIfMissing(
          m,
          'laundry_orders',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'invoice TEXT NOT NULL, '
              'customer_name TEXT NOT NULL, '
              'customer_phone TEXT, '
              'items TEXT, '
              'weight_kg REAL, '
              'total INTEGER NOT NULL, '
              'paid INTEGER DEFAULT 0, '
              'status TEXT, '
              'notes TEXT, '
              'created_at INTEGER, '
              'pickup_at INTEGER, '
              'estimated_ready INTEGER',
        );
        await _createTableIfMissing(
          m,
          'service_tickets',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'ticket_no TEXT, '
              'customer_name TEXT, '
              'customer_phone TEXT, '
              'vehicle_plate TEXT, '
              'vehicle_brand TEXT, '
              'vehicle_year INTEGER, '
              'service_type TEXT, '
              'technician TEXT, '
              'queue_number INTEGER, '
              'sparepart_cost INTEGER, '
              'service_cost INTEGER, '
              'status TEXT, '
              'notes TEXT, '
              'created_at INTEGER, '
              'estimated_ready INTEGER',
        );
        await _createTableIfMissing(
          m,
          'appointments',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'customer_name TEXT NOT NULL, '
              'customer_phone TEXT, '
              'service_name TEXT, '
              'date TEXT, '
              'time TEXT, '
              'status TEXT, '
              'notes TEXT, '
              'created_at INTEGER, '
              'estimated_duration INTEGER, '
              'counter_id INTEGER',
        );
        await _createTableIfMissing(
          m,
          'prescriptions',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'patient_name TEXT NOT NULL, '
              'doctor TEXT, '
              'items TEXT, '
              'total INTEGER, '
              'status TEXT, '
              'notes TEXT, '
              'created_at INTEGER',
        );
        await _createTableIfMissing(
          m,
          'print_orders',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'invoice TEXT NOT NULL, '
              'service_name TEXT NOT NULL, '
              'customer_name TEXT, '
              'quantity INTEGER DEFAULT 1, '
              'price INTEGER NOT NULL, '
              'status TEXT, '
              'notes TEXT, '
              'created_at INTEGER, '
              'pickup_at INTEGER, '
              'width_cm REAL, '
              'length_cm REAL, '
              'estimate_ready TEXT',
        );
      }
      if (from < 25) {
        await _addColumnIfMissing(m, 'employees', 'requires_attendance', 'INTEGER');
      }
      if (from < 26) {
        await _addColumnIfMissing(m, 'employees', 'requires_cash_open', 'INTEGER');
        await _addColumnIfMissing(m, 'employees', 'requires_cash_close', 'INTEGER');
      }
      if (from < 27) {
        // ── Self-healing (v2.2.34): DB restore lama bisa bawa kolom order_type
        // sudah ada tapi user_version < 27 → ALTER TABLE mentah error
        // "duplicate column name". Guard semua kolom v27 (skip kalau ada).
        await _addColumnIfMissing(m, 'transactions', 'order_type', 'TEXT');
        await _addColumnIfMissing(m, 'transactions', 'table_id', 'INTEGER');
        await _addColumnIfMissing(m, 'transactions', 'notes', 'TEXT');
        await _addColumnIfMissing(m, 'settings', 'kitchen_printer_address', 'TEXT');
        await _addColumnIfMissing(m, 'settings', 'kitchen_printer_enabled', 'INTEGER');
        await _createTableIfMissing(
          m,
          'open_tabs',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'table_id INTEGER, '
              'order_type TEXT DEFAULT \'Dine In\', '
              'items_json TEXT NOT NULL, '
              'total INTEGER DEFAULT 0, '
              'discount INTEGER DEFAULT 0, '
              'status TEXT DEFAULT \'Open\', '
              'created_at INTEGER, '
              'updated_at INTEGER',
        );
      }
      if (from < 28) {
        await _addColumnIfMissing(m, 'laundry_orders', 'estimated_ready', 'INTEGER');
      }
      if (from < 29) {
        await _addColumnIfMissing(m, 'products', 'price_type', 'TEXT');
      }
      if (from < 30) {
        await _addColumnIfMissing(m, 'appointments', 'estimated_duration', 'INTEGER');
        await _addColumnIfMissing(m, 'appointments', 'counter_id', 'INTEGER');
      }
      if (from < 31) {
        await _addColumnIfMissing(m, 'service_tickets', 'plate_number', 'TEXT');
        await _addColumnIfMissing(m, 'service_tickets', 'vehicle_brand', 'TEXT');
        await _addColumnIfMissing(m, 'service_tickets', 'vehicle_year', 'INTEGER');
        await _addColumnIfMissing(m, 'service_tickets', 'technician', 'TEXT');
        await _addColumnIfMissing(m, 'service_tickets', 'sparepart_cost', 'INTEGER');
        await _addColumnIfMissing(m, 'service_tickets', 'service_cost', 'INTEGER');
        await _addColumnIfMissing(m, 'service_tickets', 'queue_number', 'INTEGER');
      }
      if (from < 32) {
        // Promo mode: 'otomatis' | 'kode' | 'bebas' (hybrid discount 3-arah)
        await _addColumnIfMissing(m, 'promos', 'mode', 'TEXT');
      }
      if (from < 33) {
        // Diskon standalone per produk (% potongan dari harga jual)
        await _addColumnIfMissing(m, 'products', 'discount_percent', 'INTEGER');
      }
      if (from < 34) {
        // RBAC: roles pindah ke SQLite (ikut backup/restore cloud antar device)
        await _createTableIfMissing(
          m,
          'roles',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'name TEXT NOT NULL, '
              'permissions TEXT, '
              'created_at INTEGER',
        );
        // Sales per kasir: atribusi transaksi ke karyawan/sesi shift
        await _addColumnIfMissing(m, 'transactions', 'employee_id', 'INTEGER');
        await _addColumnIfMissing(m, 'transactions', 'session_id', 'INTEGER');
        // Backfill employeeId dari cashier_name yang tersimpan.
        // NOTE: raw SQL wajib pakai nama kolom SQLite (snake_case) — drift
        // memetakan cashierName → cashier_name, employeeId → employee_id.
        await _runIfColumnExists(m, 'transactions', 'employee_id', '''
          UPDATE transactions
          SET employee_id = (SELECT e.id FROM employees e WHERE e.name = transactions.cashier_name LIMIT 1)
          WHERE employee_id IS NULL AND cashier_name IS NOT NULL AND cashier_name != ''
        ''');
      }
      if (from < 35) {
        // Diskon fleksibel: % (persen) atau nominal uang (Rp) langsung.
        // Kolom baru discount_type; data lama otomatis 'persen' via default.
        await _addColumnIfMissing(m, 'products', 'discount_type', 'TEXT');
      }
      if (from < 36) {
        // Retur/refund parsial: tabel refunds mencatat barang dikembalikan
        // (stok balik) + uang dikembalikan per transaksi, agar laporan omzet,
        // HPP, top produk, dan kas shift akurat.
        await _createTableIfMissing(
          m,
          'refunds',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'transaction_id INTEGER NOT NULL, '
              'product_id INTEGER, '
              'product_name TEXT NOT NULL, '
              'quantity INTEGER NOT NULL, '
              'amount INTEGER NOT NULL, '
              'reason TEXT, '
              'created_at INTEGER',
        );
      }
      if (from < 37) {
        // Riwayat poin per pelanggan (dapat / pakai) — untuk tampilan
        // "Poin History" di detail pelanggan & info poin di struk.
        await _createTableIfMissing(
          m,
          'point_histories',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'customer_id INTEGER NOT NULL, '
              'points INTEGER NOT NULL, '
              'type TEXT, '
              'note TEXT, '
              'created_at INTEGER',
        );
      }
      if (from < 38) {
        // Pembelian supplier (restok): header + item. Saat pembelian
        // dicatat, stok produk masuk & harga modal (buyPrice) diperbarui
        // ke harga beli terbaru.
        await _createTableIfMissing(
          m,
          'purchase_orders',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'invoice TEXT NOT NULL, '
              'supplier_id INTEGER, '
              'supplier_name TEXT, '
              'total INTEGER NOT NULL, '
              'status TEXT, '
              'note TEXT, '
              'created_at INTEGER, '
              'extra_costs_json TEXT',
        );
        await _createTableIfMissing(
          m,
          'purchase_order_items',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'purchase_order_id INTEGER NOT NULL, '
              'product_id INTEGER, '
              'product_name TEXT NOT NULL, '
              'quantity INTEGER NOT NULL, '
              'price INTEGER NOT NULL, '
              'is_material INTEGER DEFAULT 0',
        );
      }
      if (from < 39) {
        // Bahan pembelian (non-produk, mis. plastik): item pembelian kini
        // bisa berupa bahan (isMaterial=1, productId nullable) yang hanya
        // dicatat riwayatnya — tanpa menyentuh stok produk. Riwayat harga
        // beli bahan per supplier disimpan di MaterialPrices.
        await _addColumnIfMissing(m, 'purchase_order_items', 'is_material', 'INTEGER');
        await _createTableIfMissing(
          m,
          'material_prices',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'material_name TEXT NOT NULL, '
              'supplier_id INTEGER, '
              'price INTEGER NOT NULL, '
              'qty INTEGER DEFAULT 1, '
              'date INTEGER, '
              'note TEXT',
        );
      }
      if (from < 40) {
        // Catat pembelian mode POS: produk bisa terikat supplier langganan
        // (supplierId) + biaya tambahan (packing/ongkir/stiker) disimpan di
        // header pembelian (extraCostsJson) untuk HPP akurat.
        await _addColumnIfMissing(m, 'products', 'supplier_id', 'INTEGER');
        await _addColumnIfMissing(m, 'purchase_orders', 'extra_costs_json', 'TEXT');
      }
      if (from < 41) {
        // Sub-header struk (biasanya alamat toko) — baris teks di bawah
        // header/nama toko, sebelum invoice/tanggal (v2.2.30).
        await _addColumnIfMissing(m, 'settings', 'receipt_sub_header', 'TEXT');
      }
      if (from < 42) {
        // Percetakan (fotocopy upgrade): dimensi cetak + estimasi selesai
        // di order, dan tabel jenis layanan custom (tanpa icon bulat).
        await _addColumnIfMissing(m, 'print_orders', 'width_cm', 'REAL');
        await _addColumnIfMissing(m, 'print_orders', 'length_cm', 'REAL');
        await _addColumnIfMissing(m, 'print_orders', 'estimate_ready', 'TEXT');
        await _createTableIfMissing(
          m,
          'print_service_types',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'name TEXT NOT NULL, '
              'is_default INTEGER DEFAULT 0, '
              'created_at INTEGER',
        );
        // Seed 6 layanan default — bisa diubah/ditambah user (CRUD).
        // NOTE: raw SQL wajib pakai nama kolom SQLite (snake_case):
        // isDefault → is_default. Hanya seed kalau tabel masih kosong
        // (supaya tidak dobel saat DB sudah pernah punya tabel ini).
        final existing = await m.database
            .customSelect('SELECT COUNT(*) AS c FROM print_service_types')
            .getSingle();
        if ((existing.read<int>('c') ?? 0) == 0) {
          for (final name in ['Fotocopy', 'Print Warna', 'Print B/W', 'Jilid', 'Laminating', 'Scan']) {
            await customStatement(
                "INSERT INTO print_service_types (name, is_default) VALUES ('$name', 1)");
          }
        }
      }
      if (from < 43) {
        // Piutang & cicilan (v2.2.34): DP/persen/nominal + opsi cicilan
        // CRUD + link transaksi→debt (status bayar sinkron di riwayat).
        await _addColumnIfMissing(m, 'transactions', 'dp_amount', 'INTEGER');
        await _addColumnIfMissing(m, 'transactions', 'installment_months', 'INTEGER');
        await _addColumnIfMissing(m, 'transactions', 'installment_per_month', 'INTEGER');
        await _addColumnIfMissing(m, 'transactions', 'debt_id', 'INTEGER');
        await _addColumnIfMissing(m, 'customer_debts', 'installment_months', 'INTEGER');
        // Opsi cicilan (CRUD owner) — seed default 1/2/3/6/12 bulan.
        await _createTableIfMissing(
          m,
          'installment_options',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'months INTEGER NOT NULL, '
              'label TEXT, '
              'is_default INTEGER DEFAULT 0',
        );
        final instCount = await m.database
            .customSelect('SELECT COUNT(*) AS c FROM installment_options')
            .getSingle();
        if ((instCount.read<int>('c') ?? 0) == 0) {
          for (final months in [1, 2, 3, 6, 12]) {
            await customStatement(
                "INSERT INTO installment_options (months, label, is_default) "
                "VALUES ($months, '$months× bulanan', 1)");
          }
        }
        // Preset estimasi selesai Order Cetak (CRUD) — seed default.
        await _createTableIfMissing(
          m,
          'estimate_options',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'label TEXT NOT NULL UNIQUE',
        );
        final estCount = await m.database
            .customSelect('SELECT COUNT(*) AS c FROM estimate_options')
            .getSingle();
        if ((estCount.read<int>('c') ?? 0) == 0) {
          for (final label in ['1 jam', '2 jam', '3 jam', 'Besok 10:00', 'Besok 14:00', '3 hari', '1 minggu']) {
            await customStatement(
                "INSERT INTO estimate_options (label) VALUES ('$label')");
          }
        }
      }
      if (from < 44) {
        // v2.2.35: cabang pada setoran piutang (laporan uang masuk per cabang)
        // + config field form Order Cetak per layanan + nilai field kustom.
        await _addColumnIfMissing(m, 'debt_payments', 'branch_id', 'INTEGER');
        await _addColumnIfMissing(
            m, 'print_service_types', 'fields_json', 'TEXT');
        await _addColumnIfMissing(m, 'print_orders', 'custom_fields_json', 'TEXT');
      }
      if (from < 45) {
        // v2.2.43: Satuan dinamis (kamus CRUD) + konversi per produk
        // + F&B bahan baku / resep / mutasi stok bahan.
        await _createTableIfMissing(
          m,
          'units',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'name TEXT NOT NULL UNIQUE, '
              'created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP',
        );
        // Seed satuan dasar — pcs (hanya jika kamus kosong; user bebas
        // tambah/rename/hapus lewat "Kelola Satuan").
        final unitCount = await m.database
            .customSelect('SELECT COUNT(*) AS c FROM units')
            .getSingle();
        if ((unitCount.read<int>('c') ?? 0) == 0) {
          await customStatement("INSERT INTO units (name) VALUES ('pcs')");
        }
        await _createTableIfMissing(
          m,
          'product_units',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'product_id INTEGER NOT NULL, '
              'unit_id INTEGER NOT NULL, '
              'qty_per_base REAL NOT NULL DEFAULT 1, '
              'is_base INTEGER NOT NULL DEFAULT 0',
        );
        await _createTableIfMissing(
          m,
          'raw_materials',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'name TEXT NOT NULL, '
              'unit_id INTEGER, '
              'stock INTEGER NOT NULL DEFAULT 0, '
              'min_stock INTEGER NOT NULL DEFAULT 0, '
              'cost_price INTEGER NOT NULL DEFAULT 0, '
              'supplier_id INTEGER, '
              'updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP',
        );
        await _createTableIfMissing(
          m,
          'recipes',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'product_id INTEGER NOT NULL, '
              'material_id INTEGER NOT NULL, '
              'qty REAL NOT NULL DEFAULT 1',
        );
        await _createTableIfMissing(
          m,
          'ingredient_stocks',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'material_id INTEGER NOT NULL, '
              'type TEXT NOT NULL, '
              'qty REAL NOT NULL, '
              'note TEXT, '
              'date TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP',
        );
      }
      if (from < 46) {
        // v2.2.44: (B1) foto produk ikut backup cloud — BASE64 di kolom produk;
        // (B8) barcode karyawan — 4 jalur auth (PIN/FP/NFC/barcode);
        // (B10) Tab Layanan — flag isService pada produk (jasa vs barang).
        await _addColumnIfMissing(m, 'products', 'image_base64', 'TEXT');
        await _addColumnIfMissing(m, 'employees', 'barcode', 'TEXT');
        await _addColumnIfMissing(m, 'products', 'is_service', 'INTEGER');
        // ALTER tanpa DEFAULT → baris lama NULL; backfill 0 (barang) supaya
        // SELECT tidak "Null check" pada bool non-nullable.
        await m.database.customStatement(
          'UPDATE products SET is_service = 0 WHERE is_service IS NULL',
        );
      }
      if (from < 47) {
        // v2.2.45 (B11): barcode member/pelanggan — scan HID/kamera untuk
        // pilih pelanggan + cetak kartu member.
        await _addColumnIfMissing(m, 'customers', 'barcode', 'TEXT');
        // v2.2.45 (B1): foto profil karyawan ikut backup cloud (BASE64).
        await _addColumnIfMissing(m, 'employees', 'photo_base64', 'TEXT');
      }
      if (from < 48) {
        // v2.2.54: staf layanan (picker stylist booking) +
        // stylistId pada appointment (link logis ke Employees).
        await _addColumnIfMissing(m, 'employees', 'is_service_staff', 'INTEGER');
        // ALTER tanpa DEFAULT → baris lama NULL; backfill 1 (default true —
        // semua karyawan existing dianggap staf layanan sampai owner ubah).
        await m.database.customStatement(
          'UPDATE employees SET is_service_staff = 1 WHERE is_service_staff IS NULL',
        );
        await _addColumnIfMissing(m, 'appointments', 'stylist_id', 'INTEGER');
        // v2.2.57: komisi Stylist (% omset) — dipakai laporan Kinerja Stylist
        // + hitung komisi per-line booking. Default 10 untuk karyawan existing.
        await _addColumnIfMissing(
            m, 'employees', 'commission_percent', 'REAL DEFAULT 10.0');
        await m.database.customStatement(
          'UPDATE employees SET commission_percent = 10.0 '
          'WHERE commission_percent IS NULL',
        );
        // v2.2.57: link appointment → transaksi (omset & komisi per Stylist).
        await _addColumnIfMissing(m, 'appointments', 'transaction_id', 'INTEGER');
      }
      // v2.2.57+130: base64 TIDAK di-clear. User yang uninstall-reinstall akan
      // kehilangan gambar jika base64 dihapus — backup ringan lebih baik dari
      // data user hilang. Gambar tetap ada di DB sampai di-pack ke arsip.
    },
  );
}

// ── v2.2.41: repair data NULL di kolom yang drift baca non-null ────────────
// Backup cloud lama bisa punya user_version == schemaVersion (44) tapi baris
// kolom bernilai NULL — kolom dibuat TANPA DEFAULT oleh app versi lama (lihat
// riwayat: discount_percent/discount_type/price_type sempat tanpa DEFAULT).
// Drift memetakan kolom non-nullable dengan `!` → NULL → "Null check operator
// used on a null value" → query throw → layar kosong/loading abadi. beforeOpen
// jalan SETIAP buka (koneksi normal + AppDatabase.at untuk migrasi temp),
// jadi NULL diisi nilainya di sini. Semua statement pakai IFNULL/WHERE untuk
// idempoten — aman dijalankan berulang.
Future<void> _repairNullDefaults(AppDatabase db) async {
  await db.customStatement(
    'UPDATE products SET discount_percent = 0 WHERE discount_percent IS NULL',
  );
  await db.customStatement(
    "UPDATE products SET discount_type = 'persen' WHERE discount_type IS NULL",
  );
  await db.customStatement(
    "UPDATE products SET price_type = 'pcs' WHERE price_type IS NULL",
  );
  await db.customStatement(
    "UPDATE products SET category = 'Lainnya' WHERE category IS NULL",
  );
  // v2.2.44 (B10): is_service ditambah via ALTER tanpa DEFAULT → baris lama
  // NULL. Drift memetakan bool non-nullable → "Null check" saat SELECT. Backfill
  // 0 (barang) — idempoten.
  await db.customStatement(
    'UPDATE products SET is_service = 0 WHERE is_service IS NULL',
  );
  await db.customStatement(
    "UPDATE transactions SET status = 'Normal' WHERE status IS NULL",
  );
  await db.customStatement(
    "UPDATE employees SET role = 'Kasir' WHERE role IS NULL",
  );
  await db.customStatement(
    "UPDATE employees SET status = 'Aktif' WHERE status IS NULL",
  );
  // v2.2.57+114: kolom v2.2.57 (stylist) dibuat LEWAT _ensureColumnExists,
  // bukan hanya backfill NULL. Kenapa penting: v2.2.54 menambah
  // employees.is_service_staff (blok migrasi `from < 48`), lalu v2.2.57+110
  // menambah commission_percent DI BLOK YANG SAMA tanpa menaikkan schemaVersion
  // (tetap 48). Device yang user_version-nya sudah 48 sejak v2.2.54 → upgrade
  // → drift skip onUpgrade (from == 48 == to) → kolom commission_percent TIDAK
  // PERNAH dibuat → getEmployees() throw "no such column" → login loop "Data
  // Ditemukan" (kasus percetakanrks, backup uv=48 + kolom hilang). Sebelumnya
  // cuma UPDATE ... WHERE IS NULL → no-op diam-diam kalau kolom tidak ada.
  await _ensureColumnExists(
    db,
    'employees',
    'is_service_staff',
    'ALTER TABLE employees ADD COLUMN is_service_staff INTEGER',
  );
  await db.customStatement(
    'UPDATE employees SET is_service_staff = 1 WHERE is_service_staff IS NULL',
  );
  await _ensureColumnExists(
    db,
    'employees',
    'commission_percent',
    'ALTER TABLE employees ADD COLUMN commission_percent REAL DEFAULT 10.0',
  );
  await db.customStatement(
    'UPDATE employees SET commission_percent = 10.0 WHERE commission_percent IS NULL',
  );
  // v2.2.57+114: appointments.transaction_id (nullable di drift, tidak crash,
  // tapi aman ditambahkan supaya struktur konsisten untuk seluruh varian).
  await _ensureColumnExists(
    db,
    'appointments',
    'transaction_id',
    'ALTER TABLE appointments ADD COLUMN transaction_id INTEGER',
  );
  await db.customStatement(
    'UPDATE cashier_sessions SET starting_cash = 0 WHERE starting_cash IS NULL',
  );
  // Kolom yang secara teknis nullable di drift TAPI beberapa query memakai
  // operator seperti `.equals(null)` yang bisa error — pastikan default yang
  // aman: invoice/items wajib ada supaya join & parsing JSON tidak jatuh.
  await db.customStatement(
    "UPDATE transactions SET items = '[]' WHERE items IS NULL OR items = ''",
  );
  await db.customStatement(
    "UPDATE products SET name = 'Produk' WHERE name IS NULL OR name = ''",
  );
  await db.customStatement(
    "UPDATE transactions SET invoice = '' WHERE invoice IS NULL",
  );
  await db.customStatement(
    'UPDATE online_orders SET subtotal = 0 WHERE subtotal IS NULL',
  );
  await db.customStatement(
    'UPDATE online_orders SET discount = 0 WHERE discount IS NULL',
  );
  await db.customStatement(
    'UPDATE online_orders SET handling_fee = 0 WHERE handling_fee IS NULL',
  );
  await db.customStatement(
    'UPDATE customer_debts SET amount = 0 WHERE amount IS NULL',
  );
  await db.customStatement(
    'UPDATE customer_debts SET remaining_amount = 0 WHERE remaining_amount IS NULL',
  );
  await db.customStatement(
    'UPDATE debt_payments SET amount = 0 WHERE amount IS NULL',
  );
  // ── Performance indexes ─────────────────────────────────────────────
  // Index untuk mempercepat query yang sering dipakai (filter produk online,
  // transaksi by tanggal, pelanggan by nama/phone). IF NOT EXISTS supaya
  // idempoten — aman dijalankan berulang di beforeOpen.
  await db.customStatement(
    'CREATE INDEX IF NOT EXISTS idx_products_online_cat '
    'ON products(is_online, category, name)',
  );
  await db.customStatement(
    'CREATE INDEX IF NOT EXISTS idx_transactions_date_branch '
    'ON transactions(date, branch_id, employee_id)',
  );
  await db.customStatement(
    'CREATE INDEX IF NOT EXISTS idx_customers_name_phone '
    'ON customers(name, phone)',
  );

  // Tabel yang belum ada di backup lama (mis. open_tabs, roles) — buat kalau
  // hilang. Guard ini hanya berjalan kalau tabel belum ada (idempoten).
  await _createTableIfMissingSafe(db, 'open_tabs');
  await _createTableIfMissingSafe(db, 'roles');
  await _createTableIfMissingSafe(db, 'stock_counts');
  await _createTableIfMissingSafe(db, 'stock_count_items');
  await _createTableIfMissingSafe(db, 'stock_movements');
  await _createTableIfMissingSafe(db, 'point_histories');
  await _createTableIfMissingSafe(db, 'promos');
  await _createTableIfMissingSafe(db, 'recurring_expenses');
  await _createTableIfMissingSafe(db, 'waste');
  await _createTableIfMissingSafe(db, 'sync_queue');
  await _createTableIfMissingSafe(db, 'units');
  await _createTableIfMissingSafe(db, 'product_units');
  await _createTableIfMissingSafe(db, 'raw_materials');
  await _createTableIfMissingSafe(db, 'recipes');
  await _createTableIfMissingSafe(db, 'ingredient_stocks');
}

/// CREATE TABLE IF NOT EXISTS untuk tabel yang mungkin hilang di backup lama
/// (mis. backup varian lain yang masih schema < 40). Query select drift ke
/// tabel yang tidak ada melempar "no such table" — ini mencegahnya.
/// Definisi tabel mengikuti tables.dart (drift) — JANGAN ubah tanpa sinkron.
Future<void> _createTableIfMissingSafe(AppDatabase db, String table) async {
  final exists = await db.customSelect(
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
    variables: [Variable(table)],
  ).get();
  if (exists.isNotEmpty) return;
  switch (table) {
    case 'open_tabs':
      await db.customStatement(
        'CREATE TABLE IF NOT EXISTS open_tabs ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'table_id INTEGER, order_type TEXT, items_json TEXT, total INTEGER, '
        'discount INTEGER, status TEXT, created_at INTEGER, updated_at INTEGER)',
      );
    case 'roles':
      await db.customStatement(
        'CREATE TABLE IF NOT EXISTS roles ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'name TEXT NOT NULL, permissions TEXT, created_at INTEGER)',
      );
    case 'stock_counts':
      await db.customStatement(
        'CREATE TABLE IF NOT EXISTS stock_counts ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, status TEXT, '
        'created_at INTEGER, completed_at INTEGER, total_products INTEGER, '
        'match_count INTEGER, diff_count INTEGER)',
      );
    case 'stock_count_items':
      await db.customStatement(
        'CREATE TABLE IF NOT EXISTS stock_count_items ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, count_session_id INTEGER, '
        'product_id INTEGER, product_name TEXT, system_stock INTEGER, '
        'physical_stock INTEGER, difference INTEGER, buy_price INTEGER, '
        'sell_price INTEGER, notes TEXT)',
      );
    case 'stock_movements':
      await db.customStatement(
        'CREATE TABLE IF NOT EXISTS stock_movements ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, product_id INTEGER, type TEXT, '
        'qty INTEGER, note TEXT, date INTEGER)',
      );
    case 'point_histories':
      await db.customStatement(
        'CREATE TABLE IF NOT EXISTS point_histories ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, customer_id INTEGER, points INTEGER, '
        'type TEXT, note TEXT, created_at INTEGER)',
      );
    case 'promos':
      await db.customStatement(
        'CREATE TABLE IF NOT EXISTS promos ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, code TEXT, type TEXT, '
        'value INTEGER, min_belanja INTEGER, start_date INTEGER, end_date INTEGER, '
        'max_uses INTEGER, used_count INTEGER, status TEXT, mode TEXT)',
      );
    case 'recurring_expenses':
      await db.customStatement(
        'CREATE TABLE IF NOT EXISTS recurring_expenses ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, category TEXT, amount INTEGER, '
        'description TEXT, frequency TEXT, next_date INTEGER, active INTEGER)',
      );
    case 'waste':
      await db.customStatement(
        'CREATE TABLE IF NOT EXISTS waste ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, product_id INTEGER, qty INTEGER, '
        'reason TEXT, type TEXT, date INTEGER)',
      );
    case 'sync_queue':
      await db.customStatement(
        'CREATE TABLE IF NOT EXISTS sync_queue ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, task_type TEXT, payload TEXT, '
        'status TEXT, retry_count INTEGER, error_message TEXT, created_at INTEGER)',
      );
    case 'units':
      await db.customStatement(
        'CREATE TABLE IF NOT EXISTS units ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE, '
        'created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)',
      );
    case 'product_units':
      await db.customStatement(
        'CREATE TABLE IF NOT EXISTS product_units ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, product_id INTEGER NOT NULL, '
        'unit_id INTEGER NOT NULL, qty_per_base REAL NOT NULL DEFAULT 1, '
        'is_base INTEGER NOT NULL DEFAULT 0)',
      );
    case 'raw_materials':
      await db.customStatement(
        'CREATE TABLE IF NOT EXISTS raw_materials ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, '
        'unit_id INTEGER, stock INTEGER NOT NULL DEFAULT 0, '
        'min_stock INTEGER NOT NULL DEFAULT 0, '
        'cost_price INTEGER NOT NULL DEFAULT 0, supplier_id INTEGER, '
        'updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)',
      );
    case 'recipes':
      await db.customStatement(
        'CREATE TABLE IF NOT EXISTS recipes ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, product_id INTEGER NOT NULL, '
        'material_id INTEGER NOT NULL, qty REAL NOT NULL DEFAULT 1)',
      );
    case 'ingredient_stocks':
      await db.customStatement(
        'CREATE TABLE IF NOT EXISTS ingredient_stocks ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, material_id INTEGER NOT NULL, '
        'type TEXT NOT NULL, qty REAL NOT NULL, note TEXT, '
        'date TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)',
      );
  }
}

// ── Self-healing migration guards ──────────────────────────────────────────
// DB hasil restore cloud/backup lama bisa membawa struktur kolom yang SUDAH
// ada padahal `user_version` masih di bawah target (mis. kolom order_type ada
// tapi user_version < 27). Kalau `ALTER TABLE ... ADD COLUMN` dibiarkan jalan,
// SQLite melempar "duplicate column name" → migrasi gagal → seluruh aplikasi
// tidak bisa dipakai. Guard berikut mengecek pragma table_info dulu: kolom
// sudah ada → skip; belum ada → tambah. Idempoten & aman dipanggil ulang.

/// Run [sql] if column [column] does not exist yet in [table].
/// Raw SQL wajib pakai nama kolom SQLite (snake_case), bukan nama Dart.
Future<void> _runIfColumnMissing(
  Migrator m,
  String table,
  String column,
  String sql,
) async {
  final has = await m.database
      .customSelect('PRAGMA table_info($table)')
      .get()
      .then((rows) => rows.any((r) => r.read<String>('name') == column));
  if (!has) {
    await m.database.customStatement(sql);
  }
}

/// `ALTER TABLE [table] ADD COLUMN [column] [sqlType]` — skip jika kolom ada.
/// Drift memetakan nama Dart ke snake_case; [sqlType] contoh: 'TEXT', 'INTEGER'.
Future<void> _addColumnIfMissing(
  Migrator m,
  String table,
  String column,
  String sqlType,
) {
  return _runIfColumnMissing(
    m,
    table,
    column,
    'ALTER TABLE "$table" ADD COLUMN "$column" $sqlType',
  );
}

/// Jalankan [sql] (biasanya ALTER TABLE ... ADD COLUMN) kalau kolom [column]
/// belum ada di [table]. Dipakai dari beforeOpen/_repairNullDefaults yang tidak
/// punya Migrator — versi customStatement dari [_runIfColumnMissing].
/// Idempoten: PRAGMA table_info dulu, skip kalau kolom sudah ada.
Future<void> _ensureColumnExists(
  AppDatabase db,
  String table,
  String column,
  String sql,
) async {
  final has = await db
      .customSelect('PRAGMA table_info($table)')
      .get()
      .then((rows) => rows.any((r) => r.read<String>('name') == column));
  if (!has) {
    await db.customStatement(sql);
  }
}

/// `CREATE TABLE IF NOT EXISTS [name] ([definition])` — tidak error bila ada.
Future<void> _createTableIfMissing(
  Migrator m,
  String name,
  String definition,
) {
  return m.database.customStatement(
    'CREATE TABLE IF NOT EXISTS "$name" ($definition)',
  );
}

/// Backfill [table].[column] dengan [sql] jika kolom ada (setelah
/// [_addColumnIfMissing]). Digunakan untuk data lama yang nilainya kosong.
Future<void> _runIfColumnExists(
  Migrator m,
  String table,
  String column,
  String sql,
) async {
  final has = await m.database
      .customSelect('PRAGMA table_info($table)')
      .get()
      .then((rows) => rows.any((r) => r.read<String>('name') == column));
  if (has) {
    await m.database.customStatement(sql);
  }
}

LazyDatabase _openConnection() {
  return _openConnectionAt(null);
}

/// Buka koneksi drift ke file SQLite tertentu (bukan selalu file live).
/// Dipakai untuk migrasi schema bytes hasil decrypt di _migrateSqliteBytes
/// (activation_repository) — file temp di-migrasi dulu sebelum ditulis ke
/// live. Kalau [path] null → pakai path default nusa_kasir.sqlite.
LazyDatabase _openConnectionAt(String? path) {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = path != null
        ? p.join(dir.path, path)
        : p.join(dir.path, 'nusa_kasir.sqlite');
    return NativeDatabase.createInBackground(File(file));
  });
}
