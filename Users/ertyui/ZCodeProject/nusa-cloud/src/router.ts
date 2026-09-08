/**
 * Router — /api/{fn}/{action} dispatch, CORS, dan util JSON.
 * Payload 1:1 dengan edge fn Supabase: action dipindah dari body ke path,
 * sisanya body JSON sama persis.
 */
import type { Env } from './index';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, content-type, x-admin-key, x-app-version, x-build-number',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
};

export function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS },
  });
}

export function errorJson(message: string, status = 400): Response {
  return json({ error: message }, status);
}

export async function readBody(req: Request): Promise<Record<string, unknown>> {
  try {
    const raw = await req.text();
    if (!raw) return {};
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

type FnHandler = (ctx: FnContext, params: Record<string, unknown>) => Promise<Response>;

export interface FnContext {
  env: Env;
  req: Request;
  /** JWT payload bila Authorization: Bearer valid (akun email/password). */
  jwt: Record<string, unknown> | null;
  /** x-admin-key header == NUSA_ADMIN_KEY (dashboard). */
  isAdmin: boolean;
}

export class Router {
  private static fns = new Map<string, FnHandler>();

  static register(fn: string, action: string, handler: FnHandler) {
    this.fns.set(`${fn}/${action}`, handler);
  }

  /** Registrasi banyak action sekaligus: reg('license-manager', { generate: h, list: h2 }) */
  static registerAll(fn: string, actions: Record<string, FnHandler>) {
    for (const [action, handler] of Object.entries(actions)) {
      this.register(fn, action, handler);
    }
  }

  static async handle(req: Request, env: Env, _ctx: ExecutionContext): Promise<Response> {
    const url = new URL(req.url);
    const path = url.pathname;

    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });

    // ── WebSocket realtime ────────────────────────────────────────────
    if (path === '/ws' && req.headers.get('Upgrade') === 'websocket') {
      const channel = url.searchParams.get('channel') ?? '';
      if (!channel) return errorJson('channel required', 400);
      const id = env.ROOM.idFromName(channel);
      const stub = env.ROOM.get(id);
      return stub.fetch(req);
    }

    // ── Public image proxy (pengganti getPublicUrl) ───────────────────
    // /img/{path} → coba nusa-images dulu, lalu tutorial-thumbnails
    // (thumbnail tutorial dipindah ke R2 saat migrasi).
    if (path.startsWith('/img/') && req.method === 'GET') {
      const key = decodeURIComponent(path.slice('/img/'.length));
      let obj = await env.BUCKET_IMAGES.get(key);
      if (!obj) obj = await env.BUCKET_THUMBS.get(key);
      if (!obj) return errorJson('not found', 404);
      const headers = new Headers(CORS);
      headers.set('Content-Type', obj.httpMetadata?.contentType ?? 'application/octet-stream');
      headers.set('Cache-Control', 'public, max-age=3600');
      return new Response(obj.body, { headers });
    }

    // ── Health check ──────────────────────────────────────────────────
    if (path === '/health') return json({ ok: true, service: 'nusa-cloud' });

    // ── Auth context (dipakai /storage dan /api) ─────────────────────
    let jwtPayload: Record<string, unknown> | null = null;
    const authHeader = req.headers.get('Authorization') ?? '';
    if (authHeader.startsWith('Bearer ')) {
      const { verifyJwt } = await import('./auth');
      const claims = await verifyJwt(env, authHeader.slice(7));
      jwtPayload = claims ? { ...claims } : null;
    }
    const isAdmin = (req.headers.get('x-admin-key') ?? '') === env.NUSA_ADMIN_KEY;

    // ── Storage R2 (app CloudGateway + dashboard) ────────────────────
    //   GET  /storage/{bucket}?prefix=P      → list JSON [{name,size,updated}]
    //   GET  /storage/{bucket}/{path...}     → bytes (nusa-backups butuh auth)
    //   POST /storage/{bucket}/{path...}     → put bytes (auth wajib)
    //   POST /storage/{bucket}/remove        → {paths: [...]} delete (auth)
    if (path === '/storage' || path.startsWith('/storage/')) {
      const seg = path.slice('/storage/'.length); // '{bucket}' atau '{bucket}/{path...}'
      const slash = seg.indexOf('/');
      const bucketName = slash === -1 ? seg : seg.slice(0, slash);
      const objPath = slash === -1 ? '' : decodeURIComponent(seg.slice(slash + 1));
      const bucket =
        bucketName === 'nusa-backups' ? env.BUCKET_BACKUPS :
        bucketName === 'nusa-images' ? env.BUCKET_IMAGES :
        bucketName === 'tutorial-thumbnails' ? env.BUCKET_THUMBS :
        null;
      if (!bucket) return errorJson(`unknown bucket: ${bucketName}`, 404);

      const authed = isAdmin || jwtPayload != null;

      // LIST — auth required (v2.2.57+130-fix: tutup enumeration,
      // siapa saja bisa list semua backup path + size tanpa auth)
      if (objPath === '' && req.method === 'GET') {
        if (!authed) return errorJson('Unauthorized', 401);
        const prefix = url.searchParams.get('prefix') ?? '';
        const limit = Number(url.searchParams.get('limit') ?? 500);
        const listed = await bucket.list({ prefix, limit });
        return json((listed.objects ?? []).map((o) => ({
          name: o.key,
          size: o.size,
          updated: o.uploaded?.toISOString?.() ?? null,
        })));
      }

      // REMOVE
      if (objPath === 'remove' && req.method === 'POST') {
        if (!authed) return errorJson('Unauthorized', 401);
        const body = (await readBody(req)) as { paths?: string[] };
        for (const p of body.paths ?? []) {
          await bucket.delete(p);
        }
        return json({ ok: true, removed: (body.paths ?? []).length });
      }

      // DOWNLOAD (publik kecuali nusa-backups — backup memuat data kas)
      if (req.method === 'GET' && objPath !== '') {
        if (bucketName === 'nusa-backups' && !authed) return errorJson('Unauthorized', 401);
        const obj = await bucket.get(objPath);
        if (!obj) return errorJson('not found', 404);
        const headers = new Headers(CORS);
        headers.set('Content-Type', obj.httpMetadata?.contentType ?? 'application/octet-stream');
        return new Response(obj.body, { headers });
      }

      // UPLOAD
      if (req.method === 'POST' && objPath !== '') {
        if (!authed) return errorJson('Unauthorized', 401);
        const bytes = await req.arrayBuffer();
        const upsert = req.headers.get('X-Upsert') === '1';
        if (!upsert) {
          const existing = await bucket.head(objPath);
          if (existing) return errorJson('already exists', 409);
        }
        await bucket.put(objPath, bytes, {
          httpMetadata: { contentType: req.headers.get('Content-Type') ?? 'application/octet-stream' },
        });
        return json({ ok: true, path: objPath });
      }

      return errorJson('bad storage request', 400);
    }

    // ── /api/{fn}/{action} ────────────────────────────────────────────
    if (path.startsWith('/api/') && req.method === 'POST') {
      const seg = path.slice('/api/'.length).split('/').filter(Boolean);
      const fn = (seg[0] ?? '').replace(/_/g, '-');
      let action = seg.slice(1).join('/');

      const params = await readBody(req);

      // ── Fallback untuk app lama yang kirim action via body (CloudGateway.invoke
      //   baca body.action, bukan path). Kalau path action kosong/tidak ketemu,
      //   coba ambil dari body.action atau tebak dari presence of 'key' di body
      //   (key ada → activate, tidak → check).
      if (!action || !this.fns.has(`${fn}/${action}`)) {
        const bodyAction = (params as any).action as string | undefined;
        if (bodyAction && this.fns.has(`${fn}/${bodyAction}`)) {
          action = bodyAction;
        } else if (params && (params as any).key && this.fns.has(`${fn}/activate`)) {
          action = 'activate';
        } else if (this.fns.has(`${fn}/check`)) {
          action = 'check';
        }
      }

      // auth/* → modul auth (di-import dinamis agar router tetap tipis)
      if (fn === 'auth') {
        const mod = await import('./auth_routes');
        const handler = (mod as Record<string, unknown>)[`handle_${action.replace(/-/g, '_')}`];
        if (typeof handler !== 'function') return errorJson(`unknown auth action: ${action}`, 404);
        return (handler as FnHandler)({ env, req, jwt: null, isAdmin: false }, {});
      }

      if (!action) return errorJson('bad path, use /api/{fn}/{action}', 404);

      const handler = this.fns.get(`${fn}/${action}`);
      if (!handler) return errorJson(`unknown: ${fn}/${action}`, 404);

      // action juga diisi di params supaya port edge fn yang membaca
      // params.action tetap jalan tanpa perubahan.
      params.action = action;

      const ctx: FnContext = { env, req, jwt: jwtPayload, isAdmin };
      return handler(ctx, params);
    }

    // GET /api/{fn} tunggal (mis. GET /api/ai-assistant/settings?owner=)
    if (path.startsWith('/api/') && req.method === 'GET') {
      const seg = path.slice('/api/'.length).split('/').filter(Boolean);
      if (seg.length < 1) return errorJson('bad path', 404);
      const fn = seg[0];
      const action = seg.slice(1).join('/') || '';
      const handler = action ? this.fns.get(`${fn}/${action}`) : undefined;
      if (!handler) return errorJson(`unknown: ${fn}/${action}`, 404);
      const params: Record<string, unknown> = {};
      url.searchParams.forEach((v, k) => { params[k] = v; });
      params.action = action;
      const ctx: FnContext = { env, req, jwt: jwtPayload, isAdmin };
      return handler(ctx, params);
    }

    return errorJson('not found', 404);
  }
}
