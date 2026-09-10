import 'package:drift/drift.dart';
import 'package:nusa_kasir/core/services/delta_sync_service.dart';
import 'package:nusa_kasir/data/database/app_database.dart';

class DebtRepository {
  final AppDatabase db;
  DebtRepository(this.db);

  /// Add a new debt (utang/pinjaman). Returns the debt id.
  Future<int> addDebt({
    required int customerId,
    required String customerName,
    required int amount,
    DateTime? dueDate,
    String? description,
    int? installmentMonths,
  }) async {
    final newId = await db.into(db.customerDebts).insert(
      CustomerDebtsCompanion.insert(
        customerId: customerId,
        customerName: customerName,
        amount: amount,
        remainingAmount: amount,
        dueDate: Value(dueDate),
        description: Value(description),
        installmentMonths: Value(installmentMonths),
      ),
    );
    DeltaSyncService.I.pushDelta(
      table: 'customer_debts',
      recordId: newId.toString(),
      operation: 'INSERT',
      data: {
        'id': newId,
        'customerId': customerId,
        'customerName': customerName,
        'amount': amount,
        'remainingAmount': amount,
        'dueDate': dueDate?.toIso8601String(),
        'description': description,
        'installmentMonths': installmentMonths,
      },
    );
    return newId;
  }

  /// Get a debt by id.
  Future<CustomerDebt?> byId(int id) =>
      (db.select(db.customerDebts)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// Ambil debt yang terhubung ke sebuah transaksi (lewat tx.debtId).
  Future<CustomerDebt?> byTransactionId(int transactionId) async {
    final tx = await (db.select(db.transactions)
          ..where((t) => t.id.equals(transactionId)))
        .getSingleOrNull();
    final debtId = tx?.debtId;
    if (debtId == null) return null;
    return byId(debtId);
  }

  /// Hapus debt + seluruh pembayarannya (dipakai saat transaksi di-void
  /// supaya tidak ada piutang yatim yang tersisa).
  Future<void> deleteDebtWithPayments(int debtId) async {
    await db.transaction(() async {
      await (db.delete(db.debtPayments)..where((t) => t.debtId.equals(debtId))).go();
      await (db.delete(db.customerDebts)..where((t) => t.id.equals(debtId))).go();
    });
    DeltaSyncService.I.pushDelta(
      table: 'customer_debts',
      recordId: debtId.toString(),
      operation: 'DELETE',
      data: {'id': debtId},
    );
  }

  /// Get active (unpaid) debts, optionally filtered by customer.
  Future<List<CustomerDebt>> getActiveDebts({int? customerId}) {
    final q = db.select(db.customerDebts)
      ..where((t) => t.status.equals('Belum Lunas'));
    if (customerId != null) {
      q.where((t) => t.customerId.equals(customerId));
    }
    q.orderBy([
      (t) => OrderingTerm(expression: t.debtDate, mode: OrderingMode.desc),
    ]);
    return q.get();
  }

  /// Get all debts ordered by debtDate desc, optionally filtered by customer.
  Future<List<CustomerDebt>> getAllDebts({int? customerId}) {
    final q = db.select(db.customerDebts);
    if (customerId != null) {
      q.where((t) => t.customerId.equals(customerId));
    }
    q.orderBy([
      (t) => OrderingTerm(expression: t.debtDate, mode: OrderingMode.desc),
    ]);
    return q.get();
  }

  /// Ubah jumlah bulan cicilan debt (null = hapus cicilan).
  Future<void> setInstallmentMonths(int debtId, int? months) async {
    await (db.update(db.customerDebts)..where((t) => t.id.equals(debtId)))
        .write(CustomerDebtsCompanion(installmentMonths: Value(months)));
    DeltaSyncService.I.pushDelta(
      table: 'customer_debts',
      recordId: debtId.toString(),
      operation: 'UPDATE',
      data: {'id': debtId, 'installmentMonths': months},
    );
  }

  /// Ubah tanggal jatuh tempo debt (null = hapus jatuh tempo).
  Future<void> setDueDate(int debtId, DateTime? dueDate) async {
    await (db.update(db.customerDebts)..where((t) => t.id.equals(debtId)))
        .write(CustomerDebtsCompanion(dueDate: Value(dueDate)));
    DeltaSyncService.I.pushDelta(
      table: 'customer_debts',
      recordId: debtId.toString(),
      operation: 'UPDATE',
      data: {'id': debtId, 'dueDate': dueDate?.toIso8601String()},
    );
  }

  /// Add a payment towards a debt. Updates remainingAmount and auto-sets status to 'Lunas' if fully paid.
  /// [branchId] = cabang tempat setoran dicatat (untuk laporan uang masuk v2.2.35).
  Future<void> addPayment({
    required int debtId,
    required int amount,
    String method = 'Tunai',
    String? notes,
    int? branchId,
  }) async {
    if (amount <= 0) {
      throw ArgumentError.value(
        amount,
        'amount',
        'Pembayaran harus lebih dari nol',
      );
    }
    if (method.trim().isEmpty) {
      throw ArgumentError.value(
        method,
        'method',
        'Metode pembayaran wajib diisi',
      );
    }

    int newRemaining = 0;
    await db.transaction(() async {
      final debt = await (db.select(
        db.customerDebts,
      )..where((t) => t.id.equals(debtId))).getSingleOrNull();
      if (debt == null) {
        throw StateError('Utang tidak ditemukan');
      }
      if (debt.status == 'Lunas' || debt.remainingAmount <= 0) {
        throw StateError('Utang sudah lunas');
      }
      if (amount > debt.remainingAmount) {
        throw ArgumentError.value(
          amount,
          'amount',
          'Pembayaran melebihi sisa utang',
        );
      }

      await db
          .into(db.debtPayments)
          .insert(
            DebtPaymentsCompanion.insert(
              debtId: debtId,
              amount: amount,
              method: Value(method.trim()),
              notes: Value(notes),
              branchId: Value(branchId),
            ),
          );

      newRemaining = debt.remainingAmount - amount;
      await (db.update(
        db.customerDebts,
      )..where((t) => t.id.equals(debtId))).write(
        CustomerDebtsCompanion(
          remainingAmount: Value(newRemaining),
          status: Value(newRemaining == 0 ? 'Lunas' : 'Belum Lunas'),
        ),
      );
    });
    DeltaSyncService.I.pushDelta(
      table: 'customer_debts',
      recordId: debtId.toString(),
      operation: 'UPDATE',
      data: {
        'id': debtId,
        'remainingAmount': newRemaining,
        'status': newRemaining == 0 ? 'Lunas' : 'Belum Lunas',
      },
    );
    DeltaSyncService.I.pushDelta(
      table: 'debt_payments',
      recordId: '${debtId}_${DateTime.now().millisecondsSinceEpoch}',
      operation: 'INSERT',
      data: {
        'debtId': debtId,
        'amount': amount,
        'method': method,
        'notes': notes,
        'branchId': branchId,
      },
    );
  }

  /// Get payment history for a specific debt.
  Future<List<DebtPayment>> getPayments(int debtId) {
    final q = db.select(db.debtPayments)..where((t) => t.debtId.equals(debtId));
    q.orderBy([
      (t) => OrderingTerm(expression: t.paidAt, mode: OrderingMode.desc),
    ]);
    return q.get();
  }

  /// Get sum of all remaining amounts for unpaid debts.
  Future<int> getTotalReceivables() async {
    final row =
        await (db.selectOnly(db.customerDebts)
              ..addColumns([db.customerDebts.remainingAmount.sum()])
              ..where(db.customerDebts.status.equals('Belum Lunas')))
            .getSingleOrNull();

    return row?.read(db.customerDebts.remainingAmount.sum()) ?? 0;
  }

  /// Get overdue debts (dueDate < now AND status != 'Lunas').
  Future<List<CustomerDebt>> getOverdueDebts() {
    final now = DateTime.now();
    final q = db.select(db.customerDebts)
      ..where(
        (t) =>
            t.dueDate.isSmallerThanValue(now) & t.status.equals('Belum Lunas'),
      );
    q.orderBy([
      (t) => OrderingTerm(expression: t.dueDate, mode: OrderingMode.asc),
    ]);
    return q.get();
  }

  /// Get outstanding debt total for a specific customer.
  Future<int> getCustomerOutstanding(int customerId) async {
    final row =
        await (db.selectOnly(db.customerDebts)
              ..addColumns([db.customerDebts.remainingAmount.sum()])
              ..where(
                db.customerDebts.customerId.equals(customerId) &
                    db.customerDebts.status.equals('Belum Lunas'),
              ))
            .getSingleOrNull();

    return row?.read(db.customerDebts.remainingAmount.sum()) ?? 0;
  }
}
