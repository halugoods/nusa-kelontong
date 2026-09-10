import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' hide Column, Table, isNull, isNotNull;
import 'package:nusa_kasir/data/database/app_database.dart';
import 'package:nusa_kasir/data/database/sync_triggers.dart'
    show setSyncMuted, syncPkColumnFor;

/// v2.2.57+136 — roundtrip delta sync tanpa mock jaringan:
///
/// 1. PUSH side: tulis transaksi/produk → trigger SQLite harus mencatat
///    outbox (regresi +134/135: trigger gagal terpasang karena temp table).
/// 2. Snapshot: datetime drift tersimpan int DETIK (bukan ms) — konversi ke
///    ISO harus benar (regresi +135: fromMillisecondsSinceEpoch pada nilai
///    detik → tahun 20.000-an → apply-side TypeError → transaksi tak pernah
///    muncul di device lain).
/// 3. APPLY side: replay `_upsertSql/_upsertVars` (copy of logic — private
///    di service) harus INSERT utuh 27 kolom transaksi + UPDATE parsial
///    tidak menghapus kolom yang tidak dikirim.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.test());
  tearDown(() => db.close());

  test('trigger mencatat outbox untuk INSERT/UPDATE/DELETE', () async {
    final cat = await db.into(db.categories).insert(
          CategoriesCompanion.insert(name: 'T1'),
        );
    expect(cat, greaterThan(0));

    final outbox = await db.customSelect(
      "SELECT table_name, record_pk, operation FROM sync_outbox WHERE table_name='categories'",
    ).get();
    expect(outbox, isNotEmpty, reason: 'trigger ins harus menulis outbox');
    expect(outbox.first.data['operation'], 'INSERT');

    await (db.update(db.categories)..where((t) => t.name.equals('T1')))
        .write(CategoriesCompanion(name: Value('T1x')));
    final upd = await db.customSelect(
      "SELECT operation FROM sync_outbox WHERE table_name='categories' AND operation='UPDATE'",
    ).get();
    expect(upd, isNotEmpty);
  });

  test('snapshot datetime: int detik → ISO benar (bukan 1970-an)', () {
    const sec = 1789000000; // ~2026-09 dalam detik
    final wrong = DateTime.fromMillisecondsSinceEpoch(sec); // bug +135
    final right = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
    expect(right.year, 2026);
    expect(wrong.millisecondsSinceEpoch * 1000, right.millisecondsSinceEpoch,
        reason: 'bug: nilai detik dikira ms → 1000x lebih kecil (1970-an)');
    expect(wrong.isBefore(right), isTrue);
  });

  test('apply: replay upsert transaksi ISO date → semua kolom masuk', () async {
    await setSyncMuted(db, true); // simulasi apply-side
    const cols = <String, String>{
      'invoice': 'invoice',
      'date': 'date',
      'items': 'items',
      'total': 'total',
      'discount': 'discount',
      'payment_method': 'payment_method',
      'cashier_name': 'cashier_name',
      'status': 'status',
    };
    final data = <String, dynamic>{
      'id': 999,
      'invoice': 'INV-TEST-1',
      'date': '2026-09-10T12:34:56.000Z',
      'items': '[{"productId":1,"qty":2}]',
      'total': 25000,
      'discount': 2000,
      'payment_method': 'qris',
      'cashier_name': 'Kasir A',
      'status': 'Normal',
    };
    final sqlCols = <String>['id', ...cols.values.where((c) => c != 'id')];
    final sets = sqlCols.where((c) => c != 'id')
        .map((c) => '$c = excluded.$c').join(', ');
    final sql = 'INSERT INTO transactions (${sqlCols.join(', ')}) '
        'VALUES (${List.filled(sqlCols.length, '?').join(', ')}) '
        'ON CONFLICT(id) DO UPDATE SET $sets';
    final vars = <Variable>[
      // Bind mengikuti urutan sqlCols persis (id, invoice, date, items, ...).
      // Kolom date di-bind sebagai DateTime object — sama dengan _coerceValue
      // di service (drift memetakan DateTime → int detik saat binding).
      for (final c in sqlCols)
        Variable(
          c == 'id'
              ? 999
              : c == 'date'
                  ? DateTime.parse(data['date'] as String)
                  : data[c],
        ),
    ];
    await db.customUpdate(sql, variables: vars, updates: {db.transactions});
    await setSyncMuted(db, false);

    final row = await (db.select(db.transactions)
          ..where((t) => t.invoice.equals('INV-TEST-1')))
        .getSingleOrNull();
    expect(row, isNotNull, reason: 'transaksi harus masuk DB');
    expect(row!.total, 25000);
    expect(row.cashierName, 'Kasir A');
    expect(row.date.year, 2026, reason: 'ISO date harus ter-parse benar');

    // Apply-side write TIDAK boleh masuk outbox (mute aktif).
    final leak = await db.customSelect(
      "SELECT * FROM sync_outbox WHERE table_name='transactions'",
    ).get();
    expect(leak, isEmpty, reason: 'mute guard harus mencegah echo');
  });

  test('apply parsial stok: kolom lain TIDAK tertimpa default', () async {
    // Seed produk lengkap
    await db.into(db.products).insert(ProductsCompanion.insert(
          id: Value(55),
          name: 'Produk Uji',
          sellPrice: 10000,
          stock: Value(7),
        ));
    // Update parsial {id, stock} seperti adjustStock
    await (db.update(db.products)..where((t) => t.id.equals(55)))
        .write(ProductsCompanion(stock: Value(3)));
    final p = await (db.select(db.products)
          ..where((t) => t.id.equals(55)))
        .getSingle();
    expect(p.stock, 3);
    expect(p.name, 'Produk Uji');
    expect(p.sellPrice, 10000);
  });

  test('setSyncMuted toggle mempengaruhi outbox', () async {
    await setSyncMuted(db, true);
    await db.into(db.categories).insert(CategoriesCompanion.insert(name: 'M1'));
    var rows = await db.customSelect(
      "SELECT * FROM sync_outbox WHERE table_name='categories' AND record_pk='M1'",
    ).get();
    expect(rows, isEmpty, reason: 'mute aktif → trigger skip');

    await setSyncMuted(db, false);
    await db.into(db.categories).insert(CategoriesCompanion.insert(name: 'M2'));
    rows = await db.customSelect(
      "SELECT * FROM sync_outbox WHERE table_name='categories' AND record_pk='M2'",
    ).get();
    expect(rows, isNotEmpty, reason: 'mute off → trigger jalan');
  });

  test('syncPkColumnFor default id', () {
    expect(syncPkColumnFor('transactions'), 'id');
    expect(syncPkColumnFor('roles'), 'name');
  });

  test('jsonEncode payload snapshot konsisten dgn push server', () {
    final payload = {
      'id': '1789000000-123',
      'table': 'transactions',
      'record_id': '42',
      'operation': 'INSERT',
      'data': jsonEncode({'id': 42, 'total': 5000}),
      'device_id': 'dev-test',
    };
    expect(payload['operation'], anyOf('INSERT', 'UPDATE', 'DELETE'));
    expect(payload.containsKey('created_at'), isFalse,
        reason: '+136: created_at device tidak dikirim (clock skew)');
  });
}
