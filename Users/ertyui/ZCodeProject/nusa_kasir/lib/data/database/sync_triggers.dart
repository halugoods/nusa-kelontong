// ============================================================================
// v2.2.57+134 — SQLite-level delta capture (auto-push SEMUA perubahan)
// ============================================================================
// Masalah: pushDelta manual hanya dipasang di SEBAGIAN jalur tulis —
// saveTransaction (jalur checkout utama!) bahkan TIDAK push delta sama
// sekali → transaksi kasir tidak pernah sampai ke device owner. Menambahkan
// pushDelta per-repo satu per satu terbukti selalu ada yang bolong.
//
// Solusi: AFTER INSERT/UPDATE/DELETE trigger di level SQLite mencatat
// (table, pk, op) ke tabel outbox `sync_outbox` untuk SETIAP perubahan data
// pada tabel yang di-sync. DeltaSyncService mengosongkan outbox: baris
// terakhir per (table, pk) diambil datanya langsung dari DB (snapshot
// terkini — beberapa UPDATE ke baris sama otomatis kolaps jadi 1 delta),
// lalu di-push ke cloud. DELETE dikirim tanpa data (apply-side delete by pk).
//
// Loop guard: saat MENGAPLIKAN delta dari device lain, DeltaSyncService
// men-set sync_muted = 1 supaya tulisan apply lokal tidak memicu
// trigger lagi (ping-pong tanpa ujung). WHEN clause trigger cek tabel mute.
// v2.2.57+135: tabel mute PINDAH ke main database — dulu TEMP TABLE dan
// SQLite menolak trigger yang mereferensi database temp ("trigger cannot
// reference objects in database temp") → trigger tidak pernah terpasang
// sama sekali (silent failure, error ditelan non-fatal) → outbox kosong.
//
// Outbox dibuat via raw SQL di beforeOpen (BUKAN drift table) supaya tidak
// perlu naikkan schemaVersion / build_runner — idempoten & murah.
// ============================================================================

import 'app_database.dart';

/// Tabel yang di-capture trigger. Hanya tabel yang apply-side
/// (DeltaSyncService._upsertRecord/_deleteRecord) mengerti — tabel di luar
/// daftar ini diabaikan (delta tak dikonsumsi = sia-sia).
/// stock_movements sengaja dikecualikan (log turunan, churn tinggi);
/// chat_sessions/activations_local/cashier_sessions/sync_queue lokal device;
/// open_tabs = keranjang sedang dikerjakan (state lokal kasir).
const List<String> kSyncedTables = [
  'products',
  'transactions',
  'customers',
  'categories',
  'roles',
  'employees',
  'branches',
  'promos',
  'suppliers',
  'customer_debts',
  'debt_payments',
  'expenses',
  'expense_categories',
  'recurring_expenses',
  'liquidity',
  'attendance',
  'online_orders',
  'waste',
  'payroll',
  'purchase_orders',
  'stock_counts',
  'stock_count_items',
  'print_orders',
  'point_histories',
  'settings',
];

/// PK per tabel untuk record_id delta. Default 'id' (autoincrement);
/// roles PK = name; categories dipakai by-name di apply-side (hapus/upsert).
const Map<String, String> kSyncPkColumn = {
  'roles': 'name',
  'categories': 'name',
};

/// Kolom PK untuk lookup snapshot baris saat flush.
String syncPkColumnFor(String table) => kSyncPkColumn[table] ?? 'id';

/// Pasang trigger + outbox + tabel mute. Idempoten (IF NOT EXISTS) —
/// dipanggil dari beforeOpen SETIAP koneksi dibuka.
Future<void> installDeltaSyncTriggers(AppDatabase db) async {
  // ── Outbox (raw SQL, di luar drift schema) ──
  await db.customStatement('''
    CREATE TABLE IF NOT EXISTS sync_outbox (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      table_name TEXT NOT NULL,
      record_pk TEXT NOT NULL,
      operation TEXT NOT NULL,
      created_at TEXT NOT NULL
    )
  ''');
  await db.customStatement(
    'CREATE INDEX IF NOT EXISTS idx_sync_outbox_pk ON sync_outbox(table_name, record_pk)',
  );

  // ── Mute guard ──
  // v2.2.57+135 FIX KRITIS: dulu tabel ini dibuat sebagai TEMP TABLE —
  // SQLite MENOLAK trigger yang mereferensi objek di database temp
  // ("trigger cannot reference objects in database temp") → SEMUA trigger
  // gagal terpasang (error ditelan non-fatal) → outbox selalu kosong →
  // TIDAK ADA delta yang di-push ke cloud walau app +134. Pindah ke tabel
  // main (persist, 1 baris) supaya WHEN clause valid. Idempoten.
  await db.customStatement(
    'CREATE TABLE IF NOT EXISTS sync_muted (m INTEGER NOT NULL DEFAULT 0)',
  );
  await db.customStatement(
    'INSERT OR IGNORE INTO sync_muted (m) SELECT 0 WHERE NOT EXISTS (SELECT 1 FROM sync_muted)',
  );

  // ── Trigger per tabel ──
  // v2.2.57+135: DROP dulu trigger lama dari build +134 — di DB yang pernah
  // dibuka +134, trigger bisa terlanjur terpasang saat temp.sync_muted masih
  // ada di koneksi itu (validasi referensi temp terjadi saat CREATE, jadi
  // trigger lama menunjuk tabel temp yang tidak ada di koneksi baru → WHEN
  // error saat fire). DROP IF EXISTS memastikan state bersih lalu CREATE
  // ulang dengan mute main-db. Murah (75 statement idempoten di beforeOpen).
  for (final table in kSyncedTables) {
    final pk = syncPkColumnFor(table);
    final guard = '(SELECT COALESCE((SELECT m FROM sync_muted LIMIT 1), 0) = 0)';

    await db.customStatement('DROP TRIGGER IF EXISTS trg_sync_${table}_ins');
    await db.customStatement('DROP TRIGGER IF EXISTS trg_sync_${table}_upd');
    await db.customStatement('DROP TRIGGER IF EXISTS trg_sync_${table}_del');

    await db.customStatement('''
      CREATE TRIGGER IF NOT EXISTS trg_sync_${table}_ins AFTER INSERT ON $table
      WHEN $guard
      BEGIN
        INSERT INTO sync_outbox (table_name, record_pk, operation, created_at)
        VALUES ('$table', CAST(NEW.$pk AS TEXT), 'INSERT', strftime('%Y-%m-%dT%H:%M:%fZ','now'));
      END
    ''');
    await db.customStatement('''
      CREATE TRIGGER IF NOT EXISTS trg_sync_${table}_upd AFTER UPDATE ON $table
      WHEN $guard
      BEGIN
        INSERT INTO sync_outbox (table_name, record_pk, operation, created_at)
        VALUES ('$table', CAST(NEW.$pk AS TEXT), 'UPDATE', strftime('%Y-%m-%dT%H:%M:%fZ','now'));
      END
    ''');
    await db.customStatement('''
      CREATE TRIGGER IF NOT EXISTS trg_sync_${table}_del AFTER DELETE ON $table
      WHEN $guard
      BEGIN
        INSERT INTO sync_outbox (table_name, record_pk, operation, created_at)
        VALUES ('$table', CAST(OLD.$pk AS TEXT), 'DELETE', strftime('%Y-%m-%dT%H:%M:%fZ','now'));
      END
    ''');
  }
}

/// Set / clear mute flag (dipakai DeltaSyncService saat mengaplikasikan
/// delta remote supaya apply tidak di-capture lagi).
/// v2.2.57+135: tabel main (bukan temp) — lihat catatan installDeltaSyncTriggers.
Future<void> setSyncMuted(AppDatabase db, bool muted) async {
  try {
    await db.customStatement(
      'UPDATE sync_muted SET m = ?',
      [muted ? 1 : 0],
    );
  } catch (_) {
    // Tabel mute hilang (koneksi baru) — trigger juga baru dipasang, aman.
  }
}
