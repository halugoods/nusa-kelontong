import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nusa_kasir/core/config/nusa_config.dart';
import 'package:nusa_kasir/core/services/sound_service.dart';
import 'package:nusa_kasir/core/providers.dart';
import 'package:nusa_kasir/data/repositories/attendance_repository.dart';
import 'package:nusa_kasir/shared/widgets/pin_keypad.dart';

/// Result of a PIN dialog authentication attempt.
class PinResult {
  final bool success;
  final bool remember;
  /// If NFC was used, the employee ID from the tag.
  final int? nfcEmployeeId;
  PinResult({required this.success, required this.remember, this.nfcEmployeeId});
}

/// Unified PIN authentication dialog -- used everywhere.
///
/// Two modes:
/// - **Direct PIN match**: pass `correctPin` -- dialog compares locally.
/// - **Verify callback**: pass `onVerify` -- dialog calls your async function
///   with the entered PIN. Return `true` for success.
///
/// Also supports fingerprint (`onFingerprint`), NFC (`onNfc`), and barcode.
///
/// **v2.2.47 revisi**: popup dialog (bukan fullscreen), animasi pop-up.
/// `showRemember` defaults to `false` (no "Ingat PIN selama 8 jam").
class PinDialog extends StatelessWidget {
  final String? title;
  final String? subtitle;
  final String? employeeName;
  final String? employeeRole;
  final String? correctPin;
  final Future<bool> Function(String pin)? onVerify;
  final bool allowOverride;
  final bool showRemember;
  final int pinLength;
  final bool showFingerprint;
  final bool showNfc;
  final bool showBarcode;
  final Future<bool> Function()? onFingerprint;
  final Future<String?> Function()? onNfc;
  final Future<String?> Function(String code)? onBarcode;
  /// v2.2.50 (A5): "Lupa PIN?" button — dipanggil dari 5 tempat.
  final VoidCallback? onForgotPin;

  const PinDialog({
    super.key,
    this.title,
    this.subtitle,
    this.employeeName,
    this.employeeRole,
    this.correctPin,
    this.onVerify,
    this.allowOverride = true,
    this.showRemember = false,
    this.pinLength = 6,
    this.showFingerprint = false,
    this.showNfc = false,
    this.showBarcode = false,
    this.onFingerprint,
    this.onNfc,
    this.onBarcode,
    this.onForgotPin,
  });

  /// Show the dialog (popup animation). Returns [PinResult] or null if cancelled.
  /// `showNfc` and `showBarcode` default to `true` so NFC/barcode hints selalu muncul.
  static Future<PinResult?> show({
    required BuildContext context,
    String? title,
    String? subtitle,
    String? employeeName,
    String? employeeRole,
    String? correctPin,
    Future<bool> Function(String pin)? onVerify,
    bool allowOverride = true,
    bool showRemember = false,
    int? pinLength,
    bool showFingerprint = false,
    bool showNfc = true,
    bool showBarcode = true,
    Future<bool> Function()? onFingerprint,
    Future<String?> Function()? onNfc,
    Future<String?> Function(String code)? onBarcode,
    VoidCallback? onForgotPin,
  }) async {
    // Resolve stored PIN length (4/6) -- never hardcode 6.
    var resolvedLength = pinLength ?? 6;
    if (pinLength == null) {
      try {
        final container = ProviderScope.containerOf(context, listen: false);
        resolvedLength = await container.read(settingsRepoProvider).getPinLength();
      } catch (_) {
        resolvedLength = 6;
      }
    }

    return showDialog<PinResult>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _PinDialogContent(
        title: title,
        subtitle: subtitle,
        employeeName: employeeName,
        employeeRole: employeeRole,
        correctPin: correctPin,
        onVerify: onVerify,
        allowOverride: allowOverride,
        showRemember: showRemember,
        pinLength: resolvedLength,
        showFingerprint: showFingerprint,
        showNfc: showNfc,
        showBarcode: showBarcode,
        onFingerprint: onFingerprint,
        onNfc: onNfc,
        onBarcode: onBarcode,
        onForgotPin: onForgotPin,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Popup dialog content -- card layout matching login pinpad.
/// v2.2.47 revisi: popup (bukan fullscreen), NFC/barcode hints stacked vertikal.
class _PinDialogContent extends StatefulWidget {
  final String? title;
  final String? subtitle;
  final String? employeeName;
  final String? employeeRole;
  final String? correctPin;
  final Future<bool> Function(String pin)? onVerify;
  final bool allowOverride;
  final bool showRemember;
  final int pinLength;
  final bool showFingerprint;
  final bool showNfc;
  final bool showBarcode;
  final Future<bool> Function()? onFingerprint;
  final Future<String?> Function()? onNfc;
  final Future<String?> Function(String code)? onBarcode;
  final VoidCallback? onForgotPin;

  const _PinDialogContent({
    this.title,
    this.subtitle,
    this.employeeName,
    this.employeeRole,
    this.correctPin,
    this.onVerify,
    this.allowOverride = true,
    this.showRemember = false,
    required this.pinLength,
    this.showFingerprint = false,
    this.showNfc = true,
    this.showBarcode = true,
    this.onFingerprint,
    this.onNfc,
    this.onBarcode,
    this.onForgotPin,
  });

  @override
  State<_PinDialogContent> createState() => _PinDialogContentState();
}

class _PinDialogContentState extends State<_PinDialogContent> {
  String? _error;
  bool _remember = false;
  final _keypadKey = GlobalKey<_PinDialogKeypadState>();

  String get _displayTitle => widget.title ?? 'Masuk';

  String? get _displaySubtitle {
    if (widget.subtitle != null) return widget.subtitle;
    if (widget.employeeName != null) {
      return 'Masukkan PIN ${widget.employeeName}';
    }
    return null;
  }

  Future<void> _verify(String pin) async {
    if (pin.isEmpty) return;
    bool ok = false;

    if (widget.correctPin != null) {
      ok = pin == widget.correctPin;
    } else if (widget.onVerify != null) {
      ok = await widget.onVerify!(pin);
    }

    if (!ok && widget.allowOverride) {
      try {
        final container = ProviderScope.containerOf(context, listen: false);
        final db = container.read(databaseProvider);
        final overrideEmp = await AttendanceRepository(db).findOverrideEmployee();
        if (overrideEmp != null && pin == overrideEmp.pin) {
          ok = true;
        }
      } catch (_) {}
    }

    if (ok) {
      if (mounted) {
        Navigator.of(context).pop(PinResult(success: true, remember: _remember));
      }
    } else {
      SoundService.I.play(NusaSound.error);
      setState(() {
        _error = 'PIN salah';
        _keypadKey.currentState?.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Modern Card without redundant big lock icon
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              decoration: BoxDecoration(
                color: isDark ? NusaConfig.darkSurface : Colors.white,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor.withValues(alpha: 0.5),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                    blurRadius: 28,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Modern Icon badge inside card
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: NusaConfig.activePrimary.withValues(alpha: isDark ? 0.2 : 0.1),
                    ),
                    child: Icon(
                      Icons.pin_outlined,
                      color: NusaConfig.activePrimary,
                      size: 24,
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Title
                  Text(
                    _displayTitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: isDark ? NusaConfig.darkTextPrimary : const Color(0xFF151717),
                    ),
                  ),
                  if (_displaySubtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      _displaySubtitle!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary,
                      ),
                    ),
                  ],
                  if (widget.employeeRole != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      widget.employeeRole!,
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),

                  // Keypad — dengan NFC + barcode hints stacked vertikal
                  _PinDialogKeypad(
                    key: _keypadKey,
                    pinLength: widget.pinLength,
                    error: _error,
                    showFingerprint: widget.showFingerprint,
                    showNfc: widget.showNfc,
                    showBarcode: widget.showBarcode,
                    onFingerprint: widget.onFingerprint,
                    onNfc: widget.onNfc,
                    onNfcSuccess: (id) {
                      Navigator.of(context).pop(PinResult(
                          success: true, remember: _remember, nfcEmployeeId: int.tryParse(id)));
                    },
                    onBarcode: widget.onBarcode,
                    onBarcodeSuccess: (id) {
                      Navigator.of(context).pop(PinResult(
                          success: true, remember: _remember, nfcEmployeeId: id));
                    },
                    onComplete: _verify,
                  ),

                  // Remember checkbox
                  if (widget.showRemember) ...[
                    const SizedBox(height: 12),
                    GestureDetector(
                      onTap: () => setState(() => _remember = !_remember),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 22,
                            height: 22,
                            child: Checkbox(
                              value: _remember,
                              onChanged: (v) => setState(() => _remember = v ?? false),
                              activeColor: NusaConfig.activePrimary,
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Ingat PIN selama 8 jam',
                            style: TextStyle(
                              fontSize: 13,
                              color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  // v2.2.50 (A5): "Lupa PIN?" — muncul di bawah keypad
                  if (widget.onForgotPin != null) ...[
                    const SizedBox(height: 10),
                    GestureDetector(
                      onTap: widget.onForgotPin,
                      child: Text(
                        'Lupa PIN?',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: NusaConfig.activePrimary,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────
// Internal keypad holder that exposes [clear].
// ─────────────────────────────────────────────────

class _PinDialogKeypad extends StatefulWidget {
  final int pinLength;
  final String? error;
  final bool showFingerprint;
  final bool showNfc;
  final bool showBarcode;
  final Future<bool> Function()? onFingerprint;
  final Future<String?> Function()? onNfc;
  final Future<String?> Function(String code)? onBarcode;
  final ValueChanged<String> onComplete;
  final ValueChanged<String>? onNfcSuccess;
  final ValueChanged<int>? onBarcodeSuccess;

  const _PinDialogKeypad({
    super.key,
    required this.pinLength,
    this.error,
    this.showFingerprint = false,
    this.showNfc = true,
    this.showBarcode = true,
    this.onFingerprint,
    this.onNfc,
    this.onBarcode,
    required this.onComplete,
    this.onNfcSuccess,
    this.onBarcodeSuccess,
  });

  @override
  State<_PinDialogKeypad> createState() => _PinDialogKeypadState();
}

class _PinDialogKeypadState extends State<_PinDialogKeypad> {
  int _resetCount = 0;

  void clear() {
    setState(() => _resetCount++);
  }

  Future<String?> _onNfcHandler() async {
    if (widget.onNfc != null) {
      final result = await widget.onNfc!();
      if (result != null && mounted) {
        widget.onNfcSuccess?.call(result);
      }
      return result;
    }
    return null;
  }

  Future<String?> _onBarcodeHandler(String code) async {
    if (widget.onBarcode != null) {
      final result = await widget.onBarcode!(code);
      if (result != null && mounted) {
        widget.onBarcodeSuccess?.call(int.tryParse(result) ?? -1);
      }
      return result;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return PinKeypad(
      key: ValueKey('dialog_pad_$_resetCount'),
      length: widget.pinLength,
      error: widget.error,
      showFingerprint: widget.showFingerprint,
      showNfc: widget.showNfc,
      showBarcode: widget.showBarcode,
      showCancel: false,
      onFingerprint: widget.onFingerprint,
      onFingerprintSuccess: () => Navigator.of(context)
          .pop(PinResult(success: true, remember: true)),
      onNfc: _onNfcHandler,
      onBarcode: _onBarcodeHandler,
      onComplete: widget.onComplete,
      onCancel: () => Navigator.of(context).pop(null),
    );
  }
}
