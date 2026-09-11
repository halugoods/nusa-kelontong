import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/config/nusa_config.dart';
import '../../core/providers/restore_progress_provider.dart';

/// Modern Editorial Glassmorphism Dialog untuk persiapan data & restore backup.
/// Menghilangkan dialog kaku jadul dan menggantinya dengan step milestone
/// interaktif, icon pulse animasi, dan kartu progress halus.
class RestoreProgressDialog extends ConsumerStatefulWidget {
  const RestoreProgressDialog({super.key, this.showImages = true});

  final bool showImages;

  @override
  ConsumerState<RestoreProgressDialog> createState() =>
      _RestoreProgressDialogState();
}

class _RestoreProgressDialogState extends ConsumerState<RestoreProgressDialog>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.92, end: 1.08).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rp = ref.watch(restoreProgressProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = NusaConfig.activePrimary;

    // Milestone calculation
    int currentStep = 1;
    if (rp.phase == RestorePhase.unpack) currentStep = 2;
    if (rp.phase == RestorePhase.images) currentStep = 3;
    if (rp.phase == RestorePhase.done) currentStep = 4;

    return PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xE61E293B)
                    : const Color(0xF2FFFFFF),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.1)
                      : primary.withValues(alpha: 0.15),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.12),
                    blurRadius: 28,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── Animated Header Icon ──
                  AnimatedBuilder(
                    animation: _pulseAnimation,
                    builder: (context, child) {
                      return Transform.scale(
                        scale: (rp.phase == RestorePhase.error ||
                                rp.phase == RestorePhase.done)
                            ? 1.0
                            : _pulseAnimation.value,
                        child: Container(
                          width: 68,
                          height: 68,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: rp.phase == RestorePhase.error
                                  ? [
                                      Colors.red.withValues(alpha: 0.2),
                                      Colors.red.withValues(alpha: 0.05),
                                    ]
                                  : rp.phase == RestorePhase.done
                                      ? [
                                          Colors.green.withValues(alpha: 0.2),
                                          Colors.green.withValues(alpha: 0.05),
                                        ]
                                      : [
                                          primary.withValues(alpha: 0.25),
                                          primary.withValues(alpha: 0.05),
                                        ],
                            ),
                          ),
                          child: Center(
                            child: Icon(
                              rp.phase == RestorePhase.error
                                  ? Icons.error_rounded
                                  : rp.phase == RestorePhase.done
                                      ? Icons.check_circle_rounded
                                      : Icons.cloud_sync_rounded,
                              size: 38,
                              color: rp.phase == RestorePhase.error
                                  ? Colors.redAccent
                                  : rp.phase == RestorePhase.done
                                      ? Colors.green
                                      : primary,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 16),

                  // ── Title & Status ──
                  Text(
                    rp.label,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: isDark ? Colors.white : const Color(0xFF0F172A),
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    rp.phase == RestorePhase.error
                        ? 'Terjadi kendala saat menyinkronkan data.'
                        : rp.phase == RestorePhase.done
                            ? 'Seluruh data berhasil disiapkan.'
                            : 'Mohon tunggu sejenak, data Anda sedang disiapkan.',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: isDark ? Colors.white60 : Colors.black54,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),

                  // ── Step Milestones ──
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF0F172A).withValues(alpha: 0.6)
                          : const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.05)
                            : Colors.black.withValues(alpha: 0.04),
                      ),
                    ),
                    child: Column(
                      children: [
                        _buildStepItem(
                          step: 1,
                          title: 'Unduh Arsip Cloud',
                          active: currentStep == 1,
                          done: currentStep > 1,
                          isDark: isDark,
                          primary: primary,
                        ),
                        const SizedBox(height: 8),
                        _buildStepItem(
                          step: 2,
                          title: 'Tata Database & Akun',
                          active: currentStep == 2,
                          done: currentStep > 2,
                          isDark: isDark,
                          primary: primary,
                        ),
                        if (widget.showImages) ...[
                          const SizedBox(height: 8),
                          _buildStepItem(
                            step: 3,
                            title: 'Sinkronisasi Foto Produk',
                            subtitle: rp.phase == RestorePhase.images &&
                                    rp.imageLabel.isNotEmpty
                                ? rp.imageLabel
                                : null,
                            active: currentStep == 3,
                            done: currentStep > 3,
                            isDark: isDark,
                            primary: primary,
                          ),
                        ],
                      ],
                    ),
                  ),

                  // ── Progress Bar untuk Images ──
                  if (rp.phase == RestorePhase.images) ...[
                    const SizedBox(height: 16),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: rp.determinate,
                        minHeight: 6,
                        backgroundColor: primary.withValues(alpha: 0.15),
                        valueColor: AlwaysStoppedAnimation(primary),
                      ),
                    ),
                  ],

                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.lock_clock_outlined,
                          size: 13,
                          color: isDark ? Colors.white38 : Colors.black38),
                      const SizedBox(width: 4),
                      Text(
                        'Sinkronisasi aman terenkripsi AES-256',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: isDark ? Colors.white38 : Colors.black45,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStepItem({
    required int step,
    required String title,
    String? subtitle,
    required bool active,
    required bool done,
    required bool isDark,
    required Color primary,
  }) {
    return Row(
      children: [
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: done
                ? Colors.green
                : active
                    ? primary
                    : (isDark ? Colors.white12 : Colors.black12),
          ),
          child: Center(
            child: done
                ? const Icon(Icons.check, size: 13, color: Colors.white)
                : active
                    ? const SizedBox(
                        width: 11,
                        height: 11,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(Colors.white),
                        ),
                      )
                    : Text(
                        '$step',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: isDark ? Colors.white54 : Colors.black54,
                        ),
                      ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 12.5,
                  fontWeight: active || done ? FontWeight.w700 : FontWeight.w500,
                  color: isDark
                      ? (active || done ? Colors.white : Colors.white54)
                      : (active || done ? const Color(0xFF0F172A) : Colors.black54),
                ),
              ),
              if (subtitle != null)
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: primary,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Tampilkan dialog progress modern (awaitable).
Future<void> showRestoreProgressDialog(BuildContext context,
    {bool showImages = true}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => RestoreProgressDialog(showImages: showImages),
  );
}
