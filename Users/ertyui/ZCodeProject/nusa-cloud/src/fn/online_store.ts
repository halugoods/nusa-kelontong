// ============================================================================
// NUSA KASIR — Online Store (port edge fn `online-store` → Cloudflare Worker)
// ============================================================================
// Handles all admin operations for the online store:
//   action: 'upsert_store'      — create/update store settings (slug unik per variant)
//   action: 'check_slug'        — cek ketersediaan slug (untuk input real-time)
//   action: 'sync_products'     — batch upsert products for a store
//   action: 'get_orders'        — get online orders for a store
//   action: 'update_order'      — update order status (state machine)
//   action: 'get_store'         — get store settings
//   action: 'get_store_by_variant_slug' — public storefront lookup
//   action: 'submit_order'      — order dari web storefront (WA normalize + anti-dobel customer + poin + promo + referral)
//   action: 'redeem_points'     — tukar poin member (validasi saldo)
//   action: 'sync_branches'     — upload cabang Aktif + WA per cabang → tabel branches
//   action: 'sync_promos'       — upload promo (quota/periode/minSpend/limitPerUser) → tabel promos
//   action: 'get_promos'        — read-back promo milik store
//   action: 'sync_print_form_configs' — cadangan config field form Order Cetak (replace-all per store)
//   action: 'get_print_form_configs'  — read-back config field form Order Cetak
//
// Port notes (Supabase → D1):
//   * PostgREST query → prepared statements (payload HTTP 1:1).
//   * Kolom boolean pg → INTEGER 0/1; dikonversi balik ke boolean di respons
//     supaya bentuk payload sama dengan edge fn lama.
//   * Kolom JSON (order_types, items, promo_history, fields_json, …) → TEXT;
//     ditulis via stringify, dibaca via parseJson (semantik jsonb).
//   * online_products.original_price TIDAK ada di schema D1 → field di-drop
//     saat sync (tidak dibaca balik oleh action manapun).
//   * Realtime: order_new / order_updated di-publish ke room `orders:{store_id}`
//     (pengganti channel realtime Supabase; opsional, gagal diabaikan).
//   * Registrasi Router side-effect saat import — modul ini HARUS di-import
//     oleh entry (src/index.ts / aggregator) agar route terdaftar.
// ============================================================================

import { Router, json, errorJson, type FnContext } from '../router';
import { publishToRoom } from '../room';
import { nowIso, parseJson } from './db';

type Row = Record<string, any>;
type Ctx = FnContext;
type Handler = (ctx: Ctx, p: Row) => Promise<Response>;

// ─── WA normalize (adaptasi GAS normalizePhoneTo08 + formatWA) ──────
// Simpan selalu bentuk 08xx (strip non-digit, 62→0, 8→08).
function normalizePhoneTo08(phone: any): string {
  if (!phone) return '';
  const clean = String(phone).replace(/[^0-9]/g, '');
  if (clean.startsWith('62')) return '0' + clean.substring(2);
  if (clean.startsWith('8')) return '0' + clean;
  return clean;
}
// wa.me butuh 62xx — 08xx → 62xx.
function formatWA(phone: string): string {
  const n = normalizePhoneTo08(phone);
  if (!n) return '';
  return '62' + n.substring(1);
}

// ─── Konversi tipe (pg → SQLite) ─────────────────────────────────────
/** boolean pg → INTEGER 0/1. */
function toInt(v: unknown): number {
  return v ? 1 : 0;
}
/** Nilai JSON kolom: string JSON dari app → disimpan apa adanya; object/array → stringify (semantik jsonb). */
function asText(v: unknown): string | null {
  if (v === undefined || v === null) return null;
  if (typeof v === 'string') return v;
  return JSON.stringify(v);
}
/** Baca kolom JSON/TEXT balik ke bentuk payload Supabase (jsonb): parse bila bisa, else apa adanya. */
function jsonish(v: unknown): unknown {
  return parseJson<unknown>(v, v as unknown);
}

// ─── Slug helpers ────────────────────────────────────────────────────
// Slug hanya huruf kecil, angka, dan tanda hubung. Panjang maks 40.
function isValidSlug(slug: string): boolean {
  return /^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug) && slug.length <= 40;
}

// Level member dari poin — konsisten dengan web (src/lib/supabase.ts).
function memberLevelOf(points: number, member: Row): string {
  const goldMin = Number(member.goldMin) || 1000;
  const platinumMin = Number(member.platinumMin) || 5000;
  if (points >= platinumMin) return 'Platinum';
  if (points >= goldMin) return 'Gold';
  return 'Silver';
}

/**
 * Payload store_settings → bentuk Supabase.
 * is_active: pg BOOLEAN → INTEGER 0/1 dikonversi balik ke boolean.
 * order_types/pickup_options/payment_methods/member_settings: di Supabase
 * kolomnya TEXT (bukan jsonb — lihat migrasi nusa-online 0012) → dikirim
 * mentah sebagai string JSON; web parse sendiri via parseJson client-side.
 * Jadi jangan di-parse di sini — kirim persis seperti Supabase.
 */
function storePayload(row: Row): Row {
  return { ...row, is_active: !!row.is_active };
}

/** Payload order → bentuk Supabase (items jsonb ter-parse). */
function orderPayload(row: Row): Row {
  return { ...row, items: jsonish(row.items) };
}

/** Realtime opsional: publish event ke room orders:{store_id} (gagal diabaikan). */
async function publishOrderEvent(ctx: Ctx, storeId: string, event: string, extra: Row): Promise<void> {
  try {
    await publishToRoom(ctx.env, `orders:${storeId}`, { event, store_id: storeId, ...extra });
  } catch {
    // realtime opsional — jangan gagalkan request
  }
}

// ─── Upsert store settings ──────────────────────────────────────────
// Identitas toko: user_id (Google UID) + variant. store_id (= activation
// key) tetap disimpan untuk kompatibilitas data lama (produk/order).
// Alur:
//   1. user_id + variant → cari row milik user tsb; jika ada → UPDATE row itu.
//   2. Jika belum ada tapi ada row dengan store_id sama (milik user tsb,
//      dibuat sebelum migrasi user_id) → KLAIM: set user_id ke row itu.
//   3. Jika belum ada sama sekali → INSERT row baru dengan store_id + user_id.
// Slug unik per (user_id, variant) — toko milik user lain dengan variant
// sama TIDAK boleh pakai slug yang sama (409 slug_taken).
async function upsertStore(ctx: Ctx, p: Row): Promise<Response> {
  const db = ctx.env.DB;
  const storeId = p.store_id as string | undefined;
  if (!storeId) return errorJson('store_id required', 400);

  const userId = p.user_id ? String(p.user_id) : null;
  const varId = p.variant == null ? '' : String(p.variant);

  // Ambil row milik user (by user_id+variant), lalu by store_id (legacy).
  const userRow = await db
    .prepare('SELECT store_id FROM store_settings WHERE user_id IS ? AND variant = ? LIMIT 1')
    .bind(userId, varId)
    .first<{ store_id: string }>();
  // SELALU query legacy by store_id — user tanpa Google login (user_id null)
  // tetap harus bisa UPDATE row lama; kalau hanya query saat uid, mereka
  // jatuh ke INSERT yang bentrok → 500 "server sibuk" (fix v2.2.57+116).
  const legacyRow = await db
    .prepare('SELECT store_id FROM store_settings WHERE store_id = ?')
    .bind(storeId)
    .first<{ store_id: string }>();

  // Slug unik per (user_id, variant): cek hanya antar row MILIK USER yang
  // bukan row target. Row user lain tidak menghalangi (anti rebutan slug).
  const slug = p.slug === undefined ? undefined : p.slug === null ? null : String(p.slug);
  if (slug !== undefined && slug !== null && slug !== '') {
    if (!isValidSlug(slug)) return errorJson('slug_invalid', 400);
    const targetStoreId0 = userRow?.store_id ?? legacyRow?.store_id ?? storeId;
    const existing = await db
      .prepare('SELECT store_id FROM store_settings WHERE variant = ? AND slug = ? AND store_id <> ? LIMIT 1')
      .bind(varId, slug, targetStoreId0)
      .first<{ store_id: string }>();
    // Kalau yang punya slug sama adalah row MILIK USER ini sendiri di
    // store_id lain (mis. varian lama) → row itu akan di-klaim/diupdate
    // lewat userRow, jadi tidak dianggap konflik. Konflik hanya bila
    // slug dipegang row milik user LAIN (user_id beda & bukan null).
    if (existing) {
      const owner = await db
        .prepare('SELECT user_id FROM store_settings WHERE store_id = ?')
        .bind(existing.store_id)
        .first<{ user_id: string | null }>();
      const ownerIsSelf = !!userId && owner?.user_id === userId;
      if (!ownerIsSelf) return errorJson('slug_taken', 409);
    }
  }

  const cols: Row = {
    store_name: p.store_name ?? '',
    description: p.description ?? '',
    whatsapp: p.whatsapp ? normalizePhoneTo08(p.whatsapp) : '', // WA selalu 08xx
    address: p.address ?? '',
    open_hours: p.open_hours ?? '08:00 - 21:00',
    is_active: toInt(p.is_active ?? false),
    slug: slug ?? '',
    variant: varId,
    theme_id: p.theme_id ?? '',
    primary_color: p.primary_color ?? '',
    dark_color: p.dark_color ?? '',
    soft_color: p.soft_color ?? '',
    updated_at: nowIso(),
  };
  if (userId) cols.user_id = userId;
  // Kolom ekstra (C1) — hanya ditulis bila dikirim (JSON string dari app).
  if (p.order_types !== undefined) cols.order_types = asText(p.order_types);
  if (p.delivery_fee !== undefined) cols.delivery_fee = Number(p.delivery_fee) || 0;
  if (p.pickup_options !== undefined) cols.pickup_options = asText(p.pickup_options);
  if (p.payment_methods !== undefined) cols.payment_methods = asText(p.payment_methods);
  if (p.member_settings !== undefined) cols.member_settings = asText(p.member_settings);
  if (p.logo_url !== undefined) cols.logo_url = p.logo_url === null ? null : String(p.logo_url);

  // Target: row milik user (userRow), lalu row legacy by store_id,
  // lalu insert baru. Sumber .update(row) menyertakan store_id (params) →
  // row target ikut di-re-key bila activation key berubah (perilaku sama).
  const targetId = userRow?.store_id ?? legacyRow?.store_id;
  if (targetId) {
    const setSql = ['store_id = ?', ...Object.keys(cols).map((k) => `${k} = ?`)].join(', ');
    await db
      .prepare(`UPDATE store_settings SET ${setSql} WHERE store_id = ?`)
      .bind(storeId, ...Object.values(cols), targetId)
      .run();
    return json({ ok: true, store_id: targetId, claimed: !!(legacyRow && !userRow) });
  }

  // INSERT baru (upsert ON CONFLICT(store_id) — store_id adalah PK).
  const keys = ['store_id', 'created_at', ...Object.keys(cols)];
  const placeholders = keys.map(() => '?').join(', ');
  const updates = Object.keys(cols)
    .map((k) => `${k} = excluded.${k}`)
    .join(', ');
  await db
    .prepare(
      `INSERT INTO store_settings (${keys.join(', ')}) VALUES (${placeholders}) ` +
        `ON CONFLICT(store_id) DO UPDATE SET ${updates}`,
    )
    .bind(storeId, nowIso(), ...Object.values(cols))
    .run();
  return json({ ok: true, store_id: storeId });
}

// ─── Cek ketersediaan slug (real-time saat user mengetik) ───────────
// Slug dianggap TERSEDIA bila tidak ada row varian sama yang memakainya
// KECUALI row itu milik user yang sama (row sendiri tidak menghalangi).
async function checkSlug(ctx: Ctx, p: Row): Promise<Response> {
  const db = ctx.env.DB;
  const slug = String(p.slug ?? '');
  if (!slug) return errorJson('slug required', 400);
  if (!isValidSlug(slug)) {
    return json({ available: false, reason: 'invalid' });
  }
  const variant = p.variant == null ? '' : String(p.variant);

  const data = await db
    .prepare('SELECT store_id, user_id FROM store_settings WHERE variant = ? AND slug = ? LIMIT 1')
    .bind(variant, slug)
    .first<{ store_id: string; user_id: string | null }>();

  // Row sendiri (user_id sama) → bukan "taken".
  if (data && p.user_id && data.user_id === String(p.user_id)) {
    return json({ available: true, reason: 'ok' });
  }
  return json({ available: !data, reason: data ? 'taken' : 'ok' });
}

// ─── Sync products (batch upsert, dedupe by product_id) ─────────────
// v2.2.57+120: DELETE+INSERT batch sebelumnya 500 "server sibuk" kalau
// daftar produk mengandung product_id duplikat (id dobel dari restore/
// import) → melanggar unique index (store_id, product_id). Sekarang:
//   1. dedupe by product_id (last-wins) — sync tidak pernah gagal total
//      gara-gara 1 produk bermasalah;
//   2. DELETE all dulu (clean sync, produk non-online dihapus dari web),
//      lalu INSERT batch yang sudah bersih.
// Catatan: original_price (source Supabase) tidak ada di schema D1 → drop.
async function syncProducts(ctx: Ctx, p: Row): Promise<Response> {
  const db = ctx.env.DB;
  const storeId = p.store_id as string | undefined;
  if (!storeId) return errorJson('store_id required', 400);
  const products = p.products;
  if (!products || !Array.isArray(products)) return errorJson('products array required', 400);

  const byId = new Map<string, unknown[]>();
  for (const raw of products as Row[]) {
    const pid = raw.product_id;
    if (pid === undefined || pid === null || pid === '') continue; // skip row tanpa id
    // product_id INTEGER di schema D1 — cast ke Number agar bind selalu
    // integer (PostgREST coerce otomatis; SQLite tidak).
    const pidNum = Number(pid);
    if (!Number.isFinite(pidNum)) continue; // id non-numerik → skip (bukan crash)
    // Last-wins: kalau product_id sama muncul 2x, pakai baris terakhir.
    byId.set(String(pid), [
      storeId,
      pidNum,
      raw.name ?? '',
      raw.category ?? 'Lainnya',
      raw.price ?? 0,
      raw.stock ?? 0,
      raw.image ?? '',
      raw.description ?? '',
      toInt(raw.is_published ?? true),
    ]);
  }
  const rows = [...byId.values()];

  // Delete old products, then insert clean batch (clean sync).
  await db.prepare('DELETE FROM online_products WHERE store_id = ?').bind(storeId).run();

  if (rows.length > 0) {
    // Chunk insert biar tidak kena payload limit / row limit (batch besar).
    // Catatan port: original_price & updated_at (ada di Supabase migration
    // 0012) TIDAK ada di schema D1 → tidak ditulis.
    for (let i = 0; i < rows.length; i += 500) {
      const chunk = rows.slice(i, i + 500);
      await db.batch(
        chunk.map((r) =>
          db
            .prepare(
              'INSERT INTO online_products (store_id, product_id, name, category, price, stock, image_url, description, is_published) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
            )
            .bind(...r),
        ),
      );
    }
  }

  return json({ ok: true, count: rows.length, skipped: products.length - rows.length });
}

// ─── Get orders for a store ────────────────────────────────────────
async function getOrders(ctx: Ctx, p: Row): Promise<Response> {
  const db = ctx.env.DB;
  const storeId = p.store_id as string | undefined;
  if (!storeId) return errorJson('store_id required', 400);

  const status = p.status == null || p.status === '' ? '' : String(p.status);
  const limitNum = Number(p.limit);
  const limit = p.limit != null && Number.isFinite(limitNum) ? Math.max(1, Math.floor(limitNum)) : 50;

  let sql = 'SELECT * FROM online_orders WHERE store_id = ?';
  const binds: unknown[] = [storeId];
  if (status) {
    sql += ' AND status = ?';
    binds.push(status);
  }
  sql += ' ORDER BY created_at DESC LIMIT ?';
  binds.push(limit);

  const res = await db.prepare(sql).bind(...binds).all<Row>();
  return json({ orders: (res.results ?? []).map(orderPayload) });
}

// ─── Update order status (state machine) ───────────────────────────
// Status baru (v2.2.23):
//   "Menunggu Verifikasi Pembeli" → [Online Baru, Dibatalkan]   (non-tunai: kasir cek bukti)
//   "Online Baru"                 → [Disiapkan, Dibatalkan]
//   "Disiapkan"                   → [Siap Diambil, Dibatalkan]
//   "Siap Diambil"                → [Lunas, Dibatalkan]
//   "Lunas"                       → [Direfund]
//   "Direfund"                    → []   (terminal)
//   "Dibatalkan"                  → []
async function updateOrder(ctx: Ctx, p: Row): Promise<Response> {
  const db = ctx.env.DB;
  // v2.2.57+130 (A1.5): app kini mengirim `invoice` (kunci bersama app ↔
  // server). `order_id` tetap diterima untuk kompatibilitas dashboard lama.
  const storeId = p.store_id as string | undefined;
  const orderId = p.order_id as string | undefined;
  const invoice = p.invoice as string | undefined;
  const status = p.status as string | undefined;
  const processedBy = p.processed_by as string | undefined;
  if (!storeId || (!orderId && !invoice) || !status) {
    return errorJson('store_id, invoice (atau order_id), status required', 400);
  }

  // Validate state transition
  const validTransitions: Record<string, string[]> = {
    'Menunggu Verifikasi Pembeli': ['Online Baru', 'Dibatalkan'],
    'Online Baru': ['Disiapkan', 'Dibatalkan'],
    Disiapkan: ['Siap Diambil', 'Dibatalkan'],
    'Siap Diambil': ['Lunas', 'Dibatalkan'],
    Lunas: ['Direfund'],
    Direfund: [],
    Dibatalkan: [],
  };

  // Get current status — lookup by invoice bila ada, fallback order_id.
  // id INTEGER di SQLite → cast Number (PostgREST otomatis coerce; SQLite tidak).
  // order_id non-numerik → "Order not found" (D1 tidak bisa bind NaN).
  const byInvoice = !!invoice;
  const keyCol = byInvoice ? 'invoice' : 'id';
  const orderIdNum = Number(orderId);
  if (!byInvoice && !Number.isFinite(orderIdNum)) return errorJson('Order not found', 404);
  const keyValue: unknown = byInvoice ? invoice : orderIdNum;
  const existing = await db
    .prepare(
      `SELECT id, status, used_points, customer_phone, store_id FROM online_orders WHERE ${keyCol} = ? AND store_id = ? LIMIT 1`,
    )
    .bind(keyValue, storeId)
    .first<{ id: number; status: string; used_points: number | null; customer_phone: string | null; store_id: string }>();

  if (!existing) return errorJson('Order not found', 404);

  const currentStatus = existing.status;
  const allowed = validTransitions[currentStatus];
  if (!allowed || !allowed.includes(status)) {
    return json({ error: `Cannot transition from '${currentStatus}' to '${status}'`, allowed }, 400);
  }

  // Lunas: akumulasi poin + total_spent ke online_customers (GAS pattern).
  if (status === 'Lunas' && ((existing.used_points ?? 0) > 0 || existing.customer_phone)) {
    await applyOrderToCustomer(ctx, storeId, existing as Row, p);
  }

  const sets: string[] = ['status = ?', 'updated_at = ?'];
  const binds: unknown[] = [status, nowIso()];
  if (processedBy) {
    sets.push('processed_by = ?');
    binds.push(processedBy);
  }
  binds.push(keyValue, storeId);
  await db
    .prepare(`UPDATE online_orders SET ${sets.join(', ')} WHERE ${keyCol} = ? AND store_id = ?`)
    .bind(...binds)
    .run();

  await publishOrderEvent(ctx, storeId, 'order_updated', {
    invoice: byInvoice ? invoice : null,
    order_id: orderId ?? null,
    status,
  });

  return json({ ok: true, status });
}

// Akumulasi ke online_customers saat Lunas: total_spent, poin earned,
// referral reward untuk referrer, promo history. Di-call dari update_order
// (kasir konfirmasi Lunas) — order sudah final.
async function applyOrderToCustomer(ctx: Ctx, storeId: string, order: Row, _params: Row): Promise<void> {
  try {
    const db = ctx.env.DB;
    const phone = normalizePhoneTo08(order.customer_phone);
    if (!phone) return;

    // Ambil store settings (member_settings: poin rate + referral).
    const store = await db
      .prepare('SELECT store_id, member_settings FROM store_settings WHERE store_id = ?')
      .bind(storeId)
      .first<{ store_id: string; member_settings: string | null }>();
    let member: Row = { pointEarnPercent: 0, referralRewardType: 'nominal', referralRewardValue: 0, goldMin: 1000, platinumMin: 5000 };
    const ms = parseJson<unknown>(store?.member_settings, {});
    if (ms && typeof ms === 'object' && !Array.isArray(ms)) {
      member = { ...member, ...(ms as Row) };
    }

    // Order detail (used_points, promo) sudah di kolom online_orders.
    const ord = await db
      .prepare('SELECT id, total, used_points, used_promo_id, promo_discount, referred_by, customer_name FROM online_orders WHERE id = ?')
      .bind(order.id)
      .first<Row>();
    if (!ord) return;

    const total = Number(ord.total) || 0;
    const usedPoints = Number(ord.used_points) || 0;
    const earned = Math.floor((total * (Number(member.pointEarnPercent) || 0)) / 100);

    // Upsert customer by (store_id, phone) — anti-dobel: update nama & akumulasi.
    const existing = await db
      .prepare('SELECT id, points, total_spent, promo_history, name FROM online_customers WHERE store_id = ? AND phone = ? LIMIT 1')
      .bind(storeId, phone)
      .first<Row>();

    if (existing) {
      const historyRaw = parseJson<unknown>(existing.promo_history, []);
      const history = Array.isArray(historyRaw) ? historyRaw : [];
      if (ord.used_promo_id && !history.some((h: Row) => h.promo_id === ord.used_promo_id)) {
        history.push({ promo_id: ord.used_promo_id, used_at: nowIso() });
      }
      const newPoints = (Number(existing.points) || 0) + earned - usedPoints;
      // name: ord.customer_name || existing.name — bila keduanya kosong,
      // nama lama dipertahankan (COALESCE).
      const newName = ord.customer_name || existing.name || null;
      await db
        .prepare(
          'UPDATE online_customers SET name = COALESCE(?, name), points = ?, level = ?, total_spent = ?, promo_history = ?, updated_at = ? WHERE id = ?',
        )
        .bind(newName, newPoints, memberLevelOf(newPoints, member), (Number(existing.total_spent) || 0) + total, JSON.stringify(history), nowIso(), existing.id)
        .run();
    } else {
      const history = ord.used_promo_id ? [{ promo_id: ord.used_promo_id, used_at: nowIso() }] : [];
      const newPoints = earned - usedPoints;
      const newCust = await db
        .prepare(
          'INSERT INTO online_customers (store_id, name, phone, total_spent, points, level, promo_history, referred_by, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id, referred_by',
        )
        .bind(
          storeId,
          ord.customer_name || 'Pelanggan',
          phone,
          total,
          newPoints,
          memberLevelOf(newPoints, member),
          JSON.stringify(history),
          normalizePhoneTo08(ord.referred_by || ''),
          nowIso(),
          nowIso(),
        )
        .first<{ id: string; referred_by: string | null }>();

      // Ajak teman: reward referrer HANYA untuk customer BARU (GAS pattern).
      const refPhone = normalizePhoneTo08(ord.referred_by || '');
      if (newCust && refPhone && refPhone !== phone) {
        let refPts = 0;
        if (member.referralRewardType === 'persen') {
          refPts = Math.floor((total * (Number(member.referralRewardValue) || 0)) / 100);
        } else {
          refPts = Number(member.referralRewardValue) || 0;
        }
        if (refPts > 0) {
          const ref = await db
            .prepare('SELECT id, points FROM online_customers WHERE store_id = ? AND phone = ? LIMIT 1')
            .bind(storeId, refPhone)
            .first<Row>();
          if (ref) {
            const refPoints = (Number(ref.points) || 0) + refPts;
            await db
              .prepare('UPDATE online_customers SET points = ?, level = ?, updated_at = ? WHERE id = ?')
              .bind(refPoints, memberLevelOf(refPoints, member), nowIso(), ref.id)
              .run();
          }
        }
      }
    }
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.warn('[applyOrderToCustomer] failed (non-blocking):', msg);
  }
}

// ─── Submit order (web storefront / direct) ─────────────────────────
// Non-tunai → status "Menunggu Verifikasi Pembeli" (kasir cek bukti dulu).
// Tunai → "Online Baru". WA dinormalisasi 08xx; customer anti-dobel.
async function submitOrder(ctx: Ctx, p: Row): Promise<Response> {
  const db = ctx.env.DB;
  const storeId = p.store_id as string | undefined;
  const customerName = p.customer_name as string | undefined;
  const customerPhone = p.customer_phone as string | undefined;
  const items = p.items;
  if (!storeId || !customerPhone || !items || !Array.isArray(items)) {
    return errorJson('store_id, customer_phone, items required', 400);
  }

  const phone = normalizePhoneTo08(customerPhone);
  if (!phone) return errorJson('Nomor WhatsApp tidak valid', 400);

  const invoice = `ONL-${nowIso().replace(/[-:T]/g, '').slice(2, 14)}`;
  const isTunai = String(p.payment_method || '').toLowerCase().includes('tunai');
  // GAS initStatus: tunai → "Online Baru"; non-tunai → "Menunggu Verifikasi Pembeli".
  const initStatus = isTunai ? 'Online Baru' : 'Menunggu Verifikasi Pembeli';

  await db
    .prepare(
      'INSERT INTO online_orders (store_id, invoice, customer_name, customer_phone, items, subtotal, discount, promo_code, handling_fee, total, payment_method, pickup_time, branch, notes, order_type, used_points, used_promo_id, promo_discount, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    )
    .bind(
      storeId,
      invoice,
      customerName ?? 'Pelanggan',
      phone,
      JSON.stringify(items),
      Number(p.subtotal) || 0,
      Number(p.discount) || 0,
      p.promo_code ?? '',
      Number(p.handling_fee) || 0,
      Number(p.total) || 0,
      p.payment_method ?? 'Tunai',
      p.pickup_time ?? 'Segera',
      p.branch ?? 'Pusat',
      p.notes ?? '',
      p.order_type ?? '',
      Number(p.used_points) || 0,
      p.used_promo_id ?? null,
      Number(p.promo_discount) || 0,
      initStatus,
      nowIso(),
      nowIso(),
    )
    .run();

  // Anti-dobel customer: lookup by (store_id, phone ternormalisasi) →
  // update nama + akumulasi, BUKAN insert baru ("Adi"/"adi" = 1 pelanggan).
  try {
    const existing = await db
      .prepare('SELECT id FROM online_customers WHERE store_id = ? AND phone = ? LIMIT 1')
      .bind(storeId, phone)
      .first<{ id: string }>();
    if (existing) {
      await db
        .prepare('UPDATE online_customers SET name = ?, updated_at = ? WHERE id = ?')
        .bind(customerName ?? '', nowIso(), existing.id)
        .run();
    } else {
      await db
        .prepare('INSERT INTO online_customers (store_id, name, phone, referred_by, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)')
        .bind(storeId, customerName ?? 'Pelanggan', phone, normalizePhoneTo08(p.referred_by || ''), nowIso(), nowIso())
        .run();
    }
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.warn('[submitOrder] customer upsert failed (non-blocking):', msg);
  }

  // WA link tujuan: store.whatsapp (08xx → 62xx).
  const store = await db
    .prepare('SELECT store_name, whatsapp FROM store_settings WHERE store_id = ?')
    .bind(storeId)
    .first<{ store_name: string | null; whatsapp: string | null }>();
  const storeWa = formatWA(store?.whatsapp || '');
  const storeName = store?.store_name || 'Toko';

  const itemsText = (items as Row[])
    .map((i) => `• ${i.name} x${i.qty} — ${formatRupiah(i.subtotal ?? i.price * i.qty)}`)
    .join('\n');
  const waMessage = encodeURIComponent(
    `🛒 *Pesanan Baru — ${storeName}*\n\n` +
      `📋 *${invoice}*\n` +
      `👤 ${customerName}\n` +
      `📱 ${phone}\n` +
      `🏪 ${p.branch ?? 'Pusat'}\n` +
      `💳 ${p.payment_method}\n` +
      `🕐 ${p.pickup_time ?? 'Segera'}\n\n` +
      `*Item:*\n${itemsText}\n\n` +
      `💰 *Total: ${formatRupiah(Number(p.total) || 0)}*\n\n` +
      `_Catatan: ${p.notes || '-'}_`,
  );

  // v2.2.57+131: broadcast row order LENGKAP (bukan cuma invoice+status)
  // supaya app bisa insert langsung ke DB lokal via _handleRealtimeInsert.
  await publishOrderEvent(ctx, storeId, 'order_new', {
    invoice,
    status: initStatus,
    customer_name: customerName ?? 'Pelanggan',
    customer_phone: phone,
    items,
    subtotal: Number(p.subtotal) || 0,
    discount: Number(p.discount) || 0,
    handling_fee: Number(p.handling_fee) || 0,
    total: Number(p.total) || 0,
    payment_method: p.payment_method ?? 'Tunai',
    pickup_time: p.pickup_time ?? 'Segera',
    branch: p.branch ?? 'Pusat',
    notes: p.notes ?? '',
  });

  return json({
    ok: true,
    invoice,
    status: initStatus,
    whatsappUrl: storeWa ? `https://wa.me/${storeWa}?text=${waMessage}` : '',
  });
}

// ─── Redeem points (tukar poin member) ──────────────────────────────
async function redeemPoints(ctx: Ctx, p: Row): Promise<Response> {
  const db = ctx.env.DB;
  const storeId = p.store_id as string | undefined;
  const phone = p.phone as string | undefined;
  const points = p.points as number | undefined;
  if (!storeId || !phone || !points || Number(points) <= 0) {
    return errorJson('store_id, phone, points required', 400);
  }
  const ph = normalizePhoneTo08(phone);
  const pts = Number(points);

  const cust = await db
    .prepare('SELECT id, points FROM online_customers WHERE store_id = ? AND phone = ? LIMIT 1')
    .bind(storeId, ph)
    .first<{ id: string; points: number | null }>();
  if (!cust) return errorJson('Customer not found', 404);
  if ((Number(cust.points) || 0) < pts) {
    return json({ error: 'Poin tidak cukup', available: cust.points }, 400);
  }

  // Ambil member_settings untuk hitung ulang level setelah tukar poin.
  let member: Row = {};
  try {
    const store = await db
      .prepare('SELECT member_settings FROM store_settings WHERE store_id = ?')
      .bind(storeId)
      .first<{ member_settings: string | null }>();
    member = parseJson<Row>(store?.member_settings, {}) ?? {};
  } catch {
    // member_settings optional
  }

  const pointsLeft = (Number(cust.points) || 0) - pts;
  await db
    .prepare('UPDATE online_customers SET points = ?, level = ?, updated_at = ? WHERE id = ?')
    .bind(pointsLeft, memberLevelOf(pointsLeft, member), nowIso(), cust.id)
    .run();

  return json({ ok: true, points_left: pointsLeft });
}

// ─── Sync branches (cabang toko online + WA per cabang) ─────────────
// Dedupe by name (unique idx_branches_store_name) — nama dobel tidak
// boleh menggagalkan seluruh sync (v2.2.57+120).
async function syncBranches(ctx: Ctx, p: Row): Promise<Response> {
  const db = ctx.env.DB;
  const storeId = p.store_id as string | undefined;
  if (!storeId) return errorJson('store_id required', 400);
  const branches = p.branches;
  if (!branches || !Array.isArray(branches)) {
    return errorJson('branches array required', 400);
  }

  await db.prepare('DELETE FROM branches WHERE store_id = ?').bind(storeId).run();

  if (branches.length > 0) {
    const byName = new Map<string, unknown[]>();
    (branches as Row[]).forEach((b, i) => {
      const name = String(b.name ?? '').trim();
      if (!name) return;
      byName.set(name, [
        storeId,
        name,
        normalizePhoneTo08(b.phone || ''),
        toInt(b.is_active ?? true),
        i,
      ]);
    });
    const rows = [...byName.values()];
    if (rows.length > 0) {
      await db.batch(
        rows.map((r) =>
          db
            .prepare('INSERT INTO branches (store_id, name, phone, is_active, sort, created_at) VALUES (?, ?, ?, ?, ?, ?)')
            .bind(r[0], r[1], r[2], r[3], r[4], nowIso()),
        ),
      );
    }
    return json({ ok: true, count: rows.length, skipped: branches.length - rows.length });
  }

  return json({ ok: true, count: 0 });
}

// ─── Sync promos (kupon online) ─────────────────────────────────────
// Dedupe by code (unique idx_promos_store_code) — kode dobel tidak
// boleh menggagalkan seluruh sync (v2.2.57+120).
async function syncPromos(ctx: Ctx, p: Row): Promise<Response> {
  const db = ctx.env.DB;
  const storeId = p.store_id as string | undefined;
  if (!storeId) return errorJson('store_id required', 400);
  const promos = p.promos;
  if (!promos || !Array.isArray(promos)) {
    return errorJson('promos array required', 400);
  }

  await db.prepare('DELETE FROM promos WHERE store_id = ?').bind(storeId).run();

  if (promos.length > 0) {
    const byCode = new Map<string, unknown[]>();
    for (const raw of promos as Row[]) {
      const code = String(raw.code ?? '').trim().toUpperCase();
      if (!code) continue;
      byCode.set(code, [
        storeId,
        code,
        raw.title ?? raw.code ?? '',
        raw.type ?? 'persen', // persen | nominal
        Number(raw.value) || 0,
        Number(raw.min_spend) || 0,
        raw.quota === undefined || raw.quota === null ? null : Number(raw.quota),
        raw.limit_per_user === undefined || raw.limit_per_user === null ? null : Number(raw.limit_per_user),
        raw.start_date ?? null,
        raw.end_date ?? null,
        toInt(raw.is_active ?? true),
      ]);
    }
    const rows = [...byCode.values()];
    if (rows.length > 0) {
      await db.batch(
        rows.map((r) =>
          db
            .prepare(
              'INSERT INTO promos (store_id, code, title, type, value, min_spend, quota, limit_per_user, start_date, end_date, is_active, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            )
            .bind(r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10], nowIso()),
        ),
      );
    }
    return json({ ok: true, count: rows.length, skipped: promos.length - rows.length });
  }

  return json({ ok: true, count: 0 });
}

// ─── Get promos (admin app read-back untuk CRUD kupon) ────────────
async function getPromos(ctx: Ctx, p: Row): Promise<Response> {
  const db = ctx.env.DB;
  const storeId = p.store_id as string | undefined;
  if (!storeId) return errorJson('store_id required', 400);
  const res = await db
    .prepare('SELECT * FROM promos WHERE store_id = ? ORDER BY created_at DESC')
    .bind(storeId)
    .all<Row>();
  // is_active INTEGER 0/1 → boolean (bentuk payload Supabase).
  return json({ promos: (res.results ?? []).map((r) => ({ ...r, is_active: !!r.is_active })) });
}

// ─── Print form configs (Order Cetak — field per layanan) ──────────
// Cadangan cloud dari config field form per layanan percetakan.
// Store keyed by store_id (sama dengan tabel lain). Web tidak memakai —
// murni supaya config tidak hilang saat clear-data / ganti device.
async function syncPrintFormConfigs(ctx: Ctx, p: Row): Promise<Response> {
  const db = ctx.env.DB;
  const storeId = p.store_id as string | undefined;
  if (!storeId) return errorJson('store_id required', 400);
  const configs = p.configs;
  if (!configs || !Array.isArray(configs)) {
    return errorJson('configs array required', 400);
  }

  await db.prepare('DELETE FROM print_form_configs WHERE store_id = ?').bind(storeId).run();

  if (configs.length === 0) return json({ ok: true, count: 0 });

  // Dedupe by service_name — nama layanan dobel tidak menggagalkan sync.
  const byService = new Map<string, unknown[]>();
  for (const raw of configs as Row[]) {
    const name = String(raw.service_name ?? '').trim();
    if (!name) continue;
    byService.set(name, [storeId, name, raw.fields_json ?? null, nowIso()]);
  }
  const rows = [...byService.values()];
  await db.batch(
    rows.map((r) =>
      db
        .prepare('INSERT INTO print_form_configs (store_id, service_name, fields_json, updated_at, created_at) VALUES (?, ?, ?, ?, ?)')
        .bind(r[0], r[1], r[2] === null ? null : asText(r[2]), r[3], nowIso()),
    ),
  );
  return json({ ok: true, count: rows.length, skipped: configs.length - rows.length });
}

async function getPrintFormConfigs(ctx: Ctx, p: Row): Promise<Response> {
  const db = ctx.env.DB;
  const storeId = p.store_id as string | undefined;
  if (!storeId) return errorJson('store_id required', 400);
  const res = await db
    .prepare('SELECT service_name, fields_json FROM print_form_configs WHERE store_id = ?')
    .bind(storeId)
    .all<Row>();
  // fields_json: di Supabase kolom TEXT (bukan jsonb) → dikirim verbatim
  // persis seperti edge fn lama (app yang parse).
  return json({ configs: (res.results ?? []).map((r) => ({ service_name: r.service_name, fields_json: r.fields_json ?? null })) });
}

// ─── Get store settings (admin app) ────────────────────────────
// TANPA filter is_active: app harus bisa membaca toko walau toggle
// OFF (mis. user baru saja mematikan lalu kembali ke layar). Storefront
// publik (getStoreByVariantSlug) yang memfilter is_active.
// Lookup: store_id (legacy) DULU, lalu fallback (user_id, variant) —
// supaya user yang clear-data + re-login (key mungkin beda) tetap
// menemukan setup lamanya.
async function getStore(ctx: Ctx, p: Row): Promise<Response> {
  const db = ctx.env.DB;
  const storeId = p.store_id as string | undefined;
  const userId = p.user_id as string | undefined;
  const variant = p.variant as string | undefined;
  if (!storeId && !(userId && variant)) {
    return errorJson('store_id (atau user_id+variant) required', 400);
  }

  let data: Row | null = null;
  if (storeId) {
    data = await db.prepare('SELECT * FROM store_settings WHERE store_id = ?').bind(storeId).first<Row>();
  }

  // Fallback: row milik user ini di varian ini (setup lama tetap ketemu).
  if (!data && userId && variant) {
    data = await db
      .prepare('SELECT * FROM store_settings WHERE user_id = ? AND variant = ? LIMIT 1')
      .bind(userId, variant)
      .first<Row>();
  }

  if (!data) return errorJson('Store not found', 404);

  return json({ store: storePayload(data) });
}

// ─── Public storefront lookup by slug only (legacy, tanpa variant) ──
async function getStoreBySlug(ctx: Ctx, p: Row): Promise<Response> {
  const db = ctx.env.DB;
  const slug = p.slug as string | undefined;
  if (!slug) return errorJson('slug required', 400);
  const data = await db
    .prepare('SELECT * FROM store_settings WHERE slug = ? AND is_active = 1 LIMIT 1')
    .bind(slug)
    .first<Row>();
  if (!data) return errorJson('Store not found or inactive', 404);
  return json({ store: storePayload(data) });
}

// ─── Public storefront lookup: /toko/{variant}/{slug} ──────────────
async function getStoreByVariantSlug(ctx: Ctx, p: Row): Promise<Response> {
  const db = ctx.env.DB;
  const variant = p.variant as string | undefined;
  const slug = p.slug as string | undefined;
  if (!variant || !slug) {
    return errorJson('variant and slug required', 400);
  }

  const data = await db
    .prepare('SELECT * FROM store_settings WHERE variant = ? AND slug = ? AND is_active = 1 LIMIT 1')
    .bind(variant, slug)
    .first<Row>();

  if (!data) return errorJson('Store not found or inactive', 404);

  return json({ store: storePayload(data) });
}

function formatRupiah(n: number): string {
  return `Rp ${(n || 0).toLocaleString('id-ID')}`;
}

// ─── Storefront read actions (pengganti PostgREST langsung di web) ──
// Web storefront dulu query PostgREST langsung (anon). Di arsitektur
// Cloudflare, pembacaan publik ini lewat worker dengan LIMIT ketat.
// Bentuk payload mengikuti src/lib/supabase.ts lama:
//   * is_published/is_active → boolean
//   * promos: end_date IS NULL OR >= now
//   * orders by phone: 08xx normalized, limit 30

async function getProductsPublic(ctx: Ctx, p: Row): Promise<Response> {
  const db = ctx.env.DB;
  const storeId = p.store_id as string | undefined;
  if (!storeId) return errorJson('store_id required', 400);
  const category = p.category as string | undefined;

  let sql = 'SELECT * FROM online_products WHERE store_id = ? AND is_published = 1';
  const binds: unknown[] = [storeId];
  if (category && category !== 'Semua') {
    sql += ' AND category = ?';
    binds.push(category);
  }
  sql += ' ORDER BY name ASC LIMIT 500';

  const res = await db.prepare(sql).bind(...binds).all<Row>();
  const products = (res.results ?? []).map((r) => ({
    ...r,
    is_published: !!r.is_published,
    original_price: null, // kolom tidak ada di D1 (lihat port notes)
  }));
  return json({ products });
}

async function getBranchesPublic(ctx: Ctx, p: Row): Promise<Response> {
  const db = ctx.env.DB;
  const storeId = p.store_id as string | undefined;
  if (!storeId) return errorJson('store_id required', 400);
  const res = await db
    .prepare('SELECT * FROM branches WHERE store_id = ? AND is_active = 1 ORDER BY sort ASC, id ASC LIMIT 100')
    .bind(storeId)
    .all<Row>();
  return json({ branches: (res.results ?? []).map((r) => ({ ...r, is_active: !!r.is_active })) });
}

async function getPromosPublic(ctx: Ctx, p: Row): Promise<Response> {
  const db = ctx.env.DB;
  const storeId = p.store_id as string | undefined;
  if (!storeId) return errorJson('store_id required', 400);
  const now = new Date().toISOString();
  const res = await db
    .prepare(`SELECT * FROM promos WHERE store_id = ? AND is_active = 1
              AND (end_date IS NULL OR end_date >= ?)
              ORDER BY created_at DESC LIMIT 100`)
    .bind(storeId, now)
    .all<Row>();
  return json({ promos: (res.results ?? []).map((r) => ({ ...r, is_active: !!r.is_active })) });
}

async function getCustomerPublic(ctx: Ctx, p: Row): Promise<Response> {
  const db = ctx.env.DB;
  const storeId = p.store_id as string | undefined;
  const phone = normalizePhoneTo08(p.phone as string | undefined);
  if (!storeId || !phone) return errorJson('store_id and phone required', 400);
  const row = await db
    .prepare('SELECT * FROM online_customers WHERE store_id = ? AND phone = ? LIMIT 1')
    .bind(storeId, phone)
    .first<Row>();
  if (!row) return json({ customer: null });
  return json({
    customer: {
      ...row,
      promo_history: jsonish(row.promo_history),
    },
  });
}

async function getOrdersByPhone(ctx: Ctx, p: Row): Promise<Response> {
  const db = ctx.env.DB;
  const storeId = p.store_id as string | undefined;
  const phone = normalizePhoneTo08(p.phone as string | undefined);
  if (!storeId || !phone) return errorJson('store_id and phone required', 400);
  const res = await db
    .prepare('SELECT * FROM online_orders WHERE store_id = ? AND customer_phone = ? ORDER BY created_at DESC LIMIT 30')
    .bind(storeId, phone)
    .all<Row>();
  return json({ orders: (res.results ?? []).map(orderPayload) });
}

// Pembatalan oleh pembeli: hanya "Online Baru" → "Dibatalkan", dan hanya
// milik phone tsb (frontend kirim id numerik).
async function cancelOrderByPhone(ctx: Ctx, p: Row): Promise<Response> {
  const db = ctx.env.DB;
  const storeId = p.store_id as string | undefined;
  const phone = normalizePhoneTo08(p.phone as string | undefined);
  const id = Number(p.id);
  if (!storeId || !phone || !Number.isFinite(id)) {
    return errorJson('store_id, phone, id required', 400);
  }
  const res = await db
    .prepare(`UPDATE online_orders SET status = 'Dibatalkan'
              WHERE id = ? AND store_id = ? AND customer_phone = ? AND status = 'Online Baru'`)
    .bind(id, storeId, phone)
    .run();
  if ((res.meta?.changes ?? 0) > 0) {
    await publishOrderEvent(ctx, storeId, 'order_updated', { id, status: 'Dibatalkan' });
  }
  return json({ ok: (res.meta?.changes ?? 0) > 0 });
}

// ─── Registrasi route (side-effect saat import) ─────────────────────
// Wrapper `safe` meniru try/catch global edge fn lama: exception tak
// tertangani → { error: msg } 500, bukan 500 tanpa body dari runtime.
const safe =
  (h: Handler): Handler =>
  async (ctx, p) => {
    try {
      return await h(ctx, p);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      return json({ error: msg }, 500);
    }
  };

export const onlineStoreHandlers: Record<string, Handler> = {
  upsert_store: safe(upsertStore),
  check_slug: safe(checkSlug),
  sync_products: safe(syncProducts),
  get_orders: safe(getOrders),
  update_order: safe(updateOrder),
  get_store: safe(getStore),
  get_store_by_variant_slug: safe(getStoreByVariantSlug),
  get_store_by_slug: safe(getStoreBySlug),
  submit_order: safe(submitOrder),
  redeem_points: safe(redeemPoints),
  sync_branches: safe(syncBranches),
  sync_promos: safe(syncPromos),
  get_promos: safe(getPromos),
  sync_print_form_configs: safe(syncPrintFormConfigs),
  get_print_form_configs: safe(getPrintFormConfigs),
  // Storefront publik (pengganti PostgREST langsung dari web):
  get_products: safe(getProductsPublic),
  get_branches: safe(getBranchesPublic),
  get_promos_public: safe(getPromosPublic),
  get_customer: safe(getCustomerPublic),
  get_orders_by_phone: safe(getOrdersByPhone),
  cancel_order_by_phone: safe(cancelOrderByPhone),
};

Router.registerAll('online-store', onlineStoreHandlers);
