import 'package:flutter/material.dart';
import '../config/nusa_config.dart';
import '../utils/icon_loader.dart';

/// Kinetic Splash Screen — Signature fluid entrance with ambient glow halo & horizon progress.
class SplashScreen extends StatefulWidget {
  final void Function(BuildContext context) onDone;
  final Duration duration;

  const SplashScreen({
    super.key,
    required this.onDone,
    this.duration = const Duration(milliseconds: 2400),
  });

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _fadeCtrl;
  late final Animation<double> _fadeAnim;

  late final AnimationController _scaleCtrl;
  late final Animation<double> _scaleAnim;

  late final AnimationController _glowCtrl;
  late final Animation<double> _glowAnim;

  late final AnimationController _progressCtrl;
  late final Animation<double> _progressAnim;

  @override
  void initState() {
    super.initState();

    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeIn);
    _fadeCtrl.forward();

    _scaleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    _scaleAnim = CurvedAnimation(parent: _scaleCtrl, curve: Curves.elasticOut);
    _scaleCtrl.forward();

    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
    _glowAnim = Tween<double>(begin: 0.85, end: 1.15).animate(
      CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOut),
    );

    _progressCtrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: widget.duration.inMilliseconds - 400),
    );
    _progressAnim = CurvedAnimation(parent: _progressCtrl, curve: Curves.easeInOutCubic);
    _progressCtrl.forward();

    Future.delayed(widget.duration, () {
      if (mounted) {
        _fadeCtrl.reverse().then((_) {
          widget.onDone(context);
        });
      }
    });
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    _scaleCtrl.dispose();
    _glowCtrl.dispose();
    _progressCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = NusaConfig.activePrimary;
    final logoAsset = splashLogoPath();

    return FadeTransition(
      opacity: _fadeAnim,
      child: Container(
        color: isDark ? NusaConfig.darkBackground : NusaConfig.backgroundColor,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Ambient pulsating back glow
            AnimatedBuilder(
              animation: _glowAnim,
              builder: (context, child) {
                return Center(
                  child: Container(
                    width: 280 * _glowAnim.value,
                    height: 280 * _glowAnim.value,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          primary.withValues(alpha: isDark ? 0.22 : 0.15),
                          primary.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),

            // Centered kinetic logo + branding
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ScaleTransition(
                      scale: _scaleAnim,
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: isDark
                              ? NusaConfig.darkSurface
                              : Colors.white,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: primary.withValues(alpha: 0.2),
                              blurRadius: 28,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: Image.asset(
                          logoAsset,
                          width: 88,
                          height: 88,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'NUSA',
                      style: TextStyle(
                        fontFamily: 'Poppins',
                        fontSize: 34,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 4,
                        decoration: TextDecoration.none,
                        color: isDark
                            ? NusaConfig.darkTextPrimary
                            : NusaConfig.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'by Halu Goods Indonesia',
                      style: TextStyle(
                        fontFamily: 'Poppins',
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        decoration: TextDecoration.none,
                        color: isDark
                            ? NusaConfig.darkTextTertiary
                            : NusaConfig.textTertiary,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Horizon Progress Bar at bottom
            Positioned(
              bottom: 48,
              left: 64,
              right: 64,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: AnimatedBuilder(
                      animation: _progressAnim,
                      builder: (context, child) {
                        return LinearProgressIndicator(
                          value: _progressAnim.value,
                          backgroundColor: isDark
                              ? NusaConfig.darkSurface
                              : primary.withValues(alpha: 0.12),
                          valueColor: AlwaysStoppedAnimation<Color>(primary),
                          minHeight: 3.5,
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
