/**
 * /api/auth/* — custom auth full (pengganti Supabase Auth).
 *
 * handle_login           POST {email, password}                       → {jwt, account}
 * handle_signup          POST {email, password, displayName?}         → {jwt, account}
 * handle_google_link     POST {googleUserId, email, displayName}      → {jwt, account} (link/akun Google)
 * handle_anon            POST {}                                      → {jwt, account} (uid anon sinkron dengan app)
 * handle_reset_request   POST {email}                                 → kirim email via Resend
 * handle_reset_confirm   POST {token, newPassword}                    → {ok}
 * handle_me              POST {}  (Bearer JWT)                        → {account}
 *
 * Akun id = uuid v4 → menjadi canonical uid backup (path R2 D1), sama
 * pola dengan Supabase user.id dulu.
 */
import { json, readBody, type FnContext } from './router';
import { hashPassword, verifyPassword, signJwt, uuid } from './auth';

interface AccountRow {
  id: string;
  email: string;
  password_hash: string;
  google_user_id: string | null;
  display_name: string | null;
}

function accountPayload(a: AccountRow) {
  return {
    id: a.id,
    email: a.email,
    displayName: a.display_name,
    googleUserId: a.google_user_id,
  };
}

async function makeJwt(ctx: FnContext, a: AccountRow, provider: 'password' | 'google' | 'anon') {
  return signJwt(ctx.env, {
    sub: a.id,
    email: a.email,
    provider,
    google_user_id: a.google_user_id ?? undefined,
  });
}

// ── signup ───────────────────────────────────────────────────────────
export async function handle_signup(ctx: FnContext, _params: Record<string, unknown>): Promise<Response> {
  const body = await readBody(ctx.req);
  const email = String(body.email ?? '').trim().toLowerCase();
  const password = String(body.password ?? '');
  if (!email || !email.includes('@')) return json({ error: 'email tidak valid' }, 400);
  if (password.length < 6) return json({ error: 'password minimal 6 karakter' }, 400);

  const existing = await ctx.env.DB.prepare('SELECT id FROM accounts WHERE email = ?').bind(email).first();
  if (existing) return json({ error: 'email sudah terdaftar' }, 409);

  const id = uuid();
  const hash = await hashPassword(password);
  await ctx.env.DB.prepare(
    'INSERT INTO accounts (id, email, password_hash, display_name) VALUES (?, ?, ?, ?)',
  ).bind(id, email, hash, body.displayName ? String(body.displayName) : null).run();

  const a: AccountRow = { id, email, password_hash: hash, google_user_id: null, display_name: body.displayName ? String(body.displayName) : null };
  return json({ jwt: await makeJwt(ctx, a, 'password'), account: accountPayload(a) }, 201);
}

// ── login ────────────────────────────────────────────────────────────
export async function handle_login(ctx: FnContext, _params: Record<string, unknown>): Promise<Response> {
  const body = await readBody(ctx.req);
  const email = String(body.email ?? '').trim().toLowerCase();
  const password = String(body.password ?? '');

  const row = await ctx.env.DB.prepare('SELECT * FROM accounts WHERE email = ?').bind(email).first<AccountRow>();
  if (!row || !(await verifyPassword(password, row.password_hash))) {
    return json({ error: 'email atau password salah' }, 401);
  }
  return json({ jwt: await makeJwt(ctx, row, 'password'), account: accountPayload(row) });
}

// ── google link (Google Sign-In native → identitas kanonik) ─────────
export async function handle_google_link(ctx: FnContext, _params: Record<string, unknown>): Promise<Response> {
  const body = await readBody(ctx.req);
  const gid = String(body.googleUserId ?? '').trim();
  const email = String(body.email ?? '').trim().toLowerCase();
  if (!gid) return json({ error: 'googleUserId required' }, 400);

  // 1. Sudah ada akun dengan google_user_id ini → login langsung.
  let row = await ctx.env.DB.prepare('SELECT * FROM accounts WHERE google_user_id = ?').bind(gid).first<AccountRow>();

  if (!row) {
    // 2. Sudah ada akun email sama (password) → LINK.
    // v2.2.57+130-fix: cek apakah akun ini sudah punya google_user_id BEDA.
    // Jangan overwrite — bisa corrupt akun orang lain yang sudah linked.
    if (email) {
      row = await ctx.env.DB.prepare('SELECT * FROM accounts WHERE email = ?').bind(email).first<AccountRow>();
      if (row) {
        if (row.google_user_id && row.google_user_id !== gid) {
          return json({ error: 'Email ini sudah linked ke akun Google lain' }, 409);
        }
        try {
          await ctx.env.DB.prepare('UPDATE accounts SET google_user_id = ?, updated_at = datetime(\'now\') WHERE id = ?')
            .bind(gid, row.id).run();
          row.google_user_id = gid;
        } catch (e) {
          // UNIQUE violation — google_user_id sudah dipakai akun lain
          return json({ error: 'Akun Google ini sudah linked ke email lain' }, 409);
        }
      }
    }
    if (!row) {
      // 3. Buat akun baru tanpa password (login Google).
      const id = uuid();
      const storeEmail = email || `${gid}@google.nusa`;
      await ctx.env.DB.prepare(
        'INSERT INTO accounts (id, email, password_hash, google_user_id, display_name) VALUES (?, ?, ?, ?, ?)',
      ).bind(id, storeEmail, '', gid, body.displayName ? String(body.displayName) : null).run();
      row = { id, email: storeEmail, password_hash: '', google_user_id: gid, display_name: body.displayName ? String(body.displayName) : null };
    }
  }
  return json({ jwt: await makeJwt(ctx, row, 'google'), account: accountPayload(row) });
}

// ── anon (backward-compat dengan uid anon lama) ─────────────────────
export async function handle_anon(ctx: FnContext, _params: Record<string, unknown>): Promise<Response> {
  const body = await readBody(ctx.req);
  const legacyId = String(body.legacyId ?? '').trim();
  // App kirim legacyId (uuid lokal) supaya path backup lama tetap valid.
  if (legacyId) {
    const existing = await ctx.env.DB.prepare('SELECT * FROM accounts WHERE id = ?').bind(legacyId).first<AccountRow>();
    if (existing) {
      return json({ jwt: await makeJwt(ctx, existing, 'anon'), account: accountPayload(existing) });
    }
    const email = `${legacyId}@anon.nusa`;
    await ctx.env.DB.prepare(
      "INSERT OR IGNORE INTO accounts (id, email, password_hash) VALUES (?, ?, '')",
    ).bind(legacyId, email).run();
    const a: AccountRow = { id: legacyId, email, password_hash: '', google_user_id: null, display_name: null };
    return json({ jwt: await makeJwt(ctx, a, 'anon'), account: accountPayload(a) });
  }
  // Tanpa legacyId — buat sesi anon baru.
  const id = uuid();
  const email = `${id}@anon.nusa`;
  await ctx.env.DB.prepare("INSERT INTO accounts (id, email, password_hash) VALUES (?, ?, '')").bind(id, email).run();
  const a: AccountRow = { id, email, password_hash: '', google_user_id: null, display_name: null };
  return json({ jwt: await makeJwt(ctx, a, 'anon'), account: accountPayload(a) });
}

// ── reset password ───────────────────────────────────────────────────
export async function handle_reset_request(ctx: FnContext, _params: Record<string, unknown>): Promise<Response> {
  const body = await readBody(ctx.req);
  const email = String(body.email ?? '').trim().toLowerCase();
  const row = await ctx.env.DB.prepare('SELECT id FROM accounts WHERE email = ?').bind(email).first<{ id: string }>();
  // Selalu OK (anti-enumerasi), tapi kirim email hanya bila akun ada.
  if (row) {
    const token = crypto.getRandomValues(new Uint8Array(32));
    const tokenHex = Array.from(token).map(b => b.toString(16).padStart(2, '0')).join('');
    const expires = new Date(Date.now() + 3600_000).toISOString(); // 1 jam
    await ctx.env.DB.prepare(
      'INSERT INTO reset_tokens (token, account_id, expires_at) VALUES (?, ?, ?)',
    ).bind(tokenHex, row.id, expires).run();
    const resetUrl = `${String(body.appBaseUrl ?? 'https://nusa-online.vercel.app')}/reset-password?token=${tokenHex}`;
    try {
      await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${ctx.env.RESEND_API_KEY}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          from: ctx.env.RESEND_FROM_EMAIL || 'nusa@halugoods.com',
          to: email,
          subject: 'Reset Password NUSA Kasir',
          html: `<p>Klik link berikut untuk mereset password NUSA Kasir Anda (berlaku 1 jam):</p><p><a href="${resetUrl}">${resetUrl}</a></p>`,
        }),
      });
    } catch {
      // email gagal → tetap 200 anti-enumerasi; user bisa minta ulang
    }
  }
  return json({ ok: true });
}

export async function handle_reset_confirm(ctx: FnContext, _params: Record<string, unknown>): Promise<Response> {
  const body = await readBody(ctx.req);
  const token = String(body.token ?? '');
  const newPassword = String(body.newPassword ?? '');
  if (newPassword.length < 6) return json({ error: 'password minimal 6 karakter' }, 400);

  const row = await ctx.env.DB.prepare('SELECT * FROM reset_tokens WHERE token = ? AND used = 0').bind(token).first<{ token: string; account_id: string; expires_at: string }>();
  if (!row || new Date(row.expires_at).getTime() < Date.now()) {
    return json({ error: 'token tidak valid atau kedaluwarsa' }, 400);
  }
  const hash = await hashPassword(newPassword);
  await ctx.env.DB.batch([
    ctx.env.DB.prepare('UPDATE accounts SET password_hash = ?, updated_at = datetime(\'now\') WHERE id = ?').bind(hash, row.account_id),
    ctx.env.DB.prepare('UPDATE reset_tokens SET used = 1 WHERE token = ?').bind(token),
  ]);
  return json({ ok: true });
}

// ── me (profil dari JWT) ─────────────────────────────────────────────
export async function handle_me(ctx: FnContext, _params: Record<string, unknown>): Promise<Response> {
  const auth = ctx.req.headers.get('Authorization') ?? '';
  if (!auth.startsWith('Bearer ')) return json({ error: 'jwt required' }, 401);
  const { verifyJwt } = await import('./auth');
  const claims = await verifyJwt(ctx.env, auth.slice(7));
  if (!claims) return json({ error: 'jwt invalid' }, 401);
  const row = await ctx.env.DB.prepare('SELECT * FROM accounts WHERE id = ?').bind(claims.sub).first<AccountRow>();
  if (!row) return json({ error: 'account not found' }, 404);
  return json({ account: accountPayload(row) });
}
