import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:nusa_kasir/core/services/delta_sync_service.dart';
import 'package:nusa_kasir/data/database/app_database.dart';

/// Item baris pembelian yang belum dicatat (dari form).
///
/// [isMaterial] true → bahan non-produk (mis. plastik): hanya dicatat
/// riwayatnya (item + MaterialPrices), TIDAK menyentuh stok produk.
/// [isMaterial] false → produk: stok masuk + harga modal (buyPrice) update.
class PurchaseItemInput {
  final int? productId;
  final String name; // nama produk atau bahan
  final int qty;
  final int buyPrice;
  final bool isMaterial;
  PurchaseItemInput({
    this.productId,
    required this.name,
    required this.qty,
    required this.buyPrice,
    this.isMaterial = false,
  });
}

/// Biaya tambahan pembelian (packing/ongkir/stiker dll).
class PurchaseExtraCost {
  final String name;
  final int amount;
  PurchaseExtraCost({required this.name, required this.amount});
  Map<String, dynamic> toJson() => {'name': name, 'amount': amount};
  factory PurchaseExtraCost.fromJson(Map<String, dynamic> j) =>
      PurchaseExtraCost(name: j['name'] ?? '', amount: j['amount'] ?? 0);
}

/// Pembelian/restok dari supplier.
///
/// `recordPurchase` mencatat semuanya atomically dalam satu transaksi DB:
/// 1. header [PurchaseOrders] + item [PurchaseOrderItems]
/// 2. untuk item PRODUK: stok masuk (`adjustStock` setara: stock += qty)
///    + harga modal (buyPrice) diperbarui → HPP / laba rugi presisi
///    + riwayat [StockMovements] type 'in'
/// 3. untuk item BAHAN: hanya dicatat di item + [MaterialPrices] (riwayat
///    harga beli bahan per supplier) — tanpa menyentuh stok produk
class PurchaseRepository {
  final AppDatabase db;
  PurchaseRepository(this.db);

  Future<List<PurchaseOrder>> getOrders() =>
      (db.select(db.purchaseOrders)..orderBy([
            (t) => OrderingTerm(expression: t.date, mode: OrderingMode.desc),
          ]))
          .get();

  Future<List<PurchaseOrderItem>> getItems(int orderId) => (db.select(
    db.purchaseOrderItems,
  )..where((t) => t.purchaseOrderId.equals(orderId))).get();

  Future<PurchaseOrder?> orderById(int id) => (db.select(
    db.purchaseOrders,
  )..where((t) => t.id.equals(id))).getSingleOrNull();

  /// Riwayat harga beli bahan per supplier (untuk melihat kenaikan/penurunan).
  Future<List<MaterialPrice>> getMaterialPrices(int supplierId) =>
      (db.select(db.materialPrices)
            ..where((t) => t.supplierId.equals(supplierId))
            ..orderBy([
              (t) => OrderingTerm(expression: t.date, mode: OrderingMode.desc),
              (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
            ]))
          .get();

  /// Daftar nama bahan unik yang pernah dibeli (untuk filter/riwayat).
  Future<List<String>> getMaterialNames() async {
    final rows = await (db.select(db.materialPrices)).get();
    return rows.map((r) => r.materialName).toSet().toList()..sort();
  }

  /// Catat pembelian supplier: stok masuk + harga modal dinamis + riwayat.
  ///
  /// [extraCosts] biaya tambahan (packing/ongkir/stiker): total biaya dibagi
  /// rata ke total qty item → biayaPerUnit ditambahkan ke buyPrice tiap item
  /// (HPP akurat). Disimpan di header [PurchaseOrders.extraCostsJson].
  Future<int> recordPurchase({
    required int supplierId,
    required String supplierName,
    required List<PurchaseItemInput> items,
    List<PurchaseExtraCost> extraCosts = const [],
    String? note,
  }) async {
    var orderId = 0;
    final pushedProductIds = <int>[];
    await db.transaction(() async {
      // ── 0. Alokasi biaya tambahan → per unit → HPP ──
      // Biaya (packing/ongkir/stiker) dibagi rata ke TOTAL QTY seluruh item,
      // lalu ditambahkan ke harga modal tiap unit. Sisa pembagian (karena
      // integer) dibebankan ke item TERAKHIR supaya Σ total item ==
      // subtotal + biaya tambahan PERSIS (tidak pernah selisih rupiah).
      final validCosts = extraCosts.where((c) => c.amount > 0).toList();
      final totalExtra = validCosts.fold<int>(0, (s, c) => s + c.amount);
      final totalQty = items.fold<int>(
        0,
        (s, i) => s + (i.qty > 0 ? i.qty : 0),
      );
      final costPerUnit = (totalExtra > 0 && totalQty > 0)
          ? totalExtra ~/ totalQty
          : 0;
      final remainder =
          (totalExtra > 0 && totalQty > 0) ? totalExtra % totalQty : 0;

      // ── 1. Header ──
      final subtotal = items.fold<int>(
        0,
        (sum, i) => sum + (i.qty * i.buyPrice),
      );
      final total = subtotal + totalExtra;
      final invoice = await _nextInvoice();
      orderId = await db
          .into(db.purchaseOrders)
          .insert(
            PurchaseOrdersCompanion.insert(
              invoice: invoice,
              supplierId: supplierId,
              supplierName: supplierName,
              total: Value(total),
              extraCostsJson: Value(
                validCosts.isEmpty
                    ? null
                    : jsonEncode(validCosts.map((c) => c.toJson()).toList()),
              ),
              note: Value(note),
            ),
          );

      // ── 2. Item + stok/harga modal (produk) atau riwayat bahan ──
      // Indeks item valid TERAKHIR — sisa pembagian (remainder) dibebankan ke
      // item itu supaya Σ total item == subtotal + biaya tambahan PERSIS.
      var lastValidIndex = -1;
      for (var i = 0; i < items.length; i++) {
        if (items[i].qty > 0) lastValidIndex = i;
      }
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        if (item.qty <= 0) continue;
        // HPP presisi: harga beli + bagian biaya tambahan (packing/ongkir dll).
        final unitPrice = item.buyPrice + costPerUnit;
        final isLastItem = i == lastValidIndex;
        final carry = (isLastItem && remainder > 0) ? remainder : 0;
        final itemTotal = (item.qty * unitPrice) + carry;
        await db
            .into(db.purchaseOrderItems)
            .insert(
              PurchaseOrderItemsCompanion.insert(
                purchaseOrderId: orderId,
                productId: Value(item.productId),
                productName: item.name,
                qty: item.qty,
                buyPrice: unitPrice,
                total: itemTotal,
                isMaterial: Value(item.isMaterial),
              ),
            );

        if (item.isMaterial) {
          // Bahan non-produk: simpan riwayat harga beli per supplier.
          await db
              .into(db.materialPrices)
              .insert(
                MaterialPricesCompanion.insert(
                  supplierId: supplierId,
                  orderId: orderId,
                  materialName: item.name,
                  price: unitPrice,
                  qty: Value(item.qty),
                  date: Value(DateTime.now()),
                ),
              );
          // v2.2.43 (F&B): kalau bahan ini TERDAFTAR di RawMaterials (bahan
          // baku tab ke-3 menu Produk) → stok bahan bertambah + costPrice
          // (HPP) mengikuti harga beli terbaru. Nama dicocokkan case-insensitive.
          final rm = await (db.select(db.rawMaterials)
                ..where((t) => t.name.lower().equals(item.name.trim().toLowerCase())))
              .getSingleOrNull();
          if (rm != null) {
            final nextStock = rm.stock + item.qty;
            await (db.update(db.rawMaterials)..where((t) => t.id.equals(rm.id)))
                .write(RawMaterialsCompanion(
              stock: Value(nextStock),
              costPrice: Value(unitPrice),
              updatedAt: Value(DateTime.now()),
            ));
          }
          continue;
        }

        final pid = item.productId;
        if (pid == null) continue;
        // Stok bertambah (tanpa clamp — restok memang menambah stok).
        final p = await (db.select(
          db.products,
        )..where((t) => t.id.equals(pid))).getSingleOrNull();
        if (p == null) continue;
        final next = p.stock + item.qty;
        await (db.update(db.products)..where((t) => t.id.equals(pid))).write(
          ProductsCompanion(
            stock: Value(next),
            // Harga modal mengikuti harga beli terbaru — HPP presisi.
            buyPrice: Value(unitPrice),
            // Link produk ke supplier pembelian (terakhir dipasok dari mana).
            supplierId: Value(supplierId),
          ),
        );
        pushedProductIds.add(pid);
        // Riwayat stok masuk, biar laporan Stok lengkap.
        await db
            .into(db.stockMovements)
            .insert(
              StockMovementsCompanion.insert(
                productId: pid,
                type: 'in',
                qty: item.qty,
                note: Value('Pembelian $supplierName'),
              ),
            );
      }
    });

    // Push deltas setelah transaksi commit: header + stok/harga modal produk.
    if (orderId > 0) {
      final order = await orderById(orderId);
      DeltaSyncService.I.pushDelta(
        table: 'purchase_orders',
        recordId: orderId.toString(),
        operation: 'INSERT',
        data: {
          'id': orderId,
          'invoice': order?.invoice ?? '',
          'supplierId': supplierId,
          'supplierName': supplierName,
          'total': order?.total ?? 0,
          'note': note,
        },
      );
      for (final pid in pushedProductIds) {
        final p = await (db.select(
          db.products,
        )..where((t) => t.id.equals(pid))).getSingleOrNull();
        if (p == null) continue;
        DeltaSyncService.I.pushDelta(
          table: 'products',
          recordId: pid.toString(),
          operation: 'UPDATE',
          data: {
            'id': pid,
            'stock': p.stock,
            'buyPrice': p.buyPrice,
            'supplierId': supplierId,
          },
        );
      }
    }
    return orderId;
  }

  Future<String> _nextInvoice() async {
    final now = DateTime.now();
    final prefix = 'PB-${now.year}${_2(now.month)}${_2(now.day)}';
    final count = await (db.select(
      db.purchaseOrders,
    )..where((t) => t.invoice.like('$prefix%'))).get();
    return '$prefix-${(count.length + 1).toString().padLeft(3, '0')}';
  }

  static String _2(int n) => n.toString().padLeft(2, '0');

  /// Total pengeluaran pembelian pada rentang tanggal (untuk laporan keuangan).
  Future<int> totalSpentBetween(DateTime from, DateTime to) async {
    final rows =
        await (db.select(db.purchaseOrders)..where(
              (t) =>
                  t.date.isBiggerOrEqual(Constant(from)) &
                  t.date.isSmallerOrEqual(Constant(to)),
            ))
            .get();
    return rows.fold<int>(0, (sum, o) => sum + o.total);
  }
}
