// ============================================================================
// NUSA — Delta Sync (server-side)
// ============================================================================
// Endpoint sinkronisasi data antar-device via D1 + Durable Object broadcast.
//   action: 'push'            — kirim delta dari device ke server
//   action: 'pull'            — ambil delta yang belum di-pull device
//   action: 'ack'             — tandai delta sudah di-apply device
//   action: 'status'          — status sync uid (last_sync, pending, devices)
//   action: 'register-device' — daftarkan/heartbeat device
//
// Pola auth: semua endpoint butuh JWT atau x-admin-key (requireAdmin).
// ============================================================================

import { json, errorJson, Router, type FnContext } from '../router';
import { uid, nowIso, requireAdmin } from './db';
import { publishSyncEvent } from '../room';
import type { Env } from '../index';

type Params = Record<string, unknown>;
type Row = Record<string, any>;
type H = (ctx: FnContext, params: Params) => Promise<Response>;

// ─── Auth wrapper (sama pola adminWrap di license_manager) ────────────

function authWrap(h: H): H {
  return async (ctx: FnContext, params: Params): Promise<Response> => {
    if (!requireAdmin(ctx)) return errorJson('Unauthorized', 401);
    try {
      return await h(ctx, params);
    } catch (e: any) {
      return errorJson(e?.message ?? String(e), 500);
    }
  };
}

// ─── Helper: extract UID from JWT / admin context ─────────────────────

function getUid(ctx: FnContext, params: Params): string | null {
  // Admin bisa kirim uid via params; non-admin pakai JWT sub
  if (ctx.isAdmin && params.uid) return String(params.uid);
  const jwt = ctx.jwt;
  if (jwt && jwt.sub) return String(jwt.sub);
  if (jwt && jwt.uid) return String(jwt.uid);
  return null;
}

// ─── POST /api/sync-delta/push ────────────────────────────────────────

export async function handlePush(ctx: FnContext, params: Params): Promise<Response> {
  const env = ctx.env;
  const uid = getUid(ctx, params);
  if (!uid) return errorJson('Unauthorized — no uid', 401);

  const deltas = (params.deltas as any[]) ?? [];
  if (!Array.isArray(deltas) || deltas.length === 0) {
    return errorJson('deltas array required', 400);
  }

  const storeId = (params.store_id as string) ?? '';
  const myDeviceId = (params.device_id as string) ?? 'unknown';
  const now = nowIso();

  // Group deltas by table for broadcast
  const byTable: Record<string, string[]> = {};

  for (const d of deltas) {
    const deltaId = d.id || uid();
    const tableName = d.table || d.table_name;
    const recordId = d.record_id;
    const operation = d.operation || d.op || 'upsert';
    const data = typeof d.data === 'string' ? d.data : JSON.stringify(d.data ?? {});
    const createdAt = d.created_at || now;
    const deviceId = d.device_id || myDeviceId;

    if (!tableName || !recordId) continue;

    // INSERT OR IGNORE untuk skip duplicates by PK
    try {
      await env.DB.prepare(
        `INSERT OR IGNORE INTO sync_queue
         (id, uid, store_id, table_name, record_id, operation, data, created_at, device_id, applied)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)`
      )
        .bind(deltaId, uid, storeId, tableName, recordId, operation, data, createdAt, deviceId)
        .run();
    } catch (e: any) {
      // Skip failed individual inserts (log only)
      console.error('sync push insert error:', e?.message);
    }

    // Group for broadcast
    if (!byTable[tableName]) byTable[tableName] = [];
    byTable[tableName].push(recordId);
  }

  // Broadcast via RoomDO per table
  for (const [table, ids] of Object.entries(byTable)) {
    await publishSyncEvent(env, uid, table, ids);
  }

  return json({ ok: true, accepted: deltas.length, rejected: 0 });
}

// ─── POST /api/sync-delta/pull ────────────────────────────────────────

export async function handlePull(ctx: FnContext, params: Params): Promise<Response> {
  const env = ctx.env;
  const uid = getUid(ctx, params);
  if (!uid) return errorJson('Unauthorized — no uid', 401);

  const myDeviceId = (params.device_id as string) ?? 'unknown';
  const since = (params.since as string) ?? null;
  const ids = (params.ids as string[]) ?? null;
  const limit = Math.min(Math.max(Number(params.limit) || 100, 1), 500);
  const offset = Math.max(Number(params.offset) || 0, 0);

  // Build dynamic WHERE
  const where: string[] = ['uid = ?', 'device_id != ?'];
  const binds: unknown[] = [uid, myDeviceId];

  if (since) {
    where.push('created_at > ?');
    binds.push(since);
  }

  if (ids && ids.length > 0) {
    const ph = ids.map(() => '?').join(',');
    where.push(`id IN (${ph})`);
    binds.push(...ids);
  }

  const whereSql = `WHERE ${where.join(' AND ')}`;

  const rowsRes = await env.DB.prepare(
    `SELECT * FROM sync_queue ${whereSql} ORDER BY created_at ASC LIMIT ? OFFSET ?`
  )
    .bind(...binds, limit, offset)
    .all<Row>();

  const deltas = rowsRes.results ?? [];
  const hasMore = deltas.length === limit;

  // Update last_pull for this device
  try {
    await env.DB.prepare(
      `UPDATE sync_devices SET last_pull = ? WHERE device_id = ? AND uid = ?`
    ).bind(nowIso(), myDeviceId, uid).run();
  } catch {
    // non-fatal
  }

  return json({
    deltas,
    has_more: hasMore,
    next_offset: hasMore ? offset + limit : offset,
    server_time: nowIso(),
  });
}

// ─── POST /api/sync-delta/ack ─────────────────────────────────────────

export async function handleAck(ctx: FnContext, params: Params): Promise<Response> {
  const env = ctx.env;
  const uid = getUid(ctx, params);
  if (!uid) return errorJson('Unauthorized — no uid', 401);

  const deltaIds = (params.delta_ids as string[]) ?? [];
  if (!Array.isArray(deltaIds) || deltaIds.length === 0) {
    return errorJson('delta_ids array required', 400);
  }

  const ph = deltaIds.map(() => '?').join(',');
  const now = nowIso();

  const result = await env.DB.prepare(
    `UPDATE sync_queue SET applied = 1, applied_at = ? WHERE id IN (${ph}) AND uid = ?`
  )
    .bind(now, ...deltaIds, uid)
    .run();

  return json({ ok: true, acked: deltaIds.length });
}

// ─── GET /api/sync-delta/status ───────────────────────────────────────

export async function handleStatus(ctx: FnContext, params: Params): Promise<Response> {
  const env = ctx.env;
  const uid = getUid(ctx, params);
  if (!uid) return errorJson('Unauthorized — no uid', 401);

  // Get sync_state
  const stateRow = await env.DB.prepare(
    'SELECT * FROM sync_state WHERE uid = ?'
  ).bind(uid).first<Row>();

  // Get devices
  const devicesRes = await env.DB.prepare(
    'SELECT * FROM sync_devices WHERE uid = ? ORDER BY last_seen DESC'
  ).bind(uid).all<Row>();

  // Count pending deltas
  const pendingRow = await env.DB.prepare(
    'SELECT COUNT(*) AS c FROM sync_queue WHERE uid = ? AND applied = 0'
  ).bind(uid).first<Row>();

  return json({
    uid,
    last_sync_at: stateRow?.last_sync_at ?? null,
    pending_deltas: pendingRow?.c ?? 0,
    devices: devicesRes.results ?? [],
  });
}

// ─── POST /api/sync-delta/register-device ─────────────────────────────

export async function handleRegisterDevice(ctx: FnContext, params: Params): Promise<Response> {
  const env = ctx.env;
  const uid = getUid(ctx, params);
  if (!uid) return errorJson('Unauthorized — no uid', 401);

  const deviceId = (params.device_id as string) ?? '';
  if (!deviceId) return errorJson('device_id required', 400);

  const deviceName = (params.device_name as string) ?? null;
  const userAgent = (params.user_agent as string) ?? ctx.req.headers.get('User-Agent') ?? null;
  const ipAddress = ctx.req.headers.get('CF-Connecting-IP') ?? null;
  const now = nowIso();

  await env.DB.prepare(
    `INSERT INTO sync_devices (device_id, uid, device_name, last_seen, ip_address, user_agent)
     VALUES (?, ?, ?, ?, ?, ?)
     ON CONFLICT(device_id) DO UPDATE SET
       uid = excluded.uid,
       device_name = excluded.device_name,
       last_seen = excluded.last_seen,
       ip_address = excluded.ip_address,
       user_agent = excluded.user_agent`
  )
    .bind(deviceId, uid, deviceName, now, ipAddress, userAgent)
    .run();

  return json({ ok: true });
}

// ─── Registrasi route ────────────────────────────────────────────────

Router.registerAll('sync-delta', {
  push: authWrap(handlePush),
  pull: authWrap(handlePull),
  ack: authWrap(handleAck),
  status: authWrap(handleStatus),
  'register-device': authWrap(handleRegisterDevice),
});
