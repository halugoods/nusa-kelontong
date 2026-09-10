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
import 'package:nusa_kasir/data/database/sync_triggers.dart'
    show setSyncMuted, syncPkColumnFor;

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
  // v2.2.57+135: interval flush safety-net (outbox dibaca trigger SQLite).
  static const _flushInterval = Duration(seconds: 5);
  static const _maxBatchSize = 50;

  final _controller = StreamController<DeltaEvent>.broadcast();
  Stream<DeltaEvent> get stream => _controller.stream;

  AppDatabase? _db;
  bool _started = false;
  Timer? _pushTimer;
  Timer? _periodicPull;
  Timer? _periodicFlush;
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

    // v2.2.57+135: safety-net periodic flush — trigger menulis outbox
    // langsung dari SQLite TANPA tahu DeltaSyncService ada. Dulu flush cuma
    // jalan via pushDelta shim (hanya dipanggil repo tertentu) / flush awal —
    // perubahan yang ditulis jalur lain (mis. saveTransaction) menumpuk di
    // outbox sampai perubahan berikutnya. Sekarang: coalesce — kalau outbox
    // kosong, flush jadi no-op murah; kalau ada isi, keluar dalam 2 dtk.
    _periodicFlush = Timer.periodic(_flushInterval, (_) => _flushOutbox());

    // v2.2.57+134: flush sisa outbox dari sesi sebelumnya + outbox yg
    // tertimbun saat offline (retry stranded flush).
    _scheduleFlush();
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

  /// v2.2.57+134: pushDelta manual TIDAK DIPAKAI LAGI — semua perubahan
  /// di-capture trigger SQLite ke outbox `sync_outbox` (lihat
  /// sync_triggers.dart). Fungsi ini tinggal demi kompatibilitas call-site
  /// lama: outbox trigger akan mencatat perubahan yang sama, jadi cukup
  /// pastikan flush jalan.
  Future<void> pushDelta({
    required String table,
    required String recordId,
    required String operation, // INSERT, UPDATE, DELETE
    Map<String, dynamic>? data,
  }) async {
    _scheduleFlush();
  }

  void _scheduleFlush() {
    _pushTimer?.cancel();
    _pushTimer = Timer(_pushDebounce, _flushOutbox);
  }

  /// v2.2.57+134: flush outbox hasil trigger — ambil baris TERAKHIR per
  /// (table, pk), baca snapshot datanya langsung dari DB, kirim ke cloud.
  /// Beberapa UPDATE ke baris sama otomatis kolaps; DELETE tanpa payload.
  Future<void> _flushOutbox() async {
    if (_db == null || _uid == null || _deviceId == null) return;

    try {
      // 1. Kandidat = baris terakhir per (table_name, record_pk), FIFO.
      //    v2.2.57+136: ORDER BY max_id dulu lalu take — dulu sort sesudah
      //    LIMIT sehingga grup yang kepotong tak selalu yang terlama (delta
      //    lama bisa menunggu berkali-kali flush).
      final rows = await _db!.customSelect('''
        SELECT o.table_name, o.record_pk, o.operation, MAX(o.id) AS max_id
        FROM sync_outbox o
        GROUP BY o.table_name, o.record_pk
        ORDER BY max_id ASC
        LIMIT ?
      ''', variables: [Variable.withInt(_maxBatchSize)]).get();

      if (rows.isEmpty) return;

      final batch = rows.toList();
      final maxIdInBatch =
          batch.map((r) => r.data['max_id'] as int).reduce((a, b) => a > b ? a : b);

      final deltas = <Map<String, dynamic>>[];

      for (final row in batch) {
        final table = '${row.data['table_name']}';
        final pk = '${row.data['record_pk']}';
        final op = '${row.data['operation']}';
        if (table.isEmpty || pk.isEmpty) continue;

        // 2. Snapshot data dari DB utk INSERT/UPDATE.
        Map<String, dynamic>? data;
        if (op != 'DELETE') {
          data = await _snapshotRow(table, pk);
          if (data == null) {
            // Baris sudah hilang (di-DELETE setelah INSERT/UPDATE) →
            // kirim DELETE supaya device lain ikut menghapus.
            deltas.add({
              'id': _uuid(),
              'table': table,
              'record_id': pk,
              'operation': 'DELETE',
              'data': null,
              'device_id': _deviceId,
            });
            continue;
          }
        }

        deltas.add({
          'id': _uuid(),
          'table': table,
          'record_id': pk,
          'operation': op,
          'data': data != null ? jsonEncode(data) : null,
          'device_id': _deviceId,
        });
        // v2.2.57+136: created_at device TIDAK dikirim. Dulu timestamp device
        // (jam HP) bisa di belakang timestamp server → worker pull dengan
        // since=server_time melewatkan delta barunya (SKIP permanen).
      }

      if (deltas.isEmpty) {
        // Tidak ada delta valid — bersihkan outbox sampai max id batch.
        await _db!.customStatement(
          'DELETE FROM sync_outbox WHERE id <= ?',
          [maxIdInBatch],
        );
        return;
      }

      // 3. Push (dengan device_id! — sebelumnya 401 karena tidak dikirim).
      final result = await CloudGateway.shared.invoke('sync-delta', body: {
        'action': 'push',
        'deltas': deltas,
        'uid': _uid!,
        'google_user_id': _uid!,
        'device_id': _deviceId!,
      });

      if (result.ok) {
        await _db!.customStatement(
          'DELETE FROM sync_outbox WHERE id <= ?',
          [maxIdInBatch],
        );
      } else {
        debugPrint('[DeltaSync] push failed (${result.status}): ${result.error ?? result.data}');
        _scheduleFlushRetry();
      }
    } catch (e) {
      debugPrint('[DeltaSync] flush error: $e');
      _scheduleFlushRetry();
    }
  }

  /// Retry backoff sederhana untuk flush yang gagal (offline / 5xx) —
  /// sebelumnya delta stranded sampai perubahan berikutnya.
  void _scheduleFlushRetry() {
    _pushTimer?.cancel();
    _pushTimer = Timer(const Duration(seconds: 10), _flushOutbox);
  }

  /// Ambil satu baris sebagai map jsonKey → nilai (siap di-encode JSON).
  /// Mapping snake_case kolom → camelCase jsonKey dilakukan terbalik dari
  /// _xxxCols supaya apply-side (_partialUpdate/_mapToXxx) menerima bentuk
  /// yang sama dengan pushDelta lama. Tabel tanpa map → select * apa adanya
  /// (kolom snake_case tetap konsisten dengan _cols di apply-side).
  Future<Map<String, dynamic>?> _snapshotRow(String table, String pk) async {
    try {
      final pkCol = syncPkColumnFor(table);
      final row = await _db!.customSelect(
        'SELECT * FROM $table WHERE $pkCol = ? LIMIT 1',
        variables: [Variable.withString(pk)],
      ).getSingleOrNull();
      if (row == null) return null;
      final data = Map<String, dynamic>.from(row.data);
      // image_base64/photo_base64 TIDAK ikut delta (besar & redundan —
      // gambar tersimpan di R2; apply-side hydrate dari R2).
      data.remove('image_base64');
      data.remove('photo_base64');
      // v2.2.57+136 FIX KRITIS: kolom datetime drift disimpan SQLite sebagai
      // int DETIK (millisecondsSinceEpoch ~/ 1000 — lihat drift mapping.dart),
      // bukan ms! Dulu dikonversi with fromMillisecondsSinceEpoch → ISO
      // 20.000 tahun di masa depan, dan apply-side (_mapToTransaction) yang
      // expect int malah dapat string → TypeError → transaksi GAGAL apply
      // diam-diam. Sekarang: detik → ISO benar; apply-side menerima bentuk
      // int-detik ATAU ISO.
      for (final e in data.entries.toList()) {
        final v = e.value;
        if (v is int && _looksLikeDatetimeColumn(table, e.key)) {
          data[e.key] = DateTime.fromMillisecondsSinceEpoch(v * 1000)
              .toUtc()
              .toIso8601String();
        }
      }
      return data;
    } catch (_) {
      return null;
    }
  }

  bool _looksLikeDatetimeColumn(String table, String col) {
    // Kolom datetime drift (snake_case) yang ada di tabel synced.
    const dtCols = <String>{
      'date', 'created_at', 'updated_at', 'expiry_date', 'voided_at',
      'opened_at', 'closed_at', 'start_date', 'end_date', 'due_date',
      'debt_date', 'paid_at', 'next_date', 'joined_at', 'last_backup_at',
    };
    return dtCols.contains(col);
  }

  Future<void> _pull() async {
    if (_db == null || _uid == null) return;

    try {
      // v2.2.57+136: since pakai server_time dari pull sebelumnya — JAM
      // SERVER, bukan jam device (device clock bisa meleset → delta di-skip).
      // Pull lama tanpa server_time tersimpan → fallback DateTime sekarang
      // hanya untuk device yang belum pernah dapat server_time.
      var since = await SecureStore.getLastDeltaPull();
      since ??= DateTime.now().toUtc().subtract(const Duration(minutes: 5));
      final sinceBase = since;

      String? serverTime;
      var guard = 0;
      // v2.2.57+136: has_more diikuti sampai habis — dulu cuma batch 100
      // pertama per pull → saat sync pertama / offline lama, sisa delta
      // nunggu tick 30 detik berikutnya (n batch = n×30 detik).
      do {
        final result = await CloudGateway.shared.invoke('sync-delta', body: {
          'action': 'pull',
          'since': sinceBase.toIso8601String(),
          'limit': 200,
          'uid': _uid!,
          'google_user_id': _uid!,
          // v2.2.57+134: WAJIB — sebelumnya tidak dikirim → worker deviceWrap
          // menolak 401 (device_id tidak ada) DAN filter device_id != 'unknown'
          // salah sehingga device bisa menarik delta-nya sendiri.
          if (_deviceId != null) 'device_id': _deviceId!,
        });

        if (!result.ok) return;

        final data = result.data;
        if (data is! Map) return;

        final deltas = (data['deltas'] as List?) ?? [];
        serverTime = data['server_time'] as String? ?? serverTime;

        if (deltas.isEmpty) break;

        // v2.2.57+134/136: mute trigger selama apply — tulisan hasil apply
        // tidak boleh masuk outbox lagi (ping-pong antar device tanpa ujung).
        await setSyncMuted(_db!, true);
        final appliedIds = <String>[];
        var changed = false;
        try {
          for (final d in deltas) {
            if (d is! Map) continue;
            final delta = Map<String, dynamic>.from(d);
            // v2.2.57+136: apply SEKARANG mencekoki data (parse/validasi) dan
            // HANYA delta yang sukses di-ack. Dulu semua id di-ack walau apply
            // crash → delta gagal hilang PERMANEN dari server.
            try {
              await _applyDelta(delta);
              final id = delta['id'];
              if (id is String && id.isNotEmpty) appliedIds.add(id);
              changed = true;
            } catch (e) {
              debugPrint(
                  '[DeltaSync] apply failed (NOT acked) ${delta['table']}/${delta['record_id']}: $e');
            }
          }
        } finally {
          await setSyncMuted(_db!, false);
        }

        // Ack received deltas
        if (appliedIds.isNotEmpty) {
          try {
            await CloudGateway.shared.invoke('sync-delta', body: {
              'action': 'ack',
              'delta_ids': appliedIds,
              'uid': _uid!,
              'google_user_id': _uid!,
              if (_deviceId != null) 'device_id': _deviceId!,
            });
          } catch (_) {}
        }

        // v2.2.57+136: beri tahu UI bahwa DB berubah (refresh layar yang
        // load-once: dashboard, transaksi, produk, POS).
        if (changed) _controller.add(DeltaEvent(
          table: '*',
          recordId: '',
          operation: 'BATCH',
        ));

        since = serverTime != null
            ? (DateTime.tryParse(serverTime)?.toUtc() ?? since)
            : since;
        if (!changed) {
          // Semua delta gagal apply — jangan ulang loop tanpa akhir; keluar
          // dan andalkan retry tick berikutnya.
          break;
        }
      } while (serverTime != null && ++guard < 10);

      if (serverTime != null) {
        await SecureStore.setLastDeltaPull(
            DateTime.tryParse(serverTime)?.toUtc() ?? DateTime.now().toUtc());
      }
    } catch (e) {
      debugPrint('[DeltaSync] pull error: $e');
    }
  }

  Future<void> _applyDelta(Map<String, dynamic> delta) async {
    if (_db == null) return;

    // v2.2.57+134: server D1 sync_queue kolomnya table_name/operation —
    // dulu app baca 'table' → selalu kosong → apply no-op diam-diam!
    final table = (delta['table'] ?? delta['table_name']) as String? ?? '';
    final recordId = delta['record_id'] as String? ?? '';
    final operation =
        (delta['operation'] ?? delta['op']) as String? ?? '';
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
    } catch (e) {
      // v2.2.57+136: JANGAN ditelan di sini — caller butuh tahu delta ini
      // gagal supaya TIDAK di-ack (delta tetap di server, di-retry nanti).
      debugPrint('[DeltaSync] apply error for $table/$recordId: $e');
      rethrow;
    } finally {
      // Notify UI tetap dikirim walau delta gagal (best-effort refresh).
      _controller.add(DeltaEvent(
        table: table,
        recordId: recordId,
        operation: operation,
      ));
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
          // v2.2.57+133 (anti-clobber): delta UPDATE parsial (mis. {id,stock}
          // dari adjustStock) HANYA boleh menulis kolom yang dikirim. Dulu
          // insertOnConflictUpdate dengan companion penuh menimpa field yang
          // tidak dikirim dengan default (nama kosong, harga 0, imagePath
          // NULL) — "foto produk hilang semua" di device penerima.
          // v2.2.57+136: full-mapper dijalankan dulu (absent-aware — kolom
          // tak-dikirim = Value.absent(), BUKAN default kosong) sehingga
          // INSERT maupun UPDATE keduanya utuh; UPDATE parsial tetap jalan
          // untuk payload kecil.
          final looksPartial = data.length <= 3 && !data.containsKey('name');
          if (looksPartial) {
            await _partialUpdate('products', recordId, data, _productCols);
          } else {
            await _db!.customUpdate(
              _upsertSql('products', _productCols,
                  pkColumn: 'id', data: data),
              variables: _upsertVars(_productCols, data, id: recordId),
              updates: {_db!.products},
            );
          }
          // Download image from cloud if product has image_path but local
          // file missing. v2.2.57+136: mute sudah lepas saat future ini jalan
          // (fire-and-forget setelah apply) → tulisan imagePath baru hasil
          // hydrate di-capture trigger dan balik ke device asal — dulu ikut
          // terekap dalam mute window → device asal menolak (device_id !=
          // miliknya) tapi image_path lokal device lain tidak valid buatnya
          // (file tak ada → langsung hydrate juga). Aman dua arah.
          final imgPath = data['image_path'] as String?;
          if (imgPath != null && imgPath.isNotEmpty) {
            final file = File(imgPath);
            if (!await file.exists()) {
              // Tunggu mute lepas dulu (unawaited) supaya update imagePath
              // hasil hydrate ter-capture trigger untuk device asal.
              unawaited(_hydrateProductImage(recordId, imgPath));
            }
          }
          break;
        case 'transactions':
          // v2.2.57+136 FIX UTAMA "trx tidak pernah muncul di owner":
          // _mapToTransaction lama expect data['date'] int MILLISECOND,
          // padahal push mengirim ISO string (dan int detik dari SQLite) →
          // TypeError SETIAP kali → catch di _upsertRecord menelan →
          // transaksi tak pernah masuk DB penerima. Mapper baru absent-aware
          // + menerima int-detik / int-ms / ISO + jangan pernah gagal karena
          // format tanggal.
          await _db!.customUpdate(
            _upsertSql('transactions', _txCols,
                pkColumn: 'id', data: data),
            variables: _upsertVars(_txCols, data, id: recordId),
            updates: {_db!.transactions},
          );
          break;
        case 'categories':
          await _upsertCategory(data);
          break;
        case 'customers':
          if (data.containsKey('name')) {
            await _db!.into(_db!.customers)
                .insertOnConflictUpdate(_mapToCustomer(data));
          } else {
            await _partialUpdate('customers', recordId, data, _customerCols);
          }
          break;
        case 'roles':
          // PK = name; upsert by name (access/color full payload).
          final roleName = data['name'] as String? ?? recordId;
          final existing = await (_db!.select(_db!.roles)
                ..where((t) => t.name.equals(roleName)))
              .getSingleOrNull();
          if (existing == null) {
            await _db!.into(_db!.roles).insert(_mapToRole(data));
          } else {
            await _partialUpdate('roles', roleName, data, _roleCols);
          }
          break;
        case 'employees':
          final emp = await (_db!.select(_db!.employees)
                ..where((t) => t.id.equals(int.tryParse(recordId) ?? 0)))
              .getSingleOrNull();
          if (emp == null) {
            await _db!.into(_db!.employees)
                .insertOnConflictUpdate(_mapToEmployee(data));
          } else {
            await _partialUpdate('employees', recordId, data, _employeeCols);
          }
          break;
        case 'branches':
          final br = await (_db!.select(_db!.branches)
                ..where((t) => t.id.equals(int.tryParse(recordId) ?? 0)))
              .getSingleOrNull();
          if (br == null) {
            await _db!.into(_db!.branches)
                .insertOnConflictUpdate(_mapToBranch(data));
          } else {
            await _partialUpdate('branches', recordId, data, _branchCols);
          }
          break;
        case 'promos':
          final promo = await (_db!.select(_db!.promos)
                ..where((t) => t.id.equals(int.tryParse(recordId) ?? 0)))
              .getSingleOrNull();
          if (promo == null) {
            await _db!.into(_db!.promos)
                .insertOnConflictUpdate(_mapToPromo(data));
          } else {
            await _partialUpdate('promos', recordId, data, _promoCols);
          }
          break;
        case 'suppliers':
          final sup = await (_db!.select(_db!.suppliers)
                ..where((t) => t.id.equals(int.tryParse(recordId) ?? 0)))
              .getSingleOrNull();
          if (sup == null) {
            await _db!.into(_db!.suppliers)
                .insertOnConflictUpdate(_mapToSupplier(data));
          } else {
            await _partialUpdate('suppliers', recordId, data, _supplierCols);
          }
          break;
        case 'customer_debts':
          final debt = await (_db!.select(_db!.customerDebts)
                ..where((t) => t.id.equals(int.tryParse(recordId) ?? 0)))
              .getSingleOrNull();
          if (debt == null) {
            await _db!.into(_db!.customerDebts)
                .insertOnConflictUpdate(_mapToDebt(data));
          } else {
            await _partialUpdate('customer_debts', recordId, data, _debtCols);
          }
          break;
        case 'expenses':
          final exp = await (_db!.select(_db!.expenses)
                ..where((t) => t.id.equals(int.tryParse(recordId) ?? 0)))
              .getSingleOrNull();
          if (exp == null) {
            await _db!.into(_db!.expenses)
                .insertOnConflictUpdate(_mapToExpense(data));
          } else {
            await _partialUpdate('expenses', recordId, data, _expenseCols);
          }
          break;
        case 'liquidity':
          final liq = await (_db!.select(_db!.liquidity)
                ..where((t) => t.id.equals(int.tryParse(recordId) ?? 0)))
              .getSingleOrNull();
          if (liq == null) {
            await _db!.into(_db!.liquidity)
                .insertOnConflictUpdate(_mapToLiquidity(data));
          } else {
            await _partialUpdate('liquidity', recordId, data, _liquidityCols);
          }
          break;
        case 'attendance':
          final att = await (_db!.select(_db!.attendance)
                ..where((t) => t.id.equals(int.tryParse(recordId) ?? 0)))
              .getSingleOrNull();
          if (att == null) {
            await _db!.into(_db!.attendance)
                .insertOnConflictUpdate(_mapToAttendance(data));
          } else {
            await _partialUpdate('attendance', recordId, data, _attendanceCols);
          }
          break;
        case 'online_orders':
          final oo = await (_db!.select(_db!.onlineOrders)
                ..where((t) => t.id.equals(int.tryParse(recordId) ?? 0)))
              .getSingleOrNull();
          if (oo == null) {
            await _db!.into(_db!.onlineOrders)
                .insertOnConflictUpdate(_mapToOnlineOrder(data));
          } else {
            await _partialUpdate(
                'online_orders', recordId, data, _onlineOrderCols);
          }
          break;
        case 'settings':
          await _applySettingsDelta(data);
          break;
        case 'waste':
          final ws = await (_db!.select(_db!.waste)
                ..where((t) => t.id.equals(int.tryParse(recordId) ?? 0)))
              .getSingleOrNull();
          if (ws == null) {
            await _db!.into(_db!.waste).insertOnConflictUpdate(_mapToWaste(data));
          } else {
            await _partialUpdate('waste', recordId, data, _wasteCols);
          }
          break;
        case 'payroll':
          final pr = await (_db!.select(_db!.payroll)
                ..where((t) => t.id.equals(int.tryParse(recordId) ?? 0)))
              .getSingleOrNull();
          if (pr == null) {
            await _db!.into(_db!.payroll)
                .insertOnConflictUpdate(_mapToPayroll(data));
          } else {
            await _partialUpdate('payroll', recordId, data, _payrollCols);
          }
          break;
        case 'recurring_expenses':
          final re = await (_db!.select(_db!.recurringExpenses)
                ..where((t) => t.id.equals(int.tryParse(recordId) ?? 0)))
              .getSingleOrNull();
          if (re == null) {
            await _db!.into(_db!.recurringExpenses)
                .insertOnConflictUpdate(_mapToRecurring(data));
          } else {
            await _partialUpdate(
                'recurring_expenses', recordId, data, _recurringCols);
          }
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
          final dp = await (_db!.select(_db!.debtPayments)
                ..where((t) => t.id.equals(int.tryParse(recordId) ?? 0)))
              .getSingleOrNull();
          if (dp == null) {
            await _db!.into(_db!.debtPayments)
                .insertOnConflictUpdate(_mapToDebtPayment(data));
          } else {
            await _partialUpdate(
                'debt_payments', recordId, data, _debtPaymentCols);
          }
          break;
        case 'purchase_orders':
          final po = await (_db!.select(_db!.purchaseOrders)
                ..where((t) => t.id.equals(int.tryParse(recordId) ?? 0)))
              .getSingleOrNull();
          if (po == null) {
            await _db!.into(_db!.purchaseOrders)
                .insertOnConflictUpdate(_mapToPurchaseOrder(data));
          } else {
            await _partialUpdate(
                'purchase_orders', recordId, data, _purchaseOrderCols);
          }
          break;
        case 'stock_counts':
          final sc = await (_db!.select(_db!.stockCounts)
                ..where((t) => t.id.equals(int.tryParse(recordId) ?? 0)))
              .getSingleOrNull();
          if (sc == null) {
            await _db!.into(_db!.stockCounts)
                .insertOnConflictUpdate(_mapToStockCount(data));
          } else {
            await _partialUpdate('stock_counts', recordId, data, _stockCountCols);
          }
          break;
        case 'stock_count_items':
          final sci = await (_db!.select(_db!.stockCountItems)
                ..where((t) => t.id.equals(int.tryParse(recordId) ?? 0)))
              .getSingleOrNull();
          if (sci == null) {
            await _db!.into(_db!.stockCountItems)
                .insertOnConflictUpdate(_mapToStockCountItem(data));
          } else {
            await _partialUpdate(
                'stock_count_items', recordId, data, _stockCountItemCols);
          }
          break;
        case 'print_orders':
          final pord = await (_db!.select(_db!.printOrders)
                ..where((t) => t.id.equals(int.tryParse(recordId) ?? 0)))
              .getSingleOrNull();
          if (pord == null) {
            await _db!.into(_db!.printOrders)
                .insertOnConflictUpdate(_mapToPrintOrder(data));
          } else {
            await _partialUpdate('print_orders', recordId, data, _printOrderCols);
          }
          break;
        case 'point_histories':
          final ph = await (_db!.select(_db!.pointHistories)
                ..where((t) => t.id.equals(int.tryParse(recordId) ?? 0)))
              .getSingleOrNull();
          if (ph == null) {
            await _db!.into(_db!.pointHistories)
                .insertOnConflictUpdate(_mapToPointHistory(data));
          } else {
            await _partialUpdate(
                'point_histories', recordId, data, _pointHistoryCols);
          }
          break;
      }
    } catch (_) {
      // Non-fatal — delta apply failure should not break the app
    }
  }

  /// v2.2.57+133 (anti-clobber): UPDATE parsial — tulis HANYA kolom yang ada
  /// di payload. Nilai dikonversi sesuai tipe kolom drift; JSON-encoded text
  /// (accessJson) sudah string dari push. Baris tidak ada → di-skip (push
  /// INSERT yang sesuai akan datang dari device sumber).
  Future<void> _partialUpdate(
    String sqlTable,
    String recordId,
    Map<String, dynamic> data,
    Map<String, String> cols, // jsonKey → SQL column
  ) async {
    final id = int.tryParse(recordId);
    final fields = <String, dynamic>{};
    for (final entry in cols.entries) {
      if (!data.containsKey(entry.key) && !data.containsKey(_snake(entry.key))) {
        continue;
      }
      if (entry.key == 'id') continue; // PK tidak ikut SET
      // Terima jsonKey camelCase ATAU snake_case (snapshot trigger mengirim
      // snake_case; pushDelta manual kadang mengirim camelCase).
      final v = data.containsKey(entry.key)
          ? data[entry.key]
          : data[_snake(entry.key)];
      fields[entry.value] = _coerceValue(entry.value, v);
    }
    if (fields.isEmpty) return;
    final whereCol = 'id';
    final whereVal = id != null ? id : recordId;
    final sets = fields.keys.map((f) => '$f = ?').join(', ');
    // v2.2.57+136: customUpdate(updates:) — notify drift stream query agar
    // UI yang watch tabel ikut rebuild. customStatement TIDAK notify.
    await _db!.customUpdate(
      'UPDATE $sqlTable SET $sets WHERE $whereCol = ?',
      variables: [...fields.values.map(Variable.new), Variable(whereVal)],
      updates: {_tableFor(sqlTable)},
      updateKind: UpdateKind.update,
    );
  }

  /// Map nama tabel SQL → ResultSetImplementation drift untuk notify stream.
  ResultSetImplementation _tableFor(String sqlTable) {
    switch (sqlTable) {
      case 'products':
        return _db!.products;
      case 'transactions':
        return _db!.transactions;
      case 'customers':
        return _db!.customers;
      case 'categories':
        return _db!.categories;
      case 'roles':
        return _db!.roles;
      case 'employees':
        return _db!.employees;
      case 'branches':
        return _db!.branches;
      case 'promos':
        return _db!.promos;
      case 'suppliers':
        return _db!.suppliers;
      case 'customer_debts':
        return _db!.customerDebts;
      case 'debt_payments':
        return _db!.debtPayments;
      case 'expenses':
        return _db!.expenses;
      case 'liquidity':
        return _db!.liquidity;
      case 'attendance':
        return _db!.attendance;
      case 'online_orders':
        return _db!.onlineOrders;
      case 'waste':
        return _db!.waste;
      case 'payroll':
        return _db!.payroll;
      case 'recurring_expenses':
        return _db!.recurringExpenses;
      case 'purchase_orders':
        return _db!.purchaseOrders;
      case 'stock_counts':
        return _db!.stockCounts;
      case 'stock_count_items':
        return _db!.stockCountItems;
      case 'print_orders':
        return _db!.printOrders;
      case 'point_histories':
        return _db!.pointHistories;
      default:
        // Fallback generik — CustomTableInfo minimal; stream per-tabel ini
        // jarang dipakai UI langsung.
        return _db!.products;
    }
  }

  /// Kolom SQL untuk update parsial (jsonKey → SQL column).
  /// camelCase drift → snake_case SQLite.
  /// v2.2.57+136: 'image_base64' DIHAPUS dari peta produk — _snapshotRow
  /// tidak pernah mengirim base64, dan _partialUpdate yang menulis NULL ke
  /// kolom ini menghapus foto di device penerima.
  static const _productCols = <String, String>{
    'name': 'name',
    'sku': 'sku',
    'barcode': 'barcode',
    'category': 'category',
    'buy_price': 'buy_price',
    'sell_price': 'sell_price',
    'discount_percent': 'discount_percent',
    'discount_type': 'discount_type',
    'stock': 'stock',
    'min_stock': 'min_stock',
    'image_path': 'image_path',
    'is_service': 'is_service',
    'is_online': 'is_online',
    'expiry_date': 'expiry_date',
    'product_type': 'product_type',
    'variants_json': 'variants_json',
    'wholesale_json': 'wholesale_json',
    'price_type': 'price_type',
    'supplier_id': 'supplier_id',
    'created_at': 'created_at',
  };

  // ═══ v2.2.57+136: generic upsert helpers ═══════════════════════════════
  // INSERT ... ON CONFLICT DO UPDATE yang ABSENT-AWARE: kolom yang tidak ada
  // di payload delta TIDAK ditulis (NULLIF inject + COALESCE guard). Ini
  // pengganti mappers drift lama (_mapToTransaction/_mapToProduct) yang
  // (a) cuma bawa 5–10 dari 27 kolom transaksi (cashierName, diskon, status,
  // dp/cicilan HILANG), (b) expect 'date' int-milidetik padahal push kirim
  // ISO / int-detik → TypeError → apply transaksi GAGAL total.
  // customUpdate(updates:) dipakai agar drift stream (watch*) di UI ikut
  // terbangun — dulu customStatement tak notify → layar tak refresh.

  /// Kolom yang tak boleh ditimpa NULL saat partial payload.
  static const _nullableSqlCols = <String>{
    'sku', 'barcode', 'image_path', 'expiry_date', 'product_type',
    'variants_json', 'wholesale_json', 'supplier_id', 'created_at',
    'customer_id', 'cash_given', 'cash_return', 'cashier_name', 'branch_id',
    'employee_id', 'session_id', 'void_reason', 'voided_at', 'order_type',
    'table_id', 'notes', 'dp_amount', 'installment_months',
    'installment_per_month', 'debt_id', 'phone', 'address',
  };

  /// Nilai JSON → string SQL variable siap bind (konversi tipe per kolom).
  Object? _coerceValue(String sqlCol, Object? v) {
    if (v == null) return null;
    if (_datetimeSqlCols.contains(sqlCol)) return _parseFlexibleDateTime(v);
    if (v is bool) return v ? 1 : 0;
    return v;
  }

  /// Kolom datetime (SQL name) di tabel synced.
  static const _datetimeSqlCols = <String>{
    'date', 'created_at', 'voided_at', 'expiry_date', 'debt_date', 'due_date',
    'paid_at', 'start_date', 'next_date', 'check_in', 'check_out',
    'completed_at', 'opened_at', 'closed_at', 'joined_at', 'work_start',
    'work_end',
  };

  /// Terima int DETIK (drift default), int MILISEKONDE, atau ISO string.
  DateTime _parseFlexibleDateTime(Object v) {
    if (v is int) {
      // <= 1e11 berarti detik (≈ tahun 5138 dalam ms) — heuristik aman.
      return v < 100000000000
          ? DateTime.fromMillisecondsSinceEpoch(v * 1000)
          : DateTime.fromMillisecondsSinceEpoch(v);
    }
    final parsed = DateTime.tryParse('$v');
    if (parsed != null) return parsed;
    throw FormatException('Unparseable datetime: $v');
  }

  /// camelCase / drift field → snake_case (untuk payload pushDelta manual
  /// yang mengirim nama field drift).
  String _snake(String s) => s
      .replaceAllMapped(RegExp(r'([A-Z])'), (m) => '_${m.group(1)!.toLowerCase()}');

  /// Bangun SQL: INSERT INTO t (cols...) VALUES (...) ON CONFLICT(pk) DO
  /// UPDATE SET col = excluded.col utk kolom yang ADA di payload; kolom
  /// absent ditulis NULL saat INSERT BARU (dilengkapi delta INSERT sumber)
  /// dan TIDAK menimpa nilai lama saat UPDATE parsial (COALESCE utk kolom
  /// nullable, default-safe utk NOT NULL via excluded sendiri).
  String _upsertSql(
    String table,
    Map<String, String> cols, {
    required String pkColumn,
    required Map<String, dynamic> data,
  }) {
    // v2.2.57+136: PK ikut di-INSERT — dulu id tak masuk daftar kolom →
    // SQLite meng-assign autoincrement BARU → row penerima beda id dengan
    // device sumber (delta berikutnya menimpa row salah, data duplikat).
    // PK hanya ikut INSERT, tidak pernah di-UPDATE.
    final sqlCols = <String>[pkColumn, ...cols.values.where((c) => c != pkColumn)];
    final placeholders = List.filled(sqlCols.length, '?').join(', ');
    final updateSets = sqlCols
        .where((c) => c != pkColumn)
        .map((c) => _nullableSqlCols.contains(c)
            ? '$c = COALESCE(excluded.$c, $table.$c)'
            : '$c = excluded.$c')
        .join(', ');
    return 'INSERT INTO $table (${sqlCols.join(', ')}) VALUES ($placeholders) '
        'ON CONFLICT($pkColumn) DO UPDATE SET $updateSets';
  }

  /// Bind variables mengikuti urutan _upsertSql. Missing key → null.
  /// Terima jsonKey camelCase ATAU snake_case.
  List<Variable> _upsertVars(
    Map<String, String> cols,
    Map<String, dynamic> data, {
    required String id,
  }) {
    return [Variable(_coerceValue('id', int.tryParse(id) ?? id)), ...cols.values.map((sqlCol) {
      final jsonKey = cols.keys.firstWhere(
        (k) => cols[k] == sqlCol,
        orElse: () => sqlCol,
      );
      final v = data.containsKey(jsonKey)
          ? data[jsonKey]
          : (data.containsKey(_snake(jsonKey)) ? data[_snake(jsonKey)] : null);
      return Variable(_coerceValue(sqlCol, v));
    })];
  }
  static const _txCols = <String, String>{
    'invoice': 'invoice',
    'date': 'date',
    'items': 'items',
    'total': 'total',
    'discount': 'discount',
    'payment_method': 'payment_method',
    'customer_id': 'customer_id',
    'cash_given': 'cash_given',
    'cash_return': 'cash_return',
    'cashier_name': 'cashier_name',
    'branch_id': 'branch_id',
    'employee_id': 'employee_id',
    'session_id': 'session_id',
    'status': 'status',
    'void_reason': 'void_reason',
    'voided_at': 'voided_at',
    'order_type': 'order_type',
    'table_id': 'table_id',
    'notes': 'notes',
    'dp_amount': 'dp_amount',
    'installment_months': 'installment_months',
    'installment_per_month': 'installment_per_month',
    'debt_id': 'debt_id',
  };
  static const _customerCols = <String, String>{
    'name': 'name',
    'phone': 'phone',
    'address': 'address',
    'barcode': 'barcode',
    'points': 'points',
    'totalSpent': 'total_spent',
    'level': 'level',
  };
  static const _roleCols = <String, String>{
    'color': 'color',
    'access': 'access_json',
  };
  static const _employeeCols = <String, String>{
    'name': 'name',
    'pin': 'pin',
    'role': 'role',
    'branch_id': 'branch_id',
    'status': 'status',
    'phone': 'phone',
    'photo_path': 'photo_path',
    'base_salary': 'base_salary',
    'start_date': 'start_date',
    'nfc_tag': 'nfc_tag',
    'barcode': 'barcode',
    'photo_base64': 'photo_base64',
    'work_start': 'work_start',
    'work_end': 'work_end',
    'requires_attendance': 'requires_attendance',
    'requires_cash_open': 'requires_cash_open',
    'requires_cash_close': 'requires_cash_close',
    'is_service_staff': 'is_service_staff',
    'commission_percent': 'commission_percent',
  };
  static const _branchCols = <String, String>{
    'name': 'name',
    'address': 'address',
    'phone': 'phone',
    'status': 'status',
  };
  static const _promoCols = <String, String>{
    'name': 'name',
    'code': 'code',
    'type': 'type',
    'value': 'value',
    'minBelanja': 'min_belanja',
    'startDate': 'start_date',
    'endDate': 'end_date',
    'maxUses': 'max_uses',
    'usedCount': 'used_count',
    'status': 'status',
    'mode': 'mode',
  };
  static const _supplierCols = <String, String>{
    'name': 'name',
    'phone': 'phone',
    'address': 'address',
    'contactPerson': 'contact_person',
    'note': 'note',
  };
  static const _debtCols = <String, String>{
    'customerId': 'customer_id',
    'customerName': 'customer_name',
    'amount': 'amount',
    'remainingAmount': 'remaining_amount',
    'description': 'description',
    'debtDate': 'debt_date',
    'dueDate': 'due_date',
    'status': 'status',
    'installmentMonths': 'installment_months',
  };
  static const _expenseCols = <String, String>{
    'category': 'category',
    'description': 'description',
    'amount': 'amount',
    'branchId': 'branch_id',
    'date': 'date',
  };
  static const _liquidityCols = <String, String>{
    'type': 'type',
    'category': 'category',
    'description': 'description',
    'amount': 'amount',
    'method': 'method',
    'branchId': 'branch_id',
    'date': 'date',
  };
  static const _attendanceCols = <String, String>{
    'employeeId': 'employee_id',
    'date': 'date',
    'checkIn': 'check_in',
    'checkOut': 'check_out',
    'pettyCash': 'petty_cash',
    'finalCash': 'final_cash',
    'status': 'status',
    'expectedCash': 'expected_cash',
    'shiftNotes': 'shift_notes',
  };
  static const _onlineOrderCols = <String, String>{
    'invoice': 'invoice',
    'customerName': 'customer_name',
    'customerPhone': 'customer_phone',
    'items': 'items',
    'subtotal': 'subtotal',
    'discount': 'discount',
    'handlingFee': 'handling_fee',
    'total': 'total',
    'paymentMethod': 'payment_method',
    'pickupTime': 'pickup_time',
    'branch': 'branch',
    'notes': 'notes',
    'status': 'status',
    'processedBy': 'processed_by',
  };
  static const _wasteCols = <String, String>{
    'productId': 'product_id',
    'qty': 'qty',
    'reason': 'reason',
    'type': 'type',
    'date': 'date',
  };
  static const _payrollCols = <String, String>{
    'employeeId': 'employee_id',
    'period': 'period',
    'salary': 'salary',
    'bonus': 'bonus',
    'deduction': 'deduction',
    'notes': 'notes',
    'status': 'status',
    'date': 'date',
  };
  static const _recurringCols = <String, String>{
    'category': 'category',
    'amount': 'amount',
    'description': 'description',
    'frequency': 'frequency',
    'nextDate': 'next_date',
    'active': 'active',
  };
  static const _debtPaymentCols = <String, String>{
    'debtId': 'debt_id',
    'amount': 'amount',
    'method': 'method',
    'notes': 'notes',
    'paidAt': 'paid_at',
    'branchId': 'branch_id',
  };
  static const _purchaseOrderCols = <String, String>{
    'invoice': 'invoice',
    'supplierId': 'supplier_id',
    'supplierName': 'supplier_name',
    'total': 'total',
    'note': 'note',
    'date': 'date',
  };
  static const _stockCountCols = <String, String>{
    'name': 'name',
    'status': 'status',
    'totalProducts': 'total_products',
    'matchCount': 'match_count',
    'diffCount': 'diff_count',
    'completedAt': 'completed_at',
  };
  static const _stockCountItemCols = <String, String>{
    'countSessionId': 'count_session_id',
    'productId': 'product_id',
    'productName': 'product_name',
    'systemStock': 'system_stock',
    'physicalStock': 'physical_stock',
    'difference': 'difference',
    'buyPrice': 'buy_price',
    'sellPrice': 'sell_price',
  };
  static const _printOrderCols = <String, String>{
    'customerName': 'customer_name',
    'customerPhone': 'customer_phone',
    'serviceType': 'service_type',
    'pages': 'pages',
    'copies': 'copies',
    'paperSize': 'paper_size',
    'widthCm': 'width_cm',
    'lengthCm': 'length_cm',
    'estimateReady': 'estimate_ready',
    'total': 'total',
    'notes': 'notes',
    'status': 'status',
    'customFieldsJson': 'custom_fields_json',
  };
  static const _pointHistoryCols = <String, String>{
    'customerId': 'customer_id',
    'type': 'type',
    'points': 'points',
    'transactionId': 'transaction_id',
    'note': 'note',
    'date': 'date',
  };

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
  // v2.2.57+136: _mapToProduct & _mapToTransaction DIHAPUS — diganti generic
  // upsert absent-aware (_upsertSql/_upsertVars). Mapper lama (a) cuma bawa
  // 5–10 dari 27 kolom transaksi, (b) crash karena date int-vs-ISO.

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

  CustomersCompanion _mapToCustomer(Map<String, dynamic> data) {
    return CustomersCompanion(
      id: Value(data['id'] as int? ?? 0),
      name: Value(data['name'] as String? ?? ''),
      phone: Value(data['phone'] as String?),
      address: Value(data['address'] as String?),
      barcode: Value(data['barcode'] as String?),
      points: Value(data['points'] as int? ?? 0),
      totalSpent: Value(data['totalSpent'] as int? ?? 0),
      level: Value(data['level'] as String? ?? 'Silver'),
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
      pin: Value(data['pin'] as String? ?? '1234'),
      role: Value(data['role'] as String? ?? 'kasir'),
      phone: Value(data['phone'] as String?),
      photoPath: Value(data['photo_path'] as String?),
      photoBase64: Value(data['photo_base64'] as String?),
      status: Value(data['status'] as String?),
      branchId: Value(data['branch_id'] as int?),
      isServiceStaff: Value(data['is_service_staff'] as bool? ?? true),
      commissionPercent: Value((data['commission_percent'] as num?)?.toDouble() ?? 10.0),
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
      createdAt: Value(data['createdAt'] != null
          ? DateTime.tryParse(data['createdAt'] as String) ?? DateTime.now()
          : DateTime.now()),
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
      createdAt: Value(data['createdAt'] != null
          ? DateTime.tryParse(data['createdAt'] as String) ?? DateTime.now()
          : DateTime.now()),
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
      createdAt: Value(data['createdAt'] != null
          ? DateTime.tryParse(data['createdAt'] as String) ?? DateTime.now()
          : DateTime.now()),
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
      createdAt: Value(data['createdAt'] != null
          ? DateTime.tryParse(data['createdAt'] as String) ?? DateTime.now()
          : DateTime.now()),
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
    // v2.2.57+136: notify drift streams (customStatement tak notify).
    await _db!.customUpdate(
      'UPDATE settings SET $sets WHERE id = ?',
      variables: [...binds.map(Variable.new)],
      updates: {_db!.settings},
      updateKind: UpdateKind.update,
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

  /// v2.2.57+133: pulihkan SEMUA foto produk & karyawan dari bucket R2 untuk
  /// baris yang imagePath menunjuk file yang tidak ada dan base64 kosong.
  /// Dipanggil setelah restore sukses (aktivasi / pending-restore) — dulu
  /// relink hanya jalan di main() startup, jadi restore via layar aktivasi
  /// tidak pernah memulihkan foto sampai restart kedua.
  Future<void> hydrateAllImages() async {
    if (_db == null) return;
    final uid = _uid ?? await SecureStore.resolveCanonicalUid();
    if (uid == null) return;
    final svc = ImageStorageService(uid);
    try {
      // ── Produk ──
      final rows = await _db!.select(_db!.products).get();
      for (final pr in rows) {
        final path = pr.imagePath;
        final hasFile = path != null &&
            path.isNotEmpty &&
            await File(path).exists();
        if (hasFile) continue;
        final b64 = pr.imageBase64;
        if (b64 != null && b64.isNotEmpty) continue; // hydrate base64 yang urus
        final name = path?.split('/').last ?? '';
        if (name.isEmpty) continue;
        // Gate longgar: product_/photo_/crop_ (hasil crop dari form) —
        // dulu cuma product_/photo_ → foto crop_ tidak pernah pulih.
        if (!(name.startsWith('product_') || name.startsWith('crop_'))) {
          continue;
        }
        final restored = await svc.downloadOriginal('products', name);
        if (restored == null) continue;
        await (_db!.update(_db!.products)..where((t) => t.id.equals(pr.id)))
            .write(ProductsCompanion(imagePath: Value(restored)));
        debugPrint('[DeltaSync] hydrateAllImages: product ${pr.id} → $restored');
      }
      // ── Karyawan ──
      final emps = await _db!.select(_db!.employees).get();
      for (final em in emps) {
        final path = em.photoPath;
        final hasFile = path != null &&
            path.isNotEmpty &&
            await File(path).exists();
        if (hasFile) continue;
        final b64 = em.photoBase64;
        if (b64 != null && b64.isNotEmpty) continue;
        final name = path?.split('/').last ?? '';
        if (name.isEmpty || !name.startsWith('photo_')) continue;
        final restored = await svc.downloadOriginal('employees', name);
        if (restored == null) continue;
        await (_db!.update(_db!.employees)..where((t) => t.id.equals(em.id)))
            .write(EmployeesCompanion(photoPath: Value(restored)));
        debugPrint('[DeltaSync] hydrateAllImages: employee ${em.id} → $restored');
      }
    } catch (e) {
      debugPrint('[DeltaSync] hydrateAllImages error: $e');
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
    _periodicFlush?.cancel();
    _periodicFlush = null;
    _db = null;
    _started = false;
  }
}
