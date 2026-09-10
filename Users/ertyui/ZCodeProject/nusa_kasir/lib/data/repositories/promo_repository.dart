import 'package:drift/drift.dart';
import 'package:nusa_kasir/core/services/delta_sync_service.dart';
import 'package:nusa_kasir/data/database/app_database.dart';

class PromoRepository {
  final AppDatabase db;
  PromoRepository(this.db);

  Future<int> addPromo({
    required String name,
    required String code,
    required String type, // 'persen' | 'nominal'
    required int value,
    int minBelanja = 0,
    DateTime? startDate,
    DateTime? endDate,
    int? maxUses,
    String status = 'Aktif',
    String mode = 'otomatis', // 'otomatis' | 'kode' | 'bebas'
  }) async {
    final newId = await db.into(db.promos).insert(PromosCompanion.insert(
      name: name,
      code: code,
      type: type,
      value: value,
      minBelanja: Value(minBelanja),
      startDate: Value(startDate),
      endDate: Value(endDate),
      maxUses: Value(maxUses),
      status: Value(status),
      mode: Value(mode),
    ));
    DeltaSyncService.I.pushDelta(
      table: 'promos',
      recordId: newId.toString(),
      operation: 'INSERT',
      data: {
        'id': newId,
        'name': name,
        'code': code,
        'type': type,
        'value': value,
        'minBelanja': minBelanja,
        'startDate': startDate?.toIso8601String(),
        'endDate': endDate?.toIso8601String(),
        'maxUses': maxUses,
        'status': status,
        'mode': mode,
      },
    );
    return newId;
  }

  Future<List<Promo>> getPromos() =>
      (db.select(db.promos)
            ..orderBy([
              (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc)
            ]))
          .get();

  Future<Promo?> byId(int id) =>
      (db.select(db.promos)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> updateStatus(int id, String status) async {
    await (db.update(db.promos)..where((t) => t.id.equals(id)))
        .write(PromosCompanion(status: Value(status)));
    DeltaSyncService.I.pushDelta(
      table: 'promos',
      recordId: id.toString(),
      operation: 'UPDATE',
      data: {'id': id, 'status': status},
    );
  }

  Future<void> incrementUsed(int id) async {
    final p = await byId(id);
    if (p == null) return;
    await (db.update(db.promos)..where((t) => t.id.equals(id)))
        .write(PromosCompanion(usedCount: Value(p.usedCount + 1)));
    DeltaSyncService.I.pushDelta(
      table: 'promos',
      recordId: id.toString(),
      operation: 'UPDATE',
      data: {'id': id, 'usedCount': p.usedCount + 1},
    );
  }

  Future<void> updatePromo(int id,
      {String? name,
      String? code,
      String? type,
      int? value,
      int? minBelanja,
      DateTime? startDate,
      DateTime? endDate,
      int? maxUses,
      String? status,
      String? mode}) async {
    var companion = const PromosCompanion();
    if (name != null) companion = companion.copyWith(name: Value(name));
    if (code != null) companion = companion.copyWith(code: Value(code));
    if (type != null) companion = companion.copyWith(type: Value(type));
    if (value != null) companion = companion.copyWith(value: Value(value));
    if (minBelanja != null) {
      companion = companion.copyWith(minBelanja: Value(minBelanja));
    }
    if (startDate != null) {
      companion = companion.copyWith(startDate: Value(startDate));
    }
    if (endDate != null) {
      companion = companion.copyWith(endDate: Value(endDate));
    }
    if (maxUses != null) companion = companion.copyWith(maxUses: Value(maxUses));
    if (status != null) companion = companion.copyWith(status: Value(status));
    if (mode != null) companion = companion.copyWith(mode: Value(mode));
    await (db.update(db.promos)..where((t) => t.id.equals(id))).write(companion);
    DeltaSyncService.I.pushDelta(
      table: 'promos',
      recordId: id.toString(),
      operation: 'UPDATE',
      data: {
        'id': id,
        'name': name,
        'code': code,
        'type': type,
        'value': value,
        'minBelanja': minBelanja,
        'startDate': startDate?.toIso8601String(),
        'endDate': endDate?.toIso8601String(),
        'maxUses': maxUses,
        'status': status,
        'mode': mode,
      },
    );
  }

  Future<void> deletePromo(int id) async {
    await (db.delete(db.promos)..where((t) => t.id.equals(id))).go();
    DeltaSyncService.I.pushDelta(
      table: 'promos',
      recordId: id.toString(),
      operation: 'DELETE',
      data: {'id': id},
    );
  }
}
