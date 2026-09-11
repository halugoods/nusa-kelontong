import 'dart:convert';
import 'package:nusa_kasir/core/config/nusa_config.dart';
import 'package:nusa_kasir/core/agent/agent_action_controller.dart';
import 'package:nusa_kasir/data/database/app_database.dart';
import 'package:nusa_kasir/data/repositories/product_repository.dart';
import 'package:nusa_kasir/data/repositories/customer_repository.dart';
import 'package:nusa_kasir/data/repositories/transaction_repository.dart';
import 'package:nusa_kasir/data/repositories/promo_repository.dart';
import 'package:nusa_kasir/data/repositories/finance_repository.dart';
import 'package:nusa_kasir/data/repositories/debt_repository.dart';
import 'package:nusa_kasir/data/repositories/supplier_repository.dart';
import 'package:nusa_kasir/data/repositories/report_repository.dart';
import 'package:nusa_kasir/data/repositories/laundry_order_repository.dart';
import 'package:nusa_kasir/data/repositories/dining_table_repository.dart';
import 'package:nusa_kasir/data/repositories/service_ticket_repository.dart';
import 'package:nusa_kasir/data/repositories/appointment_repository.dart';
import 'package:nusa_kasir/data/repositories/prescription_repository.dart';
import 'package:nusa_kasir/data/repositories/print_order_repository.dart';

/// A tool that the AI agent can call to query data or perform actions.
class AgentTool {
  final String name;
  final String description;
  final Map<String, dynamic> parameters; // JSON Schema for Groq/OpenAI tool calling
  final bool isDestructive;

  /// Execute the tool with the given arguments. Returns a JSON string result.
  final Future<String> Function(AppDatabase db, Map<String, dynamic> args) execute;

  const AgentTool({
    required this.name,
    required this.description,
    required this.parameters,
    required this.execute,
    this.isDestructive = false,
  });

  Map<String, dynamic> toOpenAiTool() => {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': parameters,
        },
      };
}

/// Registry that provides variant-aware tool sets for the AI agent.
class AgentToolRegistry {
  /// Returns all tools available for the currently active variant.
  static List<AgentTool> forVariant() {
    final tools = <AgentTool>[..._universalTools];

    if (NusaConfig.isLaundryVariant) tools.addAll(_laundryTools);
    if (NusaConfig.productId == 'nusa-fnb') tools.addAll(_fnbTools);
    if (NusaConfig.productId == 'nusa-bengkel' || NusaConfig.productId == 'nusa-servis') tools.addAll(_servisTools);
    if (NusaConfig.productId == 'nusa-salon') tools.addAll(_salonTools);
    if (NusaConfig.productId == 'nusa-apotek') tools.addAll(_apotekTools);
    if (NusaConfig.productId == 'nusa-fotocopy') tools.addAll(_fotocopyTools);

    return tools;
  }

  // ═══════════════════════════════════════════════════════════════════
  // UNIVERSAL TOOLS (all 8 variants)
  // ═══════════════════════════════════════════════════════════════════

  static const _universalTools = <AgentTool>[
    AgentTool(
      name: 'get_products',
      description: 'Get all products with name, stock, price, and category. Use when user asks about products, stock, or inventory.',
      parameters: {
        'type': 'object',
        'properties': {
          'search': {'type': 'string', 'description': 'Optional search term to filter by product name'},
        },
      },
      execute: _getProducts,
    ),
    AgentTool(
      name: 'get_low_stock',
      description: 'Get products where stock is below minimum stock threshold (menipis/habis).',
      parameters: {'type': 'object', 'properties': {}},
      execute: _getLowStock,
    ),
    AgentTool(
      name: 'get_customers',
      description: 'Get all customers with name, phone, level, and points.',
      parameters: {
        'type': 'object',
        'properties': {
          'search': {'type': 'string', 'description': 'Optional search term to filter by customer name or phone'},
        },
      },
      execute: _getCustomers,
    ),
    AgentTool(
      name: 'get_summary',
      description: 'Get today\'s sales summary: total revenue (omzet), transaction count, average transaction value.',
      parameters: {'type': 'object', 'properties': {}},
      execute: _getSummary,
    ),
    AgentTool(
      name: 'get_monthly_summary',
      description: 'Get this month\'s sales summary: total revenue and transaction count.',
      parameters: {'type': 'object', 'properties': {}},
      execute: _getMonthlySummary,
    ),
    AgentTool(
      name: 'get_transactions',
      description: 'Get recent transactions (last 20).',
      parameters: {'type': 'object', 'properties': {}},
      execute: _getTransactions,
    ),
    AgentTool(
      name: 'get_top_products',
      description: 'Get top 10 best-selling products this month.',
      parameters: {'type': 'object', 'properties': {}},
      execute: _getTopProducts,
    ),
    AgentTool(
      name: 'get_promos',
      description: 'Get all active promos with name, code, discount value, and usage count.',
      parameters: {'type': 'object', 'properties': {}},
      execute: _getPromos,
    ),
    AgentTool(
      name: 'get_employees',
      description: 'Get all employees with name, role, phone, and status.',
      parameters: {'type': 'object', 'properties': {}},
      execute: _getEmployees,
    ),
    AgentTool(
      name: 'get_attendance',
      description: 'Get today\'s attendance count — how many employees have checked in.',
      parameters: {'type': 'object', 'properties': {}},
      execute: _getAttendance,
    ),
    AgentTool(
      name: 'get_expenses',
      description: 'Get this month\'s expenses by category with amounts.',
      parameters: {'type': 'object', 'properties': {}},
      execute: _getExpenses,
    ),
    AgentTool(
      name: 'get_debts',
      description: 'Get outstanding customer debts (piutang).',
      parameters: {'type': 'object', 'properties': {}},
      execute: _getDebts,
    ),
    AgentTool(
      name: 'get_suppliers',
      description: 'Get all suppliers with name and phone.',
      parameters: {'type': 'object', 'properties': {}},
      execute: _getSuppliers,
    ),

    // ── AI AGENT MUTATION & ACTION TOOLS (App Use) ──
    AgentTool(
      name: 'create_product',
      description: 'Tambah master produk baru secara langsung ke database kasir.',
      isDestructive: true,
      parameters: {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': 'Nama produk'},
          'sell_price': {'type': 'number', 'description': 'Harga jual (Rp)'},
          'buy_price': {'type': 'number', 'description': 'Harga modal / beli (Rp, default 0)'},
          'stock': {'type': 'number', 'description': 'Jumlah stok awal (default 0)'},
          'category': {'type': 'string', 'description': 'Kategori produk'},
          'barcode': {'type': 'string', 'description': 'Barcode / SKU (opsional)'},
        },
        'required': ['name', 'sell_price']
      },
      execute: _createProduct,
    ),
    AgentTool(
      name: 'update_stock',
      description: 'Sesuaikan atau tambah/kurang stok barang produk tertentu.',
      isDestructive: true,
      parameters: {
        'type': 'object',
        'properties': {
          'product_name': {'type': 'string', 'description': 'Nama produk yang akan diubah stoknya'},
          'delta': {'type': 'number', 'description': 'Perubahan stok (+ untuk menambah, - untuk mengurangi)'},
          'reason': {'type': 'string', 'description': 'Alasan penyesuaian (opsional)'},
        },
        'required': ['product_name', 'delta']
      },
      execute: _updateStock,
    ),
    AgentTool(
      name: 'create_customer',
      description: 'Daftarkan data pelanggan / member baru ke toko.',
      isDestructive: true,
      parameters: {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': 'Nama pelanggan'},
          'phone': {'type': 'string', 'description': 'Nomor WhatsApp / telepon'},
          'address': {'type': 'string', 'description': 'Alamat pelanggan (opsional)'},
        },
        'required': ['name']
      },
      execute: _createCustomer,
    ),
  ];

  // ═══════════════════════════════════════════════════════════════════
  // DOMAIN: Laundry
  // ═══════════════════════════════════════════════════════════════════

  static const _laundryTools = <AgentTool>[
    AgentTool(
      name: 'get_laundry_orders',
      description: 'Get laundry orders filtered by status. Statuses: Baru, Cuci, Kering, Setrika, Siap, Diantar, Diambil.',
      parameters: {
        'type': 'object',
        'properties': {
          'status': {'type': 'string', 'description': 'Filter by status. Omit for all orders.'},
        },
      },
      execute: _getLaundryOrders,
    ),
    AgentTool(
      name: 'get_laundry_stats',
      description: 'Get laundry statistics: total orders today, pending, ready for pickup, and delivered.',
      parameters: {'type': 'object', 'properties': {}},
      execute: _getLaundryStats,
    ),
  ];

  // ═══════════════════════════════════════════════════════════════════
  // DOMAIN: F&B
  // ═══════════════════════════════════════════════════════════════════

  static const _fnbTools = <AgentTool>[
    AgentTool(
      name: 'get_tables',
      description: 'Get all dining tables with status (Kosong, Dipesan, Tutup) and capacity.',
      parameters: {'type': 'object', 'properties': {}},
      execute: _getTables,
    ),
    AgentTool(
      name: 'get_open_tabs',
      description: 'Get currently open dining tabs (orders in progress) with item counts and totals.',
      parameters: {'type': 'object', 'properties': {}},
      execute: _getOpenTabs,
    ),
  ];

  // ═══════════════════════════════════════════════════════════════════
  // DOMAIN: Bengkel & Servis
  // ═══════════════════════════════════════════════════════════════════

  static const _servisTools = <AgentTool>[
    AgentTool(
      name: 'get_service_tickets',
      description: 'Get service/repair tickets filtered by status. Statuses for Bengkel: Diagnosa, Estimasi, Perbaikan, Selesai, Diambil.',
      parameters: {
        'type': 'object',
        'properties': {
          'status': {'type': 'string', 'description': 'Filter by status. Omit for all tickets.'},
        },
      },
      execute: _getServiceTickets,
    ),
  ];

  // ═══════════════════════════════════════════════════════════════════
  // DOMAIN: Salon
  // ═══════════════════════════════════════════════════════════════════

  static const _salonTools = <AgentTool>[
    AgentTool(
      name: 'get_appointments',
      description: 'Get salon appointments filtered by status. Statuses: Dikonfirmasi, Datang, Menunggu, Selesai, Batal.',
      parameters: {
        'type': 'object',
        'properties': {
          'status': {'type': 'string', 'description': 'Filter by status. Omit for all appointments.'},
        },
      },
      execute: _getAppointments,
    ),
    AgentTool(
      name: 'get_booking_stats',
      description: 'Get salon booking statistics: total today, confirmed, arrived, waiting, completed.',
      parameters: {'type': 'object', 'properties': {}},
      execute: _getBookingStats,
    ),
  ];

  // ═══════════════════════════════════════════════════════════════════
  // DOMAIN: Apotek
  // ═══════════════════════════════════════════════════════════════════

  static const _apotekTools = <AgentTool>[
    AgentTool(
      name: 'get_prescriptions',
      description: 'Get prescriptions filtered by status. Statuses: Baru, Diproses, Siap, Diambil.',
      parameters: {
        'type': 'object',
        'properties': {
          'status': {'type': 'string', 'description': 'Filter by status. Omit for all prescriptions.'},
        },
      },
      execute: _getPrescriptions,
    ),
  ];

  // ═══════════════════════════════════════════════════════════════════
  // DOMAIN: Fotocopy
  // ═══════════════════════════════════════════════════════════════════

  static const _fotocopyTools = <AgentTool>[
    AgentTool(
      name: 'get_print_orders',
      description: 'Get print/copy orders filtered by status or service type. Statuses: Baru, Diproses, Selesai, Diambil. Types: Fotocopy, Print Warna, Print B/W, Jilid, Laminating, Scan.',
      parameters: {
        'type': 'object',
        'properties': {
          'status': {'type': 'string', 'description': 'Filter by status.'},
          'type': {'type': 'string', 'description': 'Filter by service type.'},
        },
      },
      execute: _getPrintOrders,
    ),
  ];

  // ── Tool Implementations ──────────────────────────────────────────

  static Future<String> _getProducts(AppDatabase db, Map<String, dynamic> args) async {
    final products = await ProductRepository(db).getProducts();
    final search = args['search'] as String?;
    final filtered = search != null && search.isNotEmpty
        ? products.where((p) => p.name.toLowerCase().contains(search.toLowerCase())).toList()
        : products;
    final list = filtered.map((p) => {
      'name': p.name,
      'category': p.category,
      'price': p.sellPrice,
      'stock': p.stock,
      'status': p.stock == 0 ? 'HABIS' : p.stock <= p.minStock ? 'MENIPIS' : 'Aktif',
    }).toList();
    return jsonEncode({'total': filtered.length, 'products': list});
  }

  static Future<String> _getLowStock(AppDatabase db, Map<String, dynamic> args) async {
    final products = await ProductRepository(db).getProducts();
    final low = products.where((p) => p.stock <= p.minStock && p.minStock > 0).toList();
    final list = low.map((p) => {
      'name': p.name, 'category': p.category, 'stock': p.stock, 'minStock': p.minStock,
      'status': p.stock == 0 ? 'HABIS' : 'MENIPIS',
    }).toList();
    return jsonEncode({'total': low.length, 'products': list});
  }

  static Future<String> _getCustomers(AppDatabase db, Map<String, dynamic> args) async {
    final customers = await CustomerRepository(db).getCustomers();
    final search = args['search'] as String?;
    final filtered = search != null && search.isNotEmpty
        ? customers.where((c) => c.name.toLowerCase().contains(search.toLowerCase()) || (c.phone?.contains(search) ?? false)).toList()
        : customers;
    final list = filtered.map((c) => {
      'name': c.name, 'phone': c.phone, 'level': c.level, 'points': c.points,
    }).toList();
    return jsonEncode({'total': filtered.length, 'customers': list});
  }

  static Future<String> _getSummary(AppDatabase db, Map<String, dynamic> args) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final reportRepo = ReportRepository(db);
    final sum = await reportRepo.summary(from: today, to: now);
    return jsonEncode({
      'revenue': sum['omzet'] ?? 0,
      'transaction_count': sum['count'] ?? 0,
      'average': sum['avg'] ?? 0,
      'date': '${today.day}/${today.month}/${today.year}',
    });
  }

  static Future<String> _getMonthlySummary(AppDatabase db, Map<String, dynamic> args) async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, 1);
    final reportRepo = ReportRepository(db);
    final sum = await reportRepo.summary(from: start, to: now);
    return jsonEncode({
      'monthly_revenue': sum['omzet'] ?? 0,
      'transaction_count': sum['count'] ?? 0,
      'month': '${now.month}/${now.year}',
    });
  }

  static Future<String> _getTransactions(AppDatabase db, Map<String, dynamic> args) async {
    final txns = await TransactionRepository(db).getTransactions();
    final recent = txns.take(20).toList();
    final list = recent.map((t) => {
      'id': t.id, 'total': t.total, 'payment_method': t.paymentMethod,
      'date': '${t.date.day}/${t.date.month}/${t.date.year}',
      'customer_id': t.customerId,
    }).toList();
    return jsonEncode({'total': recent.length, 'transactions': list});
  }

  static Future<String> _getTopProducts(AppDatabase db, Map<String, dynamic> args) async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, 1);
    final reportRepo = ReportRepository(db);
    final top = await reportRepo.topProducts(from: start, to: now, limit: 10);
    return jsonEncode({'products': top});
  }

  static Future<String> _getPromos(AppDatabase db, Map<String, dynamic> args) async {
    final promos = await PromoRepository(db).getPromos();
    final active = promos.where((p) => p.status == 'Aktif').toList();
    final list = active.map((p) => {
      'name': p.name, 'code': p.code, 'type': p.type, 'value': p.value,
      'used_count': p.usedCount,
    }).toList();
    return jsonEncode({'total': active.length, 'promos': list});
  }

  static Future<String> _getEmployees(AppDatabase db, Map<String, dynamic> args) async {
    final emps = await (db.select(db.employees)).get();
    final list = emps.map((e) => {'name': e.name, 'role': e.role, 'phone': e.phone, 'status': e.status}).toList();
    return jsonEncode({'total': emps.length, 'employees': list});
  }

  static Future<String> _getAttendance(AppDatabase db, Map<String, dynamic> args) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final att = await (db.select(db.attendance)).get();
    final todayAtt = att.where((a) => a.date.year == today.year && a.date.month == today.month && a.date.day == today.day).toList();
    return jsonEncode({'present_today': todayAtt.length, 'date': '${today.day}/${today.month}/${today.year}'});
  }

  static Future<String> _getExpenses(AppDatabase db, Map<String, dynamic> args) async {
    final financeRepo = FinanceRepository(db);
    final summary = await financeRepo.getDashboardSummary();
    return jsonEncode({
      'total_expense': summary['totalExpense'] ?? 0,
      'total_income': summary['totalIncome'] ?? 0,
    });
  }

  static Future<String> _getDebts(AppDatabase db, Map<String, dynamic> args) async {
    final debts = await DebtRepository(db).getAllDebts();
    final outstanding = debts.where((d) => d.remainingAmount > 0).toList();
    final list = outstanding.map((d) => {
      'customer': d.customerName, 'total': d.amount, 'remaining': d.remainingAmount,
    }).toList();
    return jsonEncode({'total': outstanding.length, 'debts': list});
  }

  static Future<String> _getSuppliers(AppDatabase db, Map<String, dynamic> args) async {
    final suppliers = await SupplierRepository(db).getSuppliers();
    final list = suppliers.map((s) => {'name': s.name, 'phone': s.phone}).toList();
    return jsonEncode({'total': suppliers.length, 'suppliers': list});
  }

  // ── Domain Implementations ────────────────────────────────────────

  static Future<String> _getLaundryOrders(AppDatabase db, Map<String, dynamic> args) async {
    final repo = LaundryOrderRepository(db);
    final orders = await repo.getAll();
    final status = args['status'] as String?;
    final filtered = status != null && status.isNotEmpty
        ? orders.where((o) => o.status == status).toList()
        : orders;
    final list = filtered.take(20).map((o) => {
      'id': o.id, 'customer': o.customerName, 'status': o.status,
      'total': o.total,
    }).toList();
    return jsonEncode({'total': filtered.length, 'orders': list});
  }

  static Future<String> _getLaundryStats(AppDatabase db, Map<String, dynamic> args) async {
    final repo = LaundryOrderRepository(db);
    final today = await repo.countToday();
    final pending = await repo.countPending();
    final ready = await repo.countByStatus('Siap');
    final delivered = await repo.countByStatus('Diambil');
    return jsonEncode({'today': today, 'pending': pending, 'ready': ready, 'delivered': delivered});
  }

  static Future<String> _getTables(AppDatabase db, Map<String, dynamic> args) async {
    final repo = DiningTableRepository(db);
    final tables = await repo.getAll();
    final list = tables.map((t) => {'name': t.name, 'capacity': t.capacity, 'status': t.status}).toList();
    final occupied = tables.where((t) => t.status == 'Dipesan').length;
    return jsonEncode({'total': tables.length, 'occupied': occupied, 'available': tables.length - occupied, 'tables': list});
  }

  static Future<String> _getOpenTabs(AppDatabase db, Map<String, dynamic> args) async {
    final tabs = await (db.select(db.openTabs)).get();
    final list = tabs.map((t) => {
      'table_id': t.tableId, 'total': t.total, 'status': t.status,
    }).toList();
    return jsonEncode({'total': tabs.length, 'tabs': list});
  }

  static Future<String> _getServiceTickets(AppDatabase db, Map<String, dynamic> args) async {
    final repo = ServiceTicketRepository(db);
    final tickets = await repo.getAll();
    final status = args['status'] as String?;
    final filtered = status != null && status.isNotEmpty
        ? tickets.where((t) => t.status == status).toList()
        : tickets;
    final list = filtered.take(20).map((t) => {
      'id': t.id, 'customer': t.customerName, 'device': t.deviceName,
      'status': t.status, 'estimated_cost': t.estimatedCost,
    }).toList();
    return jsonEncode({'total': filtered.length, 'tickets': list});
  }

  static Future<String> _getAppointments(AppDatabase db, Map<String, dynamic> args) async {
    final repo = AppointmentRepository(db);
    final appointments = await repo.getAll();
    final status = args['status'] as String?;
    final filtered = status != null && status.isNotEmpty
        ? appointments.where((a) => a.status == status).toList()
        : appointments;
    final list = filtered.take(20).map((a) => {
      'id': a.id, 'customer': a.customerName, 'service': a.service,
      'status': a.status, 'date': '${a.date.day}/${a.date.month}/${a.date.year}',
    }).toList();
    return jsonEncode({'total': filtered.length, 'appointments': list});
  }

  static Future<String> _getBookingStats(AppDatabase db, Map<String, dynamic> args) async {
    final repo = AppointmentRepository(db);
    final all = await repo.getAll();
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    final today = all.where((a) => a.date.isAfter(now.subtract(const Duration(days: 1))) && a.date.isBefore(tomorrow)).length;
    final confirmed = all.where((a) => a.status == 'Dikonfirmasi').length;
    final arrived = all.where((a) => a.status == 'Datang').length;
    final waiting = all.where((a) => a.status == 'Menunggu').length;
    final done = all.where((a) => a.status == 'Selesai').length;
    return jsonEncode({
      'today': today, 'confirmed': confirmed, 'arrived': arrived,
      'waiting': waiting, 'done': done, 'total': all.length,
    });
  }

  static Future<String> _getPrescriptions(AppDatabase db, Map<String, dynamic> args) async {
    final repo = PrescriptionRepository(db);
    final prescriptions = await repo.getAll();
    final status = args['status'] as String?;
    final filtered = status != null && status.isNotEmpty
        ? prescriptions.where((p) => p.status == status).toList()
        : prescriptions;
    final list = filtered.take(20).map((p) => {
      'id': p.id, 'patient': p.patientName, 'doctor': p.doctorName,
      'status': p.status,
    }).toList();
    return jsonEncode({'total': filtered.length, 'prescriptions': list});
  }

  static Future<String> _getPrintOrders(AppDatabase db, Map<String, dynamic> args) async {
    final repo = PrintOrderRepository(db);
    var orders = await repo.getAll();
    final status = args['status'] as String?;
    final type = args['type'] as String?;
    if (status != null && status.isNotEmpty) {
      orders = orders.where((o) => o.status == status).toList();
    }
    if (type != null && type.isNotEmpty) {
      orders = orders.where((o) => o.serviceType == type).toList();
    }
    final list = orders.take(20).map((o) => {
      'id': o.id, 'customer': o.customerName, 'service_type': o.serviceType,
      'status': o.status, 'pages': o.pages, 'total': o.total,
    }).toList();
    return jsonEncode({'total': orders.length, 'orders': list});
  }

  // ── Mutating Tool Implementations (Live Action Simulation) ──

  static Future<String> _createProduct(AppDatabase db, Map<String, dynamic> args) async {
    final name = (args['name'] as String?)?.trim() ?? '';
    final sellPrice = (args['sell_price'] as num?)?.toInt() ?? 0;
    final buyPrice = (args['buy_price'] as num?)?.toInt() ?? 0;
    final stock = (args['stock'] as num?)?.toInt() ?? 0;
    final category = (args['category'] as String?)?.trim() ?? 'Umum';
    final barcode = args['barcode'] as String?;

    if (name.isEmpty || sellPrice <= 0) {
      return jsonEncode({'status': 'error', 'message': 'Nama dan harga jual wajib diisi'});
    }

    // Visual typing simulation
    await AgentActionController.I.simulateTyping(targetField: 'Nama Produk', textToType: name);
    await AgentActionController.I.simulateTyping(targetField: 'Harga Jual', textToType: '$sellPrice');

    final repo = ProductRepository(db);
    final id = await repo.addProduct(
      name: name,
      category: category,
      buyPrice: buyPrice,
      sellPrice: sellPrice,
      stock: stock,
      minStock: 5,
      barcode: barcode,
    );

    AgentActionController.I.finishAction('Produk "$name" berhasil ditambahkan');
    return jsonEncode({
      'status': 'success',
      'id': id,
      'message': 'Produk $name (Rp $sellPrice) berhasil ditambahkan dengan stok $stock'
    });
  }

  static Future<String> _updateStock(AppDatabase db, Map<String, dynamic> args) async {
    final productName = (args['product_name'] as String?)?.trim() ?? '';
    final delta = (args['delta'] as num?)?.toInt() ?? 0;
    final reason = args['reason'] as String? ?? 'Penyesuaian AI Agent';

    if (productName.isEmpty || delta == 0) {
      return jsonEncode({'status': 'error', 'message': 'Nama produk dan jumlah perubahan wajib diisi'});
    }

    final repo = ProductRepository(db);
    final products = await repo.getProducts();
    final p = products.where((item) => item.name.toLowerCase().contains(productName.toLowerCase())).firstOrNull;

    if (p == null) {
      return jsonEncode({'status': 'error', 'message': 'Produk "$productName" tidak ditemukan'});
    }

    // Visual pointer feedback
    AgentActionController.I.emitAction('Menyesuaikan Stok', detail: '${p.name} (${delta > 0 ? "+$delta" : "$delta"})');
    await Future.delayed(const Duration(milliseconds: 600));

    await repo.adjustStock(p.id, delta);
    AgentActionController.I.finishAction('Stok ${p.name} diperbarui');

    return jsonEncode({
      'status': 'success',
      'product': p.name,
      'old_stock': p.stock,
      'new_stock': p.stock + delta,
      'reason': reason,
    });
  }

  static Future<String> _createCustomer(AppDatabase db, Map<String, dynamic> args) async {
    final name = (args['name'] as String?)?.trim() ?? '';
    final phone = (args['phone'] as String?)?.trim();
    final address = (args['address'] as String?)?.trim();

    if (name.isEmpty) {
      return jsonEncode({'status': 'error', 'message': 'Nama pelanggan wajib diisi'});
    }

    await AgentActionController.I.simulateTyping(targetField: 'Nama Pelanggan', textToType: name);
    if (phone != null && phone.isNotEmpty) {
      await AgentActionController.I.simulateTyping(targetField: 'WhatsApp / No HP', textToType: phone);
    }

    final repo = CustomerRepository(db);
    final id = await repo.addCustomer(name: name, phone: phone, address: address);
    AgentActionController.I.finishAction('Pelanggan "$name" berhasil terdaftar');

    return jsonEncode({
      'status': 'success',
      'id': id,
      'message': 'Pelanggan $name ($phone) berhasil disimpan'
    });
  }
}
