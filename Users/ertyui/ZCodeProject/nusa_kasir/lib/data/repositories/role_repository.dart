import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:nusa_kasir/data/database/app_database.dart';
import 'package:nusa_kasir/core/services/delta_sync_service.dart';

/// Role permissions (RBAC) — per-role menu access, persisted in SQLite so
/// role permissions ride along with the cloud DB backup/restore (phone ↔
/// tablet stay in sync). Migrates the legacy per-device `nusa_roles.json`
/// file into the DB once.
class RoleRepository {
  final AppDatabase db;
  RoleRepository(this.db);

  static const _legacyFilename = 'nusa_roles.json';
  static const _defaultRoles = ['Owner', 'Manager', 'Kasir', 'Gudang', 'Finance'];

  /// Public list of default role names (used by UI to check deletability).
  static const defaultRoleNames = ['Owner', 'Manager', 'Kasir', 'Gudang', 'Finance'];

  static const _defaultRoleColors = {
    'Owner': 0xFF8B5CF6,
    'Manager': 0xFF3B82F6,
    'Kasir': 0xFF10B981,
    'Gudang': 0xFFF59E0B,
    'Finance': 0xFFEC4899,
  };

  static const _defaultRoleAccess = {
    'Owner': ["home","kasir","produk","stok","transaksi","pelanggan","promo","laporan","presensi","karyawan","keuangan","pengaturan","supplier","spreadsheet","pesanan_online","ai_chat","piutang","cabang",
               "meja","laundry_status","servis","booking","resep","print_order"],
    'Manager': ["home","kasir","produk","stok","transaksi","pelanggan","promo","laporan","presensi","karyawan","keuangan","pengaturan","supplier","spreadsheet","pesanan_online","ai_chat","piutang","cabang",
                "meja","laundry_status","servis","booking","resep","print_order"],
    'Kasir': ["home","kasir","produk","stok","transaksi","pelanggan","ai_chat"],
    'Gudang': ["home","produk","stok","laporan","supplier"],
    'Finance': ["home","transaksi","keuangan","laporan","presensi","karyawan","supplier"],
  };

  Map<String, dynamic> _defaultEntry(String name) => {
    'name': name,
    'color': _defaultRoleColors[name] ?? 0xFF3B82F6,
    'access': _defaultRoleAccess[name] ?? ['home'],
  };

  /// Load all roles from DB, ensuring defaults exist. Also performs a one-time
  /// migration of the legacy `nusa_roles.json` file into the DB.
  Future<List<Map<String, dynamic>>> getRoles() async {
    await _migrateLegacyFile();
    final rows = await (db.select(db.roles)..orderBy([(t) => OrderingTerm(expression: t.name, mode: OrderingMode.asc)])).get();
    final list = rows.map((r) => <String, dynamic>{
      'name': r.name,
      'color': r.color != null ? int.tryParse(r.color!) ?? _defaultRoleColors[r.name] ?? 0xFF3B82F6 : _defaultRoleColors[r.name] ?? 0xFF3B82F6,
      'access': _parseAccess(r.accessJson),
    }).toList();

    // Ensure defaults always present
    final names = list.map((r) => r['name'] as String).toSet();
    for (final d in _defaultRoles) {
      if (!names.contains(d)) {
        list.add(_defaultEntry(d));
        await (db.into(db.roles)).insert(RolesCompanion.insert(
          name: d,
          color: Value(_defaultRoleColors[d]?.toRadixString(16)),
          accessJson: Value(jsonEncode(_defaultRoleAccess[d] ?? ['home'])),
        ));
      }
    }
    return list;
  }

  List<String> _parseAccess(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is List) return decoded.cast<String>();
    } catch (_) {}
    return ['home'];
  }

  /// One-time migration: read legacy JSON file (if present) into the DB,
  /// then remove the file so future reads come from SQLite only.
  Future<void> _migrateLegacyFile() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, _legacyFilename));
      if (!await file.exists()) return;
      final raw = await file.readAsString();
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      for (final r in list) {
        final name = r['name'] as String;
        final color = (r['color'] as int?) ?? _defaultRoleColors[name] ?? 0xFF3B82F6;
        final access = ((r['access'] as List?) ?? ['home']).cast<String>();
        await (db.into(db.roles)).insert(
          RolesCompanion.insert(
            name: name,
            color: Value(color.toRadixString(16)),
            accessJson: Value(jsonEncode(access)),
          ),
          mode: InsertMode.insertOrIgnore,
        );
      }
      await file.delete();
    } catch (_) {
      // Legacy file missing/corrupt — defaults will be seeded instead.
    }
  }

  /// Add a new custom role.
  Future<void> addRole(String name, int color, List<String> access) async {
    await (db.into(db.roles)).insert(
      RolesCompanion.insert(
        name: name,
        color: Value(color.toRadixString(16)),
        accessJson: Value(jsonEncode(access)),
      ),
      mode: InsertMode.insertOrReplace,
    );
    // Delta sync: announce new role
    DeltaSyncService.I.pushDelta(
      table: 'roles',
      recordId: name,
      operation: 'INSERT',
      data: {'name': name, 'color': color, 'access': access},
    );
  }

  /// Update an existing role (name may change).
  Future<void> updateRole(String oldName, String newName, int color, List<String> access) async {
    await (db.update(db.roles)..where((t) => t.name.equals(oldName))).write(
      RolesCompanion(
        name: Value(newName),
        color: Value(color.toRadixString(16)),
        accessJson: Value(jsonEncode(access)),
      ),
    );
    // Delta sync: announce role update (use new name as recordId since it's the PK)
    DeltaSyncService.I.pushDelta(
      table: 'roles',
      recordId: newName,
      operation: 'UPDATE',
      data: {'name': newName, 'color': color, 'access': access},
    );
  }

  /// Delete a custom role. Default roles cannot be deleted.
  Future<bool> deleteRole(String name) async {
    if (_defaultRoles.contains(name)) return false;
    await (db.delete(db.roles)..where((t) => t.name.equals(name))).go();
    // Delta sync: announce role delete
    DeltaSyncService.I.pushDelta(
      table: 'roles',
      recordId: name,
      operation: 'DELETE',
    );
    return true;
  }

  /// Get access list for a role, with fallback to defaults.
  Future<List<String>> getAccess(String roleName) async {
    final row = await (db.select(db.roles)..where((t) => t.name.equals(roleName))).getSingleOrNull();
    if (row != null) return _parseAccess(row.accessJson);
    return _defaultRoleAccess[roleName] ?? ['home'];
  }

  /// Get role color, with fallback.
  Future<int> getColor(String roleName) async {
    final row = await (db.select(db.roles)..where((t) => t.name.equals(roleName))).getSingleOrNull();
    if (row != null && row.color != null) {
      final c = int.tryParse(row.color!);
      if (c != null) return c;
    }
    return _defaultRoleColors[roleName] ?? 0xFF3B82F6;
  }
}
