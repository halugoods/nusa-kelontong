import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:nusa_kasir/core/config/nusa_config.dart';
import 'package:nusa_kasir/core/providers.dart';
import 'package:nusa_kasir/core/services/delta_sync_service.dart';
import 'package:nusa_kasir/data/database/app_database.dart';
import 'package:nusa_kasir/data/repositories/category_repository.dart';
import 'package:nusa_kasir/data/repositories/product_repository.dart';
import 'package:nusa_kasir/shared/widgets/screen_scaffold.dart';
import 'package:nusa_kasir/shared/widgets/skeleton_list.dart';
import 'package:nusa_kasir/shared/widgets/top_toast.dart';

/// Kategori grid screen — CRUD utama untuk kelola kategori.
/// Route: /produk/kategori
class KategoriListScreen extends ConsumerStatefulWidget {
  KategoriListScreen({super.key});
  @override
  ConsumerState<KategoriListScreen> createState() => _KategoriListScreenState();
}

class _KategoriListScreenState extends ConsumerState<KategoriListScreen> {
  Map<String, int> _counts = {};
  bool _loading = true;
  bool _sortByCount = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = ProductRepository(ref.read(databaseProvider));
    final counts = await repo.categoryProductCounts();
    if (mounted) setState(() { _counts = counts; _loading = false; });
  }

  List<MapEntry<String, int>> _sortedCats() {
    final entries = _counts.entries.toList();
    if (_sortByCount) {
      entries.sort((a, b) => b.value.compareTo(a.value));
    } else {
      entries.sort((a, b) => a.key.compareTo(b.key));
    }
    return entries;
  }

  // ── CRUD: Add Category ──
  Future<void> _addCategory() async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Tambah Kategori'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Nama kategori',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Batal')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            style: ElevatedButton.styleFrom(backgroundColor: NusaConfig.activePrimary, foregroundColor: Colors.white),
            child: Text('Simpan'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      await CategoryRepository(ref.read(databaseProvider)).add(result);
      TopToast.success(context, 'Kategori "$result" ditambahkan');
      _load();
    }
  }

  // ── CRUD: Rename Category ──
  Future<void> _renameCategory(String oldName) async {
    final ctrl = TextEditingController(text: oldName);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Ubah Nama Kategori'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Nama baru',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Batal')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            style: ElevatedButton.styleFrom(backgroundColor: NusaConfig.activePrimary, foregroundColor: Colors.white),
            child: Text('Simpan'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty && result != oldName) {
      final db = ref.read(databaseProvider);
      await CategoryRepository(db).rename(oldName, result);
      // Update product category references
      final affected = await (db.select(db.products)
            ..where((t) => t.category.equals(oldName)))
          .get();
      await (db.update(db.products)..where((t) => t.category.equals(oldName)))
          .write(ProductsCompanion(category: Value(result)));
      for (final p in affected) {
        DeltaSyncService.I.pushDelta(
          table: 'products',
          recordId: p.id.toString(),
          operation: 'UPDATE',
          data: {'id': p.id, 'category': result},
        );
      }
      TopToast.success(context, 'Kategori diubah ke "$result"');
      _load();
    }
  }

  // ── CRUD: Delete Category ──
  Future<void> _deleteCategory(String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Hapus Kategori'),
        content: Text('Hapus kategori "$name"? Produk dengan kategori ini akan dipindah ke "Lainnya".'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Batal')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: NusaConfig.error, foregroundColor: Colors.white),
            child: Text('Hapus'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      final db = ref.read(databaseProvider);
      // Move products to "Lainnya"
      final affected = await (db.select(db.products)
            ..where((t) => t.category.equals(name)))
          .get();
      await (db.update(db.products)..where((t) => t.category.equals(name)))
          .write(ProductsCompanion(category: Value('Lainnya')));
      for (final p in affected) {
        DeltaSyncService.I.pushDelta(
          table: 'products',
          recordId: p.id.toString(),
          operation: 'UPDATE',
          data: {'id': p.id, 'category': 'Lainnya'},
        );
      }
      await CategoryRepository(db).delete(name);
      TopToast.success(context, 'Kategori "$name" dihapus');
      _load();
    }
  }

  // ── Context menu for long-press ──
  void _showCategoryMenu(String cat) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: isDark ? NusaConfig.darkSurface : NusaConfig.surfaceColor,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(margin: EdgeInsets.only(bottom: 16), width: 40, height: 4,
            decoration: BoxDecoration(color: NusaConfig.dividerColor, borderRadius: BorderRadius.circular(2))),
          Text(cat, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800,
            color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary)),
          SizedBox(height: 16),
          ListTile(
            leading:  Icon(Icons.edit_rounded, color: NusaConfig.activePrimary),
            title: Text('Ubah Nama'),
            onTap: () { Navigator.pop(ctx); _renameCategory(cat); },
          ),
          ListTile(
            leading: Icon(Icons.delete_rounded, color: NusaConfig.error),
            title: Text('Hapus Kategori', style: TextStyle(color: NusaConfig.error)),
            onTap: () { Navigator.pop(ctx); _deleteCategory(cat); },
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ScreenScaffold(
      'Kategori Produk',
      _loading
          ? SkeletonList()
          : Column(children: [
              // Sort toggle — ringkas (B9): satu label ganti urut, tanpa pill boros.
              Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Row(children: [
                  Text('${_counts.length} kategori',
                      style: TextStyle(fontSize: 12,
                          color: isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary)),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => setState(() => _sortByCount = !_sortByCount),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(_sortByCount ? 'Terbanyak' : 'A-Z',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                              color: NusaConfig.activePrimary)),
                      const SizedBox(width: 2),
                      Icon(Icons.swap_vert, size: 16, color: NusaConfig.activePrimary),
                    ]),
                  ),
                ]),
              ),
              SizedBox(height: 8),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: GridView.builder(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 80),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2, crossAxisSpacing: 12, mainAxisSpacing: 12, childAspectRatio: 1.1),
                    itemCount: _sortedCats().length,
                    itemBuilder: (_, i) {
                      final entry = _sortedCats()[i];
                      final cat = entry.key;
                      final count = entry.value;
                      final gradient = NusaConfig.catGradientFor(cat);
                      final emoji = NusaConfig.catEmojiFor(cat);

                      return GestureDetector(
                        onTap: () => context.push('/produk/kategori/$cat'),
                        onLongPress: () => _showCategoryMenu(cat),
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(NusaConfig.radiusXL),
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: gradient,
                            ),
                            boxShadow: [BoxShadow(
                              color: gradient.last.withValues(alpha: 0.5),
                              blurRadius: 12, offset: Offset(0, 4))],
                          ),
                          child: Stack(
                            children: [
                              Positioned(
                                right: -10, top: -10,
                                child: Opacity(opacity: 0.2,
                                  child: Text(emoji, style: TextStyle(fontSize: 72))),
                              ),
                              Padding(
                                padding: EdgeInsets.all(NusaConfig.spaceLG),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(emoji, style: TextStyle(fontSize: 32)),
                                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                      Text(cat, style: TextStyle(
                                        fontSize: 18, fontWeight: FontWeight.w800, color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary,
                                        letterSpacing: -0.3)),
                                      SizedBox(height: 2),
                                      Container(
                                        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(alpha: 0.08),
                                          borderRadius: BorderRadius.circular(NusaConfig.radiusFull)),
                                        child: Text('$count produk',
                                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary)),
                                      ),
                                    ]),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ]),
      floatingActionButton: Padding(
        padding: EdgeInsets.only(bottom: 8),
        child: FloatingActionButton.extended(
          backgroundColor: NusaConfig.activePrimary,
          foregroundColor: Colors.white,
          icon: Icon(Icons.create_new_folder),
          label: Text('Tambah Kategori'),
          onPressed: _addCategory,
        ),
      ),
    );
  }
}
