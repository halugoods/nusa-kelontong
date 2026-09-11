import 'dart:async';
import 'package:flutter/material.dart';

/// Event yang dipancarkan saat AI Agent melakukan aksi mandiri di aplikasi.
class AgentActionEvent {
  final String action;
  final String? detail;
  final bool isTyping;
  final String? typingTarget;
  final String? typedText;
  final bool isFinished;

  const AgentActionEvent({
    required this.action,
    this.detail,
    this.isTyping = false,
    this.typingTarget,
    this.typedText,
    this.isFinished = false,
  });
}

/// Service kontrol visual untuk AI Agent (Floating Action Pill & Virtual Typing)
class AgentActionController {
  static final AgentActionController I = AgentActionController._();
  AgentActionController._();

  final _controller = StreamController<AgentActionEvent>.broadcast();
  Stream<AgentActionEvent> get stream => _controller.stream;

  bool _isAgentModeEnabled = false;
  bool get isAgentModeEnabled => _isAgentModeEnabled;

  void setAgentMode(bool enabled) {
    _isAgentModeEnabled = enabled;
  }

  void emitAction(String action, {String? detail}) {
    if (!_controller.isClosed) {
      _controller.add(AgentActionEvent(
        action: action,
        detail: detail,
      ));
    }
  }

  /// Simulasi pengetikan virtual karakter per karakter dengan jeda waktu alami
  Future<void> simulateTyping({
    required String targetField,
    required String textToType,
    int delayMs = 35,
  }) async {
    String currentText = '';
    for (int i = 0; i < textToType.length; i++) {
      currentText += textToType[i];
      if (!_controller.isClosed) {
        _controller.add(AgentActionEvent(
          action: 'Mengetik $targetField',
          isTyping: true,
          typingTarget: targetField,
          typedText: currentText,
        ));
      }
      await Future.delayed(Duration(milliseconds: delayMs));
    }
  }

  void finishAction([String? message]) {
    if (!_controller.isClosed) {
      _controller.add(AgentActionEvent(
        action: message ?? 'Aksi selesai',
        isFinished: true,
      ));
    }
  }
}
