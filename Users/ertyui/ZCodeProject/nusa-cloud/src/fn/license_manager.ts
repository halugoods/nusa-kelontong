// ============================================================================
// NUSA — License Manager (port dari supabase/functions/license-manager)
// v2 — Multi-App + Tier
// ============================================================================
// Operasi admin untuk manajemen activation key. Action dipindah dari body ke
// path: POST /api/license-manager/{action}, body JSON sisanya identik.
//   action: 'generate'        — generate key aktivasi ter-signing baru
//   action: 'add'             — tambah key pre-generated (dari keygen.dart CLI)
//   action: 'list'            — daftar semua lisensi + jumlah aktivasi
//   action: 'detail'          — satu lisensi + aktivasinya
//   action: 'revoke'          — revoke lisensi (status → Cancelled)
//   action: 'set_status'      — set status manual (admin override, ter-audit)
//   action: 'delete'          — hapus lisensi unused
//   action: 'stats'           — ringkasan statistik
//   action: 'get_min_versions' — versi minimum app per produk (force update)
//   action: 'set_min_version'  — set/hapus versi minimum produk
//
// Catatan port:
//   - Admin auth di edge fn lama: header x-admin-key == "280303" (hardcoded).
//     Di sini router sudah membandingkan x-admin-key dgn secret NUSA_ADMIN_KEY
//     → set secret tersebut ke "280303" agar dashboard lama tetap jalan.
//   - Sign Ed25519 via WebCrypto native (seed 32B dibungkus PKCS8); signature
//     deterministik RFC 8032 → byte-per-byte sama dengan ed.sign() noble.
//   - Kirim email via Resend (fetch ke api.resend.com), sama seperti sumber.
// ============================================================================

import { json, errorJson, Router, type FnContext } from '../router';
import { uid, nowIso } from './db';
import type { Env } from '../index';

type Params = Record<string, unknown>;
type Row = Record<string, any>;
type H = (ctx: FnContext, params: Params) => Promise<Response>;

// ─── Keygen (identik dengan tools/keygen/bin/keygen.dart) ─────────────

const PREFIX = 'NUSA-';
const SERIAL_LEN = 8;
const SERIAL_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const B32_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

function generateSerial(): string {
  const bytes = new Uint8Array(SERIAL_LEN);
  crypto.getRandomValues(bytes);
  let buf = '';
  for (let i = 0; i < SERIAL_LEN; i++) {
    buf += SERIAL_ALPHABET[bytes[i] % SERIAL_ALPHABET.length];
  }
  return buf;
}

function base32Encode(data: Uint8Array): string {
  let bits = 0, value = 0;
  const out: string[] = [];
  for (const b of data) {
    value = (value << 8) | b;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out.push(B32_ALPHABET[(value >> bits) & 31]);
    }
  }
  if (bits > 0) {
    out.push(B32_ALPHABET[(value << (5 - bits)) & 31]);
  }
  return out.join('');
}

function formatKey(serial: string, signature: Uint8Array): string {
  const sigB32 = base32Encode(signature);
  const groups: string[] = [];
  for (let i = 0; i < serial.length; i += 4) {
    groups.push(serial.substring(i, i + 4));
  }
  for (let i = 0; i < sigB32.length; i += 4) {
    groups.push(sigB32.substring(i, i + 4));
  }
  return PREFIX + groups.join('-');
}

// Return type mengikuti inferensi TS (Uint8Array<ArrayBuffer>) supaya
// langsung valid utk parameter BufferSource di crypto.subtle.
export function hexToBytes(hex: string) {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
  }
  return out;
}

function utf8(s: string) {
  return new TextEncoder().encode(s);
}

// PKCS8 DER prefix untuk Ed25519: SEQ { INTEGER 0, SEQ { OID 1.3.101.112 },
// OCTET STRING (32B) } — wrapper di depan seed 32 byte.
const ED25519_PKCS8_PREFIX = new Uint8Array([
  0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06,
  0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
]);

export async function generateKey(env: Env): Promise<{ key: string; serial: string }> {
  const privHex = env.NUSA_PRIVATE_KEY ?? '';
  if (!privHex) {
    throw new Error('NUSA_PRIVATE_KEY not set in environment');
  }

  const serial = generateSerial();
  const seed = hexToBytes(privHex);
  const pkcs8 = new Uint8Array(ED25519_PKCS8_PREFIX.length + seed.length);
  pkcs8.set(ED25519_PKCS8_PREFIX, 0);
  pkcs8.set(seed, ED25519_PKCS8_PREFIX.length);
  const privKey = await crypto.subtle.importKey('pkcs8', pkcs8, { name: 'Ed25519' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('Ed25519', privKey, utf8(serial)));
  return { key: formatKey(serial, sig), serial };
}

// ─── Generate new signed activation key(s) ───────────────────────────

export async function handleGenerate(ctx: FnContext, params: Params): Promise<Response> {
  const env = ctx.env;
  const count = Math.max(1, Math.min((params.count as number | undefined) ?? 1, 100));
  const ownerEmail = (params.owner_email as string | undefined) ?? null;
  const buyerName = (params.buyer_name as string | undefined) ?? null;
  const sendEmail = params.send_email === true && ownerEmail !== null;
  const isTrial = params.is_trial === true;
  const tier = (params.tier as string | undefined) ?? (isTrial ? 'trial' : 'lifetime');
  const product = (params.product as string | undefined) ?? 'nusa-kasir';
  const mode = (params.mode as string | undefined) ?? 'pro'; // pro | lite (accept 'full' as alias for backward compat)
  if (mode !== 'pro' && mode !== 'full' && mode !== 'lite') return json({ error: 'mode must be pro or lite' }, 400);

  const keys: { key: string; serial: string }[] = [];

  for (let i = 0; i < count; i++) {
    try {
      const k = await generateKey(env);
      keys.push(k);
    } catch (e: any) {
      return json({ error: e?.message ?? String(e), generated: keys.length }, 500);
    }
  }

  // Hitung expiry berdasarkan tier
  let trialExpires: string | null = null;
  if (tier === 'trial') {
    trialExpires = new Date(Date.now() + 3 * 24 * 60 * 60 * 1000).toISOString(); // 3 hari
  } else if (tier === '1month') {
    trialExpires = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString(); // 1 bulan
  }
  // lifetime: expires_at tetap null

  // Insert semua ke tabel licenses
  const insertStmt = env.DB.prepare(
    'INSERT INTO licenses (id, key, serial, product, mode, tier, status, owner_email, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)'
  );
  try {
    await env.DB.batch(
      keys.map((k) =>
        insertStmt.bind(
          uid(),
          k.key,
          k.serial,
          product,
          mode,
          tier,
          tier === 'trial' ? 'Trial' : 'Active',
          ownerEmail,
          trialExpires,
        )
      )
    );
  } catch (e: any) {
    return json({ error: e?.message ?? String(e), generated: 0 }, 500);
  }

  // Kirim email bila diminta
  let emailSent = false;
  let emailError: string | null = null;

  if (sendEmail && ownerEmail && env.RESEND_API_KEY) {
    try {
      await sendActivationEmail(
        env,
        ownerEmail,
        buyerName || 'Pelanggan NUSA',
        keys.map((k) => k.key),
        tier,
        product,
        mode
      );
      emailSent = true;
    } catch (e: any) {
      emailError = e?.message ?? String(e);
    }
  }

  return json({
    ok: true,
    count: keys.length,
    keys: keys.map((k) => k.key),
    tier,
    mode,
    product,
    expires_at: trialExpires,
    email_sent: emailSent,
    email_error: emailError,
  });
}

// ─── Send activation key email via Resend ────────────────────────────

async function sendActivationEmail(
  env: Env,
  toEmail: string,
  buyerName: string,
  keys: string[],
  tier = 'lifetime',
  product = 'nusa-kasir',
  mode = 'pro'
): Promise<void> {
  const resendApiKey = env.RESEND_API_KEY ?? '';
  const resendFromEmail = env.RESEND_FROM_EMAIL ?? 'nusa@halugoods.com';

  const keyList = keys.map((k) => `<code style="background:#f3f4f6;padding:4px 8px;border-radius:6px;font-size:13px;font-family:monospace">${k}</code>`).join("<br>");
  const singleKey = keys.length === 1 ? keys[0] : "";
  const stepActivation = singleKey
    ? `<p style="margin:8px 0"><strong>2.</strong> Buka aplikasi &amp; login dengan akun Google Anda</p>
       <p style="margin:8px 0"><strong>3.</strong> Masukkan key aktivasi: <code style="background:#fde8ea;padding:3px 8px;border-radius:5px;font-size:14px;font-weight:600">${singleKey}</code></p>`
    : `<p style="margin:8px 0"><strong>2.</strong> Buka aplikasi &amp; login dengan akun Google Anda</p>
       <p style="margin:8px 0"><strong>3.</strong> Masukkan salah satu key aktivasi di bawah</p>`;

  const productNames: Record<string, string> = {
    'nusa-kelontong': 'NUSA Kelontong',
    'nusa-fnb': 'NUSA F&B',
    'nusa-laundry': 'NUSA Laundry',
    'nusa-bengkel': 'NUSA Bengkel',
    'nusa-salon': 'NUSA Salon',
    'nusa-apotek': 'NUSA Apotek',
    'nusa-fotocopy': 'NUSA Fotocopy',
    'nusa-servicehp': 'NUSA Service HP',
    'nusa-kasir': 'NUSA Kasir',
  };
  const productName = productNames[product] ?? 'NUSA';

  const tierLabel = tier === 'trial' ? 'Trial 3 Hari' : tier === '1month' ? '1 Bulan' : 'Lifetime';
  const tierPrice = tier === 'trial' ? 'GRATIS' : tier === '1month'
    ? (mode === 'lite' ? 'Rp 49K' : 'Rp 99K')
    : (mode === 'lite' ? 'Rp 249K' : 'Rp 499K');

  const subject = tier === 'trial'
    ? `Trial ${productName} 3 Hari — Key Aktivasi Anda`
    : tier === '1month'
    ? `Lisensi ${productName} 1 Bulan — Key Aktivasi Anda`
    : `Lisensi ${productName} Lifetime — Key Aktivasi Anda`;

  const badge = `<p style="color:#fde8ea;margin:6px 0 0;font-size:13px">${tierLabel} — ${tierPrice}</p>`;

  const priceMonthly = mode === 'lite' ? 'Rp 49K' : 'Rp 99K';
  const priceLifetime = mode === 'lite' ? 'Rp 249K' : 'Rp 499K';
  const trialNotice = tier === 'trial'
    ? `<div style="background:#fef3c7;border-left:4px solid #f59e0b;border-radius:8px;padding:12px 16px;margin-bottom:24px">
        <p style="margin:0;font-size:13px;color:#92400e">
          ⏳ <strong>Trial 3 Hari</strong> — Key ini berlaku selama 3 hari sejak aktivasi pertama.<br>
          Setelah masa trial habis, kamu bisa beli lisensi seharga <strong>${priceMonthly}/bulan</strong> atau <strong>${priceLifetime} lifetime</strong>.
        </p>
      </div>`
    : tier === '1month'
    ? `<div style="background:#fef3c7;border-left:4px solid #f59e0b;border-radius:8px;padding:12px 16px;margin-bottom:24px">
        <p style="margin:0;font-size:13px;color:#92400e">
          📅 <strong>Lisensi 1 Bulan</strong> — Berlaku 30 hari sejak aktivasi.<br>
          Ingin selamanya? Upgrade ke <strong>${priceLifetime} lifetime</strong> kapan saja.
        </p>
      </div>`
    : `<div style="background:#fef3c7;border-left:4px solid #f59e0b;border-radius:8px;padding:12px 16px;margin-bottom:24px">
        <p style="margin:0;font-size:13px;color:#92400e">
          💡 <strong>Tips:</strong> Satu lisensi bisa dipakai di beberapa perangkat selama menggunakan akun Google yang sama.
        </p>
      </div>`;

  const html = `<!DOCTYPE html>
<html lang="id">
<head><meta charset="utf-8"></head>
<body style="font-family:Arial,Helvetica,sans-serif;background:#f7f7f9;padding:0;margin:0">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#f7f7f9;padding:40px 0">
<tr><td align="center">
<table width="540" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:16px;overflow:hidden;box-shadow:0 2px 12px rgba(0,0,0,0.06)">

  <!-- Header -->
  <tr>
    <td style="background:linear-gradient(135deg,#e63946,#c1121f);padding:32px 40px;text-align:center">
      <h1 style="color:#fff;margin:0;font-size:22px;font-weight:800;letter-spacing:-0.5px">${productName}</h1>
      ${badge}
    </td>
  </tr>

  <!-- Body -->
  <tr>
    <td style="padding:32px 40px">

      <p style="font-size:16px;color:#1f2937;margin:0 0 8px">Halo <strong>${buyerName}</strong>, 👋</p>
      <p style="font-size:14px;color:#6b7280;line-height:1.7;margin:0 0 24px">
        ${tier === 'trial' ? `Terima kasih sudah mencoba <strong>${productName}</strong>! Berikut key aktivasi trial 3 hari:` : `Terima kasih sudah berlangganan <strong>${productName}</strong>! Berikut key aktivasi:`}
      </p>

      <!-- Key box -->
      <div style="background:#f9fafb;border:1px solid #e5e7eb;border-radius:12px;padding:20px;margin-bottom:24px">
        ${keys.length === 1
          ? `<p style="font-size:18px;font-weight:700;font-family:monospace;color:#e63946;text-align:center;margin:0;letter-spacing:0.5px">${singleKey}</p>`
          : `<div style="font-size:14px;font-family:monospace;color:#1f2937;line-height:2;text-align:center">${keyList}</div>`}
      </div>

      <!-- Steps -->
      <h2 style="font-size:15px;color:#1f2937;margin:0 0 12px">📱 Langkah Aktivasi</h2>
      <div style="background:#f9fafb;border-radius:12px;padding:16px 20px;margin-bottom:24px">
        <p style="margin:8px 0;font-size:14px;color:#374151"><strong>1.</strong> Download ${productName} dari link yang diberikan</p>
        ${stepActivation}
        <p style="margin:8px 0;font-size:14px;color:#374151"><strong>4.</strong> Setup data toko &amp; mulai jualan! 🎉</p>
      </div>

      ${trialNotice}

      <!-- Footer -->
      <p style="font-size:12px;color:#9ca3af;line-height:1.6;margin:0">
        Jika ada pertanyaan, silakan hubungi kami di<br>
        <a href="mailto:support@halugoods.com" style="color:#e63946;text-decoration:none">support@halugoods.com</a>
        &nbsp;|&nbsp;
        <a href="https://wa.me/628976280303" style="color:#e63946;text-decoration:none">WhatsApp</a>
      </p>
    </td>
  </tr>

  <!-- Footer bar -->
  <tr>
    <td style="background:#f9fafb;padding:16px 40px;text-align:center">
      <p style="font-size:11px;color:#9ca3af;margin:0">
        © ${new Date().getFullYear()} NUSA — Aplikasi Kasir Indonesia
      </p>
    </td>
  </tr>

</table>
</td></tr>
</table>
</body>
</html>`;

  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${resendApiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      from: `NUSA Kasir <${resendFromEmail}>`,
      to: [toEmail],
      subject,
      html,
    }),
  });

  if (!res.ok) {
    const errBody = await res.text();
    throw new Error(`Resend API error: ${res.status} ${errBody}`);
  }
}

// ─── Add a pre-generated key (dari keygen.dart CLI) ──────────────────

export async function handleAdd(ctx: FnContext, params: Params): Promise<Response> {
  const { key, serial, owner_email, product } = params as any;
  if (!key || !serial) {
    return errorJson('key and serial required', 400);
  }

  try {
    await ctx.env.DB.prepare(
      'INSERT INTO licenses (id, key, serial, product, status, owner_email) VALUES (?, ?, ?, ?, ?, ?)'
    )
      .bind(uid(), String(key).toUpperCase(), String(serial), product ?? 'nusa-kasir', 'Active', owner_email ?? null)
      .run();
  } catch (e: any) {
    // PG 23505 (unique_violation) → D1: "UNIQUE constraint failed"
    if (String(e?.message ?? '').includes('UNIQUE')) {
      return errorJson('Key already exists', 409);
    }
    return errorJson(e?.message ?? String(e), 500);
  }

  return json({ ok: true, key: String(key).toUpperCase() });
}

// ─── List all licenses with activation counts ────────────────────────

export async function handleList(ctx: FnContext, params: Params): Promise<Response> {
  const page = Math.max(0, (params.page as number | undefined) ?? 0);
  const limit = Math.min((params.limit as number | undefined) ?? 50, 200);
  const status = (params.status as string | undefined) ?? null;
  const search = (params.search as string | undefined) ?? null;
  const product = (params.product as string | undefined) ?? null;
  const tier = (params.tier as string | undefined) ?? null;

  // Filter opsional — disusun dinamis seperti chain .eq()/.or() di sumber.
  const where: string[] = [];
  const binds: unknown[] = [];
  if (status) {
    where.push('status = ?');
    binds.push(status);
  }
  if (product) {
    where.push('product = ?');
    binds.push(product);
  }
  if (tier) {
    where.push('tier = ?');
    binds.push(tier);
  }
  // ilike %search% pada key / owner_email (SQLite LIKE: ASCII case-insensitive)
  if (search) {
    where.push('(key LIKE ? OR owner_email LIKE ?)');
    binds.push(`%${search}%`, `%${search}%`);
  }
  const whereSql = where.length > 0 ? `WHERE ${where.join(' AND ')}` : '';

  // Total count (pengganti select('*', { count: 'exact' }))
  const countRow = await ctx.env.DB.prepare(`SELECT COUNT(*) AS c FROM licenses ${whereSql}`)
    .bind(...binds)
    .first<Row>();

  // Halaman data (pengganti .range(from, to): LIMIT limit OFFSET from)
  const rowsRes = await ctx.env.DB.prepare(
    `SELECT * FROM licenses ${whereSql} ORDER BY created_at DESC LIMIT ? OFFSET ?`
  )
    .bind(...binds, limit, page * limit)
    .all<Row>();

  // Jumlah aktivasi utk lisensi yang dikembalikan
  const data = rowsRes.results ?? [];
  const licenseIds = data.map((l: Row) => l.id);
  const activationCounts: Record<string, number> = {};

  if (licenseIds.length > 0) {
    const ph = licenseIds.map(() => '?').join(',');
    const actRes = await ctx.env.DB.prepare(
      `SELECT license_id, COUNT(*) AS c FROM activations WHERE license_id IN (${ph}) GROUP BY license_id`
    )
      .bind(...licenseIds)
      .all<Row>();
    for (const a of actRes.results ?? []) {
      activationCounts[a.license_id] = a.c;
    }
  }

  const licenses = data.map((l: Row) => ({
    ...l,
    activation_count: activationCounts[l.id] ?? 0,
  }));

  return json({ licenses, total: countRow?.c ?? 0, page, limit });
}

// ─── Get single license detail with activations ──────────────────────

export async function handleDetail(ctx: FnContext, params: Params): Promise<Response> {
  const { license_id } = params as any;
  if (!license_id) return errorJson('license_id required', 400);

  const license = await ctx.env.DB.prepare('SELECT * FROM licenses WHERE id = ?')
    .bind(license_id)
    .first<Row>();
  if (!license) return errorJson('License not found', 404);

  const actRes = await ctx.env.DB.prepare(
    'SELECT * FROM activations WHERE license_id = ? ORDER BY created_at DESC'
  )
    .bind(license_id)
    .all<Row>();
  const activations = actRes.results ?? [];

  return json({
    license: {
      ...license,
      device_count: activations.length,
      activations,
    },
  });
}

// ─── Revoke a license ────────────────────────────────────────────────

export async function handleRevoke(ctx: FnContext, params: Params): Promise<Response> {
  const { license_id } = params as any;
  if (!license_id) return errorJson('license_id required', 400);

  await ctx.env.DB.prepare("UPDATE licenses SET status = 'Cancelled' WHERE id = ?")
    .bind(license_id)
    .run();

  return json({ ok: true, message: 'License cancelled' });
}

// ─── Manually set a license status (admin override) ────────────────────
// Dipakai dashboard admin untuk mengembalikan key yang auto-revoke
// (Expired → Cancelled setelah grace 7 hari) ke Active setelah owner
// bayar, atau cancel/suspend manual. Diaudit via license_events.
export async function handleSetStatus(ctx: FnContext, params: Params): Promise<Response> {
  const { license_id, status, reason } = params as any;
  if (!license_id) return errorJson('license_id required', 400);
  if (!status) return errorJson('status required', 400);

  const allowed = ['Generated', 'Trial', 'Active', 'Cancelled', 'Expired'];
  if (!allowed.includes(status)) {
    return errorJson(`Invalid status: ${status}`, 400);
  }

  const lic = await ctx.env.DB.prepare('SELECT status, expires_at FROM licenses WHERE id = ?')
    .bind(license_id)
    .first<Row>();
  if (!lic) return errorJson('License not found', 404);

  // Key lifetime punya expires_at = null; menjadikannya Expired tidak
  // konsisten (tidak ada yang bisa expired). Guard di sini.
  if (status === 'Expired' && !lic.expires_at) {
    return errorJson(
      'Lisensi lifetime (tanpa tanggal kadaluarsa) tidak bisa dijadikan Expired',
      400
    );
  }

  if (lic.status === status) {
    return json({ ok: true, message: 'Status sudah sama, tidak ada perubahan' });
  }

  await ctx.env.DB.prepare('UPDATE licenses SET status = ? WHERE id = ?')
    .bind(status, license_id)
    .run();

  // Audit trail
  await ctx.env.DB.prepare(
    'INSERT INTO license_events (id, license_id, event, detail) VALUES (?, ?, ?, ?)'
  )
    .bind(uid(), license_id, 'admin_set_status', JSON.stringify({ from: lic.status, to: status, reason: reason ?? null }))
    .run();

  return json({
    ok: true,
    message: `Status lisensi diubah: ${lic.status} → ${status}`,
  });
}

// ─── Delete an unused license ────────────────────────────────────────

export async function handleDelete(ctx: FnContext, params: Params): Promise<Response> {
  const { license_id } = params as any;
  if (!license_id) return errorJson('license_id required', 400);

  // Hanya lisensi Generated yang belum diaktivasi yang boleh dihapus
  const lic = await ctx.env.DB.prepare('SELECT status FROM licenses WHERE id = ?')
    .bind(license_id)
    .first<Row>();

  if (!lic) return errorJson('License not found', 404);
  if (lic.status !== 'Generated') {
    return errorJson('Hanya lisensi unused (Generated) yang bisa dihapus', 400);
  }

  // Cek juga tidak ada aktivasi (belt and suspenders)
  const actRow = await ctx.env.DB.prepare('SELECT COUNT(*) AS c FROM activations WHERE license_id = ?')
    .bind(license_id)
    .first<Row>();

  if ((actRow?.c ?? 0) > 0) {
    return errorJson('Lisensi sudah memiliki aktivasi, tidak bisa dihapus', 400);
  }

  await ctx.env.DB.prepare('DELETE FROM licenses WHERE id = ?').bind(license_id).run();

  return json({ ok: true, message: 'License deleted' });
}

// ─── Summary stats ───────────────────────────────────────────────────

export async function handleStats(ctx: FnContext, _params: Params): Promise<Response> {
  const grouped = await ctx.env.DB.prepare('SELECT status, COUNT(*) AS c FROM licenses GROUP BY status').all<Row>();
  const actRow = await ctx.env.DB.prepare('SELECT COUNT(*) AS c FROM activations').first<Row>();

  const stats: Record<string, number> = {
    total: 0,
    Generated: 0,
    Active: 0,
    Cancelled: 0,
    Trial: 0,
    Expired: 0,
    total_activations: actRow?.c ?? 0,
  };

  for (const r of grouped.results ?? []) {
    stats[r.status] = (stats[r.status] ?? 0) + r.c;
    stats.total += r.c;
  }

  return json({ stats });
}

// ─── Versi minimum app per produk (force-update) ─────────────────────

export async function handleGetMinVersions(ctx: FnContext, _params: Params): Promise<Response> {
  const res = await ctx.env.DB.prepare('SELECT * FROM app_min_versions ORDER BY product ASC').all<Row>();
  return json({ versions: res.results ?? [] });
}

export async function handleSetMinVersion(ctx: FnContext, params: Params): Promise<Response> {
  const { product, min_version, min_build, download_url } = params as any;
  if (!product) return errorJson('product required', 400);
  // min_build = 0 → hapus baris (rollback: tidak ada force update).
  if (!min_build || Number(min_build) <= 0) {
    await ctx.env.DB.prepare('DELETE FROM app_min_versions WHERE product = ?').bind(product).run();
    return json({ ok: true, cleared: true });
  }
  // Pengganti upsert { onConflict: 'product' }
  await ctx.env.DB.prepare(
    `INSERT INTO app_min_versions (product, min_version, min_build, download_url, updated_at)
     VALUES (?, ?, ?, ?, ?)
     ON CONFLICT(product) DO UPDATE SET
       min_version = excluded.min_version,
       min_build = excluded.min_build,
       download_url = excluded.download_url,
       updated_at = excluded.updated_at`
  )
    .bind(product, String(min_version ?? ''), Number(min_build), download_url ?? null, nowIso())
    .run();
  return json({ ok: true });
}

// ─── Registrasi route ────────────────────────────────────────────────

// Semua action license-manager butuh x-admin-key (sama seperti guard di
// serve() edge fn lama) + try/catch global → 500 { error: e.message }.
function adminWrap(h: H): H {
  return async (ctx: FnContext, params: Params): Promise<Response> => {
    if (!ctx.isAdmin) return errorJson('Unauthorized — invalid admin key', 401);
    try {
      return await h(ctx, params);
    } catch (e: any) {
      return errorJson(e?.message ?? String(e), 500);
    }
  };
}

// ─── Auto-claim: user login Google → lisensi auto-bind tanpa input key ─
// User-facing (tidak butuh admin key). Flow:
//   1. App Google Sign-in → kirim {email, googleUserId, product}
//   2. Cari lisensi Generated yang email-nya cocok
//   3. Bind googleUserId + set Active + insert activation
//   4. Return {ok, license_key, message}
export async function handleAutoClaim(ctx: FnContext, params: Params): Promise<Response> {
  const email = String(params.email ?? '').trim().toLowerCase();
  const googleUserId = String(params.googleUserId ?? '').trim();
  const product = String(params.product ?? 'nusa-kasir').trim();
  if (!email) return errorJson('email required', 400);
  if (!googleUserId) return errorJson('googleUserId required', 400);

  // Cari lisensi Generated yang email-nya cocok
  const lic = await ctx.env.DB.prepare(
    "SELECT id, status, google_user_id, product FROM licenses WHERE LOWER(owner_email) = ? AND status = 'Generated' ORDER BY created_at ASC LIMIT 1"
  ).bind(email).first<Row>();

  if (!lic) return errorJson('no_license', 404);

  // Bind googleUserId + set Active
  const updates: string[] = ["status = 'Active'"];
  const binds: unknown[] = [];
  if (!lic.google_user_id) {
    updates.push('google_user_id = ?');
    binds.push(googleUserId);
  }
  if (lic.product !== product) {
    updates.push('product = ?');
    binds.push(product);
  }
  try {
    await ctx.env.DB.prepare(`UPDATE licenses SET ${updates.join(', ')} WHERE id = ?`)
      .bind(...binds, lic.id).run();
  } catch (e: any) {
    return errorJson(e?.message ?? String(e), 500);
  }

  // Insert activation
  try {
    await ctx.env.DB.prepare(
      'INSERT INTO activations (id, license_id, google_user_id, device_id) VALUES (?, ?, ?, ?)'
    ).bind(uid(), lic.id, googleUserId, 'android-' + googleUserId.slice(0, 12)).run();
  } catch (e: any) {
    if (!String(e?.message ?? '').includes('UNIQUE')) {
      // UNIQUE violation = sudah pernah aktivasi, OK
      return errorJson(e?.message ?? String(e), 500);
    }
  }

  return json({ ok: true, license_key: lic.key, product, status: 'Active' });
}

// ─── Lite activation (v2.2.57+130): email + key, no Google Sign-In ──
//
// Untuk varian Lite (tanpa Google Sign-In). User input email + license key
// di app, sistem validasi email cocok dengan key di D1, langsung aktivasi.
// Tidak perlu x-admin-key karena ini endpoint publik untuk end-user.
//
// Flow:
//   1. Cari license by key
//   2. Cek: status harus Generated/Active (suspended/revoked ditolak)
//   3. Cek: LOWER(owner_email) == LOWER(input_email) → tolak kalau beda
//   4. Cek: tier = trial / 1month / lifetime — kalau trial → set Active
//      dan expires_at = now + 3 hari
//   5. Cek: kalau mode = lite, abaikan cloud features, return ok
//   6. Return {ok, license_key, product, mode, expires_at, message}
export async function handleActivateLite(ctx: FnContext, params: Params): Promise<Response> {
  const email = String(params.email ?? '').trim().toLowerCase();
  const licenseKey = String(params.license_key ?? '').trim();
  const product = String(params.product ?? 'nusa-kasir').trim();
  const deviceId = String(params.device_id ?? '').trim();

  if (!email) return errorJson('email required', 400);
  if (!licenseKey) return errorJson('license_key required', 400);
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
    return errorJson('format email tidak valid', 400);
  }

  // 1. Cari license by key
  const lic = await ctx.env.DB.prepare(
    "SELECT id, key, serial, status, owner_email, google_user_id, tier, mode, expires_at, product FROM licenses WHERE key = ?"
  ).bind(licenseKey).first<Row>();

  if (!lic) return errorJson('license_key tidak valid', 404);

  // 2. Cek status
  if (lic.status === 'Cancelled' || lic.status === 'Expired') {
    return errorJson(`lisensi ${lic.status.toLowerCase()} — hubungi admin`, 403);
  }

  // 3. Cek email cocok
  const licEmail = String(lic.owner_email ?? '').trim().toLowerCase();
  if (!licEmail) {
    return errorJson('lisensi belum terikat email — minta admin isi email saat generate', 400);
  }
  if (licEmail !== email) {
    return errorJson('email tidak cocok dengan lisensi', 403);
  }

  // 4. Tentukan mode — kalau belum ada, default 'pro' (backward compat: treat legacy 'full' as 'pro')
  const mode = lic.mode === 'full' ? 'pro' : (lic.mode ?? 'pro');

  // 5. Cek expired
  let expiresAt = lic.expires_at as string | null;
  if (lic.tier === 'trial' && (!expiresAt || new Date(expiresAt) < new Date())) {
    // trial baru: set expires_at = now + 3 hari (idempotent — hanya set sekali)
    expiresAt = new Date(Date.now() + 3 * 24 * 60 * 60 * 1000).toISOString();
  } else if (expiresAt && new Date(expiresAt) < new Date()) {
    return errorJson('lisensi sudah expired — hubungi admin untuk perpanjang', 403);
  }

  // 6. Set status → Active, simpan expires_at kalau baru
  try {
    await ctx.env.DB.prepare(
      "UPDATE licenses SET status = 'Active', expires_at = COALESCE(?, expires_at), product = COALESCE(?, product) WHERE id = ?"
    ).bind(expiresAt, product, lic.id).run();
  } catch (e: any) {
    return errorJson(e?.message ?? String(e), 500);
  }

  // 7. Insert activation (device_id opsional — Lite tanpa Google jadi
  //    device_id di-hash dari email+device agar konsisten tiap install)
  if (deviceId) {
    try {
      await ctx.env.DB.prepare(
        "INSERT OR IGNORE INTO activations (id, license_id, device_id, google_user_id) VALUES (?, ?, ?, ?)"
      ).bind(uid(), lic.id, deviceId, null).run();
    } catch (e: any) {
      // UNIQUE violation = sudah pernah aktivasi di device yg sama, OK
      if (!String(e?.message ?? '').includes('UNIQUE')) {
        // non-fatal — aktivasi utama tetap sukses
        console.error('lite activation insert error:', e?.message);
      }
    }
  }

  return json({
    ok: true,
    license_key: lic.key,
    product: lic.product ?? product,
    mode,
    tier: lic.tier,
    status: 'Active',
    expires_at: expiresAt,
    owner_email: licEmail,
    message: 'Aktivasi berhasil',
  });
}

Router.registerAll('license-manager', {
  generate: adminWrap(handleGenerate),
  add: adminWrap(handleAdd),
  list: adminWrap(handleList),
  detail: adminWrap(handleDetail),
  revoke: adminWrap(handleRevoke),
  set_status: adminWrap(handleSetStatus),
  delete: adminWrap(handleDelete),
  stats: adminWrap(handleStats),
  get_min_versions: adminWrap(handleGetMinVersions),
  set_min_version: adminWrap(handleSetMinVersion),
  auto_claim: handleAutoClaim,
  activate_lite: handleActivateLite,
});
