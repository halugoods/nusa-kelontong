// ============================================================================
// NUSA — Tutorial Manager (port dari supabase/functions/tutorial-manager)
// ============================================================================
// Admin CRUD untuk tabel `tutorials` (video panduan app, per varian).
// App mengirim {'action': 'list'|'create'|'update'|'delete', ...} — router
// juga mengisi params.action dari path, jadi kedua jalur jalan.
// Dilindungi header `x-admin-key` (kecocokan dgn secret NUSA_ADMIN_KEY),
// kecuali `list` dari app (JWT anon cukup — sama dengan edge fn lama yang
// hanya butuh apikey anon).
//
// POST /api/tutorial-manager/{action}
// ============================================================================

import { json, Router, type FnContext } from '../router';
import { uid, nowIso, parseJson } from './db';

type Params = Record<string, unknown>;
type Row = Record<string, any>;
type H = (ctx: FnContext, params: Params) => Promise<Response>;

// v2.2.57+130-fix: create/update/delete butuh admin auth (x-admin-key).
// list tetap public (JWT anon cukup — tutorial konten publik).
function requireAdmin(ctx: FnContext): Response | null {
  if (ctx.isAdmin) return null;
  return json({ error: 'Unauthorized — x-admin-key required' }, 401);
}

/** Baris D1 → bentuk JSON yang dulu dikirim Supabase (variants text[] → array). */
function rowToTutorial(r: Row): Row {
  return { ...r, variants: parseJson<string[]>(r.variants, []) };
}

async function listTutorials(ctx: FnContext, params: Params): Promise<Response> {
  const variant = typeof params.variant === 'string' ? params.variant : null;
  let sql = 'SELECT * FROM tutorials';
  const binds: string[] = [];
  if (variant) {
    sql += ' WHERE variants LIKE ?';
    binds.push(`%"${variant}"%`);
  }
  sql += ' ORDER BY sort_order ASC, created_at DESC';
  const { results } = await ctx.env.DB.prepare(sql).bind(...binds).all<Row>();
  return json({ tutorials: (results ?? []).map(rowToTutorial) });
}

async function createTutorial(ctx: FnContext, params: Params): Promise<Response> {
  const authErr = requireAdmin(ctx);
  if (authErr) return authErr;
  const title = params.title as string | undefined;
  const ytUrl = params.yt_url as string | undefined;
  if (!title || !ytUrl) return json({ error: 'title & yt_url required' }, 400);
  const id = uid();
  const variants = Array.isArray(params.variants) ? JSON.stringify(params.variants) : '[]';
  await ctx.env.DB.prepare(
    `INSERT INTO tutorials (id, title, yt_url, thumbnail_url, description, variants, sort_order, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      id,
      title,
      ytUrl,
      (params.thumbnail_url as string | undefined) ?? null,
      (params.description as string | undefined) ?? null,
      variants,
      Number(params.sort_order ?? 0) || 0,
      nowIso(),
      nowIso(),
    )
    .run();
  const row = await ctx.env.DB.prepare('SELECT * FROM tutorials WHERE id = ?').bind(id).first<Row>();
  return json({ tutorial: row ? rowToTutorial(row) : null });
}

async function updateTutorial(ctx: FnContext, params: Params): Promise<Response> {
  const authErr = requireAdmin(ctx);
  if (authErr) return authErr;
  const id = params.id as string | undefined;
  if (!id) return json({ error: 'id required' }, 400);
  const patch: string[] = ['updated_at = ?'];
  const binds: unknown[] = [nowIso()];
  if (params.title !== undefined) { patch.push('title = ?'); binds.push(params.title as string); }
  if (params.yt_url !== undefined) { patch.push('yt_url = ?'); binds.push(params.yt_url as string); }
  if (params.thumbnail_url !== undefined) { patch.push('thumbnail_url = ?'); binds.push(params.thumbnail_url ?? null); }
  if (params.description !== undefined) { patch.push('description = ?'); binds.push(params.description ?? null); }
  if (params.variants !== undefined) {
    patch.push('variants = ?');
    binds.push(Array.isArray(params.variants) ? JSON.stringify(params.variants) : '[]');
  }
  if (params.sort_order !== undefined) { patch.push('sort_order = ?'); binds.push(Number(params.sort_order) || 0); }
  binds.push(id);
  const res = await ctx.env.DB.prepare(
    `UPDATE tutorials SET ${patch.join(', ')} WHERE id = ?`,
  ).bind(...binds).run();
  if (!res.success || res.meta.changes === 0) return json({ error: 'Tutorial not found' }, 404);
  const row = await ctx.env.DB.prepare('SELECT * FROM tutorials WHERE id = ?').bind(id).first<Row>();
  return json({ tutorial: row ? rowToTutorial(row) : null });
}

async function deleteTutorial(ctx: FnContext, params: Params): Promise<Response> {
  const authErr = requireAdmin(ctx);
  if (authErr) return authErr;
  const id = params.id as string | undefined;
  if (!id) return json({ error: 'id required' }, 400);
  await ctx.env.DB.prepare('DELETE FROM tutorials WHERE id = ?').bind(id).run();
  return json({ ok: true });
}

// ─── Registrasi route ────────────────────────────────────────────────

Router.registerAll('tutorial-manager', {
  list: listTutorials,
  create: createTutorial,
  update: updateTutorial,
  delete: deleteTutorial,
} satisfies Record<string, H>);
