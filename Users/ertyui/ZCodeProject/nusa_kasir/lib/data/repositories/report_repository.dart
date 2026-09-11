import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:nusa_kasir/core/config/nusa_config.dart';
import 'package:nusa_kasir/data/database/app_database.dart';

class ReportRepository {
  final AppDatabase db;
  ReportRepository(this.db);

  Future<List<Transaction>> getTransactions({
    DateTime? from,
    DateTime? to,
    int? branchId,
    int? employeeId,
    int? onlyEmployee,
  }) async {
    final q = db.select(db.transactions)
      ..where((t) => t.status.equals('Normal'));
    if (branchId != null) {
      q.where((t) => t.branchId.equals(branchId));
    }
    if (employeeId != null) {
      // Cashier scoping: own sales + shared online orders (employeeId null).
      q.where((t) =>
          t.employeeId.equals(employeeId) |
          t.employeeId.isNull());
    }
    if (onlyEmployee != null) {
      // v2.2.54: filter KETAT per karyawan untuk laporan owner — HANYA trx
      // yang dibuat karyawan tsb (tanpa trx bersama employeeId null).
      q.where((t) => t.employeeId.equals(onlyEmployee));
    }
    if (from != null || to != null) {
      q.where((t) {
        final conds = <Expression<bool>>[];
        // Inclusive day-boundary filter: `from` (00:00:00) .. `to` end-of-day
        // (23:59:59.999). Previously the bounds were widened by ±1 day, which
        // made "Hari ini" bleed into yesterday's transactions.
        if (from != null) {
          conds.add(
            t.date.isBiggerOrEqual(Constant(DateTime(from.year, from.month, from.day))),
          );
        }
        if (to != null) {
          conds.add(
            t.date.isSmallerOrEqual(Constant(DateTime(to.year, to.month, to.day, 23, 59, 59))),
          );
        }
        return conds.reduce((a, b) => a & b);
      });
    }
    q.orderBy([
      (t) => OrderingTerm(expression: t.date, mode: OrderingMode.desc),
    ]);
    return q.get();
  }

  /// Pendapatan = uang yang BENAR-BENAR masuk (v2.2.35).
  ///  - DP (uang muka): hanya nominal DP yang masuk ke kasir saat itu.
  ///  - Hutang penuh: belum ada uang masuk → 0.
  ///  - Tunai lunas: cashGiven dikurangi kembalian.
  ///  - QRIS/Transfer/EDC: total (dianggap lunas).
  int _paidAmount(Transaction t) {
    final dp = t.dpAmount;
    if (dp != null && dp > 0) return dp;
    if (t.debtId != null) return 0;
    final given = t.cashGiven;
    if (given != null && given > 0) {
      final ret = t.cashReturn ?? 0;
      final net = given - ret;
      return net > 0 ? net : given;
    }
    return t.total;
  }

  /// Setoran piutang (uang masuk belakangan) dalam periode — ikut dihitung
  /// sebagai pendapatan. Filter cabang: setoran lama tanpa cabang (null)
  /// dianggap milik semua cabang supaya tidak hilang dari laporan.
  Future<List<DebtPayment>> _debtPaymentsFor({
    DateTime? from,
    DateTime? to,
    int? branchId,
  }) async {
    var q = db.select(db.debtPayments);
    if (from != null || to != null) {
      q.where((p) {
        final conds = <Expression<bool>>[];
        if (from != null) {
          conds.add(p.paidAt.isBiggerOrEqual(
              Constant(DateTime(from.year, from.month, from.day))));
        }
        if (to != null) {
          conds.add(p.paidAt.isSmallerOrEqual(
              Constant(DateTime(to.year, to.month, to.day, 23, 59, 59))));
        }
        return conds.reduce((a, b) => a & b);
      });
    }
    if (branchId != null) {
      q.where((p) => p.branchId.equals(branchId) | p.branchId.isNull());
    }
    return q.get();
  }

  /// Returns summary stats for a period.
  /// Keys: omzet (int, sudah dikurangi retur), count (int), avg (int),
  ///       items (List<Transaction>).
  /// When [employeeId] is set, only transactions attributed to that employee
  /// (plus shared online orders with null employeeId) are counted.
  Future<Map<String, dynamic>> summary({
    DateTime? from,
    DateTime? to,
    int? branchId,
    int? employeeId,
    int? onlyEmployee,
  }) async {
    final list = await getTransactions(
        from: from,
        to: to,
        branchId: branchId,
        employeeId: employeeId,
        onlyEmployee: onlyEmployee);
    // Retur parsial mengurangi omzet: uang yang sudah dikembalikan ke
    // pelanggan bukan lagi pendapatan. Refund dicatat per employee yang
    // memproses — jadi untuk scoping kasir dipakai employeeId refund-nya.
    final refunds = await _refundsFor(
        from: from, to: to, branchId: branchId, employeeId: employeeId);
    final refundTotal = refunds.fold(0, (int s, r) => s + r.refundAmount);
    // Uang masuk = pembayaran tunai/QRIS/Transfer yg diterima + setoran piutang.
    // (DP & cicilan piutang baru dihitung saat uangnya benar-benar diterima.)
    final debtIncome = employeeId == null
        ? (await _debtPaymentsFor(from: from, to: to, branchId: branchId))
            .fold(0, (int s, p) => s + p.amount)
        : 0;
    final omzet = list.fold(0, (int sum, t) => sum + _paidAmount(t)) -
        refundTotal +
        debtIncome;
    final count = list.length;
    final avg = count == 0 ? 0 : (omzet / count).round();
    return {'omzet': omzet, 'count': count, 'avg': avg, 'items': list};
  }

  /// Full Profit & Loss (Laba Rugi) for a date range.
  /// Returns a map with all line items.
  Future<Map<String, dynamic>> profitLoss({
    DateTime? from,
    DateTime? to,
    int? branchId,
    int? onlyEmployee,
  }) async {
    // ── Revenue (pendapatan) ──────────────────────────────────────
    final txList = await getTransactions(
      from: from,
      to: to,
      branchId: branchId,
      onlyEmployee: onlyEmployee,
    );
    final normalTx = txList.where((t) => t.status == 'Normal');
    // Pendapatan = uang masuk: DP/QRIS/Transfer diterima + setoran piutang.
    final txIncome = normalTx.fold(0, (int s, t) => s + _paidAmount(t));
    final debtPayments =
        await _debtPaymentsFor(from: from, to: to, branchId: branchId);
    final debtIncome = debtPayments.fold<int>(0, (int s, p) => s + p.amount);
    final pendapatan = txIncome + debtIncome;

    // ── HPP (Harga Pokok Penjualan) ───────────────────────────────
    int hpp = 0;
    // Collect all product IDs to batch-lookup buy prices
    final productIds = <int>{};
    for (final tx in normalTx) {
      final items = _parseItems(tx.items);
      for (final it in items) {
        final pid = (it['productId'] as num?)?.toInt();
        if (pid != null && pid >= 0) productIds.add(pid);
      }
    }
    // Batch lookup
    final products = await (db.select(
      db.products,
    )..where((p) => p.id.isIn(productIds))).get();
    final priceMap = {for (final p in products) p.id: p.buyPrice};

    // v2.2.43 (F&B): HPP resep — produk ber-resep memakai biaya bahan
    // (Σ qty × costPrice), bukan buyPrice. Untuk varian non-F&B map kosong
    // → tidak ada efek (perf ringan, satu query per laporan ini).
    final recipeCostMap = <int, int>{};
    if (NusaConfig.isFnbVariant && productIds.isNotEmpty) {
      final recipes = await (db.select(db.recipes)).get();
      if (recipes.isNotEmpty) {
        final materialIds = recipes.map((r) => r.materialId).toSet();
        final mats = await (db.select(db.rawMaterials)
              ..where((m) => m.id.isIn(materialIds)))
            .get();
        final costById = {for (final m in mats) m.id: m.costPrice};
        final byProduct = <int, List<Recipe>>{};
        for (final r in recipes) {
          byProduct.putIfAbsent(r.productId, () => []).add(r);
        }
        for (final entry in byProduct.entries) {
          int total = 0;
          for (final r in entry.value) {
            total += (r.qty * (costById[r.materialId] ?? 0)).round();
          }
          recipeCostMap[entry.key] = total;
        }
      }
    }

    for (final tx in normalTx) {
      final items = _parseItems(tx.items);
      for (final it in items) {
        final pid = (it['productId'] as num?)?.toInt();
        final qty = (it['qty'] as num?)?.toInt() ?? 0;
        // v2.2.43 (satuan dinamis): qty tercatat dalam satuan jual; konversi
        // ke satuan dasar untuk HPP (stok & modal selalu satuan dasar).
        final perBase = (it['unitQtyPerBase'] as num?)?.toDouble() ?? 1;
        final qtyInBase = perBase > 0 ? (qty * perBase).round() : qty;
        if (pid == null || qtyInBase <= 0) continue;
        if (pid < 0) {
          // Item manual (id negatif): HPP dari harga modal per item (costPrice),
          // bukan dari tabel produk. Tanpa costPrice → tidak menambah HPP.
          final cost = (it['costPrice'] as num?)?.toInt() ?? 0;
          hpp += cost * qtyInBase;
        } else {
          // F&B: prioritas HPP resep (biaya bahan), fallback buyPrice.
          final unitCost = recipeCostMap[pid] ?? (priceMap[pid] ?? 0);
          hpp += unitCost * qtyInBase;
        }
      }
    }

    // ── Retur / Refund ─────────────────────────────────────────────
    // Uang yang dikembalikan ke pelanggan keluar dari pendapatan; barang
    // yang kembali ke toko juga keluar dari HPP (sudah tidak terjual).
    final refunds = await _refundsFor(from: from, to: to, branchId: branchId);
    final totalRetur = refunds.fold(0, (int s, r) => s + r.refundAmount);
    // HPP barang yang di-retur: pakai buyPrice produk saat ini — barang
    // kembali ke stok, jadi cost-nya kembali ke persediaan.
    int hppRetur = 0;
    for (final r in refunds) {
      if (r.productId == null) continue; // item manual: tidak ada HPP
      hppRetur += (priceMap[r.productId] ?? 0) * r.qty;
    }

    final pendapatanSetelahRetur = pendapatan - totalRetur;
    final hppSetelahRetur = hpp - hppRetur;
    final labaKotor = pendapatanSetelahRetur - hppSetelahRetur;

    // ── Expenses (pengeluaran) ────────────────────────────────────
    final expenses = await _filtered(
      db.select(db.expenses),
      from: from,
      to: to,
      branchId: branchId,
      branchIdOf: (e) => e.branchId,
    );
    final totalExpenses = expenses.fold(0, (int s, e) => s + e.amount);

    // ── Payroll ───────────────────────────────────────────────────
    final payroll = await _filtered(db.select(db.payroll), from: from, to: to);
    final totalPayroll = payroll.fold(
      0,
      (int s, p) => s + p.salary + p.bonus - p.deduction,
    );

    // ── Waste (loss from spoiled goods) ───────────────────────────
    final waste = await _filtered(db.select(db.waste), from: from, to: to);
    int totalWaste = 0;
    for (final w in waste) {
      final prod =
          priceMap[w.productId] ??
          (await (db.select(
                db.products,
              )..where((p) => p.id.equals(w.productId))).getSingleOrNull())
              ?.buyPrice ??
          0;
      totalWaste += prod * w.qty;
    }

    // ── Liquidity ─────────────────────────────────────────────────
    final liquidity = await _filtered(
      db.select(db.liquidity),
      from: from,
      to: to,
      branchId: branchId,
      branchIdOf: (l) => l.branchId,
    );
    final liquidityIn = liquidity
        .where((l) => l.type == 'in')
        .fold(0, (int s, l) => s + l.amount);
    final liquidityOut = liquidity
        .where((l) => l.type == 'out')
        .fold(0, (int s, l) => s + l.amount);

    // ── Totals ────────────────────────────────────────────────────
    final totalBeban = totalExpenses + totalPayroll + totalWaste + liquidityOut;
    final labaBersih = labaKotor - totalBeban + liquidityIn;

    return {
      'pendapatan': pendapatan,
      'hpp': hpp,
      'retur': totalRetur,
      'hppRetur': hppRetur,
      'labaKotor': labaKotor,
      'expenses': totalExpenses,
      'payroll': totalPayroll,
      'waste': totalWaste,
      'liquidityIn': liquidityIn,
      'liquidityOut': liquidityOut,
      'totalBeban': totalBeban,
      'labaBersih': labaBersih,
      'txCount': normalTx.length,
    };
  }

  /// Top-selling products (by quantity) for a period.
  /// Returns list of {id, name, category, qty, revenue}.
  Future<List<Map<String, dynamic>>> topProducts({
    DateTime? from,
    DateTime? to,
    int limit = 5,
    int? branchId,
    int? onlyEmployee,
  }) async {
    final agg = await _aggregateByProduct(
      from: from,
      to: to,
      branchId: branchId,
      onlyEmployee: onlyEmployee,
    );
    final list = agg.entries.map((e) {
      final p = e.value;
      return {
        'id': e.key,
        'name': p['name'] as String,
        'category': p['category'] as String,
        'qty': p['qty'] as int,
        'revenue': p['revenue'] as int,
      };
    }).toList();
    list.sort((a, b) => (b['qty'] as int).compareTo(a['qty'] as int));
    return list.take(limit).toList();
  }

  /// Daily revenue for bar chart.
  /// Returns Map where key is "YYYY-MM-DD" and value is total revenue.
  /// Uang masuk saja: DP/hutang dihitung saat diterima (v2.2.35).
  Future<Map<String, int>> dailyRevenue({
    DateTime? from,
    DateTime? to,
    int? branchId,
    int? onlyEmployee,
  }) async {
    final txs = await getTransactions(
        from: from, to: to, branchId: branchId, onlyEmployee: onlyEmployee);
    final byDay = <String, int>{};
    for (final t in txs) {
      final key =
          '${t.date.year}-${t.date.month.toString().padLeft(2, '0')}-${t.date.day.toString().padLeft(2, '0')}';
      byDay[key] = (byDay[key] ?? 0) + _paidAmount(t);
    }
    // Setoran piutang: uang masuk pada hari itu juga.
    for (final p
        in await _debtPaymentsFor(from: from, to: to, branchId: branchId)) {
      final key = '${p.paidAt.year}-${p.paidAt.month.toString().padLeft(2, '0')}-${p.paidAt.day.toString().padLeft(2, '0')}';
      byDay[key] = (byDay[key] ?? 0) + p.amount;
    }
    return byDay;
  }

  /// Sales grouped by category for a period.
  /// Returns list of {category, qty, revenue} sorted by revenue desc.
  Future<List<Map<String, dynamic>>> salesByCategory({
    DateTime? from,
    DateTime? to,
    int? branchId,
    int? onlyEmployee,
  }) async {
    final agg = await _aggregateByProduct(
      from: from,
      to: to,
      branchId: branchId,
      onlyEmployee: onlyEmployee,
    );
    final qtyByCat = <String, int>{};
    final revByCat = <String, int>{};
    for (final p in agg.values) {
      final cat = p['category'] as String;
      qtyByCat[cat] = (qtyByCat[cat] ?? 0) + (p['qty'] as int);
      revByCat[cat] = (revByCat[cat] ?? 0) + (p['revenue'] as int);
    }
    final cats = qtyByCat.keys.toList()
      ..sort((a, b) => (revByCat[b] ?? 0).compareTo(revByCat[a] ?? 0));
    return cats
        .map(
          (c) => {
            'category': c,
            'qty': qtyByCat[c] ?? 0,
            'revenue': revByCat[c] ?? 0,
          },
        )
        .toList();
  }

  /// Totals per payment method (Tunai / QRIS / Transfer / Lainnya).
  /// Uang masuk saja: DP masuk ke metode aslinya, hutang penuh = 0,
  /// setoran piutang masuk ke metode setoran (default Tunai) (v2.2.35).
  Future<Map<String, int>> salesByPaymentMethod({
    DateTime? from,
    DateTime? to,
    int? branchId,
    int? onlyEmployee,
  }) async {
    final txs = await getTransactions(
        from: from, to: to, branchId: branchId, onlyEmployee: onlyEmployee);
    final totals = <String, int>{};
    for (final t in txs) {
      final m = _normalizeMethod(t.paymentMethod);
      totals[m] = (totals[m] ?? 0) + _paidAmount(t);
    }
    for (final p
        in await _debtPaymentsFor(from: from, to: to, branchId: branchId)) {
      final m = _normalizeMethod(p.method);
      totals[m] = (totals[m] ?? 0) + p.amount;
    }
    return totals;
  }

  /// Pengeluaran per kategori untuk periode tertentu (tab Laporan Pengeluaran).
  /// Returns list of {category, amount} sorted by amount desc.
  Future<List<Map<String, dynamic>>> expensesByCategory({
    DateTime? from,
    DateTime? to,
    int? branchId,
  }) async {
    final list = await _filtered(
      db.select(db.expenses),
      from: from,
      to: to,
      branchId: branchId,
      branchIdOf: (e) => e.branchId,
    );
    final byCat = <String, int>{};
    for (final e in list) {
      byCat[e.category] = (byCat[e.category] ?? 0) + e.amount;
    }
    final cats = byCat.keys.toList()
      ..sort((a, b) => (byCat[b] ?? 0).compareTo(byCat[a] ?? 0));
    return cats
        .map((c) => {'category': c, 'amount': byCat[c] ?? 0})
        .toList();
  }

  /// Current summary vs the immediately-preceding equal-length period.
  /// Keys: omzet, count, avg, hasPrevious, prevOmzet, prevCount,
  ///       omzetGrowth (%), countGrowth (%).
  Future<Map<String, dynamic>> summaryWithPrevious(
    DateTime? from,
    DateTime? to, {
    int? branchId,
    int? onlyEmployee,
  }) async {
    final cur = await summary(
        from: from,
        to: to,
        branchId: branchId,
        onlyEmployee: onlyEmployee);
    Map<String, dynamic>? prev;
    var hasPrev = false;
    if (from != null && to != null) {
      final dur = to.difference(from);
      final prevTo = from.subtract(const Duration(days: 1));
      final prevFrom = prevTo.subtract(dur);
      prev = await summary(
        from: prevFrom,
        to: prevTo,
        branchId: branchId,
        onlyEmployee: onlyEmployee,
      );
      hasPrev = true;
    }
    final omzet = cur['omzet'] as int? ?? 0;
    final count = cur['count'] as int? ?? 0;
    final prevOmzet = prev?['omzet'] as int? ?? 0;
    final prevCount = prev?['count'] as int? ?? 0;
    final omzetGrowth = hasPrev && prevOmzet > 0
        ? (omzet - prevOmzet) / prevOmzet * 100
        : 0.0;
    final countGrowth = hasPrev && prevCount > 0
        ? (count - prevCount) / prevCount * 100
        : 0.0;
    return {
      'omzet': omzet,
      'count': count,
      'avg': cur['avg'],
      'hasPrevious': hasPrev,
      'prevOmzet': prevOmzet,
      'prevCount': prevCount,
      'omzetGrowth': omzetGrowth,
      'countGrowth': countGrowth,
    };
  }

  /// Aggregate quantity & revenue per product id, resolving name/category
  /// from the products table.
  Future<Map<int, Map<String, dynamic>>> _aggregateByProduct({
    DateTime? from,
    DateTime? to,
    int? branchId,
    int? onlyEmployee,
  }) async {
    final txs = await getTransactions(
      from: from,
      to: to,
      branchId: branchId,
      onlyEmployee: onlyEmployee,
    );
    final qtyById = <int, int>{};
    final revById = <int, int>{};
    final ids = <int>{};
    for (final t in txs) {
      for (final it in _parseItems(t.items)) {
        final pid = it['productId'] as int?;
        final qty = (it['qty'] as int?) ?? 0;
        final price = (it['price'] as num?)?.toInt() ?? 0;
        // Item manual (id negatif) tidak masuk agregat produk
        if (pid == null || pid < 0) continue;
        ids.add(pid);
        qtyById[pid] = (qtyById[pid] ?? 0) + qty;
        revById[pid] = (revById[pid] ?? 0) + qty * price;
      }
    }
    // Retur parsial mengurangi qty & revenue produk yang di-retur.
    final refunds = await _refundsFor(from: from, to: to, branchId: branchId);
    for (final r in refunds) {
      final pid = r.productId;
      if (pid == null || pid < 0) continue;
      ids.add(pid);
      qtyById[pid] = (qtyById[pid] ?? 0) - r.qty;
      revById[pid] = (revById[pid] ?? 0) - r.refundAmount;
    }
    final products = ids.isEmpty
        ? <Product>[]
        : await (db.select(db.products)..where((p) => p.id.isIn(ids))).get();
    final pmap = {for (final p in products) p.id: p};
    final out = <int, Map<String, dynamic>>{};
    for (final id in ids) {
      final p = pmap[id];
      out[id] = {
        'name': p?.name ?? 'Produk #$id',
        'category': p?.category ?? 'Lainnya',
        'qty': qtyById[id] ?? 0,
        'revenue': revById[id] ?? 0,
      };
    }
    return out;
  }

  /// Refunds scoped by period / branch / employee, for report subtraction.
  /// Mirrors `getTransactions` scoping: employeeId null = all, non-null =
  /// refunds processed by that employee + shared (branch-wide, null employee)
  /// refunds.
  Future<List<Refund>> _refundsFor({
    DateTime? from,
    DateTime? to,
    int? branchId,
    int? employeeId,
  }) async {
    var q = db.select(db.refunds);
    if (from != null || to != null) {
      q.where((r) {
        final conds = <Expression<bool>>[];
        if (from != null) {
          conds.add(r.date.isBiggerOrEqual(
              Constant(DateTime(from.year, from.month, from.day))));
        }
        if (to != null) {
          conds.add(r.date.isSmallerOrEqual(
              Constant(DateTime(to.year, to.month, to.day, 23, 59, 59))));
        }
        return conds.reduce((a, b) => a & b);
      });
    }
    if (branchId != null) {
      q.where((r) => r.branchId.equals(branchId));
    }
    if (employeeId != null) {
      // Refund diproses employee ini, plus retur bersama (employeeId null).
      q.where((r) => r.employeeId.equals(employeeId) | r.employeeId.isNull());
    }
    return q.get();
  }

  String _normalizeMethod(String? m) {
    final s = (m ?? '').toLowerCase();
    if (s.contains('qris')) return 'QRIS';
    if (s.contains('transfer')) return 'Transfer';
    if (s.contains('edc') || s.contains('kartu') || s.contains('debit') || s.contains('kredit')) {
      return 'Kartu';
    }
    if (s.contains('cash') || s.contains('tunai')) return 'Tunai';
    return m?.isNotEmpty == true ? m! : 'Lainnya';
  }

  List<Map<String, dynamic>> _parseItems(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is List) {
        return decoded.map((e) => Map<String, dynamic>.from(e)).toList();
      }
    } catch (_) {}
    return [];
  }

  /// Helper: apply date filter to a query.
  Future<List<T>> _filtered<T>(
    Selectable<T> query, {
    DateTime? from,
    DateTime? to,
    int? branchId,
    int? Function(T item)? branchIdOf,
  }) async {
    // We rely on the generated query being filtered by the caller
    // This is a simpler approach — fetch all then filter in Dart
    final list = await query.get();
    return list
        .where((item) {
          if (branchId != null &&
              branchIdOf != null &&
              branchIdOf(item) != branchId) {
            return false;
          }
          // Drift data classes have a `date` field convention — use dynamic
          final d = (item as dynamic).date as DateTime?;
          if (d == null) return true;
          if (from != null && d.isBefore(DateTime(from.year, from.month, from.day)))
            return false;
          if (to != null &&
              d.isAfter(DateTime(to.year, to.month, to.day, 23, 59, 59)))
            return false;
          return true;
        })
        .toList()
        .cast<T>();
  }
}
