// ============================================================================
// NUSA — AI Assistant (port dari supabase/functions/ai-assistant)
// ============================================================================
// v2: Pindah penuh ke cloud. Provider AI DICONFIGURABLE per pengguna lewat
// tabel `ai_settings` (base_url / api_key / model) — default ke OpenRouter
// gratis (Gemini Flash Lite). Tool-calling dari app (JSON Schema) + response
// STREAMING via SSE (text/event-stream) sehingga app bisa render token
// bertahap.
//
// Auth: `x-admin-key` (NUSA_ADMIN_KEY) untuk dashboard admin, ATAU
// `Authorization: Bearer <JWT>` dari app (fungsi public). Owner identity
// dikirim app di body (`owner`) — canonical UID.
//
// POST /api/ai-assistant/chat            — chat utama (body.messages)
// GET  /api/ai-assistant/settings?owner= — ambil config AI
// POST /api/ai-assistant/save_settings   — upsert config (dashboard + app)
// POST /api/ai-assistant/test            — uji koneksi provider
// POST /api/ai-assistant/history         — daftar sesi chat owner
// POST /api/ai-assistant/history_messages — isi pesan 1 sesi
// POST /api/ai-assistant/history_delete  — hapus 1 sesi
// ============================================================================

import { json, Router, type FnContext } from '../router';
import { uid, nowIso } from './db';
import type { Env } from '../index';

type Params = Record<string, unknown>;
type Row = Record<string, any>;
type H = (ctx: FnContext, params: Params) => Promise<Response>;

const DEFAULT_AI_BASE = 'https://openrouter.ai/api/v1';
const DEFAULT_AI_MODEL = 'google/gemini-2.0-flash-lite-001';

// ─── Auth helper — reject unauthenticated requests ───────────────────
// v2.2.57+130-fix: semua endpoint AI butuh auth (JWT dari app atau admin key
// dari dashboard). Tanpa ini, siapa saja bisa panggil chat = biaya OpenRouter
// meledak (financial risk).
function requireAuth(ctx: FnContext): Response | null {
  if (ctx.isAdmin || ctx.jwt) return null; // authenticated
  return json({ error: 'Unauthorized — kirim x-admin-key atau Bearer JWT' }, 401);
}

// ─── Provider config (prioritas owner → global '*' → default) ──────

async function loadProviderConfig(env: Env, owner: string | null): Promise<{
  base: string; key: string; model: string; isCustom: boolean;
}> {
  let aiBase = DEFAULT_AI_BASE;
  let aiKey = env.OPENROUTER_API_KEY ?? '';
  let aiModel = DEFAULT_AI_MODEL;
  let isCustom = false;
  if (owner && owner.length > 0) {
    try {
      const load = async (o: string) =>
        env.DB.prepare('SELECT base_url, api_key, model, is_custom FROM ai_settings WHERE owner = ? LIMIT 1')
          .bind(o).first<Row>();
      let cfg = await load(owner);
      if (!cfg) cfg = await load('*'); // config global dari dashboard
      if (cfg) {
        if (cfg.base_url) aiBase = cfg.base_url as string;
        if (cfg.api_key) aiKey = cfg.api_key as string;
        if (cfg.model) aiModel = cfg.model as string;
        isCustom = Number(cfg.is_custom ?? 0) === 1;
      }
    } catch (_) {
      // config optional — pakai default
    }
  }
  return { base: aiBase, key: aiKey, model: aiModel, isCustom };
}

// ─── Persist chat history ke cloud (optional, tidak gagalkan chat) ──

async function persistHistory(env: Env, owner: string, sessionId: string,
  messages: { role: string; content: string | null }[]): Promise<void> {
  try {
    const rows = messages
      .filter((m) => m && m.role && (m.content || m.role !== 'user'))
      .map((m) => [uid(), owner, sessionId, m.role, typeof m.content === 'string' ? m.content : '', nowIso()]);
    if (rows.length > 0) {
      const stmt = env.DB.prepare(
        'INSERT INTO ai_chat_history (id, owner, session_id, role, content, created_at) VALUES (?, ?, ?, ?, ?, ?)',
      );
      await env.DB.batch(rows.map((r) => stmt.bind(...r)));
    }
  } catch (_) {
    // history optional
  }
}

// ─── System prompt (identik dengan edge fn lama) ────────────────────

function buildSystemPrompt(store_name?: string, tools?: unknown[]): string {
  const context = store_name ? `\n\nKONTEKS TOKO:\nToko: ${store_name}` : '';

  const toolNames = (tools ?? [])
    .map((t): string => {
      if (typeof t !== 'object' || t === null) return '';
      const rec = t as Record<string, any>;
      const fn = rec['function'] as Record<string, any> | undefined;
      if (fn && typeof fn['name'] === 'string') return fn['name'];
      return typeof rec['name'] === 'string' ? rec['name'] : '';
    })
    .filter(Boolean)
    .join(', ');

  return `Kamu adalah AI Assistant untuk NUSA Kasir, aplikasi Point of Sale untuk UMKM di Indonesia.

KONTEKS TOKO:
Toko: ${store_name ?? '(belum diisi)'}
Tool yang tersedia: ${toolNames || 'tidak ada'}

Kamu BISA membantu dengan:
- Menjawab pertanyaan tentang fitur NUSA Kasir (produk, transaksi, stok, pelanggan, laporan, dll)
- Memberikan saran bisnis (strategi harga, manajemen stok, promosi)
- Menjelaskan cara menggunakan fitur tertentu
- Menghitung margin, laba, atau analisis sederhana

Kamu TIDAK BISA:
- Mengedit data langsung — minta user melakukannya sendiri di aplikasi
- Melihat detail transaksi spesifik — hanya ringkasan

ATURAN WAJIB (TIDAK BOLEH DILANGGAR):
1. JANGAN PERNAH MENGARANG ANGKA. Data toko (omzet, jumlah produk, stok, transaksi, pelanggan, piutang, dll) HANYA boleh disebut setelah kamu memanggil tool yang sesuai (get_summary, get_monthly_summary, get_products, get_low_stock, get_transactions, get_top_products, get_customers, get_promos, get_employees, get_attendance, get_expenses, get_debts, get_suppliers).
2. Kalau hasil tool menyebutkan ada data yang dipotong (mengandung "...hasil dipotong"), jangan menyebutkan angka di luar data yang terlihat.
3. Kalau tidak ada tool yang relevan untuk pertanyaan user, jawab saja dengan saran/panduan — JANGAN membuat angka palsu dan JANGAN memanggil tool yang tidak tersedia di daftar di atas.
4. Kalau kamu tidak tahu jawabannya, akui "saya tidak yakin" daripada menebak.
5. Jawab dalam bahasa Indonesia yang ramah dan santai. Jawab singkat dan langsung ke poinnya.
6. Kalau user bertanya data yang TIDAK tersedia di tool (misal detail 1 transaksi, laba bersih per produk, perbandingan antar bulan), jelaskan bahwa data itu tidak tersedia dan tawarkan apa yang bisa dibantu.

Gunakan bahasa Indonesia yang ramah dan santai. Jawab singkat dan langsung.${context}`;
}

function fallbackReply(): string {
  return 'Maaf, AI Assistant belum dikonfigurasi (butuh API key).\n\nTapi saya bisa bantu dasar:\n- Untuk tambah produk: buka menu Produk → + Tambah\n- Untuk laporan: buka menu Laporan\n- Untuk stok menipis: cek menu Stok';
}

// ─── SSE relay dari provider ke client ──────────────────────────────

const SSE_HEADERS = {
  'Content-Type': 'text/event-stream',
  'Cache-Control': 'no-cache',
  Connection: 'keep-alive',
  'Access-Control-Allow-Origin': '*',
};

function streamResponse(providerRes: Response): Response {
  const reader = providerRes.body?.getReader();
  if (!reader) {
    return json({ reply: 'Maaf, tidak bisa menjawab saat ini.' });
  }
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();

  const stream = new ReadableStream({
    async start(controller) {
      let buffer = '';
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });
          const lines = buffer.split('\n');
          buffer = lines.pop() ?? '';
          for (const line of lines) {
            const trimmed = line.trim();
            if (!trimmed.startsWith('data:')) continue;
            const payload = trimmed.slice(5).trim();
            if (payload === '[DONE]') continue;
            try {
              const chunk = JSON.parse(payload);
              const delta = chunk.choices?.[0]?.delta;
              if (!delta) continue;
              // Konten final jadi teks jawaban; `reasoning_content` dikirim
              // sebagai field `reasoning` terpisah (tidak bocor ke bubble app).
              const text = delta.content ?? '';
              if (text) {
                controller.enqueue(encoder.encode(`data: ${JSON.stringify({ delta: text })}\n\n`));
              }
              const reasoning = delta.reasoning_content ?? '';
              if (reasoning) {
                controller.enqueue(encoder.encode(`data: ${JSON.stringify({ reasoning })}\n\n`));
              }
              // Tool call delta (jarang di stream, tapi didukung)
              if (delta.tool_calls) {
                controller.enqueue(
                  encoder.encode(`data: ${JSON.stringify({ tool_calls_delta: delta.tool_calls })}\n\n`),
                );
              }
            } catch (_) {
              // bukan JSON — lewati
            }
          }
        }
        controller.enqueue(encoder.encode(`data: ${JSON.stringify({ done: true })}\n\n`));
      } catch (e) {
        console.error('SSE relay error:', e);
      } finally {
        controller.close();
      }
    },
  });

  return new Response(stream, { headers: SSE_HEADERS });
}

// ─── Handler utama: chat ────────────────────────────────────────────

async function handleChat(ctx: FnContext, params: Params): Promise<Response> {
  const authErr = requireAuth(ctx);
  if (authErr) return authErr;
  const body = params;
  const messages = body.messages as { role: string; content: string | null }[] | undefined;
  const storeName = body.store_name as string | undefined;
  const tools = body.tools as unknown[] | undefined;
  const owner = body.owner as string | undefined;
  const sessionId = body.session_id as string | undefined;

  if (!messages || messages.length === 0) {
    return json({ error: 'messages array is required' }, 400);
  }

  const env = ctx.env;
  const cfg = await loadProviderConfig(env, owner ?? null);

  if (owner && sessionId) {
    await persistHistory(env, owner, sessionId, messages);
  }

  const systemPrompt = buildSystemPrompt(storeName, tools);

  if (!cfg.key) {
    return json({ reply: fallbackReply() });
  }

  const stream = body.stream === true;
  // Model reasoning (o-series / gpt-oss / deepseek-r1 / kimi-k2) memakai
  // budget max_tokens untuk "berpikir" dulu — naikkan cap khusus model
  // reasoning, dan jangan kirim temperature (tidak didukung sebagian model).
  const isReasoningModel = /(gpt-oss|o1\b|o3|o4|deepseek-r1|kimi-k2|reasoner)/i.test(cfg.model);
  const providerBody: Record<string, unknown> = {
    model: cfg.model,
    messages: [{ role: 'system', content: systemPrompt }, ...messages.slice(-20)],
    max_tokens: isReasoningModel ? 4096 : 800,
    ...(isReasoningModel ? {} : { temperature: 0.7 }),
    ...(tools && tools.length > 0 ? { tools } : {}),
    ...(stream ? { stream: true } : {}),
  };

  const providerRes = await fetch(`${cfg.base.replace(/\/+$/, '')}/chat/completions`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${cfg.key}`,
      ...(cfg.base.includes('openrouter')
        ? { 'HTTP-Referer': 'https://nusa-online.vercel.app', 'X-Title': 'NUSA Kasir' }
        : {}),
    },
    body: JSON.stringify(providerBody),
  });

  if (!providerRes.ok) {
    const err = await providerRes.text();
    console.error('AI provider error:', err);
    return json({ error: 'AI service error' }, 502);
  }

  if (stream) return streamResponse(providerRes);

  // Non-streaming: parse JSON biasa
  const data = (await providerRes.json()) as any;
  const choice = data.choices?.[0]?.message;
  const rawToolCalls = choice?.tool_calls ?? null;
  const reasoning = choice?.reasoning_content ?? null;
  const reply = choice?.content ?? 'Maaf, tidak bisa menjawab saat ini.';
  // `reasoning_content` TIDAK dilampirkan sebagai jawaban — field terpisah.
  return json({ reply, tool_calls: rawToolCalls, ...(reasoning ? { reasoning } : {}) });
}

// ─── GET settings — config AI untuk owner (dashboard + app) ────────

async function handleGetSettings(ctx: FnContext, params: Params): Promise<Response> {
  const authErr = requireAuth(ctx);
  if (authErr) return authErr;
  const owner = (params.owner as string) ?? '';
  let cfg: Row | null = null;
  if (owner) {
    try {
      const load = async (o: string) =>
        ctx.env.DB.prepare('SELECT base_url, model, is_custom, updated_at FROM ai_settings WHERE owner = ? LIMIT 1')
          .bind(o).first<Row>();
      cfg = (await load(owner)) ?? (await load('*'));
    } catch (_) {}
  }
  return json({
    base_url: cfg?.base_url ?? DEFAULT_AI_BASE,
    model: cfg?.model ?? DEFAULT_AI_MODEL,
    is_custom: cfg ? Number(cfg.is_custom ?? 0) === 1 : false,
    default_model: DEFAULT_AI_MODEL,
    owner: owner || null,
  });
}

// ─── POST save_settings — upsert ai_settings (dashboard + app) ─────

async function handleSaveSettings(ctx: FnContext, params: Params): Promise<Response> {
  const authErr = requireAuth(ctx);
  if (authErr) return authErr;
  const owner = String(params.owner ?? '').trim();
  const baseUrl = String(params.base_url ?? '').trim();
  const apiKey = String(params.api_key ?? '').trim();
  const model = String(params.model ?? '').trim();

  if (!owner) return json({ error: 'owner is required' }, 400);

  const isCustom = !!(apiKey && baseUrl);
  try {
    await ctx.env.DB.prepare(
      `INSERT INTO ai_settings (id, owner, base_url, api_key, model, is_custom, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(owner) DO UPDATE SET
         base_url = excluded.base_url, api_key = excluded.api_key,
         model = excluded.model, is_custom = excluded.is_custom, updated_at = excluded.updated_at`,
    )
      .bind(uid(), owner, baseUrl, apiKey, model, isCustom ? 1 : 0, nowIso(), nowIso())
      .run();
  } catch (err) {
    console.error('save_settings error:', err);
    return json({ error: 'Gagal menyimpan konfigurasi AI' }, 500);
  }
  return json({ ok: true, message: 'Konfigurasi AI disimpan' });
}

// ─── POST test — uji koneksi provider (config draft, belum disimpan) ──

async function handleTest(ctx: FnContext, params: Params): Promise<Response> {
  const authErr = requireAuth(ctx);
  if (authErr) return authErr;
  const baseUrl = String(params.base_url ?? '').trim() || DEFAULT_AI_BASE;
  const apiKey = String(params.api_key ?? '').trim() || ctx.env.OPENROUTER_API_KEY || '';
  const model = String(params.model ?? '').trim() || DEFAULT_AI_MODEL;

  if (!apiKey) {
    return json({
      ok: false,
      message: 'API key kosong — isi API key atau biarkan kosong untuk memakai key bawaan.',
    });
  }

  const started = Date.now();
  try {
    const isReasoningModel = /(gpt-oss|o1\b|o3|o4|deepseek-r1|kimi-k2|reasoner)/i.test(model);
    const providerRes = await fetch(`${baseUrl.replace(/\/+$/, '')}/chat/completions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${apiKey}`,
        ...(baseUrl.includes('openrouter')
          ? { 'HTTP-Referer': 'https://nusa-online.vercel.app', 'X-Title': 'NUSA Kasir' }
          : {}),
      },
      body: JSON.stringify({
        model,
        messages: [{ role: 'user', content: 'Balas singkat: OK' }],
        max_tokens: isReasoningModel ? 1024 : 10,
      }),
    });
    const latencyMs = Date.now() - started;
    if (!providerRes.ok) {
      const errText = (await providerRes.text()).slice(0, 200);
      return json({ ok: false, message: `Provider ${providerRes.status}: ${errText}`, latency_ms: latencyMs });
    }
    const data = (await providerRes.json()) as any;
    const reply = data.choices?.[0]?.message?.content ?? '';
    return json({
      ok: true,
      model,
      message: 'Koneksi berhasil',
      latency_ms: latencyMs,
      reply: typeof reply === 'string' ? reply.slice(0, 120) : String(reply),
    });
  } catch (err) {
    return json({
      ok: false,
      message: `Gagal terhubung: ${(err as Error).message}`,
      latency_ms: Date.now() - started,
    });
  }
}

// ─── POST history — daftar sesi chat cloud milik owner ──────────────

async function handleGetHistory(ctx: FnContext, params: Params): Promise<Response> {
  const authErr = requireAuth(ctx);
  if (authErr) return authErr;
  const owner = String(params.owner ?? '').trim();
  if (!owner) return json({ error: 'owner is required' }, 400);
  const limit = Math.min(Math.max(Number(params.limit) || 30, 1), 100);
  try {
    const { results } = await ctx.env.DB.prepare(
      `SELECT session_id, role, content, created_at FROM ai_chat_history
       WHERE owner = ? AND role = 'user' ORDER BY created_at DESC LIMIT ?`,
    ).bind(owner, limit).all<Row>();

    // dedup per session — ambil pesan user paling baru sebagai judul
    const seen = new Set<string>();
    const sessions: Record<string, unknown>[] = [];
    for (const row of results ?? []) {
      const sid = String(row.session_id ?? '');
      if (!sid || seen.has(sid)) continue;
      seen.add(sid);
      const content = String(row.content ?? '').replace(/\s+/g, ' ').trim();
      sessions.push({
        session_id: sid,
        title: content.length > 60 ? content.slice(0, 60) + '…' : content,
        created_at: row.created_at,
      });
    }
    return json({ sessions });
  } catch (err) {
    console.error('history error:', err);
    return json({ error: 'Internal server error' }, 500);
  }
}

// ─── POST history_messages — isi pesan 1 sesi cloud ─────────────────

async function handleGetHistoryMessages(ctx: FnContext, params: Params): Promise<Response> {
  const authErr = requireAuth(ctx);
  if (authErr) return authErr;
  const owner = String(params.owner ?? '').trim();
  const sessionId = String(params.session_id ?? '').trim();
  if (!owner || !sessionId) return json({ error: 'owner and session_id are required' }, 400);
  const limit = Math.min(Math.max(Number(params.limit) || 100, 1), 200);
  try {
    const { results } = await ctx.env.DB.prepare(
      `SELECT role, content, created_at FROM ai_chat_history
       WHERE owner = ? AND session_id = ? ORDER BY created_at ASC LIMIT ?`,
    ).bind(owner, sessionId, limit).all<Row>();
    return json({ messages: results ?? [] });
  } catch (err) {
    console.error('history_messages error:', err);
    return json({ error: 'Internal server error' }, 500);
  }
}

// ─── POST history_delete — hapus 1 sesi cloud ───────────────────────

async function handleDeleteHistory(ctx: FnContext, params: Params): Promise<Response> {
  const authErr = requireAuth(ctx);
  if (authErr) return authErr;
  const owner = String(params.owner ?? '').trim();
  const sessionId = String(params.session_id ?? '').trim();
  if (!owner || !sessionId) return json({ error: 'owner and session_id are required' }, 400);
  try {
    await ctx.env.DB.prepare('DELETE FROM ai_chat_history WHERE owner = ? AND session_id = ?')
      .bind(owner, sessionId).run();
    return json({ ok: true });
  } catch (err) {
    console.error('history_delete error:', err);
    return json({ error: 'Internal server error' }, 500);
  }
}

// ─── Registrasi route ───────────────────────────────────────────────
// Auth: x-admin-key ATAU JWT (router hitung keduanya; app anon JWT cukup).

Router.registerAll('ai-assistant', {
  chat: handleChat,
  settings: handleGetSettings,
  save_settings: handleSaveSettings,
  test: handleTest,
  history: handleGetHistory,
  history_messages: handleGetHistoryMessages,
  history_delete: handleDeleteHistory,
});
