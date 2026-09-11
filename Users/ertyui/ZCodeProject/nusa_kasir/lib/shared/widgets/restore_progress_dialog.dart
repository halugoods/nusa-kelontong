import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/restore_progress_provider.dart';

/// Dialog progress restore cloud backup — ditampilkan saat user menekan
/// "Ya, Buka Toko Ini" (aktivasi / login flow) atau "Download dari Cloud"
/// (pengaturan). Barrier tidak bisa ditutup (barrierDismissible: false) —
/// restore berjalan di latar dan mematikan aplikasi di tengah proses = data
/// korup.
///
/// Watch [restoreProgressProvider]: saat phase download/unpack berjalan,
/// indeterminate spinner; saat images berjalan, LinearProgressIndicator
/// "Mengunduh gambar 3/24"; saat done/error, dialog otomatis ditutup oleh
/// caller (bisa panggil Navigator.pop setelah restoreDirect() return).
class RestoreProgressDialog extends ConsumerWidget {
  const RestoreProgressDialog({super.key, this.showImages = true});

  /// Tampilkan bagian "Mengunduh gambar X/N". false saat restoreFromCloud
   /// (pengaturan) — gambar menyusul otomatis setelah restart.
  final bool showImages;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rp = ref.watch(restoreProgressProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;

    return PopScope(
      canPop: false,
      child: AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Ikon fase
            SizedBox(
              width: 56,
              height: 56,
              child: rp.phase == RestorePhase.error
                  ? Icon(Icons.error_outline, color: Colors.red.shade400, size: 44)
                  : rp.phase == RestorePhase.done
                      ? Icon(Icons.check_circle_outline,
                          color: Colors.green.shade500, size: 44)
                      : CircularProgressIndicator(
                          strokeWidth: 3,
                          value: rp.determinate,
                        ),
            ),
            const SizedBox(height: 18),
            Text(
              rp.label,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            // Sub-label images
            if (rp.phase == RestorePhase.images && rp.imageLabel.isNotEmpty)
              Text(
                rp.imageLabel,
                style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white60 : Colors.black54),
              ),
            const SizedBox(height: 14),
            // Progress bar saat images
            if (rp.phase == RestorePhase.images)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: rp.determinate,
                  minHeight: 8,
                  backgroundColor: primary.withValues(alpha: 0.15),
                  valueColor: AlwaysStoppedAnimation(primary),
                ),
              ),
            if (rp.phase == RestorePhase.images)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'Jangan tutup aplikasi selama proses berlangsung.',
                  style: TextStyle(fontSize: 12, color: Colors.orange),
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Tampilkan dialog progress (awaitable — resolve saat caller menutupnya).
Future<void> showRestoreProgressDialog(BuildContext context, {bool showImages = true}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => RestoreProgressDialog(showImages: showImages),
  );
}
