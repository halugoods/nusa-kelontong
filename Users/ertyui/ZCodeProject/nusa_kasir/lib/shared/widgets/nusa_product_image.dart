import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../core/services/delta_sync_service.dart';

/// Foto produk dengan fallback otomatis ke BASE64 dan animasi Liquid Wave.
///
/// v2.2.57+140:
/// 1. Liquid Sine-Wave Glassmorphism animation filling inside product image container.
/// 2. Autonomous On-Demand image hydration jika file lokal belum ada.
/// 3. Seamless update lokal saat download selesai tanpa restart app.
class NusaProductImage extends StatefulWidget {
  final String? imagePath;
  final String? imageBase64;
  final Widget placeholder;
  final BoxFit fit;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final bool circle;

  /// ID produk untuk sinkronisasi progress download on-demand.
  final int? productId;

  /// Warna tema varian untuk efek liquid air & glassmorphism tint.
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

class _NusaProductImageState extends State<NusaProductImage>
    with SingleTickerProviderStateMixin {
  double? _downloadProgress;
  String? _resolvedLocalPath;
  StreamSubscription<ImageHydrationEvent>? _sub;
  late AnimationController _waveController;

  @override
  void initState() {
    super.initState();
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    _subscribe();
    _checkAndTriggerDownload();
  }

  @override
  void didUpdateWidget(covariant NusaProductImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.productId != widget.productId ||
        oldWidget.imagePath != widget.imagePath) {
      _sub?.cancel();
      _downloadProgress = null;
      _resolvedLocalPath = null;
      _subscribe();
      _checkAndTriggerDownload();
    }
  }

  void _checkAndTriggerDownload() {
    final pid = widget.productId;
    final path = widget.imagePath;
    if (pid == null || path == null || path.isEmpty) return;

    // Cek apakah file lokal benar-benar ada
    final exists = File(path).existsSync();
    final hasB64 = widget.imageBase64 != null && widget.imageBase64!.isNotEmpty;

    // Jika file tidak ada & base64 kosong -> picu download otomatis on-demand
    if (!exists && !hasB64) {
      DeltaSyncService.I.hydrateSingleProduct(pid, path);
    }
  }

  void _subscribe() {
    final pid = widget.productId;
    if (pid == null) return;
    _sub = DeltaSyncService.I.hydrationStream.listen((ev) {
      if (ev.productId != pid) return;
      if (!mounted) return;
      if (ev.progress >= 1.0) {
        if (ev.localPath != null) {
          setState(() {
            _resolvedLocalPath = ev.localPath;
            _downloadProgress = null;
          });
        } else {
          setState(() => _downloadProgress = null);
        }
        if (_waveController.isAnimating) {
          _waveController.stop();
        }
      } else {
        setState(() => _downloadProgress = ev.progress);
        if (!_waveController.isAnimating) {
          _waveController.repeat();
        }
      }
    });
  }

  @override
  void dispose() {
    _waveController.dispose();
    _sub?.cancel();
    super.dispose();
  }

  ImageProvider? _resolveProvider() {
    // 1. Path hasil hydration terkini
    if (_resolvedLocalPath != null &&
        _resolvedLocalPath!.isNotEmpty &&
        File(_resolvedLocalPath!).existsSync()) {
      return FileImage(File(_resolvedLocalPath!));
    }
    // 2. File lokal awal jika ada
    if (widget.imagePath != null &&
        widget.imagePath!.isNotEmpty &&
        File(widget.imagePath!).existsSync()) {
      return FileImage(File(widget.imagePath!));
    }
    // 3. Fallback base64 dari DB
    if (widget.imageBase64 != null && widget.imageBase64!.isNotEmpty) {
      try {
        return MemoryImage(base64Decode(widget.imageBase64!));
      } catch (_) {
        return null;
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
        errorBuilder: (_, __, ___) => widget.placeholder,
      );
    } else {
      img = widget.placeholder;
    }

    Widget finalImg = img;

    // Overlay Liquid Wave Glassmorphism Animation
    if (_downloadProgress != null) {
      final tint = widget.tintColor ?? Theme.of(context).primaryColor;
      final pct = (_downloadProgress! * 100).clamp(0, 100).toInt();

      finalImg = Stack(
        fit: StackFit.expand,
        children: [
          img,
          ClipRect(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
              child: AnimatedBuilder(
                animation: _waveController,
                builder: (context, child) {
                  return CustomPaint(
                    painter: _LiquidWavePainter(
                      progress: _downloadProgress!,
                      wavePhase: _waveController.value * 2 * math.pi,
                      tintColor: tint,
                    ),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '$pct%',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                              fontSize: 22,
                              letterSpacing: -0.5,
                              shadows: [
                                Shadow(
                                  color: Color(0x99000000),
                                  blurRadius: 8,
                                  offset: Offset(0, 2),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'Mengunduh...',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.2,
                              shadows: [
                                Shadow(
                                  color: Color(0x66000000),
                                  blurRadius: 4,
                                ),
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

/// CustomPainter untuk animasi air bergelombang (Dual Overlapping Sine Wave)
class _LiquidWavePainter extends CustomPainter {
  final double progress;
  final double wavePhase;
  final Color tintColor;

  _LiquidWavePainter({
    required this.progress,
    required this.wavePhase,
    required this.tintColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width;
    final height = size.height;

    // Tingkat ketinggian air (0.0 = dasar, 1.0 = penuh)
    final clampedProgress = progress.clamp(0.0, 1.0);
    final waterLevel = height * (1.0 - clampedProgress);

    // Amplitudo gelombang lebih lebar dan mengecil di batas atas & bawah
    final amplitude = math.min(10.0, height * 0.08) *
        math.sin(clampedProgress * math.pi).clamp(0.2, 1.0);

    // ── Layer 1: Gelombang Belakang (Secondary Wave / Depth) ──
    final backWavePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          tintColor.withValues(alpha: 0.35),
          tintColor.withValues(alpha: 0.65),
        ],
      ).createShader(Rect.fromLTWH(0, waterLevel, width, height - waterLevel));

    final backPath = Path();
    backPath.moveTo(0, height);
    backPath.lineTo(0, waterLevel);

    for (double x = 0; x <= width; x += 1) {
      // Frekuensi rendah (lebar gelombang besar)
      final y = waterLevel +
          amplitude * 0.7 * math.sin(x / width * 1.5 * math.pi + wavePhase + math.pi / 2);
      backPath.lineTo(x, y);
    }
    backPath.lineTo(width, height);
    backPath.close();
    canvas.drawPath(backPath, backWavePaint);

    // ── Layer 2: Gelombang Depan (Primary Surface Wave) ──
    final frontWavePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          tintColor.withValues(alpha: 0.55),
          tintColor.withValues(alpha: 0.85),
        ],
      ).createShader(Rect.fromLTWH(0, waterLevel, width, height - waterLevel));

    final frontPath = Path();
    frontPath.moveTo(0, height);
    frontPath.lineTo(0, waterLevel);

    for (double x = 0; x <= width; x += 1) {
      final y = waterLevel +
          amplitude * math.sin(x / width * 1.5 * math.pi - wavePhase);
      frontPath.lineTo(x, y);
    }
    frontPath.lineTo(width, height);
    frontPath.close();
    canvas.drawPath(frontPath, frontWavePaint);

    // ── Layer 3: Foam / Highlight Line di puncak gelombang ──
    final crestPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.4)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final crestPath = Path();
    for (double x = 0; x <= width; x += 1) {
      final y = waterLevel +
          amplitude * math.sin(x / width * 1.5 * math.pi - wavePhase);
      if (x == 0) {
        crestPath.moveTo(x, y);
      } else {
        crestPath.lineTo(x, y);
      }
    }
    canvas.drawPath(crestPath, crestPaint);
  }

  @override
  bool shouldRepaint(covariant _LiquidWavePainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.wavePhase != wavePhase ||
        oldDelegate.tintColor != tintColor;
  }
}
