import 'package:drift/drift.dart';
import 'package:nusa_kasir/core/services/delta_sync_service.dart';
import 'package:nusa_kasir/data/database/app_database.dart';
import 'package:nusa_kasir/data/repositories/product_repository.dart';

class StockCountRepository {
  final AppDatabase db;
  StockCountRepository(this.db);

  /// Create a new stock count session and auto-populate all products as items.
  Future<int> createSession(String name) async {
    final sessionId = await db
        .into(db.stockCounts)
        .insert(StockCountsCompanion.insert(name: Value(name)));

    final products = await ProductRepository(db).getProducts();
    for (final p in products) {
      await db
          .into(db.stockCountItems)
          .insert(
            StockCountItemsCompanion.insert(
              countSessionId: sessionId,
              productId: p.id,
              productName: p.name,
              systemStock: p.stock,
              buyPrice: Value(p.buyPrice),
              sellPrice: Value(p.sellPrice),
            ),
          );
    }

    // Update totalProducts on the session
    await (db.update(db.stockCounts)..where((t) => t.id.equals(sessionId)))
        .write(StockCountsCompanion(totalProducts: Value(products.length)));

    DeltaSyncService.I.pushDelta(
      table: 'stock_counts',
      recordId: sessionId.toString(),
      operation: 'INSERT',
      data: {'id': sessionId, 'name': name, 'status': 'Draft', 'totalProducts': products.length},
    );

    return sessionId;
  }

  /// Get the latest Draft session, or null if none.
  Future<StockCount?> getActiveSession() async {
    final q = db.select(db.stockCounts)
      ..where((t) => t.status.equals('Draft'))
      ..orderBy([
        (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
      ])
      ..limit(1);
    return q.getSingleOrNull();
  }

  /// Get all sessions ordered by createdAt desc.
  Future<List<StockCount>> getSessions() async {
    final q = db.select(db.stockCounts)
      ..orderBy([
        (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
      ]);
    return q.get();
  }

  /// Get all items for a session.
  Future<List<StockCountItem>> getItems(int sessionId) async {
    final q = db.select(db.stockCountItems)
      ..where((t) => t.countSessionId.equals(sessionId));
    return q.get();
  }

  /// Update the physical count for an item, recalculating the difference.
  Future<void> updatePhysicalCount(int itemId, int physicalStock) async {
    final item = await (db.select(
      db.stockCountItems,
    )..where((t) => t.id.equals(itemId))).getSingleOrNull();
    if (item == null) return;

    final diff = physicalStock - item.systemStock;
    await (db.update(
      db.stockCountItems,
    )..where((t) => t.id.equals(itemId))).write(
      StockCountItemsCompanion(
        physicalStock: Value(physicalStock),
        difference: Value(diff),
      ),
    );
    DeltaSyncService.I.pushDelta(
      table: 'stock_count_items',
      recordId: itemId.toString(),
      operation: 'UPDATE',
      data: {
        'id': itemId,
        'countSessionId': item.countSessionId,
        'productId': item.productId,
        'physicalStock': physicalStock,
        'difference': diff,
      },
    );
  }

  /// Finalize a session: set status to Selesai, record completedAt, and adjust all product stocks.
  Future<Map<String, dynamic>> finalizeSession(int sessionId) async {
    final session = await (db.select(
      db.stockCounts,
    )..where((t) => t.id.equals(sessionId))).getSingleOrNull();
    if (session == null) {
      throw StateError('Sesi stok tidak ditemukan');
    }
    // A completed session is immutable. Returning its persisted summary makes
    // retries safe and prevents applying the same stock adjustment twice.
    if (session.status != 'Draft') {
      return getSessionSummary(sessionId);
    }

    final items = await getItems(sessionId);
    final productRepo = ProductRepository(db);

    int matchCount = 0;
    int diffCount = 0;
    int totalLossValue = 0; // negative = loss, positive = gain

    // Claim the draft inside the same transaction as stock adjustments. This
    // makes retries idempotent and rolls the claim back if any adjustment fails.
    var claimedSession = false;
    await db.transaction(() async {
      final claimed =
          await (db.update(db.stockCounts)..where(
                (t) => t.id.equals(sessionId) & t.status.equals('Draft'),
              ))
              .write(StockCountsCompanion(status: const Value('Memproses')));
      if (claimed == 0) return;
      claimedSession = true;

      for (final item in items) {
        if (item.physicalStock == null) continue;
        final diff = item.physicalStock! - item.systemStock;
        if (diff != 0) {
          diffCount++;
          // Adjust product stock to match physical
          await productRepo.adjustStock(item.productId, diff);
          // Track value: negative diff = loss at buyPrice
          if (diff < 0) {
            totalLossValue += diff.abs() * item.buyPrice;
          }
          // Also record as stock movement
          await db
              .into(db.stockMovements)
              .insert(
                StockMovementsCompanion.insert(
                  productId: item.productId,
                  type: diff > 0 ? 'in' : 'out',
                  qty: diff.abs(),
                  note: Value('Penyesuaian Stok Opname #$sessionId'),
                ),
              );
        } else {
          matchCount++;
        }
      }
    });

    if (!claimedSession) {
      final completed = await getSessionSummary(sessionId);
      if (completed.isNotEmpty) return completed;
      throw StateError('Sesi stok sedang diproses');
    }

    await (db.update(
      db.stockCounts,
    )..where((t) => t.id.equals(sessionId))).write(
      StockCountsCompanion(
        status: const Value('Selesai'),
        completedAt: Value(DateTime.now()),
        matchCount: Value(matchCount),
        diffCount: Value(diffCount),
      ),
    );

    // Push finalize session state (stok produk sudah di-push otomatis oleh
    // ProductRepository.adjustStock yang dipanggil di dalam transaksi).
    DeltaSyncService.I.pushDelta(
      table: 'stock_counts',
      recordId: sessionId.toString(),
      operation: 'UPDATE',
      data: {
        'id': sessionId,
        'status': 'Selesai',
        'matchCount': matchCount,
        'diffCount': diffCount,
      },
    );

    return {
      'totalProducts': items.length,
      'matchCount': matchCount,
      'diffCount': diffCount,
      'totalLossValue': totalLossValue,
    };
  }

  /// Get session summary with items.
  Future<Map<String, dynamic>> getSessionSummary(int sessionId) async {
    final session = await (db.select(
      db.stockCounts,
    )..where((t) => t.id.equals(sessionId))).getSingleOrNull();
    if (session == null) return {};

    final items = await getItems(sessionId);
    int totalLossValue = 0;
    for (final item in items) {
      if (item.physicalStock != null) {
        final diff = item.physicalStock! - item.systemStock;
        if (diff < 0) {
          totalLossValue += diff.abs() * item.buyPrice;
        }
      }
    }

    return {
      'totalProducts': session.totalProducts,
      'matchCount': session.matchCount,
      'diffCount': session.diffCount,
      'totalLossValue': totalLossValue,
      'items': items,
    };
  }
}
