import 'package:drift/drift.dart';
import 'package:nusa_kasir/core/services/delta_sync_service.dart';
import 'package:nusa_kasir/data/database/app_database.dart';

class CategoryRepository {
  final AppDatabase db;
  CategoryRepository(this.db);

  /// Get all category names. No defaults are seeded — the user creates
  /// their own categories from the product form.
  Future<List<String>> getAll() async {
    final rows = await db.select(db.categories).get();
    return rows.map((r) => r.name).toList();
  }

  /// Add a new category; returns the name on success.
  Future<String> add(String name) async {
    final trimmed = name.trim();
    await db.into(db.categories).insert(
      CategoriesCompanion.insert(name: trimmed),
      mode: InsertMode.insertOrIgnore,
    );
    DeltaSyncService.I.pushDelta(
      table: 'categories',
      recordId: trimmed,
      operation: 'INSERT',
      data: {'name': trimmed},
    );
    return trimmed;
  }

  /// Delete a category by name.
  Future<void> delete(String name) async {
    await (db.delete(db.categories)..where((t) => t.name.equals(name))).go();
    DeltaSyncService.I.pushDelta(
      table: 'categories',
      recordId: name,
      operation: 'DELETE',
      data: {'name': name},
    );
  }

  /// Rename a category.
  Future<void> rename(String oldName, String newName) async {
    await (db.update(db.categories)..where((t) => t.name.equals(oldName)))
        .write(CategoriesCompanion(name: Value(newName.trim())));
    DeltaSyncService.I.pushDelta(
      table: 'categories',
      recordId: newName.trim(),
      operation: 'UPDATE',
      data: {'name': newName.trim()},
    );
  }

}
