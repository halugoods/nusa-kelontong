import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nusa_kasir/core/providers.dart';
import 'package:nusa_kasir/core/config/nusa_config.dart';
import 'package:nusa_kasir/core/services/ai_service.dart';
import 'package:nusa_kasir/core/agent/agent_tools.dart';
import 'package:nusa_kasir/core/agent/agent_action_controller.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:nusa_kasir/data/database/app_database.dart';

int _maxContextChars = 4000; // ~1K tokens — keep dbContext lean

class AiChatScreen extends ConsumerStatefulWidget {
  const AiChatScreen({super.key});
  @override
  ConsumerState<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends ConsumerState<AiChatScreen>
    with SingleTickerProviderStateMixin {
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _messages = <ChatMessage>[];
  bool _loading = false;
  String? _storeName;
  int? _activeSessionId;
  List<ChatSession> _sessions = [];
  bool _showSessions = false;

  // Drawer animation
  late AnimationController _drawerCtrl;
  late Animation<double> _drawerAnim;

  // Agent thinking state
  String _thinkingLabel = '';

  final List<String> _hints = [
    "Produk hampir habis",
    "Analisis penjualan bulan ini",
    "Top produk terlaris",
    "Ringkasan keuangan hari ini",
    "Siapa pelanggan saya?",
    "Promo yang aktif",
    "Karyawan siapa aja?",
  ];

  // Agent Mode State
  bool _agentMode = false;
  AgentActionEvent? _currentAgentAction;
  StreamSubscription<AgentActionEvent>? _agentSub;

  @override
  void initState() {
    super.initState();
    _agentMode = AgentActionController.I.isAgentModeEnabled;
    _agentSub = AgentActionController.I.stream.listen((ev) {
      if (!mounted) return;
      setState(() {
        if (ev.isFinished) {
          _currentAgentAction = null;
        } else {
          _currentAgentAction = ev;
        }
      });
    });
    _drawerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _drawerAnim = CurvedAnimation(parent: _drawerCtrl, curve: Curves.easeOutCubic);
    _loadStoreName();
    _loadSessions();
    _messages.add(ChatMessage(
      role: 'assistant',
      content: 'Halo! Saya Nusa, AI Assistant & Agent NUSA Kasir 👋 Saya bisa bantu analisis keuangan, cari data, hingga bantu operasional langsung (App Use). Ada yang bisa dibantu?',
    ));
  }

  @override
  void dispose() {
    _agentSub?.cancel();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _drawerCtrl.dispose();
    super.dispose();
  }

  void _toggleAgentMode(bool val) {
    if (val) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.warning_amber_rounded, color: Colors.orange),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('Aktifkan AI Agent?', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          content: const Text(
            'Mode AI Agent memungkinkan AI melakukan aksi langsung di aplikasi (seperti menambah produk, menyesuaikan stok, dan mendaftarkan pelanggan).\n\nPastikan instruksi yang Anda berikan jelas untuk menghindari perubahan data yang tidak diinginkan.',
            style: TextStyle(fontSize: 13, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Batal'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                setState(() {
                  _agentMode = true;
                  AgentActionController.I.setAgentMode(true);
                });
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: NusaConfig.activePrimary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('Aktifkan'),
            ),
          ],
        ),
      );
    } else {
      setState(() {
        _agentMode = false;
        AgentActionController.I.setAgentMode(false);
      });
    }
  }

  int get _totalChars => _visibleMessages.fold<int>(0, (s, m) => s + m.content.length);
  double get _contextUsage => (_totalChars / _maxContextChars).clamp(0.0, 1.0);
  List<ChatMessage> get _visibleMessages => _messages.where((m) => !m.isInternal).toList();

  void _toggleDrawer() {
    if (_showSessions) {
      _drawerCtrl.reverse().then((_) {
        if (mounted) setState(() => _showSessions = false);
      });
    } else {
      setState(() => _showSessions = true);
      _drawerCtrl.forward();
    }
  }

  // ── Session management ──────────────────────────────────────────────

  /// Muat riwayat sesi: lokal (SQLite `chat_sessions`) saja.
  /// v2.2.57+119: riwayat chat TIDAK lagi dibedakan cloud vs local —
  /// cukup local (perangkat ini).
  Future<void> _loadSessions() async {
    try {
      final db = ref.read(databaseProvider);
      final rows = await (db.select(db.chatSessions)
        ..orderBy([(t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc)]))
        .get();
      if (mounted) setState(() => _sessions = rows);
    } catch (_) {}
  }

  Future<void> _saveSession() async {
    if (_visibleMessages.length <= 1) return;
    try {
      final db = ref.read(databaseProvider);
      final title = _autoTitle();
      final json = jsonEncode(_visibleMessages.map((m) => m.toJson()).toList());
      if (_activeSessionId != null) {
        await (db.update(db.chatSessions)..where((t) => t.id.equals(_activeSessionId!)))
            .write(ChatSessionsCompanion(
              title: Value(title),
              messagesJson: Value(json),
              updatedAt: Value(DateTime.now()),
            ));
      } else {
        _activeSessionId = await db.into(db.chatSessions).insert(ChatSessionsCompanion.insert(
              title: title,
              messagesJson: json,
            ));
      }
      _loadSessions();
    } catch (_) {}
  }

  Future<void> _loadSession(ChatSession session) async {
    try {
      final msgs = (jsonDecode(session.messagesJson) as List)
          .map((j) => ChatMessage.fromJson(j as Map<String, dynamic>))
          .toList();
      setState(() {
        _messages.clear();
        _messages.addAll(msgs);
        _activeSessionId = session.id;
      });
      _toggleDrawer();
      _scrollToBottom();
    } catch (_) {}
  }

  Future<void> _deleteSession(ChatSession session) async {
    try {
      final db = ref.read(databaseProvider);
      await (db.delete(db.chatSessions)..where((t) => t.id.equals(session.id))).go();
      if (_activeSessionId == session.id) {
        setState(() => _activeSessionId = null);
      }
      _loadSessions();
    } catch (_) {}
  }

  // v2.2.57+119: riwayat chat DIHAPUS dari cloud — cukup local saja.
  // (Blok kode cloud dihapus total; lihat _loadSessions/_newChat.)

  void _newChat() {
    _saveSession();
    setState(() {
      _messages.clear();
      _activeSessionId = null;
      _showSessions = false;
      _messages.add(ChatMessage(
        role: 'assistant',
        content: 'Halo! Ada yang bisa saya bantu hari ini?',
      ));
    });
  }

  String _autoTitle() {
    final firstUser = _visibleMessages.where((m) => m.role == 'user').firstOrNull;
    if (firstUser == null) return 'Chat Baru';
    final words = firstUser.content.split(' ');
    return words.take(6).join(' ') + (words.length > 6 ? '...' : '');
  }

  Future<void> _loadStoreName() async {
    final name = await ref.read(settingsRepoProvider).getStoreName();
    if (mounted && name.isNotEmpty) setState(() => _storeName = name);
  }

  // ── Send message (streaming cloud + agent tool calling loop) ──
  //
  // Area H (v2.2.57+115): chat TIDAK lagi ke server lokal Nusa CS — penuh
  // ke cloud Supabase edge function `ai-assistant` (streaming SSE + tools +
  // provider configurable). Riwayat chat lokal (v2.2.57+119).

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _loading) return;

    final owner = await AiService.ownerId();
    final db = ref.read(databaseProvider);
    final tools = AgentToolRegistry.forVariant();
    final toolDefs = tools.map((t) => t.toOpenAiTool()).toList();

    setState(() {
      _messages.add(ChatMessage(role: 'user', content: text));
      _loading = true;
      _thinkingLabel = 'Menganalisa...';
    });
    _inputCtrl.clear();
    _scrollToBottom();

    // Sliding window: kirim hanya 6 pesan terakhir agar hemat token.
    final visible = _visibleMessages;
    final recent = visible.length > 6
        ? visible.sublist(visible.length - 6)
        : List<ChatMessage>.from(visible);

    // Stream status bar: provider aktif.
    final settings = await AiService.getSettings(owner);
    if (mounted) {
      setState(() {
        _thinkingLabel = settings?.isCustom == true
            ? 'AI: ${settings?.model ?? 'default'} (custom)'
            : 'AI: ${settings?.model ?? 'default'}...';
      });
    }

    try {
      for (int round = 0; round < 2; round++) {
        // Buffer teks terpisah — ChatMessage.content final, jadi bubble di-replace
        // tiap token (remove/add) supaya SelectableText ikut ter-update.
        final buffer = StringBuffer();

        // v2.2.57+119: indexOf(streamMsg) memakai identitas (==) — setelah
        // bubble pertama diganti instance baru, indexOf selalu -1 → bubble
        // beku di token pertama. Iterasi manual dengan identitas field lebih
        // aman & tidak bergantung urutan List.
        final streamMsg = ChatMessage(role: 'assistant', content: '');
        if (mounted) setState(() => _messages.add(streamMsg));
        _scrollToBottom();

        final toolCalls = await AiService.chatStream(
          messages: recent,
          tools: toolDefs,
          storeName: _storeName,
          owner: owner,
          onEvent: (ev) {
            if (ev.delta != null && mounted) {
              buffer.write(ev.delta);
              final idx = _indexOfMessage(streamMsg);
              setState(() {
                if (idx >= 0) {
                  _messages[idx] = ChatMessage(
                    role: 'assistant',
                    content: buffer.toString(),
                  );
                }
              });
              _scrollToBottom();
            }
          },
        );

        if (!mounted) return;

        // Tool calls? jalankan lokal, lalu lanjut round berikutnya.
        if (toolCalls != null && toolCalls.isNotEmpty) {
          // v2.2.57+119: hanya tool call TERAKHIR yang dieksekusi — kalau
          // model minta banyak tool sekaligus, menjalankan semuanya bikin
          // jawaban berantakan & tidak nyambung. Model bisa memanggil lagi
          // di round berikutnya.
          final tc = toolCalls.last;
          final tool = tools.where((t) => t.name == tc.name).firstOrNull;
          if (tool != null) {
            setState(() => _thinkingLabel = 'Menjalankan: ${tc.name}...');
            _scrollToBottom();
            try {
              final rawResult = await tool.execute(db, tc.arguments);
              // v2.2.57+119: truncation diperlonggar (350 → 2000 char) + ada
              // penanda "...(dipotong)" supaya model tahu datanya tidak utuh
              // dan TIDAK mengarang angka yang tidak ada di potongan.
              final truncated = rawResult.length > 2000;
              final result = truncated
                  ? '${rawResult.substring(0, 2000)}\n...(hasil dipotong, ${rawResult.length} karakter total)'
                  : rawResult;

              _messages.add(ChatMessage(
                role: 'assistant',
                content: buffer.toString(),
                toolCallId: tc.id,
                toolName: tc.name,
                toolArgs: tc.arguments,
              ));
              final toolMsg = ChatMessage(
                role: 'tool',
                content: result,
                toolCallId: tc.id,
                toolName: tc.name,
              );
              _messages.add(toolMsg);
              recent.add(ChatMessage(
                role: 'assistant',
                content: buffer.toString(),
                toolCallId: tc.id,
                toolName: tc.name,
                toolArgs: tc.arguments,
              ));
              recent.add(toolMsg);
            } catch (e) {
              _messages.add(ChatMessage(
                role: 'tool',
                content: '{"error": "$e"}',
                toolCallId: tc.id,
                toolName: tc.name,
              ));
              recent.add(ChatMessage(
                role: 'tool',
                content: '{"error": "$e"}',
                toolCallId: tc.id,
                toolName: tc.name,
              ));
            }
            continue;
          }
        }

        // Teks selesai
        if (mounted) {
          setState(() {
            _loading = false;
            _thinkingLabel = '';
          });
          _scrollToBottom();
          _saveSession();
        }
        return;
      }

      // Rounds habis tanpa jawaban teks
      if (mounted) {
        setState(() {
          _messages.add(ChatMessage(
            role: 'assistant',
            content: 'Saya sudah mencari datanya tapi belum menemukan jawaban yang tepat. Coba tanyakan dengan kata kunci yang lebih spesifik ya.',
          ));
          _loading = false;
          _thinkingLabel = '';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _messages.add(ChatMessage(role: 'assistant', content: 'Gagal: $e'));
          _loading = false;
          _thinkingLabel = '';
        });
      }
    }
  }

  /// Cari index pesan dengan identitas objek — aman walau instance di dalam
  /// list sudah diganti (bubble streaming di-replace tiap token).
  int _indexOfMessage(ChatMessage needle) {
    for (int i = 0; i < _messages.length; i++) {
      if (identical(_messages[i], needle)) return i;
    }
    return -1;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ── Build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 28, height: 28,
              decoration: BoxDecoration(
                color: NusaConfig.activePrimary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Icon(Icons.auto_awesome_rounded, size: 16, color: NusaConfig.activePrimary),
            ),
            const SizedBox(width: 8),
            const Text('Nusa', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          ],
        ),
        leading: IconButton(
          icon: Icon(_showSessions ? Icons.close_rounded : Icons.history_rounded),
          onPressed: _toggleDrawer,
        ),
        actions: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Agent',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: _agentMode ? NusaConfig.activePrimary : (isDark ? Colors.white54 : Colors.black54),
                ),
              ),
              Transform.scale(
                scale: 0.75,
                child: Switch(
                  value: _agentMode,
                  activeColor: NusaConfig.activePrimary,
                  onChanged: _toggleAgentMode,
                ),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: 'Chat Baru',
            onPressed: _newChat,
          ),
        ],
      ),
      body: Stack(
        children: [
          // ── Chat area (always full-width behind drawer) ──
          _buildChatArea(isDark),

          // ── Live Ghost Action & Virtual Typing Overlay ──
          if (_currentAgentAction != null)
            Positioned(
              top: 12,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xE61E293B) : const Color(0xF2FFFFFF),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: NusaConfig.activePrimary.withValues(alpha: 0.4), width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: NusaConfig.activePrimary.withValues(alpha: 0.2),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: NusaConfig.activePrimary.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Center(
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Text(
                                _currentAgentAction!.action,
                                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                              ),
                              if (_currentAgentAction!.isTyping) ...[
                                const SizedBox(width: 4),
                                const Text('▋', style: TextStyle(color: Colors.blue, fontSize: 12)),
                              ],
                            ],
                          ),
                          if (_currentAgentAction!.typedText != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                '"${_currentAgentAction!.typedText}"',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontStyle: FontStyle.italic,
                                  color: isDark ? Colors.white70 : Colors.black87,
                                ),
                              ),
                            )
                          else if (_currentAgentAction!.detail != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                _currentAgentAction!.detail!,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: isDark ? Colors.white60 : Colors.black54,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // ── Session drawer overlay ──
          if (_showSessions) ...[
            // Backdrop
            FadeTransition(
              opacity: _drawerAnim,
              child: GestureDetector(
                onTap: _toggleDrawer,
                child: Container(color: Colors.black.withValues(alpha: 0.35)),
              ),
            ),
            // Drawer sliding from left
            AnimatedBuilder(
              animation: _drawerAnim,
              builder: (_, child) {
                return Positioned(
                  left: -(280 * (1 - _drawerAnim.value)),
                  top: 0,
                  bottom: 0,
                  width: 280,
                  child: _buildSessionDrawer(isDark),
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSessionDrawer(bool isDark) {
    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: isDark ? NusaConfig.darkSurface : Colors.white,
        border: Border(
          right: BorderSide(color: isDark ? NusaConfig.darkBorder : NusaConfig.borderColor),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 16,
            offset: const Offset(4, 0),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('Riwayat Chat',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700,
                      color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary)),
            ),
          ),
          const Divider(),
          Expanded(
            child: _sessions.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('Belum ada riwayat chat',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13,
                              color: isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary)),
                    ),
                  )
                : ListView(
                    children: [
                      // ── Riwayat lokal (perangkat ini) — v2.2.57+119:
                      // riwayat chat cukup local saja (tidak dibedakan cloud).
                      if (_sessions.isNotEmpty) ...[
                        ..._sessions.map((s) {
                          final active = s.id == _activeSessionId;
                          return ListTile(
                            dense: true,
                            selected: active,
                            selectedTileColor: NusaConfig.activePrimary.withValues(alpha: 0.08),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            title: Text(s.title,
                                maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                            subtitle: Text(
                              _formatDate(s.updatedAt),
                              style: TextStyle(fontSize: 11,
                                  color: isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary),
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline, size: 16),
                              onPressed: () => _deleteSession(s),
                            ),
                            onTap: () => _loadSession(s),
                          );
                        }),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatArea(bool isDark) {
    return Column(
      children: [
        // Status bar
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          color: NusaConfig.activePrimary.withValues(alpha: 0.06),
          child: Row(
            children: [
              Icon(Icons.circle, size: 6, color: NusaConfig.accentGreen),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _storeName != null ? 'Aktif — $_storeName' : 'Aktif',
                  style: TextStyle(
                      fontSize: 11,
                      color: isDark ? NusaConfig.darkTextSecondary : NusaConfig.textSecondary,
                      fontWeight: FontWeight.w500),
                ),
              ),
              // Context usage
              if (_visibleMessages.length > 2) ...[
                Container(
                  width: 48, height: 3,
                  decoration: BoxDecoration(
                    color: isDark ? NusaConfig.darkBorder : NusaConfig.dividerColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: _contextUsage,
                    child: Container(
                      decoration: BoxDecoration(
                        color: _contextUsage > 0.8
                            ? NusaConfig.activePrimary
                            : _contextUsage > 0.5
                                ? Colors.orange
                                : NusaConfig.accentGreen,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text('${(_contextUsage * 100).toInt()}%',
                    style: TextStyle(fontSize: 9, color: isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary)),
              ],
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: NusaConfig.accentGreen.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('GRATIS',
                    style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: NusaConfig.accentGreen)),
              ),
            ],
          ),
        ),

        // Messages (filter out internal tool messages from UI)
        Expanded(
          child: ListView.builder(
            controller: _scrollCtrl,
            padding: const EdgeInsets.all(16),
            itemCount: _visibleMessages.length + (_loading ? 1 : 0),
            itemBuilder: (_, i) {
              if (i >= _visibleMessages.length) {
                return _thinkingBubble(isDark);
              }
              return _bubble(_visibleMessages[i], isDark);
            },
          ),
        ),

        // Quick hints
        if (_hints.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _hints.map((hint) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      label: Text(hint, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500)),
                      onPressed: _loading ? null : () {
                        _inputCtrl.text = hint;
                        _send();
                      },
                      backgroundColor: isDark
                          ? NusaConfig.darkSurface2
                          : NusaConfig.backgroundColor,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: isDark ? NusaConfig.darkBorder : NusaConfig.borderColor,
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
                      visualDensity: VisualDensity.compact,
                    ),
                  );
                }).toList(),
              ),
            ),
          ),

        // Input
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          decoration: BoxDecoration(
            color: isDark ? NusaConfig.darkSurface : Colors.white,
            border: Border(
              top: BorderSide(
                  color: isDark ? NusaConfig.darkDivider : NusaConfig.dividerColor),
            ),
          ),
          child: SafeArea(
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputCtrl,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    style: TextStyle(
                      fontSize: 14,
                      color: isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Tanya tentang bisnis kamu...',
                      hintStyle: TextStyle(fontSize: 14,
                          color: isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary),
                      filled: true,
                      fillColor: isDark
                          ? NusaConfig.darkSurface2
                          : NusaConfig.backgroundColor,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  decoration: BoxDecoration(
                    color: _loading
                        ? NusaConfig.activePrimary.withValues(alpha: 0.3)
                        : NusaConfig.activePrimary,
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    onPressed: _loading ? null : _send,
                    icon: Icon(_loading ? Icons.hourglass_top_rounded : Icons.send_rounded,
                        color: Colors.white, size: 20),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _bubble(ChatMessage msg, bool isDark) {
    final isUser = msg.role == 'user';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: NusaConfig.activePrimary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.auto_awesome_rounded,
                  size: 15, color: NusaConfig.activePrimary),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.78),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isUser
                    ? NusaConfig.activePrimary
                    : (isDark ? NusaConfig.darkSurface2 : NusaConfig.surfaceColor),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isUser ? 16 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 16),
                ),
                border: isUser
                    ? null
                    : Border.all(
                        color: isDark ? NusaConfig.darkBorder : NusaConfig.borderColor),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  SelectableText(
                    msg.content,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.45,
                      color: isUser
                          ? Colors.white
                          : (isDark ? NusaConfig.darkTextPrimary : NusaConfig.textPrimary),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _formatTime(msg.timestamp),
                    style: TextStyle(
                      fontSize: 9,
                      color: isUser
                          ? Colors.white.withValues(alpha: 0.55)
                          : (isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _thinkingBubble(bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: NusaConfig.activePrimary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.auto_awesome_rounded,
                size: 15, color: NusaConfig.activePrimary),
          ),
          const SizedBox(width: 8),
          Container(
            constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.78),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: isDark ? NusaConfig.darkSurface2 : NusaConfig.surfaceColor,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomRight: Radius.circular(16),
                bottomLeft: Radius.circular(4),
              ),
              border: Border.all(
                  color: isDark ? NusaConfig.darkBorder : NusaConfig.borderColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _dot(isDark: isDark),
                    const SizedBox(width: 3),
                    _dot(delay: 200, isDark: isDark),
                    const SizedBox(width: 3),
                    _dot(delay: 400, isDark: isDark),
                  ],
                ),
                if (_thinkingLabel.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    _thinkingLabel,
                    style: TextStyle(
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                      color: isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _dot({int delay = 0, required bool isDark}) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.3, end: 1.0),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeInOut,
      builder: (_, val, __) => Opacity(
        opacity: val,
        child: Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: isDark ? NusaConfig.darkTextTertiary : NusaConfig.textTertiary,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'Baru saja';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m yg lalu';
    if (diff.inHours < 24) return '${diff.inHours}j yg lalu';
    if (diff.inDays < 7) return '${diff.inDays}h yg lalu';
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
