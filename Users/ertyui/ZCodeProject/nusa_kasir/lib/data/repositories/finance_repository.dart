import 'package:drift/drift.dart';
import 'package:nusa_kasir/core/services/delta_sync_service.dart';
import 'package:nusa_kasir/data/database/app_database.dart';

class FinanceRepository {
  final AppDatabase db;
  FinanceRepository(this.db);

  // ---- Expenses ----
  Future<int> addExpense({
    required String category,
    required String description,
    required int amount,
    int? branchId,
  }) async {
    final newId = await db.into(db.expenses).insert(ExpensesCompanion.insert(
      category: category,
      description: description,
      amount: amount,
      branchId: Value(branchId),
    ));
    DeltaSyncService.I.pushDelta(
      table: 'expenses',
      recordId: newId.toString(),
      operation: 'INSERT',
      data: {
        'id': newId,
        'category': category,
        'description': description,
        'amount': amount,
        'branchId': branchId,
      },
    );
    return newId;
  }

  Future<List<Expense>> getExpenses({int? branchId}) {
    var q = db.select(db.expenses)
      ..orderBy([
        (t) => OrderingTerm(expression: t.date, mode: OrderingMode.desc)
      ]);
    if (branchId != null) {
      q.where((t) => t.branchId.equals(branchId));
    }
    return q.get();
  }

  Future<List<Expense>> getExpensesThisMonth({int? branchId}) {
    final now = DateTime.now();
    var q = db.select(db.expenses)
      ..where((t) =>
          t.date.year.equals(now.year) & t.date.month.equals(now.month));
    if (branchId != null) {
      q.where((t) => t.branchId.equals(branchId));
    }
    return q.get();
  }

  // ---- Expense Categories ----
  Future<List<ExpenseCategory>> getCategories() =>
      (db.select(db.expenseCategories)..orderBy([(t) => OrderingTerm(expression: t.name)])).get();

  Future<int> addCategory(String name) async {
    final newId = await db.into(db.expenseCategories).insert(ExpenseCategoriesCompanion.insert(name: name));
    DeltaSyncService.I.pushDelta(
      table: 'expense_categories',
      recordId: newId.toString(),
      operation: 'INSERT',
      data: {'id': newId, 'name': name},
    );
    return newId;
  }

  Future<void> deleteCategory(int id) async {
    await (db.delete(db.expenseCategories)..where((t) => t.id.equals(id))).go();
    DeltaSyncService.I.pushDelta(
      table: 'expense_categories',
      recordId: id.toString(),
      operation: 'DELETE',
      data: {'id': id},
    );
  }

  // ---- Recurring Expenses ----
  Future<List<RecurringExpense>> getRecurring() =>
      (db.select(db.recurringExpenses)..orderBy([(t) => OrderingTerm(expression: t.nextDate)])).get();

  Future<int> addRecurring({
    required String category,
    required int amount,
    required String description,
    required String frequency,
    required DateTime nextDate,
  }) async {
    final newId = await db.into(db.recurringExpenses).insert(RecurringExpensesCompanion.insert(
      category: category,
      amount: amount,
      description: description,
      frequency: frequency,
      nextDate: nextDate,
    ));
    DeltaSyncService.I.pushDelta(
      table: 'recurring_expenses',
      recordId: newId.toString(),
      operation: 'INSERT',
      data: {
        'id': newId,
        'category': category,
        'amount': amount,
        'description': description,
        'frequency': frequency,
        'nextDate': nextDate.toIso8601String(),
      },
    );
    return newId;
  }

  Future<void> updateRecurringNextDate(int id, DateTime nextDate) async {
    await (db.update(db.recurringExpenses)..where((t) => t.id.equals(id)))
        .write(RecurringExpensesCompanion(nextDate: Value(nextDate)));
    DeltaSyncService.I.pushDelta(
      table: 'recurring_expenses',
      recordId: id.toString(),
      operation: 'UPDATE',
      data: {'id': id, 'nextDate': nextDate.toIso8601String()},
    );
  }

  Future<void> toggleRecurring(int id, bool active) async {
    await (db.update(db.recurringExpenses)..where((t) => t.id.equals(id)))
        .write(RecurringExpensesCompanion(active: Value(active)));
    DeltaSyncService.I.pushDelta(
      table: 'recurring_expenses',
      recordId: id.toString(),
      operation: 'UPDATE',
      data: {'id': id, 'active': active},
    );
  }

  Future<void> deleteRecurring(int id) async {
    await (db.delete(db.recurringExpenses)..where((t) => t.id.equals(id))).go();
    DeltaSyncService.I.pushDelta(
      table: 'recurring_expenses',
      recordId: id.toString(),
      operation: 'DELETE',
      data: {'id': id},
    );
  }

  /// Auto-generate expenses for recurring entries whose nextDate has passed.
  /// Returns the number of expenses generated.
  Future<int> processRecurring() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final due = await (db.select(db.recurringExpenses)
          ..where((t) => t.nextDate.isSmallerOrEqualValue(today) & t.active.equals(true)))
        .get();

    int count = 0;
    for (final r in due) {
      await addExpense(category: r.category, description: r.description, amount: r.amount);
      // Advance nextDate
      DateTime next;
      switch (r.frequency) {
        case 'harian':
          next = r.nextDate.add(const Duration(days: 1));
          break;
        case 'mingguan':
          next = r.nextDate.add(const Duration(days: 7));
          break;
        default: // bulanan
          next = _addMonthSafe(r.nextDate);
      }
      await updateRecurringNextDate(r.id, next);
      count++;
    }
    return count;
  }

  // ---- Payroll ----
  Future<int> addPayroll({
    required int employeeId,
    required String period,
    required int salary,
    int bonus = 0,
    int deduction = 0,
    String? notes,
    String status = 'Pending',
  }) async {
    final newId = await db.into(db.payroll).insert(PayrollCompanion.insert(
      employeeId: employeeId,
      period: period,
      salary: salary,
      bonus: Value(bonus),
      deduction: Value(deduction),
      notes: Value(notes),
      status: Value(status),
    ));
    DeltaSyncService.I.pushDelta(
      table: 'payroll',
      recordId: newId.toString(),
      operation: 'INSERT',
      data: {
        'id': newId,
        'employeeId': employeeId,
        'period': period,
        'salary': salary,
        'bonus': bonus,
        'deduction': deduction,
        'notes': notes,
        'status': status,
      },
    );
    return newId;
  }

  Future<List<PayrollData>> getPayroll() =>
      (db.select(db.payroll)
            ..orderBy([
              (t) => OrderingTerm(expression: t.date, mode: OrderingMode.desc)
            ]))
          .get();

  // ---- Waste ----
  Future<int> addWaste({
    required int productId,
    required int qty,
    String? reason,
    String type = 'Expired',
  }) async {
    final newId = await db.into(db.waste).insert(WasteCompanion.insert(
      productId: productId,
      qty: qty,
      reason: Value(reason),
      type: Value(type),
    ));
    DeltaSyncService.I.pushDelta(
      table: 'waste',
      recordId: newId.toString(),
      operation: 'INSERT',
      data: {
        'id': newId,
        'productId': productId,
        'qty': qty,
        'reason': reason,
        'type': type,
      },
    );
    return newId;
  }

  Future<List<WasteData>> getWaste() =>
      (db.select(db.waste)
            ..orderBy([
              (t) => OrderingTerm(expression: t.date, mode: OrderingMode.desc)
            ]))
          .get();

  // ---- Liquidity ----
  Future<int> addLiquidity({
    required String type, // 'in' | 'out'
    required String category,
    required String description,
    required int amount,
    String? method,
    int? branchId,
  }) async {
    final newId = await db.into(db.liquidity).insert(LiquidityCompanion.insert(
      type: type,
      category: category,
      description: description,
      amount: amount,
      method: Value(method),
      branchId: Value(branchId),
    ));
    DeltaSyncService.I.pushDelta(
      table: 'liquidity',
      recordId: newId.toString(),
      operation: 'INSERT',
      data: {
        'id': newId,
        'type': type,
        'category': category,
        'description': description,
        'amount': amount,
        'method': method,
        'branchId': branchId,
      },
    );
    return newId;
  }

  Future<List<LiquidityData>> getLiquidity({int? branchId}) {
    var q = db.select(db.liquidity)
      ..orderBy([
        (t) => OrderingTerm(expression: t.date, mode: OrderingMode.desc)
      ]);
    if (branchId != null) {
      q.where((t) => t.branchId.equals(branchId));
    }
    return q.get();
  }

  /// Get liquidity data for the last N months (for cashflow chart).
  Future<List<LiquidityData>> getLiquidityLastMonths(int months, {int? branchId}) {
    final cutoff = DateTime.now().subtract(Duration(days: months * 31));
    var q = db.select(db.liquidity)
      ..where((t) => t.date.isBiggerOrEqualValue(cutoff));
    if (branchId != null) {
      q.where((t) => t.branchId.equals(branchId));
    }
    return q.get();
  }

  /// Get monthly summary: total in vs out for the last N months.
  Future<Map<String, Map<String, int>>> getMonthlyCashflow(int months, {int? branchId}) async {
    final data = await getLiquidityLastMonths(months, branchId: branchId);
    final map = <String, Map<String, int>>{};
    const monthsEn = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    for (final l in data) {
      final key = '${monthsEn[l.date.month - 1]}';
      map.putIfAbsent(key, () => {'in': 0, 'out': 0});
      if (l.type == 'in') {
        map[key]!['in'] = map[key]!['in']! + l.amount;
      } else {
        map[key]!['out'] = map[key]!['out']! + l.amount;
      }
    }
    return map;
  }

  // ---- Dashboard Summary ----
  /// Returns { 'totalExpense': int, 'totalIncome': int (liquidity 'in'), 'net': int }
  Future<Map<String, int>> getDashboardSummary({int? branchId}) async {
    final now = DateTime.now();
    // Expenses this month
    var expQ = db.select(db.expenses)
      ..where((t) => t.date.year.equals(now.year) & t.date.month.equals(now.month));
    if (branchId != null) expQ.where((t) => t.branchId.equals(branchId));
    final expenses = await expQ.get();
    final totalExpense = expenses.fold<int>(0, (sum, e) => sum + e.amount);

    // Liquidity 'in' this month
    var liqQ = db.select(db.liquidity)
      ..where((t) => t.date.year.equals(now.year) & t.date.month.equals(now.month) & t.type.equals('in'));
    if (branchId != null) liqQ.where((t) => t.branchId.equals(branchId));
    final liqIn = await liqQ.get();
    final totalIncome = liqIn.fold<int>(0, (sum, l) => sum + l.amount);

    return {
      'totalExpense': totalExpense,
      'totalIncome': totalIncome,
      'net': totalIncome - totalExpense,
    };
  }

  // ---- Delete ----
  Future<void> deleteExpense(int id) async {
    await (db.delete(db.expenses)..where((t) => t.id.equals(id))).go();
    DeltaSyncService.I.pushDelta(
      table: 'expenses',
      recordId: id.toString(),
      operation: 'DELETE',
      data: {'id': id},
    );
  }

  Future<void> deletePayroll(int id) async {
    await (db.delete(db.payroll)..where((t) => t.id.equals(id))).go();
    DeltaSyncService.I.pushDelta(
      table: 'payroll',
      recordId: id.toString(),
      operation: 'DELETE',
      data: {'id': id},
    );
  }

  Future<void> deleteWaste(int id) async {
    await (db.delete(db.waste)..where((t) => t.id.equals(id))).go();
    DeltaSyncService.I.pushDelta(
      table: 'waste',
      recordId: id.toString(),
      operation: 'DELETE',
      data: {'id': id},
    );
  }

  Future<void> deleteLiquidity(int id) async {
    await (db.delete(db.liquidity)..where((t) => t.id.equals(id))).go();
    DeltaSyncService.I.pushDelta(
      table: 'liquidity',
      recordId: id.toString(),
      operation: 'DELETE',
      data: {'id': id},
    );
  }

  // ---- Payroll status ----
  Future<void> updatePayrollStatus(int id, String status) async {
    await (db.update(db.payroll)..where((t) => t.id.equals(id)))
        .write(PayrollCompanion(status: Value(status)));
    DeltaSyncService.I.pushDelta(
      table: 'payroll',
      recordId: id.toString(),
      operation: 'UPDATE',
      data: {'id': id, 'status': status},
    );
  }

  /// Safe month increment — avoids DateTime(date.year, 13, …) crash.
  static DateTime _addMonthSafe(DateTime date) {
    return date.month == 12
        ? DateTime(date.year + 1, 1, date.day)
        : DateTime(date.year, date.month + 1, date.day);
  }
}
