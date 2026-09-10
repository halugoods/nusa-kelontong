# v2.2.57+134 — Sync Realtime Tuntas (Delta Semua Tabel + Bridge WS + Status Sinkron)

## Akar masalah yang ditemukan & diperbaiki

1. **Transaksi/produk tidak pernah ter-push dari device** — body push/pull/ack
   tidak pernah mengirim `device_id` → worker menolak **401** diam-diam. Sekarang
   semua call sync mengirim `device_id`.
2. **`saveTransaction` (jalur checkout utama) tidak push delta sama sekali** —
   hanya void yang push. Solusi tuntas: **trigger SQLite level-DB** mencatat
   SEMUA perubahan (INSERT/UPDATE/DELETE) pada 25 tabel synced ke outbox
   `sync_outbox` → di-push otomatis (debounce 2 dtk). Tidak ada lagi jalur
   tulis yang bolong — semua jenis perubahan data (trx, produk, stok,
   pelanggan, hutang, pengeluaran, absensi, dst) tersinkron.
3. **Realtime WS tidak pernah menyala** — publisher lama (DB trigger Supabase)
   hilang saat migrasi ke Cloudflare; worker juga publish di channel yang tidak
   didengar app (`sync:{uid}` vs `backup_updated:{uid}`) dan via RPC yang
   silent-fail. Fix cloud: `publishSyncEvent` broadcast `backup_updated` ke
   channel yang didengar app → device lain menarik delta dalam ~1 detik.
4. **Apply delta no-op** — app membaca kolom `table` padahal server mengirim
   `table_name` → delta diterima tapi tidak diaplikasikan. Fixed (+ fallback).
5. **Status/timestamp sinkron mati** — sidecar `metadata.json` tidak pernah
   ditulis sejak metadata dipindah ke dalam arsip (v2.2.57). Fix cloud: worker
   menulis sidecar otomatis setiap upload backup → timestamp status sinkron
   tampil lagi.
6. **Retry flush** — delta yang gagal push (offline) kini retry 10 detik,
   tidak stranded.
7. **Loop guard** — apply delta dari device lain di-mute dari trigger supaya
   tidak memicu push ulang (ping-pong).
8. ** foto crop_1787208508137.jpg** (produk 6 djuhairsyams) dipulihkan dari
   sisi cloud (pre-crop file SHA identik) — tidak menunggu build.

## Catatan teknis
- `pushDelta` manual tetap dipanggil call-site lama tapi kini hanya memastikan
  flush jalan; sumber kebenaran = trigger + outbox (anti-bolong).
- `image_base64/photo_base64` tidak ikut delta (redundan; gambar via R2).
- Snapshot delta = baris terakhir per (table,pk) — UPDATE beruntun kolaps.
- Worker: fix bug `uid()` di handlePush (500 utk delta tanpa id).
