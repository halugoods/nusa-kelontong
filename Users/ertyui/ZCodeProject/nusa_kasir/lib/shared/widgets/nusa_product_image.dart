import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../core/services/delta_sync_service.dart';

/// Foto produk dengan fallback otomatis ke BASE64.
///
/// Backup/restore cloud membawa foto produk sebagai BASE64 (kolom
/// `image_base64`) di dalam DB. File lokal (`imagePath`) TIDAK ikut cloud,
/// jadi setelah restore di device/login ulang, path bisa menunjuk ke file yang
/// tidak ada. Widget ini menampilkan foto dari:
///   1. file lokal jika `imagePath` ada & file-nya benar-benar ada, atau
///   2. `imageBase64` (decode on the fly) jika file hilang tapi base64 ada, atau
///   3. placeholder (child) jika keduanya tidak ada.
///
/// v2.2.57+140: TAMBAHKAN `productId` + `tintColor` opsional. Saat ada,
/// widget listen ke `DeltaSyncService.hydrationStream` dan menampilkan
/// overlay glassmorphism di container dengan progress % real-time di tengah.
/// Begitu download selesai (progress 1.0 + localPath), widget langsung
/// re-render dengan gambar asli — TANPA restart app.
///
/// Menggantikan pola `Image.file(File(p.imagePath!))` yang selama ini HANYA
/// membaca file lokal — sumber regresi "foto produk tidak ke-restore".
class NusaProductImage extends StatefulWidget {
  final String? imagePath;
  final String? imageBase64;
  final Widget placeholder;
  final BoxFit fit;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final bool circle;

  /// v2.2.57+140: opsional. Kalau ada + file lokal hilang, widget listen
  /// hydration stream untuk produk ini dan tampil animasi progress.
  final int? productId;

  /// v2.2.57+140: warna tint glassmorphism (sesuai tema varian).
  /// Default = primary biru.
  final Color? tintColor;

  const NusaProductImage({
    super.key,
    this.imagePath,
    this.imageBase64,
    required this.placeholder,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.borderRadius,
    this.circle = false,
    this.productId,
    this.tintColor,
  });

  @override
  State<NusaProductImage> createState() => _NusaProductImageState();
}

class _NusaProductImageState extends State<NusaProductImage> {
  /// Progress download saat ini (0.0..1.0). Null = tidak ada download aktif.
  double? _downloadProgress;
  StreamSubscription<ImageHydrationEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant NusaProductImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.productId != widget.productId) {
      _sub?.cancel();
      _downloadProgress = null;
      _subscribe();
    }
  }

  void _subscribe() {
    final pid = widget.productId;
    if (pid == null) return;
    _sub = DeltaSyncService.I.hydrationStream.listen((ev) {
      if (ev.productId != pid) return;
      if (!mounted) return;
      if (ev.progress >= 1.0) {
        // Download selesai — bersihkan overlay. Gambar asli akan muncul
        // via FileImage dari localPath yang sudah ditulis ke DB.
        setState(() => _downloadProgress = null);
      } else {
        setState(() => _downloadProgress = ev.progress);
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  ImageProvider? _resolveProvider() {
    // 1. File lokal ada → prioritas utama (paling cepat, tanpa decode).
    if (widget.imagePath != null &&
        widget.imagePath!.isNotEmpty &&
        File(widget.imagePath!).existsSync()) {
      return FileImage(File(widget.imagePath!));
    }
    // 2. Fallback base64 dari DB (kalau path basi / belum di-hydrate).
    if (widget.imageBase64 != null && widget.imageBase64!.isNotEmpty) {
      try {
        return MemoryImage(base64Decode(widget.imageBase64!));
      } catch (_) {
        return null; // base64 rusak → placeholder
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final provider = _resolveProvider();
    Widget img;
    if (provider != null) {
      img = Image(
        image: provider,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        // Error builder: kalau file corrupt/hilang, fallback ke placeholder
        // (overlay progress masih akan tampil jika ada).
        errorBuilder: (_, __, ___) => widget.placeholder,
      );
    } else {
      img = widget.placeholder;
    }

    Widget finalImg = img;

    // Overlay glassmorphism + progress % real-time — HANYA di dalam container
    // image, bukan full card produk. Hanya tampil saat ada download aktif.
    if (_downloadProgress != null) {
      final tint = widget.tintColor ?? const Color(0xFF3B82F6);
      final pct = (_downloadProgress! * 100).clamp(0, 100).toInt();
      finalImg = Stack(
        fit: StackFit.expand,
        children: [
          img,
          // Glassmorphism: tint color + blur ringan untuk frosted-glass feel
          // (bukan warna kaku) — sesuai tema aplikasi via `tintColor`.
          ClipRect(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
              child: Container(
                color: tint.withValues(alpha: 0.32),
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$pct%',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 22,
                        letterSpacing: -0.5,
                        shadows: [
                          Shadow(
                            color: Color(0x66000000),
                            blurRadius: 6,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      width: 64,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: _downloadProgress,
                          minHeight: 4,
                          backgroundColor:
                              Colors.white.withValues(alpha: 0.25),
                          valueColor:
                              const AlwaysStoppedAnimation(Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }

    if (widget.borderRadius != null) {
      return ClipRRect(borderRadius: widget.borderRadius!, child: finalImg);
    }
    if (widget.circle) {
      return ClipOval(child: finalImg);
    }
    return finalImg;
  }
}
