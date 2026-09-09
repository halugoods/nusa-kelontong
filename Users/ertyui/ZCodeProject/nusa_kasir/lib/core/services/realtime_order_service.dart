import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:nusa_kasir/core/cloud/cloud_gateway.dart';
import 'package:nusa_kasir/core/services/online_order_service.dart';
import 'package:nusa_kasir/data/database/app_database.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Global realtime listener for online orders.
///
/// v2.2.57+131: replaces the screen-scoped WS subscription that lived only
/// inside OnlineOrdersScreen._listenSupabase(). That old listener only fired
/// while the owner was sitting on that exact screen — events were lost
/// otherwise. This singleton subscribes once at app startup (app.dart) and
/// stays alive for the full app lifetime, with auto-reconnect on drop.
///
/// On order_new: inserts into local DB + triggers a global notification.
/// On order_updated: the next natural screen refresh picks up the change.
class RealtimeOrderService {
  RealtimeOrderService._();
  static final RealtimeOrderService I = RealtimeOrderService._();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  bool _shouldRun = false;
  Timer? _reconnectTimer;
  AppDatabase? _db;

  static const _reconnectDelay = Duration(seconds: 5);

  Future<void> start(AppDatabase db) async {
    if (_shouldRun) return;
    _shouldRun = true;
    _db = db;
    _connect();
  }

  Future<String?> _channelName() async {
    try {
      final svc = OnlineOrderService();
      final storeId = await svc.storeId;
      if (storeId == null || storeId.isEmpty) return null;
      return 'orders:$storeId';
    } catch (_) {
      return null;
    }
  }

  Future<void> _connect() async {
    if (!_shouldRun) return;
    final name = await _channelName();
    if (name == null) {
      _scheduleReconnect();
      return;
    }
    try {
      final ws = CloudGateway.shared.wsChannel(name);
      if (ws == null) {
        _scheduleReconnect();
        return;
      }
      await ws.ready.timeout(const Duration(seconds: 8));
      _channel = ws;
      _sub = ws.stream.listen((message) {
        try {
          final dynamic decoded =
              message is String ? jsonDecode(message) : message;
          if (decoded is! Map) return;
          final event = '${decoded['event'] ?? ''}';
          if (event == 'order_new') {
            final payload = decoded['payload'];
            if (payload is Map) {
              _handleOrderNew(Map<String, dynamic>.from(payload));
            }
          }
          // order_updated: screens refetch on rebuild — no action needed here.
        } catch (_) {}
      }, onError: (_) {
        _scheduleReconnect();
      }, onDone: () {
        _scheduleReconnect();
      }, cancelOnError: false);
    } catch (_) {
      _channel = null;
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (!_shouldRun) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_reconnectDelay, () {
      if (!_shouldRun) return;
      _sub = null;
      _channel = null;
      _connect();
    });
  }

  /// Insert new order into local DB (dedup by invoice).
  Future<void> _handleOrderNew(Map<String, dynamic> rec) async {
    final db = _db;
    if (db == null) return;
    final invoice = rec['invoice'] as String? ?? '';
    try {
      final existing = invoice.isNotEmpty
          ? await (db.select(db.onlineOrders)
                ..where((t) => t.invoice.equals(invoice)))
              .getSingleOrNull()
          : null;
      if (existing == null) {
        await db.into(db.onlineOrders).insert(
          OnlineOrdersCompanion.insert(
            invoice: invoice,
            customerName: rec['customer_name'] as String? ?? '',
            customerPhone: rec['customer_phone'] as String? ?? '',
            items: jsonEncode(rec['items']),
            total: (rec['total'] as num?)?.toInt() ?? 0,
            subtotal: Value((rec['subtotal'] as num?)?.toInt() ?? 0),
            discount: Value((rec['discount'] as num?)?.toInt() ?? 0),
            handlingFee: Value((rec['handling_fee'] as num?)?.toInt() ?? 0),
            paymentMethod: Value(rec['payment_method'] as String? ?? 'Tunai'),
            pickupTime: Value(rec['pickup_time'] as String?),
            branch: Value(rec['branch'] as String? ?? 'Pusat'),
            notes: Value(rec['notes'] as String?),
            status: Value(rec['status'] as String? ?? 'Online Baru'),
          ),
        );
        debugPrint('[RealtimeOrder] new order: $invoice');
      }
    } catch (e) {
      debugPrint('[RealtimeOrder] insert error: $e');
    }
  }

  Future<void> stop() async {
    _shouldRun = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    try {
      await _sub?.cancel();
    } catch (_) {}
    try {
      _channel?.sink.close();
    } catch (_) {}
    _sub = null;
    _channel = null;
    _db = null;
  }
}
