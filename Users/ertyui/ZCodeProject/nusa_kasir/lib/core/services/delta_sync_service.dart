import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:nusa_kasir/core/cloud/cloud_gateway.dart';
import 'package:nusa_kasir/core/services/image_storage_service.dart';
import 'package:nusa_kasir/core/services/realtime_sync_service.dart';
import 'package:nusa_kasir/core/utils/secure_storage.dart';
import 'package:nusa_kasir/data/database/app_database.dart';

/// Delta sync event for UI refresh.
class DeltaEvent {
  final String table;
  final String recordId;
  final String operation;
  final DateTime at;
  DeltaEvent({
    required this.table,
    required this.recordId,
    required this.operation,
    DateTime? at,
  }) : at = at ?? DateTime.now();
}

/// Delta sync service — captures local changes, pushes to cloud, applies
/// remote deltas. Complements the file-based backup/restore with a
/// row-level sync channel so multi-device edits converge within seconds.
///
/// v2.2.57+131 (Milestone D): app-side delta sync. Reuses the existing
/// SyncQueue table (dormant since early versions) as the local outbox.
class DeltaSyncService {
  DeltaSyncService._();
  static final DeltaSyncService I = DeltaSyncService._();

  static const _pushDebounce = Duration(seconds: 2);
  static const _pullInterval = Duration(seconds: 30);
  static const _maxBatchSize = 50;

  final _controller = StreamController<DeltaEvent>.broadcast();
  Stream<DeltaEvent> get stream => _controller.stream;

  AppDatabase? _db;
  bool _started = false;
  Timer? _pushTimer;
  Timer? _periodicPull;
  String? _deviceId;
  String? _uid;

  Future<void> start(AppDatabase db) async {
    if (_started) return;
    _started = true;
    _db = db;
    _deviceId = await SecureStore.getDeviceId();
    _uid = await SecureStore.resolveCanonicalUid();

    // Register device with cloud
    await _registerDevice();

    // Listen for remote sync events (from WS backup_updated channel)
    try {
      RealtimeSyncService.I.stream.listen((_) => _pull());
    } catch (_) {}

    // Fallback periodic pull
    _periodicPull = Timer.periodic(_pullInterval, (_) => _pull());
  }

  Future<void> _registerDevice() async {
    if (_uid == null || _deviceId == null) return;
    try {
      await CloudGateway.shared.invoke('sync-delta', body: {
        'action': 'register-device',
        'device_id': _deviceId,
        'device_name': 'Flutter Device',
        'uid': _uid!,
        'google_user_id': _uid!,
      });
    } catch (_) {}
  }

  /// Call this from saveTransaction, product save, etc. to announce a
  /// local change so other devices can pull it within seconds.
  Future<void> pushDelta({
    required String table,
    required String recordId,
    required String operation, // INSERT, UPDATE, DELETE
    Map<String, dynamic>? data,
  }) async {
    if (_db == null || _uid == null) return;

    final delta = {
      'id': _uuid(),
      'table': table,
      'record_id': recordId,
      'operation': operation,
      'data': data != null ? jsonEncode(data) : null,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'device_id': _deviceId,
    };

    // Save to local SyncQueue outbox
    await _db!.into(_db!.syncQueue).insert(
          SyncQueueCompanion.insert(
            taskType: 'delta_push',
            payload: jsonEncode(delta),
          ),
        );

    // Debounced push
    _pushTimer?.cancel();
    _pushTimer = Timer(_pushDebounce, _flushPending);
  }

  Future<void> _flushPending() async {
    if (_db == null) return;

    final pending = await (_db!.select(_db!.syncQueue)
          ..where((t) =>
              t.status.equals('pending') & t.taskType.equals('delta_push'))
          ..limit(_maxBatchSize))
        .get();

    if (pending.isEmpty) return;

    final deltas = pending.map((row) {
      final payload = jsonDecode(row.payload) as Map<String, dynamic>;
      return payload;
    }).toList();

    try {
      final result = await CloudGateway.shared.invoke('sync-delta', body: {
        'action': 'push',
        'deltas': deltas,
        'uid': _uid!,
        'google_user_id': _uid!,
      });

      if (result.ok) {
        // Mark as pushed
        for (final row in pending) {
          await (_db!.update(_db!.syncQueue)
                ..where((t) => t.id.equals(row.id)))
              .write(const SyncQueueCompanion(status: Value('pushed')));
        }
      }
    } catch (e) {
      debugPrint('[DeltaSync] push error: $e');
    }
  }

  Future<void> _pull() async {
    if (_db == null || _uid == null) return;

    try {
      final lastPull = await SecureStore.getLastDeltaPull();
      final result = await CloudGateway.shared.invoke('sync-delta', body: {
        'action': 'pull',
        'since': lastPull?.toIso8601String(),
        'uid': _uid!,
        'google_user_id': _uid!,
      });

      if (!result.ok) return;

      final data = result.data;
      if (data is! Map) return;

      final deltas = (data['deltas'] as List?) ?? [];
      final deltaIds = <String>[];

      for (final d in deltas) {
        if (d is! Map) continue;
        final delta = Map<String, dynamic>.from(d);
        await _applyDelta(delta);
        deltaIds.add(delta['id'] as String? ?? '');
      }

      // Ack received deltas
      if (deltaIds.isNotEmpty) {
        await CloudGateway.shared.invoke('sync-delta', body: {
          'action': 'ack',
          'delta_ids': deltaIds,
          'uid': _uid!,
          'google_user_id': _uid!,
        });
      }

      await SecureStore.setLastDeltaPull(DateTime.now().toUtc());
    } catch (e) {
      debugPrint('[DeltaSync] pull error: $e');
    }
  }

  Future<void> _applyDelta(Map<String, dynamic> delta) async {
    if (_db == null) return;

    final table = delta['table'] as String? ?? '';
    final recordId = delta['record_id'] as String? ?? '';
    final operation = delta['operation'] as String? ?? '';
    final dataStr = delta['data'] as String?;

    try {
      switch (operation) {
        case 'INSERT':
        case 'UPDATE':
          if (dataStr != null) {
            final data = jsonDecode(dataStr) as Map<String, dynamic>;
            await _upsertRecord(table, recordId, data);
          }
          break;
        case 'DELETE':
          await _deleteRecord(table, recordId);
          break;
      }

      // Notify UI
      _controller.add(DeltaEvent(
        table: table,
        recordId: recordId,
        operation: operation,
      ));
    } catch (e) {
      debugPrint('[DeltaSync] apply error for $table/$recordId: $e');
    }
  }

  Future<void> _upsertRecord(
    String table,
    String recordId,
    Map<String, dynamic> data,
  ) async {
    try {
      switch (table) {
        case 'products':
          final companion = _mapToProduct(data);
          await _db!.into(_db!.products).insertOnConflictUpdate(companion);
          // Download image from cloud if product has image_path but local file missing
          final imgPath = data['image_path'] as String?;
          if (imgPath != null && imgPath.isNotEmpty) {
            final file = File(imgPath);
            if (!await file.exists()) {
              _hydrateProductImage(recordId, imgPath);
            }
          }
          break;
        case 'transactions':
          final companion = _mapToTransaction(data);
          await _db!.into(_db!.transactions).insertOnConflictUpdate(companion);
          break;
        case 'categories':
          await _upsertCategory(data);
          break;
        case 'customers':
          final companion = _mapToCustomer(data);
          await _db!.into(_db!.customers).insertOnConflictUpdate(companion);
          break;
        case 'roles':
          final companion = _mapToRole(data);
          await _db!.into(_db!.roles).insertOnConflictUpdate(companion);
          break;
        case 'employees':
          final companion = _mapToEmployee(data);
          await _db!.into(_db!.employees).insertOnConflictUpdate(companion);
          break;
        case 'branches':
          final companion = _mapToBranch(data);
          await _db!.into(_db!.branches).insertOnConflictUpdate(companion);
          break;
        case 'promos':
          final companion = _mapToPromo(data);
          await _db!.into(_db!.promos).insertOnConflictUpdate(companion);
          break;
        case 'suppliers':
          final companion = _mapToSupplier(data);
          await _db!.into(_db!.suppliers).insertOnConflictUpdate(companion);
          break;
        case 'customer_debts':
          final companion = _mapToDebt(data);
          await _db!.into(_db!.customerDebts).insertOnConflictUpdate(companion);
          break;
        case 'expenses':
          final companion = _mapToExpense(data);
          await _db!.into(_db!.expenses).insertOnConflictUpdate(companion);
          break;
        case 'liquidity':
          final companion = _mapToLiquidity(data);
          await _db!.into(_db!.liquidity).insertOnConflictUpdate(companion);
          break;
        case 'attendance':
          final companion = _mapToAttendance(data);
          await _db!.into(_db!.attendance).insertOnConflictUpdate(companion);
          break;
        case 'online_orders':
          final companion = _mapToOnlineOrder(data);
          await _db!.into(_db!.onlineOrders).insertOnConflictUpdate(companion);
          break;
        case 'settings':
          await _applySettingsDelta(data);
          break;
        case 'waste':
          await _db!.into(_db!.waste).insertOnConflictUpdate(_mapToWaste(data));
          break;
        case 'payroll':
          await _db!.into(_db!.payroll).insertOnConflictUpdate(_mapToPayroll(data));
          break;
        case 'recurring_expenses':
          await _db!.into(_db!.recurringExpenses).insertOnConflictUpdate(_mapToRecurring(data));
          break;
        case 'expense_categories':
          final ecId = data['id'] as int? ?? 0;
          final ecName = data['name'] as String? ?? '';
          if (ecName.isEmpty) break;
          final ec = await (_db!.select(_db!.expenseCategories)
                ..where((t) => t.id.equals(ecId)))
              .getSingleOrNull();
          if (ec == null && ecId > 0) {
            await _db!.into(_db!.expenseCategories)
                .insert(ExpenseCategoriesCompanion.insert(name: ecName));
          }
          break;
        case 'debt_payments':
          await _db!.into(_db!.debtPayments).insertOnConflictUpdate(_mapToDebtPayment(data));
          break;
        case 'purchase_orders':
          await _db!.into(_db!.purchaseOrders).insertOnConflictUpdate(_mapToPurchaseOrder(data));
          break;
        case 'stock_counts':
          await _db!.into(_db!.stockCounts).insertOnConflictUpdate(_mapToStockCount(data));
          break;
        case 'stock_count_items':
          await _db!.into(_db!.stockCountItems).insertOnConflictUpdate(_mapToStockCountItem(data));
          break;
        case 'print_orders':
          await _db!.into(_db!.printOrders).insertOnConflictUpdate(_mapToPrintOrder(data));
          break;
        case 'point_histories':
          await _db!.into(_db!.pointHistories).insertOnConflictUpdate(_mapToPointHistory(data));
          break;
      }
    } catch (_) {
      // Non-fatal — delta apply failure should not break the app
    }
  }

  Future<void> _deleteRecord(String table, String recordId) async {
    final id = int.tryParse(recordId);

    try {
      switch (table) {
        case 'products':
          if (id == null) return;
          await (_db!.delete(_db!.products)..where((t) => t.id.equals(id))).go();
          break;
        case 'categories':
          // recordId = nama kategori (bukan int)
          await (_db!.delete(_db!.categories)..where((t) => t.name.equals(recordId)))
              .go();
          break;
        case 'customers':
          if (id == null) return;
          await (_db!.delete(_db!.customers)..where((t) => t.id.equals(id)))
              .go();
          break;
        case 'roles':
          await (_db!.delete(_db!.roles)..where((t) => t.name.equals(recordId)))
              .go();
          break;
        case 'employees':
          if (id == null) return;
          await (_db!.delete(_db!.employees)..where((t) => t.id.equals(id)))
              .go();
          break;
        case 'branches':
          if (id == null) return;
          await (_db!.delete(_db!.branches)..where((t) => t.id.equals(id))).go();
          break;
        case 'promos':
          if (id == null) return;
          await (_db!.delete(_db!.promos)..where((t) => t.id.equals(id))).go();
          break;
        case 'suppliers':
          if (id == null) return;
          await (_db!.delete(_db!.suppliers)..where((t) => t.id.equals(id))).go();
          break;
        case 'customer_debts':
          if (id == null) return;
          await (_db!.delete(_db!.customerDebts)..where((t) => t.id.equals(id))).go();
          break;
        case 'expenses':
          if (id == null) return;
          await (_db!.delete(_db!.expenses)..where((t) => t.id.equals(id))).go();
          break;
        case 'liquidity':
          if (id == null) return;
          await (_db!.delete(_db!.liquidity)..where((t) => t.id.equals(id))).go();
          break;
        case 'print_orders':
          if (id == null) return;
          await (_db!.delete(_db!.printOrders)..where((t) => t.id.equals(id))).go();
          break;
      }
    } catch (_) {}
  }

  // ── Mapping helpers — convert JSON map to Drift companion ──────────────

  ProductsCompanion _mapToProduct(Map<String, dynamic> data) {
    return ProductsCompanion(
      id: Value(data['id'] as int? ?? 0),
      name: Value(data['name'] as String? ?? ''),
      sku: Value(data['sku'] as String?),
      barcode: Value(data['barcode'] as String?),
      category: Value(data['category'] as String? ?? 'Lainnya'),
      buyPrice: Value(data['buy_price'] as int? ?? 0),
      sellPrice: Value(data['sell_price'] as int? ?? 0),
      stock: Value(data['stock'] as int? ?? 0),
      imagePath: Value(data['image_path'] as String?),
      isOnline: Value(data['is_online'] as bool? ?? false),
      isService: Value(data['is_service'] as bool? ?? false),
    );
  }

  TransactionsCompanion _mapToTransaction(Map<String, dynamic> data) {
    return TransactionsCompanion(
      id: Value(data['id'] as int? ?? 0),
      invoice: Value(data['invoice'] as String? ?? ''),
      total: Value(data['total'] as int? ?? 0),
      items: Value(data['items'] as String? ?? '[]'),
      paymentMethod: Value(data['payment_method'] as String? ?? 'tunai'),
      date: Value(data['date'] != null
          ? DateTime.fromMillisecondsSinceEpoch(data['date'] as int)
          : DateTime.now()),
    );
  }

  /// Kategori push pakai recordId = NAMA (bukan id autoincrement), jadi
  /// id tidak dikirim — cari existing by name untuk upsert konsisten.
  Future<void> _upsertCategory(Map<String, dynamic> data) async {
    final name = data['name'] as String? ?? '';
    if (name.isEmpty) return;
    final existing = await (_db!.select(_db!.categories)
          ..where((t) => t.name.equals(name)))
        .getSingleOrNull();
    if (existing == null) {
      await _db!.into(_db!.categories)
          .insert(CategoriesCompanion.insert(name: name));
    }
  }

  CategoriesCompanion _mapToCategory(Map<String, dynamic> data) {
    return CategoriesCompanion(
      id: Value(data['id'] as int? ?? 0),
      name: Value(data['name'] as String? ?? ''),
    );
  }

  CustomersCompanion _mapToCustomer(Map<String, dynamic> data) {
    return CustomersCompanion(
      id: Value(data['id'] as int? ?? 0),
      name: Value(data['name'] as String? ?? ''),
      phone: Value(data['phone'] as String?),
    );
  }

  RolesCompanion _mapToRole(Map<String, dynamic> data) {
    final color = data['color'] as int? ?? 0xFF3B82F6;
    final access = data['access'] as List<dynamic>? ?? ['home'];
    return RolesCompanion(
      name: Value(data['name'] as String? ?? ''),
      color: Value(color.toRadixString(16)),
      accessJson: Value(jsonEncode(access)),
    );
  }

  EmployeesCompanion _mapToEmployee(Map<String, dynamic> data) {
    return EmployeesCompanion(
      id: Value(data['id'] as int? ?? 0),
      name: Value(data['name'] as String? ?? ''),
      pin: Value(data['pin'] as String? ?? ''),
      role: Value(data['role'] as String? ?? ''),
      phone: Value(data['phone'] as String?),
      photoPath: Value(data['photo_path'] as String?),
      status: Value(data['status'] as String?),
      branchId: Value(data['branch_id'] as int?),
      isServiceStaff: Value(data['is_service_staff'] as bool? ?? true),
      commissionPercent: Value(data['commission_percent'] as double? ?? 10.0),
    );
  }

  // ── Mappers tabel tambahan (sync semua perubahan data) ────────────────

  BranchesCompanion _mapToBranch(Map<String, dynamic> data) {
    return BranchesCompanion(
      id: Value(data['id'] as int? ?? 0),
      name: Value(data['name'] as String? ?? ''),
      address: Value(data['address'] as String?),
      phone: Value(data['phone'] as String?),
      status: Value(data['status'] as String? ?? 'Aktif'),
    );
  }

  PromosCompanion _mapToPromo(Map<String, dynamic> data) {
    return PromosCompanion(
      id: Value(data['id'] as int? ?? 0),
      name: Value(data['name'] as String? ?? ''),
      code: Value(data['code'] as String? ?? ''),
      type: Value(data['type'] as String? ?? 'persen'),
      value: Value(data['value'] as int? ?? 0),
      minBelanja: Value(data['minBelanja'] as int? ?? 0),
      startDate: Value(data['startDate'] != null
          ? DateTime.tryParse(data['startDate'] as String)
          : null),
      endDate: Value(data['endDate'] != null
          ? DateTime.tryParse(data['endDate'] as String)
          : null),
      maxUses: Value(data['maxUses'] as int?),
      usedCount: Value(data['usedCount'] as int? ?? 0),
      status: Value(data['status'] as String? ?? 'Aktif'),
      mode: Value(data['mode'] as String? ?? 'otomatis'),
    );
  }

  SuppliersCompanion _mapToSupplier(Map<String, dynamic> data) {
    return SuppliersCompanion(
      id: Value(data['id'] as int? ?? 0),
      name: Value(data['name'] as String? ?? ''),
      phone: Value(data['phone'] as String?),
      address: Value(data['address'] as String?),
      contactPerson: Value(data['contactPerson'] as String?),
      note: Value(data['note'] as String?),
    );
  }

  CustomerDebtsCompanion _mapToDebt(Map<String, dynamic> data) {
    return CustomerDebtsCompanion(
      id: Value(data['id'] as int? ?? 0),
      customerId: Value(data['customerId'] as int? ?? 0),
      customerName: Value(data['customerName'] as String? ?? ''),
      amount: Value(data['amount'] as int? ?? 0),
      remainingAmount: Value(data['remainingAmount'] as int? ?? 0),
      description: Value(data['description'] as String?),
      debtDate: Value(data['debtDate'] != null
          ? DateTime.tryParse(data['debtDate'] as String) ?? DateTime.now()
          : DateTime.now()),
      dueDate: Value(data['dueDate'] != null
          ? DateTime.tryParse(data['dueDate'] as String)
          : null),
      status: Value(data['status'] as String? ?? 'Belum Lunas'),
      installmentMonths: Value(data['installmentMonths'] as int?),
    );
  }

  ExpensesCompanion _mapToExpense(Map<String, dynamic> data) {
    return ExpensesCompanion(
      id: Value(data['id'] as int? ?? 0),
      category: Value(data['category'] as String? ?? 'Lainnya'),
      description: Value(data['description'] as String? ?? ''),
      amount: Value(data['amount'] as int? ?? 0),
      branchId: Value(data['branchId'] as int?),
      date: Value(data['date'] != null
          ? DateTime.tryParse(data['date'] as String) ?? DateTime.now()
          : DateTime.now()),
    );
  }

  LiquidityCompanion _mapToLiquidity(Map<String, dynamic> data) {
    return LiquidityCompanion(
      id: Value(data['id'] as int? ?? 0),
      type: Value(data['type'] as String? ?? 'out'),
      category: Value(data['category'] as String? ?? 'Lainnya'),
      description: Value(data['description'] as String? ?? ''),
      amount: Value(data['amount'] as int? ?? 0),
      method: Value(data['method'] as String?),
      branchId: Value(data['branchId'] as int?),
      date: Value(data['date'] != null
          ? DateTime.tryParse(data['date'] as String) ?? DateTime.now()
          : DateTime.now()),
    );
  }

  AttendanceCompanion _mapToAttendance(Map<String, dynamic> data) {
    return AttendanceCompanion(
      id: Value(data['id'] as int? ?? 0),
      employeeId: Value(data['employeeId'] as int? ?? 0),
      date: Value(data['date'] != null
          ? DateTime.tryParse(data['date'] as String) ?? DateTime.now()
          : DateTime.now()),
      checkIn: Value(data['checkIn'] as String?),
      checkOut: Value(data['checkOut'] as String?),
      pettyCash: Value(data['pettyCash'] as int?),
      finalCash: Value(data['finalCash'] as int?),
      status: Value(data['status'] as String?),
      expectedCash: Value(data['expectedCash'] as int?),
      shiftNotes: Value(data['shiftNotes'] as String?),
    );
  }

  OnlineOrdersCompanion _mapToOnlineOrder(Map<String, dynamic> data) {
    return OnlineOrdersCompanion(
      id: Value(data['id'] as int? ?? 0),
      invoice: Value(data['invoice'] as String? ?? ''),
      customerName: Value(data['customerName'] as String? ?? ''),
      customerPhone: Value(data['customerPhone'] as String? ?? ''),
      items: Value(data['items'] as String? ?? '[]'),
      total: Value(data['total'] as int? ?? 0),
      status: Value(data['status'] as String? ?? 'Online Baru'),
      processedBy: Value(data['processedBy'] as String?),
    );
  }

  WasteCompanion _mapToWaste(Map<String, dynamic> data) {
    return WasteCompanion(
      id: Value(data['id'] as int? ?? 0),
      productId: Value(data['productId'] as int? ?? 0),
      qty: Value(data['qty'] as int? ?? 0),
      reason: Value(data['reason'] as String?),
      type: Value(data['type'] as String? ?? 'Expired'),
      date: Value(data['date'] != null
          ? DateTime.tryParse(data['date'] as String) ?? DateTime.now()
          : DateTime.now()),
    );
  }

  PayrollCompanion _mapToPayroll(Map<String, dynamic> data) {
    return PayrollCompanion(
      id: Value(data['id'] as int? ?? 0),
      employeeId: Value(data['employeeId'] as int? ?? 0),
      period: Value(data['period'] as String? ?? ''),
      salary: Value(data['salary'] as int? ?? 0),
      bonus: Value(data['bonus'] as int? ?? 0),
      deduction: Value(data['deduction'] as int? ?? 0),
      notes: Value(data['notes'] as String?),
      status: Value(data['status'] as String? ?? 'Pending'),
      date: Value(data['date'] != null
          ? DateTime.tryParse(data['date'] as String) ?? DateTime.now()
          : DateTime.now()),
    );
  }

  RecurringExpensesCompanion _mapToRecurring(Map<String, dynamic> data) {
    return RecurringExpensesCompanion(
      id: Value(data['id'] as int? ?? 0),
      category: Value(data['category'] as String? ?? 'Lainnya'),
      amount: Value(data['amount'] as int? ?? 0),
      description: Value(data['description'] as String? ?? ''),
      frequency: Value(data['frequency'] as String? ?? 'bulanan'),
      nextDate: Value(data['nextDate'] != null
          ? DateTime.tryParse(data['nextDate'] as String) ?? DateTime.now()
          : DateTime.now()),
      active: Value(data['active'] as bool? ?? true),
    );
  }

  DebtPaymentsCompanion _mapToDebtPayment(Map<String, dynamic> data) {
    return DebtPaymentsCompanion(
      id: Value(data['id'] as int? ?? 0),
      debtId: Value(data['debtId'] as int? ?? 0),
      amount: Value(data['amount'] as int? ?? 0),
      method: Value(data['method'] as String? ?? 'Tunai'),
      notes: Value(data['notes'] as String?),
      paidAt: Value(data['paidAt'] != null
          ? DateTime.tryParse(data['paidAt'] as String) ?? DateTime.now()
          : DateTime.now()),
      branchId: Value(data['branchId'] as int?),
    );
  }

  PurchaseOrdersCompanion _mapToPurchaseOrder(Map<String, dynamic> data) {
    return PurchaseOrdersCompanion(
      id: Value(data['id'] as int? ?? 0),
      invoice: Value(data['invoice'] as String? ?? ''),
      supplierId: Value(data['supplierId'] as int? ?? 0),
      supplierName: Value(data['supplierName'] as String? ?? ''),
      total: Value(data['total'] as int? ?? 0),
      note: Value(data['note'] as String?),
      date: Value(data['date'] != null
          ? DateTime.tryParse(data['date'] as String) ?? DateTime.now()
          : DateTime.now()),
    );
  }

  StockCountsCompanion _mapToStockCount(Map<String, dynamic> data) {
    return StockCountsCompanion(
      id: Value(data['id'] as int? ?? 0),
      name: Value(data['name'] as String?),
      status: Value(data['status'] as String? ?? 'Draft'),
      totalProducts: Value(data['totalProducts'] as int? ?? 0),
      matchCount: Value(data['matchCount'] as int? ?? 0),
      diffCount: Value(data['diffCount'] as int? ?? 0),
      completedAt: Value(data['completedAt'] != null
          ? DateTime.tryParse(data['completedAt'] as String)
          : null),
    );
  }

  StockCountItemsCompanion _mapToStockCountItem(Map<String, dynamic> data) {
    return StockCountItemsCompanion(
      id: Value(data['id'] as int? ?? 0),
      countSessionId: Value(data['countSessionId'] as int? ?? 0),
      productId: Value(data['productId'] as int? ?? 0),
      productName: Value(data['productName'] as String? ?? ''),
      systemStock: Value(data['systemStock'] as int? ?? 0),
      physicalStock: Value(data['physicalStock'] as int?),
      difference: Value(data['difference'] as int? ?? 0),
      buyPrice: Value(data['buyPrice'] as int? ?? 0),
      sellPrice: Value(data['sellPrice'] as int? ?? 0),
    );
  }

  PrintOrdersCompanion _mapToPrintOrder(Map<String, dynamic> data) {
    return PrintOrdersCompanion(
      id: Value(data['id'] as int? ?? 0),
      customerName: Value(data['customerName'] as String? ?? ''),
      customerPhone: Value(data['customerPhone'] as String?),
      serviceType: Value(data['serviceType'] as String? ?? ''),
      pages: Value(data['pages'] as int? ?? 0),
      copies: Value(data['copies'] as int? ?? 1),
      paperSize: Value(data['paperSize'] as String? ?? 'A4'),
      widthCm: Value(data['widthCm'] as int?),
      lengthCm: Value(data['lengthCm'] as int?),
      estimateReady: Value(data['estimateReady'] as String?),
      total: Value(data['total'] as int? ?? 0),
      notes: Value(data['notes'] as String?),
      status: Value(data['status'] as String? ?? 'Baru'),
      customFieldsJson: Value(data['customFieldsJson'] as String?),
    );
  }

  PointHistoriesCompanion _mapToPointHistory(Map<String, dynamic> data) {
    return PointHistoriesCompanion(
      id: Value(data['id'] as int? ?? 0),
      customerId: Value(data['customerId'] as int? ?? 0),
      type: Value(data['type'] as String? ?? 'earn'),
      points: Value(data['points'] as int? ?? 0),
      transactionId: Value(data['transactionId'] as int?),
      note: Value(data['note'] as String?),
      date: Value(data['date'] != null
          ? DateTime.tryParse(data['date'] as String) ?? DateTime.now()
          : DateTime.now()),
    );
  }

  /// Settings = single-row table. Delta berisi field parsial → update kolom
  /// yang dikirim saja. Push pakai nama kolom drift (camelCase), SQL-nya
  /// snake_case — konversi di sini (drift: camelCase dart → snake_case SQL).
  Future<void> _applySettingsDelta(Map<String, dynamic> data) async {
    await _db!.customStatement(
      'INSERT OR IGNORE INTO settings (id) VALUES (1)',
    );
    // camelCase (drift field) → snake_case (kolom SQLite)
    const known = <String, String>{
      'storeName': 'store_name',
      'storeAddress': 'store_address',
      'storePhone': 'store_phone',
      'posPrefix': 'pos_prefix',
      'qrisString': 'qris_string',
      'themeMode': 'theme_mode',
      'posGridColumns': 'pos_grid_columns',
      'bankName': 'bank_name',
      'bankAccount': 'bank_account',
      'bankHolder': 'bank_holder',
      'receiptFooter': 'receipt_footer',
      'receiptHeader': 'receipt_header',
      'receiptSubHeader': 'receipt_sub_header',
      'receiptPaperSize': 'receipt_paper_size',
      'storeLogoPath': 'store_logo_path',
      'waTemplates': 'wa_templates',
      'pinLength': 'pin_length',
      'qrisImagePath': 'qris_image_path',
    };
    final fields = <String, dynamic>{};
    for (final entry in known.entries) {
      if (data.containsKey(entry.key)) fields[entry.value] = data[entry.key];
    }
    if (fields.isEmpty) return;
    final sets = fields.keys.map((f) => '$f = ?').join(', ');
    final binds = fields.values.toList()..add(1);
    await _db!.customStatement(
      'UPDATE settings SET $sets WHERE id = ?',
      binds,
    );
  }

  /// Download product image from cloud + update DB imagePath ke lokal path.
  /// Delta data image_path berisi path lokal device asal — tidak ada di
  /// device ini. Kita download dari cloud dan update DB supaya gambar muncul.
  Future<void> _hydrateProductImage(String productIdStr, String localPath) async {
    try {
      final uid = _uid;
      if (uid == null) return;
      final filename = localPath.split('/').last;
      final pid = int.tryParse(productIdStr);
      if (pid == null) return;
      final svc = ImageStorageService(uid);
      // Try downloadOriginal first (matches DB imagePath naming: product_{id}_{ts}.jpg)
      var result = await svc.downloadOriginal('products', filename);
      if (result == null) {
        // Fallback: try with productId prefix (legacy naming)
        result = await svc.downloadImage('products', filename);
      }
      if (result != null) {
        // Update DB: imagePath → lokal path yang baru di-download
        await (_db!.update(_db!.products)
              ..where((t) => t.id.equals(pid)))
            .write(ProductsCompanion(imagePath: Value(result)));
        debugPrint('[DeltaSync] image hydrated: $filename → $result');
      }
    } catch (e) {
      debugPrint('[DeltaSync] image hydrate failed: $e');
    }
  }

  String _uuid() {
    return '${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(999999)}';
  }

  Future<void> stop() async {
    _pushTimer?.cancel();
    _pushTimer = null;
    _periodicPull?.cancel();
    _periodicPull = null;
    _db = null;
    _started = false;
  }
}
