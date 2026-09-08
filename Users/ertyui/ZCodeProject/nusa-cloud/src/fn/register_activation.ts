// ============================================================================
// NUSA — Register Activation (port dari supabase/functions/register_activation)
// v3 — Multi-App
// ============================================================================
// Edge fn lama tidak punya field `action` di body — dia dispatch berdasarkan
// ada/tidaknya `key` di body. Port ini mendaftarkan handler yang sama untuk
// dua action path agar payload 1:1 tetap terjaga:
//   POST /api/register-activation/check    { product, googleUserId }      (tanpa key)
//   POST /api/register-activation/activate { key, product, googleUserId, ownerEmail }
// Handler dispatch tetap pada presence of `key`, persis seperti sumber.
//
// Catatan port:
//   - Verifikasi user Supabase Auth (Authorization header + anon key) DIHAPUS
//     — Flutter app tidak pernah pakai Supabase Auth; identitas hanya dari
//     body `googleUserId` (trust model sama seperti edge fn lama).
//   - Verifikasi Ed25519 via WebCrypto native (raw 32-byte public key) —
//     kompatibel dgn pesan yang di-sign noble/ed25519 maupun keygen.dart.
//   - rpc can_activate() di-reimplement di TS (lihat canActivate di bawah,
//     logika owner-first sesuai migrasi 0018).
// ============================================================================

import { json, errorJson, Router, type FnContext } from '../router';
import { uid } from './db';

type Params = Record<string, unknown>;
type Row = Record<string, any>;

function b32decode(s: string): number[] {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  const map: Record<string, number> = {};
  for (let i = 0; i < alphabet.length; i++) map[alphabet[i]] = i;
  let bits = 0,
    value = 0;
  const out: number[] = [];
  for (const ch of s.toUpperCase()) {
    if (!(ch in map)) continue;
    value = (value << 5) | map[ch];
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.push((value >> bits) & 0xff);
    }
  }
  return out;
}

// Return type mengikuti inferensi TS (Uint8Array<ArrayBuffer>) supaya
// langsung valid utk parameter BufferSource di crypto.subtle.
function hexToBytes(hex: string) {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
  return out;
}

// ─── can_activate (pengganti rpc Postgres, logika migrasi 0018) ───────
// Owner-first: akun Google yang sama selalu boleh re-aktivasi (renew /
// upgrade / multi-device), walau key lamanya sudah expired. Akun lain
// ditolak bila key dibatalkan / expired / sudah dimiliki orang lain, atau
// bila akun tsb masih punya lisensi aktif lain.
async function canActivate(
  env: FnContext['env'],
  lid: string,
  gid: string
): Promise<boolean> {
  const lic = await env.DB.prepare(
    'SELECT status, expires_at, google_user_id FROM licenses WHERE id = ?'
  )
    .bind(lid)
    .first<Row>();
  if (!lic) return false;

  // Akun Google yang sama → boleh (renew / upgrade / multi-device) walau
  // key sebelumnya expired. Expired TIDAK boleh memblokir owner sah.
  if (lic.google_user_id != null && lic.google_user_id === gid) return true;

  // Blokir Cancelled (revoked permanen)
  if (lic.status === 'Cancelled') return false;

  // Blokir Expired (expires_at terisi dan sudah lewat)
  if (lic.expires_at != null && new Date(lic.expires_at) < new Date()) return false;

  // Akun Google lain sudah memiliki lisensi ini → tolak
  if (lic.google_user_id != null && lic.google_user_id !== gid) return false;

  // Cek apakah akun Google ini masih punya lisensi aktif lain
  const cnt = await env.DB.prepare(
    `SELECT COUNT(*) AS c FROM licenses
     WHERE google_user_id = ? AND id != ?
       AND (expires_at IS NULL OR expires_at >= ?)
       AND status NOT IN ('Cancelled', 'Expired')`
  )
    .bind(gid, lid, new Date().toISOString())
    .first<Row>();
  if ((cnt?.c ?? 0) > 0) return false;

  return true;
}

// ─── Handler utama (dispatch pada presence of `key`) ─────────────────

export async function handleRegisterActivation(ctx: FnContext, params: Params): Promise<Response> {
  try {
    const body = params;
    const { key, product, googleUserId, ownerEmail } = body as any;
    const prod = product ?? 'nusa-kasir'; // default untuk backward compat
    const env = ctx.env;

    if (!googleUserId) {
      return errorJson('googleUserId required', 400);
    }

    // ─── CHECK action (tanpa key) ────────────────────────────────
    if (!key) {
      // Satu lisensi mencakup SEMUA varian NUSA. Cari lisensi milik akun
      // Google ini apapun produknya — key Kelontong juga membuka app
      // FnB / Laundry / Fotocopy / dst. di akun yang sama.
      // (Dulu difilter per product, yang menyisakan user yang beli lisensi
      // satu varian tapi membuka varian lain.)
      const ownedRes = await env.DB.prepare(
        `SELECT id, key, serial, status, google_user_id, owner_email, expires_at, tier, product
         FROM licenses WHERE google_user_id = ? ORDER BY created_at DESC LIMIT 5`
      )
        .bind(googleUserId)
        .all<Row>();
      let owned = ownedRes.results ?? [];

      // v2.2.57+131: kalau tidak ketemu by Google ID, cek by owner_email
      // (lisensi generated/admin-linked tapi belum pernah di-activate user).
      // Kalau email cocok → link google_user_id ke lisensi + anggap milik akun.
      if (owned.length === 0) {
        const emailMatch = await env.DB.prepare(
          `SELECT id, key, serial, status, google_user_id, owner_email, expires_at, tier, product
           FROM licenses WHERE LOWER(owner_email) = LOWER(?) AND google_user_id IS NULL
           AND status NOT IN ('Cancelled', 'Expired') ORDER BY created_at DESC LIMIT 1`
        )
          .bind(googleUserId) // googleUserId bisa berupa email untuk Lite
          .first<Row>();
        if (emailMatch) {
          // Link Google ID ke lisensi ini
          await env.DB.prepare('UPDATE licenses SET google_user_id = ? WHERE id = ?')
            .bind(googleUserId, emailMatch.id)
            .run();
          emailMatch.google_user_id = googleUserId;
          owned = [emailMatch];
        }
      }

      // Utamakan lisensi terbaru yang tidak diblokir; lisensi blocked tetap
      // diambil supaya bisa dilaporkan dengan pesan bermakna, bukan diam-diam
      // "tidak ada lisensi".
      const license =
        owned.find((l) => !['Cancelled', 'Expired'].includes(l.status)) ?? owned[0] ?? null;

      if (!license) {
        return json({ has_license: false }, 200);
      }

      // Blokir lisensi revoked/cancelled — perlakukan sebagai tidak ada lisensi
      if (license.status === 'Cancelled' || license.status === 'Expired') {
        return json(
          {
            has_license: false,
            status: license.status,
            message:
              license.status === 'Cancelled'
                ? 'Lisensi Anda telah dibatalkan.'
                : 'Lisensi Anda telah kedaluwarsa.',
          },
          200,
        );
      }

      // Cek kadaluarsa (via expires_at) — memblokir Trial DAN Active.
      // Active expired = lisensi berbayar yang masanya habis (mis. 1 bulan);
      // tanpa blokir ini user yang sudah aktivasi tidak pernah diblokir.
      const isExpired = license.expires_at && new Date(license.expires_at) < new Date();
      if (isExpired && (license.status === 'Trial' || license.status === 'Active')) {
        return json(
          {
            has_license: false,
            status: 'Expired',
            is_expired: true,
            expires_at: license.expires_at,
            message:
              license.status === 'Trial'
                ? 'Masa trial Anda telah berakhir. Silakan beli lisensi penuh.'
                : 'Lisensi Anda telah kedaluwarsa. Silakan perpanjang untuk melanjutkan.',
          },
          200,
        );
      }

      return json(
        {
          has_license: true,
          license_id: license.id,
          status: license.status,
          key: license.key,
          serial: license.serial,
          expires_at: license.expires_at,
          tier: license.tier,
          is_expired: isExpired,
        },
        200,
      );
    }

    // ─── ACTIVATE action (key diisi) ─────────────────────────────

    // 1. Verifikasi signature Ed25519
    const cleaned = String(key)
      .toUpperCase()
      .replace('NUSA-', '')
      .replace(/-/g, '');
    const serial = cleaned.slice(0, 8);
    const sig = new Uint8Array(b32decode(cleaned.slice(8)));

    const pubKeyBytes = hexToBytes(env.NUSA_PUBLIC_KEY ?? '');
    const publicKey = await crypto.subtle.importKey('raw', pubKeyBytes, { name: 'Ed25519' }, false, [
      'verify',
    ]);
    const ok = await crypto.subtle.verify(
      'Ed25519',
      publicKey,
      sig,
      new TextEncoder().encode(serial)
    );
    if (!ok) return errorJson('invalid_key', 403);

    // 2. Cek lisensi
    const lic = await env.DB.prepare(
      'SELECT id, status, google_user_id, owner_email, expires_at, product FROM licenses WHERE key = ?'
    )
      .bind(key)
      .first<Row>();

    if (!lic) return errorJson('not_found', 404);
    if (lic.status === 'Cancelled')
      return json({ error: 'cancelled', message: 'Key ini sudah dibatalkan' }, 403);

    // Terima status 'Generated' dan 'Trial' untuk aktivasi
    if (lic.status !== 'Generated' && lic.status !== 'Trial') {
      return json({ error: 'already_activated', message: 'Key ini sudah diaktivasi' }, 409);
    }

    // Satu lisensi berlaku untuk SEMUA varian NUSA (signature varian-agnostic),
    // jadi mismatch product tidak ditolak. Saat aktivasi dari varian lain,
    // migrasikan product lisensi agar action CHECK (yang tidak difilter
    // product) tetap konsisten.
    if (lic.product !== prod) {
      await env.DB.prepare('UPDATE licenses SET product = ? WHERE id = ?')
        .bind(prod, lic.id)
        .run();
    }

    // 3. Cek can_activate
    const can = await canActivate(env, lic.id, googleUserId);
    if (!can) {
      return json(
        {
          error: 'already_activated',
          message:
            'Akun Google ini sudah dipakai untuk license lain. Gunakan license yang sama atau hubungi seller.',
        },
        409,
      );
    }

    // 4. Link Google ID ke lisensi + set status Active
    // v2.2.53 fix: update ini dulu diam-diam gagal (tanpa error check) —
    // lisensi terpakai di app tapi tetap Generated + uid/owner kosong, jadi
    // revoke tidak pernah bisa memblokir device manapun (server tidak tahu
    // pemiliknya). Sekarang kegagalan update = db_error eksplisit.
    const updates: string[] = ["status = 'Active'"];
    const updateBinds: unknown[] = [];
    if (!lic.google_user_id) {
      updates.push('google_user_id = ?');
      updateBinds.push(googleUserId);
    }
    if (!lic.owner_email && ownerEmail) {
      updates.push('owner_email = ?');
      updateBinds.push(ownerEmail);
    }
    try {
      await env.DB.prepare(`UPDATE licenses SET ${updates.join(', ')} WHERE id = ?`)
        .bind(...updateBinds, lic.id)
        .run();
    } catch (e: any) {
      return json({ error: 'db_error', message: String(e?.message ?? e) }, 500);
    }

    // 5. Insert record aktivasi
    try {
      await env.DB.prepare(
        'INSERT INTO activations (id, license_id, google_user_id, device_id) VALUES (?, ?, ?, ?)'
      )
        .bind(uid(), lic.id, googleUserId, 'android-' + googleUserId.slice(0, 12))
        .run();
    } catch (e: any) {
      // PG 23505 (unique_violation) → D1: "UNIQUE constraint failed"
      if (String(e?.message ?? '').includes('UNIQUE')) {
        // Sudah pernah aktivasi dari device yang sama — pastikan ownership
        // tetap terisi (row lama bisa dibuat sebelum fix linking).
        if (!lic.google_user_id || !lic.owner_email) {
          const sets: string[] = [];
          const binds: unknown[] = [];
          if (!lic.google_user_id) {
            sets.push('google_user_id = ?');
            binds.push(googleUserId);
          }
          if (!lic.owner_email && ownerEmail) {
            sets.push('owner_email = ?');
            binds.push(ownerEmail);
          }
          if (sets.length > 0) {
            await env.DB.prepare(`UPDATE licenses SET ${sets.join(', ')} WHERE id = ?`)
              .bind(...binds, lic.id)
              .run();
          }
        }
        return json(
          {
            success: true,
            message: 'Sudah teraktivasi sebelumnya',
            expires_at: lic.expires_at,
          },
          200,
        );
      }
      return json({ error: 'db_error', message: String(e?.message ?? e) }, 500);
    }

    return json({ success: true, expires_at: lic.expires_at }, 200);
  } catch (e: any) {
    return json({ error: 'server_error', message: String(e) }, 500);
  }
}

// ─── Registrasi route ────────────────────────────────────────────────

// Dispatch tetap pada presence of `key` di body (identik dengan edge fn).
Router.registerAll('register-activation', {
  check: handleRegisterActivation,
  activate: handleRegisterActivation,
});
