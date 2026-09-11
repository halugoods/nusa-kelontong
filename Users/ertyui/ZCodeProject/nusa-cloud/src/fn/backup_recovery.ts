// ============================================================================
// NUSA — Self-Service Backup Recovery
// ============================================================================
// Endpoint admin untuk restore data user secara mandiri tanpa bantuan dev.
//
// Flow:
//   1. Admin upload file .nus1 + email user + varian di dashboard
//   2. Worker parse .nus1 → extract nusa_kasir.sqlite
//   3. Cari google_user_id dari tabel licenses
//   4. Encrypt pake SHA-256(google_user_id) → upload ke R2
//   5. Generate key baru (optional)
//   6. User login → restore dari cloud → data kembali
//
// Endpoint:
//   POST /api/backup-recovery/parse-nus1    → parse & validate .nus1
//   POST /api/backup-recovery/restore       → full restore flow
// ============================================================================

import { json, errorJson, Router, type FnContext } from '../router';

type Params = Record<string, unknown>;
type Row = Record<string, any>;

// ─── NUS1 Parser (pure TS, mirror dari backup_crypto.dart) ──────────────

function parseNus1(data: Uint8Array): Map<string, Uint8Array> {
  const result = new Map<string, Uint8Array>();
  if (data.length < 8) throw new Error('File terlalu kecil');
  if (data[0] !== 0x4E || data[1] !== 0x55 || data[2] !== 0x53 || data[3] !== 0x31) {
    throw new Error('Bukan file NUS1 (magic bytes tidak cocok)');
  }
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  let offset = 4;
  const count = view.getUint32(offset, true);
  offset += 4;
  if (count === 0 || count > 10000) throw new Error(`Invalid file count: ${count}`);

  for (let i = 0; i < count; i++) {
    if (offset + 2 > data.length) throw new Error('Truncated entry');
    const nameLen = view.getUint16(offset, true);
    offset += 2;
    if (nameLen === 0 || nameLen > 4096 || offset + nameLen > data.length) throw new Error('Invalid name length');
    const nameBytes = data.slice(offset, offset + nameLen);
    offset += nameLen;
    const name = new TextDecoder().decode(nameBytes);
    if (offset + 4 > data.length) throw new Error('Truncated data length');
    const dataLen = view.getUint32(offset, true);
    offset += 4;
    if (dataLen > data.length - offset) throw new Error('Invalid data length');
    const bytes = data.slice(offset, offset + dataLen);
    offset += dataLen;
    result.set(name, bytes);
  }
  return result;
}

// ─── SHA-256 derive key + AES-256-GCM encrypt ───────────────────────────

async function deriveKey(googleUserId: string): Promise<CryptoKey> {
  const encoder = new TextEncoder();
  const hash = await crypto.subtle.digest('SHA-256', encoder.encode(googleUserId));
  return crypto.subtle.importKey('raw', hash, { name: 'AES-GCM' }, false, ['encrypt']);
}

async function encryptBackup(plaintext: Uint8Array, googleUserId: string): Promise<Uint8Array> {
  const key = await deriveKey(googleUserId);
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, key, plaintext));
  const out = new Uint8Array(nonce.length + encrypted.length);
  out.set(nonce, 0);
  out.set(encrypted, nonce.length);
  return out;
}

// ─── Gzip (using CompressionStream) ────────────────────────────────────

async function gzip(data: Uint8Array): Promise<Uint8Array> {
  const stream = new Blob([data]).stream().pipeThrough(new CompressionStream('gzip'));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

// ─── Parse & validate .nus1 ────────────────────────────────────────────

async function handleParseNus1(ctx: FnContext, params: Params): Promise<Response> {
  if (!ctx.isAdmin) return errorJson('Unauthorized — admin key required', 401);
  const email = String(params.email ?? '').trim().toLowerCase();
  const product = String(params.product ?? 'nusa-kasir').trim();
  const nus1Base64 = String(params.nus1_base64 ?? '').trim();

  if (!email && !params.googleUserId) return errorJson('email or googleUserId required', 400);
  if (!nus1Base64) return errorJson('nus1_base64 required', 400);

  // Decode base64
  let nus1Bytes: Uint8Array;
  try {
    const binary = atob(nus1Base64);
    nus1Bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) nus1Bytes[i] = binary.charCodeAt(i);
  } catch {
    return errorJson('Invalid base64', 400);
  }

  // Parse NUS1
  let parsed: Map<string, Uint8Array>;
  try {
    parsed = parseNus1(nus1Bytes);
  } catch (e: any) {
    return errorJson(`Parse gagal: ${e?.message ?? e}`, 400);
  }

  const entries = Array.from(parsed.keys());
  const hasDb = parsed.has('nusa_kasir.sqlite');
  const dbSize = hasDb ? parsed.get('nusa_kasir.sqlite')!.length : 0;

  // Find user
  let lic: Row | null = null;
  if (email) {
    lic = await ctx.env.DB.prepare('SELECT * FROM licenses WHERE LOWER(owner_email) = ? ORDER BY created_at DESC LIMIT 1').bind(email).first<Row>();
  }
  if (!lic && params.googleUserId) {
    lic = await ctx.env.DB.prepare('SELECT * FROM licenses WHERE google_user_id = ? ORDER BY created_at DESC LIMIT 1').bind(String(params.googleUserId)).first<Row>();
  }

  return json({
    ok: true,
    parsed: true,
    entries,
    has_db: hasDb,
    db_size_bytes: dbSize,
    user_found: lic != null,
    google_user_id: lic?.google_user_id ?? null,
    license_key: lic?.key ?? null,
    license_status: lic?.status ?? null,
    product,
  });
}

// ─── Full restore flow ─────────────────────────────────────────────────

async function handleRestore(ctx: FnContext, params: Params): Promise<Response> {
  if (!ctx.isAdmin) return errorJson('Unauthorized — admin key required', 401);
  const email = String(params.email ?? '').trim().toLowerCase();
  const product = String(params.product ?? 'nusa-kasir').trim();
  const nus1Base64 = String(params.nus1_base64 ?? '').trim();
  const generateKey = params.generate_key === true;
  const mode = String(params.mode ?? 'pro');

  if (!email && !params.googleUserId) return errorJson('email or googleUserId required', 400);
  if (!nus1Base64) return errorJson('nus1_base64 required', 400);

  // Decode base64
  let nus1Bytes: Uint8Array;
  try {
    const binary = atob(nus1Base64);
    nus1Bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) nus1Bytes[i] = binary.charCodeAt(i);
  } catch {
    return errorJson('Invalid base64', 400);
  }

  // Parse NUS1
  let parsed: Map<string, Uint8Array>;
  try {
    parsed = parseNus1(nus1Bytes);
  } catch (e: any) {
    return errorJson(`Parse gagal: ${e?.message ?? e}`, 400);
  }

  if (!parsed.has('nusa_kasir.sqlite')) {
    return errorJson('File .nus1 tidak mengandung nusa_kasir.sqlite', 400);
  }

  const sqliteBytes = parsed.get('nusa_kasir.sqlite')!;

  // Find user
  let lic: Row | null = null;
  if (email) {
    lic = await ctx.env.DB.prepare('SELECT * FROM licenses WHERE LOWER(owner_email) = ? ORDER BY created_at DESC LIMIT 1').bind(email).first<Row>();
  }
  if (!lic && params.googleUserId) {
    lic = await ctx.env.DB.prepare('SELECT * FROM licenses WHERE google_user_id = ? ORDER BY created_at DESC LIMIT 1').bind(String(params.googleUserId)).first<Row>();
  }

  if (!lic) {
    return errorJson('User tidak ditemukan di tabel licenses', 404);
  }

  const googleUserId = lic.google_user_id;
  if (!googleUserId) {
    return errorJson('User tidak punya google_user_id — tidak bisa encrypt backup', 400);
  }

  // Encrypt & upload
  const encrypted = await encryptBackup(sqliteBytes, googleUserId);
  const backupPath = `${googleUserId}/${product}/backup.sqlite.enc`;

  await ctx.env.BUCKET_BACKUPS.put(backupPath, encrypted, {
    httpMetadata: { contentType: 'application/octet-stream' },
  });

  // Generate key if requested
  let newKey: string | null = null;
  if (generateKey) {
    const { generateKey: genKey } = await import('./license_manager');
    const k = await genKey(ctx.env);
    await ctx.env.DB.prepare(
      'INSERT INTO licenses (id, key, serial, product, tier, status, owner_email, mode) VALUES (?, ?, ?, ?, ?, ?, ?, ?)'
    ).bind(crypto.randomUUID(), k.key, k.serial, product, 'lifetime', 'Generated', email, mode).run();
    newKey = k.key;
  }

  return json({
    ok: true,
    restored: true,
    google_user_id: googleUserId,
    product,
    backup_path: backupPath,
    backup_size_bytes: encrypted.length,
    sqlite_size_bytes: sqliteBytes.length,
    new_key: newKey,
    message: `Backup berhasil di-restore. User ${email} bisa login dan restore data.`,
  });
}

// ─── Register routes ───────────────────────────────────────────────────

Router.registerAll('backup-recovery', {
  'parse-nus1': handleParseNus1,
  'restore': handleRestore,
});
