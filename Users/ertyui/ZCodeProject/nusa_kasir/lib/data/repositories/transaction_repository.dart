import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:nusa_kasir/core/services/delta_sync_service.dart';
import 'package:nusa_kasir/data/database/app_database.dart';
import 'package:nusa_kasir/features/pos/cart.dart';

class TransactionRepository {
  final AppDatabase db;
  TransactionRepository(this.db);

  Future<int> saveTransaction({
    required List<CartItem> items,
    required int total,
    required String paymentMethod,
    int discount = 0,
    int? customerId,
    int? cashGiven,
    int? cashReturn,
    String? cashierName,
    int? branchId,
    String? orderType,
    int? tableId,
    String? notes,
    int? employeeId,
    int? sessionId,
    int? dpAmount,
    int? installmentMonths,
    int? installmentPerMonth,
    int? debtId,
  }) async {
    final invoice = 'INV-${DateTime.now().millisecondsSinceEpoch}';
    final itemsJson = jsonEncode(items.map((e) => e.toJson()).toList());
    return db.into(db.transactions).insert(TransactionsCompanion.insert(
      invoice: invoice,
      items: itemsJson,
      total: Value(total),
      discount: Value(discount),
      paymentMethod: Value(paymentMethod),
      customerId: Value(customerId),
      cashGiven: Value(cashGiven),
      cashReturn: Value(cashReturn),
      cashierName: Value(cashierName),
      branchId: Value(branchId),
      employeeId: employeeId != null ? Value(employeeId) : const Value.absent(),
      sessionId: sessionId != null ? Value(sessionId) : const Value.absent(),
      orderType: orderType != null ? Value(orderType) : const Value.absent(),
      tableId: tableId != null ? Value(tableId) : const Value.absent(),
      notes: notes != null ? Value(notes) : const Value.absent(),
      dpAmount: dpAmount != null ? Value(dpAmount) : const Value.absent(),
      installmentMonths:
          installmentMonths != null ? Value(installmentMonths) : const Value.absent(),
      installmentPerMonth:
          installmentPerMonth != null ? Value(installmentPerMonth) : const Value.absent(),
      debtId: debtId != null ? Value(debtId) : const Value.absent(),
    ));
  }

  /// For online orders — take raw items + invoice string.
  Future<int> addTransaction({
    required String invoice,
    required String items,     // JSON string
    required int total,
    int discount = 0,
    String? cashierName,
    String? paymentMethod,
    int? branchId,
    int? cashGiven,
    int? cashReturn,
    int? customerId,
    int? employeeId,
  }) async {
    return db.into(db.transactions).insert(TransactionsCompanion.insert(
      invoice: invoice,
      items: items,
      total: Value(total),
      discount: Value(discount),
      paymentMethod: Value(paymentMethod ?? 'Tunai'),
      cashierName: Value(cashierName),
      branchId: Value(branchId),
      cashGiven: Value(cashGiven),
      cashReturn: Value(cashReturn),
      customerId: Value(customerId),
      employeeId: employeeId != null ? Value(employeeId) : const Value.absent(),
    ));
  }

  Future<List<Transaction>> getTransactions() =>
      db.select(db.transactions).get();

  /// Get transactions ordered by date descending with customer name/phone joined.
  /// Returns maps with all Transaction fields plus 'customerName' and 'customerPhone'.
  Future<List<Map<String, dynamic>>> getTransactionsWithCustomer() async {
    final query = db.select(db.transactions).join([
      leftOuterJoin(db.customers, db.customers.id.equalsExp(db.transactions.customerId)),
    ]);
    query.orderBy([OrderingTerm(expression: db.transactions.date, mode: OrderingMode.desc)]);

    final rows = await query.get();
    return rows.map((row) {
      final tx = row.readTable(db.transactions);
      final cust = row.readTableOrNull(db.customers);
      return {
        ...tx.toJson(),
        'customerName': cust?.name,
        'customerPhone': cust?.phone,
      };
    }).toList();
  }

  Future<List<Transaction>> getToday() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return (db.select(db.transactions)
          ..where((t) => t.date.isBiggerThanValue(today)))
        .get();
  }

  /// Void a transaction: mark status, restore stock, record reason.
  /// Returns null on success, or an error string.
  Future<String?> voidTransaction(int id, String reason) async {
    final tx = await (db.select(db.transactions)
      ..where((t) => t.id.equals(id))).getSingleOrNull();

    if (tx == null) return 'Transaksi tidak ditemukan';
    if (tx.status != 'Normal') return 'Transaksi sudah di-void';

    await db.transaction(() async {
      // 1. Mark as voided
      await (db.update(db.transactions)..where((t) => t.id.equals(id))).write(
        TransactionsCompanion(
          status: const Value('Void'),
          voidReason: Value(reason),
          voidedAt: Value(DateTime.now()),
        ),
      );

      // 2. Restore stock for each item
      final items = _parseItemsJson(tx.items);
      for (final item in items) {
        final pid = item['productId'] as int?;
        final qty = item['qty'] as int? ?? 0;
        if (pid != null && qty > 0) {
          // Use direct DB access to avoid repository dependency
          final product = await (db.select(db.products)
            ..where((p) => p.id.equals(pid))).getSingleOrNull();
          if (product != null) {
            final next = (product.stock + qty).clamp(0, 1000000000);
            await (db.update(db.products)..where((p) => p.id.equals(pid)))
                .write(ProductsCompanion(stock: Value(next)));
          }
        }
      }

      // 3. Hapus piutang yatim: transaksi DP/Hutang punya debtId → hapus
      //    debt + pembayarannya supaya riwayat Piutang tidak ada entri
      //    yang sudah tidak relevan (transaksi batal).
      final debtId = tx.debtId;
      if (debtId != null) {
        await (db.delete(db.debtPayments)..where((t) => t.debtId.equals(debtId))).go();
        await (db.delete(db.customerDebts)..where((t) => t.id.equals(debtId))).go();
      }
    });

    // Push deltas after successful void
    DeltaSyncService.I.pushDelta(
      table: 'transactions',
      recordId: id.toString(),
      operation: 'UPDATE',
      data: {
        'id': id,
        'status': 'Void',
        'voidReason': reason,
        'voidedAt': DateTime.now().toIso8601String(),
      },
    );
    // Push stock restoration deltas
    final items = _parseItemsJson(tx.items);
    for (final item in items) {
      final pid = item['productId'] as int?;
      final qty = item['qty'] as int? ?? 0;
      if (pid != null && qty > 0) {
        final product = await (db.select(db.products)
          ..where((p) => p.id.equals(pid))).getSingleOrNull();
        if (product != null) {
          DeltaSyncService.I.pushDelta(
            table: 'products',
            recordId: pid.toString(),
            operation: 'UPDATE',
            data: {'id': pid, 'stock': product.stock},
          );
        }
      }
    }
    // Push debt deletion if applicable
    if (tx.debtId != null) {
      DeltaSyncService.I.pushDelta(
        table: 'customer_debts',
        recordId: tx.debtId.toString(),
        operation: 'DELETE',
        data: {'id': tx.debtId},
      );
    }

    return null; // success
  }

  List<Map<String, dynamic>> _parseItemsJson(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is List) {
        return decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
    } catch (_) {}
    return [];
  }
}
