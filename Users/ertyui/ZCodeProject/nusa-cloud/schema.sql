-- NUSA Cloud — schema D1 (SQLite). Jalankan via:
--   wrangler d1 execute nusa-db --file=schema.sql --remote
-- Port dari supabase/migrations (nusa_kasir + nusa-online), TANPA RLS —
-- otorisasi di layer worker. Timestamp = TEXT ISO-8601 (SQLite idiom).

-- ── licenses ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS licenses (
  id              TEXT PRIMARY KEY,          -- uuid
  key             TEXT UNIQUE NOT NULL,
  serial          TEXT NOT NULL,
  product         TEXT DEFAULT 'nusa-kasir',
  mode            TEXT DEFAULT 'full',        -- full | lite (v2.2.57+130)
  status          TEXT DEFAULT 'Generated',  -- Generated|Trial|Active|Cancelled|Expired|Suspended
  owner_email     TEXT,
  google_user_id  TEXT,
  order_id        TEXT,
  package         TEXT,                      -- 1bulan | lifetime
  tier            TEXT DEFAULT 'lifetime',   -- trial | 1month | lifetime
  payment_provider TEXT DEFAULT 'midtrans',
  payment_url     TEXT,
  expires_at      TEXT,
  created_at      TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_licenses_key ON licenses(key);
CREATE INDEX IF NOT EXISTS idx_licenses_google ON licenses(google_user_id);
CREATE INDEX IF NOT EXISTS idx_licenses_order ON licenses(order_id);

-- ── activations ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS activations (
  id              TEXT PRIMARY KEY,
  license_id      TEXT NOT NULL REFERENCES licenses(id) ON DELETE CASCADE,
  device_id       TEXT NOT NULL,
  google_user_id  TEXT,
  created_at      TEXT DEFAULT (datetime('now')),
  UNIQUE (license_id, device_id)
);
CREATE INDEX IF NOT EXISTS idx_activations_license ON activations(license_id);

-- ── payments (midtrans + instanpay) ─────────────────────────────────
CREATE TABLE IF NOT EXISTS payments (
  id          TEXT PRIMARY KEY,
  order_id    TEXT NOT NULL UNIQUE,
  google_id   TEXT NOT NULL,
  product     TEXT DEFAULT 'nusa-kasir',
  package     TEXT,
  amount      INTEGER NOT NULL DEFAULT 0,
  status      TEXT DEFAULT 'pending',
  snap_token  TEXT,
  license_key TEXT,
  provider    TEXT DEFAULT 'midtrans',
  created_at  TEXT DEFAULT (datetime('now')),
  updated_at  TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_payments_google ON payments(google_id);
CREATE INDEX IF NOT EXISTS idx_payments_order ON payments(order_id);

-- ── license_events (audit cron revoke) ──────────────────────────────
CREATE TABLE IF NOT EXISTS license_events (
  id         TEXT PRIMARY KEY,
  license_id TEXT NOT NULL REFERENCES licenses(id) ON DELETE CASCADE,
  event      TEXT NOT NULL,                  -- expired|revoked|grace_started|renewed
  detail     TEXT,
  created_at TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_license_events_license ON license_events(license_id);

-- ── app_min_versions (force update) ─────────────────────────────────
CREATE TABLE IF NOT EXISTS app_min_versions (
  product     TEXT PRIMARY KEY,
  min_version TEXT NOT NULL DEFAULT '',
  min_build   INTEGER NOT NULL DEFAULT 0,
  download_url TEXT,
  updated_at  TEXT DEFAULT (datetime('now'))
);

-- ── tutorials ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tutorials (
  id            TEXT PRIMARY KEY,
  title         TEXT NOT NULL,
  yt_url        TEXT NOT NULL,
  thumbnail_url TEXT,
  description   TEXT,
  variants      TEXT NOT NULL DEFAULT '[]',  -- JSON array (pg text[] → json)
  sort_order    INTEGER NOT NULL DEFAULT 0,
  created_at    TEXT DEFAULT (datetime('now')),
  updated_at    TEXT DEFAULT (datetime('now'))
);

-- ── store_settings ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS store_settings (
  store_id        TEXT PRIMARY KEY,
  user_id         TEXT,                      -- Google UID / akun email uuid
  owner_user_id   TEXT DEFAULT '',
  store_name      TEXT NOT NULL DEFAULT '',
  slug            TEXT,
  variant         TEXT DEFAULT '',
  description     TEXT DEFAULT '',
  whatsapp        TEXT DEFAULT '',
  address         TEXT DEFAULT '',
  open_hours      TEXT DEFAULT '08:00 - 21:00',
  logo_url        TEXT,
  theme_id        TEXT DEFAULT '',
  primary_color   TEXT DEFAULT '',
  dark_color      TEXT DEFAULT '',
  soft_color      TEXT DEFAULT '',
  order_types     TEXT,                      -- JSON
  delivery_fee    INTEGER DEFAULT 0,
  pickup_options  TEXT,                      -- JSON
  payment_methods TEXT,                      -- JSON
  member_settings TEXT,                      -- JSON
  is_active       INTEGER DEFAULT 0,
  created_at      TEXT DEFAULT (datetime('now')),
  updated_at      TEXT DEFAULT (datetime('now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_store_slug ON store_settings(variant, slug) WHERE slug IS NOT NULL AND slug <> '';
CREATE INDEX IF NOT EXISTS idx_store_user_variant ON store_settings(user_id, variant);

-- ── online_products ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS online_products (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  store_id     TEXT NOT NULL,
  product_id   INTEGER NOT NULL,
  name         TEXT NOT NULL DEFAULT '',
  category     TEXT DEFAULT 'Lainnya',
  price        INTEGER DEFAULT 0,
  stock        INTEGER DEFAULT 0,
  image_url    TEXT DEFAULT '',
  description  TEXT DEFAULT '',
  is_published INTEGER DEFAULT 1,
  created_at   TEXT DEFAULT (datetime('now')),
  UNIQUE (store_id, product_id)
);
CREATE INDEX IF NOT EXISTS idx_op_store ON online_products(store_id);

-- ── online_orders ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS online_orders (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  store_id       TEXT NOT NULL,
  invoice        TEXT NOT NULL,
  customer_name  TEXT NOT NULL DEFAULT '',
  customer_phone TEXT NOT NULL DEFAULT '',
  items          TEXT DEFAULT '[]',          -- JSON
  subtotal       INTEGER DEFAULT 0,
  discount       INTEGER DEFAULT 0,
  promo_code     TEXT DEFAULT '',
  promo_discount INTEGER DEFAULT 0,
  used_promo_id  INTEGER,
  used_points    INTEGER DEFAULT 0,
  order_type     TEXT DEFAULT '',
  referred_by    TEXT DEFAULT '',
  handling_fee   INTEGER DEFAULT 0,
  total          INTEGER DEFAULT 0,
  payment_method TEXT DEFAULT 'Tunai',
  pickup_time    TEXT DEFAULT 'Segera',
  branch         TEXT DEFAULT 'Pusat',
  notes          TEXT DEFAULT '',
  status         TEXT DEFAULT 'Online Baru',
  processed_by   TEXT DEFAULT '',
  created_at     TEXT DEFAULT (datetime('now')),
  updated_at     TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_orders_store ON online_orders(store_id);
CREATE INDEX IF NOT EXISTS idx_orders_invoice ON online_orders(invoice);
CREATE INDEX IF NOT EXISTS idx_orders_phone ON online_orders(customer_phone);

-- ── promos ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS promos (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  store_id       TEXT NOT NULL,
  code           TEXT NOT NULL,
  title          TEXT DEFAULT '',
  type           TEXT DEFAULT 'persen',
  value          INTEGER DEFAULT 0,
  min_spend      INTEGER DEFAULT 0,
  quota          INTEGER,
  limit_per_user INTEGER,
  start_date     TEXT,
  end_date       TEXT,
  is_active      INTEGER DEFAULT 1,
  created_at     TEXT DEFAULT (datetime('now')),
  UNIQUE (store_id, code)
);

-- ── online_customers ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS online_customers (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  store_id      TEXT NOT NULL,
  name          TEXT NOT NULL DEFAULT '',
  phone         TEXT NOT NULL,
  total_spent   INTEGER NOT NULL DEFAULT 0,
  points        INTEGER NOT NULL DEFAULT 0,
  level         TEXT NOT NULL DEFAULT 'Silver',
  promo_history TEXT DEFAULT '[]',           -- JSON
  referred_by   TEXT DEFAULT '',
  created_at    TEXT DEFAULT (datetime('now')),
  updated_at    TEXT DEFAULT (datetime('now')),
  UNIQUE (store_id, phone)
);

-- ── branches ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS branches (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  store_id   TEXT NOT NULL,
  name       TEXT NOT NULL,
  phone      TEXT DEFAULT '',
  is_active  INTEGER NOT NULL DEFAULT 1,
  sort       INTEGER NOT NULL DEFAULT 0,
  created_at TEXT DEFAULT (datetime('now')),
  UNIQUE (store_id, name)
);

-- ── print_form_configs ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS print_form_configs (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  store_id     TEXT NOT NULL,
  service_name TEXT NOT NULL,
  fields_json  TEXT,
  updated_at   TEXT DEFAULT (datetime('now')),
  created_at   TEXT DEFAULT (datetime('now')),
  UNIQUE (store_id, service_name)
);

-- ── ai_settings + ai_chat_history ───────────────────────────────────
CREATE TABLE IF NOT EXISTS ai_settings (
  id        TEXT PRIMARY KEY,
  owner     TEXT NOT NULL UNIQUE,            -- uid, '*' = config global dashboard
  base_url  TEXT NOT NULL DEFAULT 'https://openrouter.ai/api/v1',
  api_key   TEXT NOT NULL DEFAULT '',
  model     TEXT NOT NULL DEFAULT 'google/gemini-2.0-flash-lite-001',
  is_custom INTEGER NOT NULL DEFAULT 0,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS ai_chat_history (
  id         TEXT PRIMARY KEY,
  owner      TEXT NOT NULL,
  session_id TEXT NOT NULL,
  role       TEXT NOT NULL,                  -- user|assistant|tool|system
  content    TEXT NOT NULL DEFAULT '',
  tool_name  TEXT,
  tool_args  TEXT,
  created_at TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_ai_chat ON ai_chat_history(owner, session_id, created_at);

-- ── sheets (hot-tier lama; arsip tetap dipakai) ─────────────────────
CREATE TABLE IF NOT EXISTS sheets_settings (
  id                   INTEGER PRIMARY KEY CHECK (id = 1),
  service_account_json TEXT NOT NULL DEFAULT '',
  enabled              INTEGER NOT NULL DEFAULT 0,
  updated_at           TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS sheets_accounts (
  id                  TEXT PRIMARY KEY,
  email               TEXT NOT NULL UNIQUE,
  oauth_refresh_token TEXT,
  enabled             INTEGER NOT NULL DEFAULT 1,
  max_users           INTEGER NOT NULL DEFAULT 50,
  label               TEXT,
  created_at          TEXT DEFAULT (datetime('now')),
  updated_at          TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS sheets_registry (
  id              TEXT PRIMARY KEY,
  user_id         TEXT NOT NULL UNIQUE,
  email           TEXT,
  store_name      TEXT,
  variant         TEXT,
  spreadsheet_id  TEXT,
  spreadsheet_url TEXT,
  status          TEXT NOT NULL DEFAULT 'pending',  -- pending|ready|error
  error           TEXT,
  created_at      TEXT DEFAULT (datetime('now')),
  updated_at      TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_sheets_registry_status ON sheets_registry(status);

CREATE TABLE IF NOT EXISTS sheets_archive (
  id          TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL,
  bulan       TEXT NOT NULL,                 -- YYYY-MM
  tab         TEXT NOT NULL,
  rows        TEXT NOT NULL DEFAULT '[]',    -- JSON array of arrays
  row_count   INTEGER NOT NULL DEFAULT 0,
  archived_at TEXT DEFAULT (datetime('now')),
  UNIQUE (user_id, bulan, tab)
);
CREATE INDEX IF NOT EXISTS idx_sheets_archive ON sheets_archive(user_id, bulan);

-- ── auth custom (Milestone B4) ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS accounts (
  id           TEXT PRIMARY KEY,             -- uuid = identitas kanonik (pengganti Supabase user id)
  email        TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,               -- PBKDF2-SHA256, format: pbkdf2$iter$saltB64$hashB64
  google_user_id TEXT UNIQUE,                -- link akun Google native (jika ada)
  display_name TEXT,
  created_at   TEXT DEFAULT (datetime('now')),
  updated_at   TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS reset_tokens (
  token      TEXT PRIMARY KEY,               -- acak 32B hex
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  expires_at TEXT NOT NULL,
  used       INTEGER NOT NULL DEFAULT 0,
  created_at TEXT DEFAULT (datetime('now'))
);

-- ── schema_addendum: app version tracking (dari migrasi 0017) ───────
-- Dipakai fn app_ping (POST /api/app-ping/ping): mencatat versi app
-- terakhir per lisensi + last_seen_at untuk dashboard admin.
-- CATATAN: SQLite/D1 tidak punya ADD COLUMN IF NOT EXISTS — jalankan
-- ALTER di bawah SEKALI saja (re-run akan error "duplicate column name").
-- Urutan eksekusi: tabel licenses di atas dulu, baru addendum ini.
ALTER TABLE licenses ADD COLUMN last_app_version TEXT;
ALTER TABLE licenses ADD COLUMN last_app_build INTEGER;
ALTER TABLE licenses ADD COLUMN last_seen_at TEXT;

-- ── addendum 2: sheets_settings pakai OAuth company account (bukan SA json) ──
-- sheets-admin port membaca/menulis kolom oauth_refresh_token + oauth_owner_email
-- (dipakai bareng sheets_accounts). Jalankan SEKALI bersama addendum di atas.
ALTER TABLE sheets_settings ADD COLUMN oauth_refresh_token TEXT;
ALTER TABLE sheets_settings ADD COLUMN oauth_owner_email TEXT;
-- sheets_registry butuh account_id untuk multi-akun Google.
ALTER TABLE sheets_registry ADD COLUMN account_id TEXT;

-- ── Performance indexes ─────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_orders_store_created ON online_orders(store_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_orders_store_status ON online_orders(store_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_orders_store_phone ON online_orders(store_id, customer_phone, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_op_store_pub_cat ON online_products(store_id, is_published, category);
CREATE INDEX IF NOT EXISTS idx_op_store_pub ON online_products(store_id, is_published);
CREATE INDEX IF NOT EXISTS idx_promos_store_active ON promos(store_id, is_active, end_date);
CREATE INDEX IF NOT EXISTS idx_licenses_status ON licenses(status, expires_at);
CREATE INDEX IF NOT EXISTS idx_activations_license_created ON activations(license_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_branches_store ON branches(store_id, is_active);
CREATE INDEX IF NOT EXISTS idx_oc_store_phone ON online_customers(store_id, phone);

-- ── sync_queue (delta sync) ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sync_queue (
  id            TEXT PRIMARY KEY,
  uid           TEXT NOT NULL,
  store_id      TEXT NOT NULL,
  table_name    TEXT NOT NULL,
  record_id     TEXT NOT NULL,
  operation     TEXT NOT NULL,
  data          TEXT,
  created_at    TEXT NOT NULL,
  device_id     TEXT NOT NULL,
  applied       INTEGER NOT NULL DEFAULT 0,
  applied_at    TEXT
);
CREATE INDEX IF NOT EXISTS idx_sync_uid_time ON sync_queue(uid, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sync_store_table ON sync_queue(store_id, table_name, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sync_applied ON sync_queue(applied, created_at DESC);

-- ── sync_devices ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sync_devices (
  device_id     TEXT PRIMARY KEY,
  uid           TEXT NOT NULL,
  device_name   TEXT,
  last_seen     TEXT NOT NULL,
  last_pull     TEXT,
  ip_address    TEXT,
  user_agent    TEXT
);
CREATE INDEX IF NOT EXISTS idx_sync_devices_uid ON sync_devices(uid, last_seen DESC);

-- ── sync_state ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sync_state (
  uid           TEXT PRIMARY KEY,
  last_delta_id TEXT,
  last_sync_at  TEXT,
  delta_count   INTEGER DEFAULT 0,
  device_count  INTEGER DEFAULT 0
);
