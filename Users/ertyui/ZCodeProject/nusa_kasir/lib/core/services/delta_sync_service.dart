import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:nusa_kasir/core/cloud/cloud_gateway.dart';
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
          break;
        case 'transactions':
          final companion = _mapToTransaction(data);
          await _db!.into(_db!.transactions).insertOnConflictUpdate(companion);
          break;
        case 'categories':
          final companion = _mapToCategory(data);
          await _db!.into(_db!.categories).insertOnConflictUpdate(companion);
          break;
        case 'customers':
          final companion = _mapToCustomer(data);
          await _db!.into(_db!.customers).insertOnConflictUpdate(companion);
          break;
      }
    } catch (_) {
      // Non-fatal — delta apply failure should not break the app
    }
  }

  Future<void> _deleteRecord(String table, String recordId) async {
    final id = int.tryParse(recordId);
    if (id == null) return;

    try {
      switch (table) {
        case 'products':
          await (_db!.delete(_db!.products)..where((t) => t.id.equals(id))).go();
          break;
        case 'categories':
          await (_db!.delete(_db!.categories)..where((t) => t.id.equals(id)))
              .go();
          break;
        case 'customers':
          await (_db!.delete(_db!.customers)..where((t) => t.id.equals(id)))
              .go();
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
