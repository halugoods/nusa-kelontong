# v2.2.57+135 — FIX REALTIME SYNC TUNTAS: trigger delta gagal terpasang diam-diam

## Root Cause (kenapa +134 masih belum realtime)

Build +134 memasang trigger SQLite untuk men-capture SEMUA perubahan data ke
outbox `sync_outbox`, lalu DeltaSyncService meng-push ke cloud. **Tapi trigger
tidak pernah terpasang sama sekali** di device:

- Tabel mute guard `sync_muted` dibuat sebagai **TEMP TABLE**.
- SQLite **menolak trigger yang mereferensi objek di database temp**:
  `trigger cannot reference objects in database temp`.
- `CREATE TRIGGER` pertama langsung throw → karena pemanggilan dibungkus
  try/catch "non-fatal" di `beforeOpen`, error ditelan diam-diam.
- Hasil: outbox selalu kosong → **0 delta di-push ke cloud** walau app +134.
  (Terbukti di D1: device terdaftar + `last_pull` tercatat, tapi
  `sync_queue` 0 row dari device.)

## Perbaikan

1. **`sync_muted` pindah ke main database** (tabel persist 1 baris, bukan
   TEMP). WHEN clause trigger sekarang valid → trigger terpasang.
2. **DROP + CREATE ulang semua trigger** di `beforeOpen`: DB yang pernah
   dibuka +134 bisa membawa trigger lama yang menunjuk `temp.sync_muted`
   (validasi referensi temp terjadi saat CREATE di koneksi itu) → WHEN error
   saat fire di koneksi baru. DROP IF EXISTS memastikan state bersih.
3. **Periodic flush 5 detik (safety-net)** di DeltaSyncService: trigger
   menulis outbox langsung dari SQLite tanpa tahu DeltaSyncService — dulu
   flush hanya jalan via shim `pushDelta` (hanya repo tertentu yang memanggil)
   atau flush awal. Perubahan dari jalur lain (mis. `saveTransaction`) bisa
   menumpuk. Sekarang outbox ter-flush maksimal 5 detik setelah perubahan
   apa pun (no-op murah kalau kosong).

## Verifikasi

- SQL trigger direproduksi + diverifikasi di SQLite mandiri: capture
  INSERT/UPDATE/DELETE ✓, mute guard mencegah capture saat apply ✓.
- `flutter analyze`: 0 error di file yang disentuh.
- `flutter test`: 98 pass.
- Endpoint cloud `/api/sync-delta/push` diuji langsung: row masuk D1 ✓
  (lalu sandbox row dihapus).
- WS bridge `backup_updated` + sidecar `metadata.json` dari +134 tetap
  berlaku (publish 2 channel per push, terverifikasi wrangler tail).

## Catatan

- Gambar djuhairsyams: backup cloud didecrypt & diaudit — 6 produk, 21
  transaksi, semua `image_path` menunjuk file yang ada di R2 (6/6 HTTP 200,
  ukuran match). Tidak ada data hilang; tidak perlu kirim ulang NUS1.
- Setelah update: transaksi kasir muncul di device owner ≤ ~7 detik
  (2 dtk debounce flush + 5 dtk safety-net worst case), perubahan produk/
  stok/customer/hutang dsb. juga otomatis.
