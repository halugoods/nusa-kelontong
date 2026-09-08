import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nusa_kasir/core/config/nusa_config.dart';
import 'package:nusa_kasir/core/providers.dart';
import 'package:nusa_kasir/core/services/backup_crypto.dart';
import 'package:nusa_kasir/core/utils/secure_storage.dart';
import "package:nusa_kasir/shared/widgets/top_toast.dart";
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

void showBackupSheet(BuildContext context, WidgetRef ref) {
  showModalBottomSheet(
    context: context,
    builder: (_) => _BackupSheetBody(rootContext: context, ref: ref),
  );
}

class _BackupSheetBody extends StatelessWidget {
  final BuildContext rootContext;
  final WidgetRef ref;
  const _BackupSheetBody({required this.rootContext, required this.ref});

  Future<String> _dbPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, 'nusa_kasir.sqlite');
  }

  /// Backup: pack SQLite (DB-only, no images) into a single NUS1 archive.
  ///
  /// v2.2.57+130 (A1): file gambar (product_*/photo_*/qris_*) TIDAK lagi
  /// ikut arsip backup lokal. Arsip gemuk (30+ MB) = bom egress + OOM.
  /// Gambar redundan: tersimpan di bucket nusa-images saat sync toko online
  /// / syncAll, dan path fisiknya tetap ada di device. Setelah restore di
  /// device baru, _relinkImagesFromCloud() (main.dart) + syncAll menarik
  /// gambar dari bucket.
  Future<void> _backup(BuildContext ctx) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final dbFile = File(p.join(dir.path, 'nusa_kasir.sqlite'));
      if (!await dbFile.exists()) {
        if (ctx.mounted) TopToast.error(ctx, 'Database tidak ditemukan');
        return;
      }

      // Pack SQLite only (no images) into NUS1 archive
      final archiveFiles = <String, Uint8List>{};
      archiveFiles['nusa_kasir.sqlite'] = await dbFile.readAsBytes();

      // Include feature toggles + menu order so phone ↔ tablet layouts sync
      final togglesJson = await SecureStore.getFeatureToggles();
      if (togglesJson != null) {
        archiveFiles['feature_toggles.json'] =
            Uint8List.fromList(utf8.encode(togglesJson));
      }
      final orderJson = await SecureStore.getMenuOrder();
      if (orderJson != null) {
        archiveFiles['menu_order.json'] =
            Uint8List.fromList(utf8.encode(orderJson));
      }

      // v2.2.57+130: pack di background isolate (arsip bisa puluhan MB).
      final packed = await packInIsolate(archiveFiles);

      // Write archive to temp for sharing
      final outDir = await getTemporaryDirectory();
      final ts = DateTime.now();
      final name =
          'nusa_kasir_db_${ts.year}${ts.month.toString().padLeft(2, '0')}${ts.day.toString().padLeft(2, '0')}_${ts.hour.toString().padLeft(2, '0')}${ts.minute.toString().padLeft(2, '0')}.nus1';
      final out = File(p.join(outDir.path, name));
      await out.writeAsBytes(packed, flush: true);

      if (ctx.mounted) Navigator.of(ctx).pop();
      await Share.shareXFiles(
        [XFile(out.path)],
        subject: 'Backup NUSA Kasir (Database)',
        text: 'File backup database NUSA Kasir — gambar tidak ikut (tersimpan di cloud)',
      );
    } catch (e) {
      if (ctx.mounted) TopToast.error(ctx, 'Gagal backup: $e');
    }
  }

  /// Restore: accept both .sqlite (legacy) and .nus1 (archive).
  /// v2.2.57+130 (A1): arsip baru DB-only — gambar TIDAK di-restore dari
  /// file. Setelah DB dipulihkan, _relinkImagesFromCloud() (main.dart) +
  /// syncAll menarik gambar dari bucket nusa-images. Arsip LAMA (dengan
  /// gambar) tetap kompatibel — gambar lama di-restore dari arsip.
  Future<void> _restore(BuildContext ctx) async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['sqlite', 'db', 'nus1'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final bytes = result.files.single.bytes;
      if (bytes == null) return;
      final ext = p.extension(result.files.single.name).toLowerCase();

      final dir = await getApplicationDocumentsDirectory();
      final db = ref.read(databaseProvider);
      await db.close();

      if (ext == '.nus1') {
        // NUS1 archive: extract SQLite (+ legacy images if present)
        final unpacked = await unpackInIsolate(bytes);
        for (final entry in unpacked.entries) {
          if (entry.key == 'nusa_kasir.sqlite') {
            // v2.2.57+131: hapus sidecar WAL/SHM dulu — kalau tidak,
            // SQLite replay WAL lama di atas DB baru → data corrupt/produk
            // sebagian hilang (user complain "produk cuma 2").
            final dbFile = File(p.join(dir.path, 'nusa_kasir.sqlite'));
            for (final sidecar in ['${dbFile.path}-wal', '${dbFile.path}-shm', '${dbFile.path}-journal']) {
              try { await File(sidecar).delete(); } catch (_) {}
            }
            await dbFile.writeAsBytes(entry.value, flush: true);
          } else if (entry.key == 'feature_toggles.json') {
            final json = utf8.decode(entry.value);
            await SecureStore.saveFeatureToggles(json);
            ref.read(featureTogglesProvider.notifier).state =
                (jsonDecode(json) as Map<String, dynamic>).map(
                    (k, v) => MapEntry(k, v as bool));
          } else if (entry.key == 'menu_order.json') {
            final json = utf8.decode(entry.value);
            await SecureStore.saveMenuOrder(json);
            ref.read(menuOrderProvider.notifier).state =
                (jsonDecode(json) as List<dynamic>).cast<String>();
          }
          // NOTE: gambar TIDAK di-restore dari arsip — baik arsip baru
          // (tanpa gambar) maupun arsip lama (dengan gambar). Gambar
          // dipulihkan dari cloud via _relinkImagesFromCloud() / syncAll.
        }
      } else {
        // Legacy .sqlite — just copy the DB
        final dbFile = File(p.join(dir.path, 'nusa_kasir.sqlite'));
        await dbFile.writeAsBytes(bytes, flush: true);
      }

      // v2.2.57+131: tandai lastCloudSeen = now supaya autosync tidak
      // menimpa DB yang baru di-restore dengan backup cloud lama/kosong
      // di launch berikutnya (akar bug "produk cuma 2 setelah restore").
      await SecureStore.setLastCloudSeen(DateTime.now());

      ref.invalidate(databaseProvider);
      if (ctx.mounted) Navigator.of(ctx).pop();
      if (rootContext.mounted) GoRouter.of(rootContext).go('/home');
    } catch (e) {
      if (ctx.mounted) TopToast.error(ctx, 'Gagal restore: $e');
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Backup & Restore',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              SizedBox(height: 16),
              ListTile(
                leading: Icon(Icons.backup),
                title: Text('Backup Database'),
                subtitle: Text(NusaConfig.cloudEnabled
                    ? 'Simpan database dalam file .nus1 (gambar tersimpan di cloud)'
                    : 'Simpan database dalam file .nus1'),
                onTap: () => _backup(context),
              ),
              ListTile(
                leading: Icon(Icons.restore),
                title: Text('Restore Database'),
                subtitle: Text(NusaConfig.cloudEnabled
                    ? 'Pilih file backup (.nus1 atau .sqlite) — gambar diunduh dari cloud'
                    : 'Pilih file backup (.nus1 atau .sqlite)'),
                onTap: () => _restore(context),
              ),
              SizedBox(height: 8),
            ],
          ),
        ),
      );
}
