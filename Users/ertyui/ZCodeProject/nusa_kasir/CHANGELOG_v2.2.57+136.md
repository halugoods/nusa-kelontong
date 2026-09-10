# v2.2.57+136 — Fix Apply-Side Delta Sync (transaksi tetap tak muncul)

## Konteks
+135 memperbaiki push (trigger→outbox) dan memang benar: D1 `sync_queue`
berisi delta transaksi dari kasir. TAPI device owner tetap tidak menampilkan
perubahan apa pun. Diagnosa lanjutan menemukan rantai bug di **apply-side**
(saat device menerima & menarik delta) — bug #1 fatal.

## Root Cause
1. **`_mapToTransaction` crash di SETIAP transaksi (FATAL)** — push mengirim
   `date` sebagai ISO string, mapper expect `int` milidetik → `TypeError` →
   ditelan catch → transaksi TIDAK PERNAH masuk DB device penerima.
   Bonus: `_snapshotRow` salah konversi int-detik SQLite dengan
   `fromMillisecondsSinceEpoch` (harusnya ×1000) → ISO tahun 1970-an.
2. **Mapper transaksi cuma bawa 6 dari 27 kolom** — cashierName, diskon,
   status, DP/cicilan, void-reason hilang di device penerima.
3. **Ack sebelum apply sukses** — delta yang gagal apply tetap di-ack →
   hilang permanen dari server.
4. **UI tidak pernah refresh** — semua layar load-once; apply pakai
   `customStatement` yang TIDAK menotify drift stream.
5. **`has_more` diabaikan** — pull cuma batch pertama per 30 detik.
6. **PK `id` tidak ikut INSERT di upsert baru** — row penerima dapat
   autoincrement beda dengan device sumber.
7. **`created_at` device dikirim ke push** — clock skew → delta di-skip
   oleh `since` pull (server time vs jam HP).

## Fixes (app)
- Generic **absent-aware upsert** `_upsertSql/_upsertVars` untuk products &
  transactions (27 kolom transaksi ikut semua) — menerima ISO / int-detik /
  int-ms, camelCase / snake_case.
- `_snapshotRow`: int-detik → ISO benar (×1000).
- `_pull`: **ack hanya delta yang sukses di-apply**; delta gagal tetap di
  server untuk di-retry. Pagination `has_more` sampai habis (guard 10).
  `since` memakai **server_time** dari pull sebelumnya (anti clock skew).
- Push TIDAK mengirim `created_at` device — worker pakai jam server.
- Apply memakai `customUpdate(updates:)` → drift stream query terbangun.
- `DeltaSyncService.I.stream` broadcast event BATCH — dashboard, transaksi,
  produk, POS subscribe & refresh otomatis (POS hanya saat keranjang kosong).
- `_partialUpdate`: terima camelCase & snake_case + konversi datetime;
  `image_base64` dihapus dari peta produk (tidak pernah ditimpa NULL).
- Hydrate gambar produk jalan setelah mute lepas (unawaited) — anti
  ping-pong image_path antar device.

## Verifikasi
- 7 test baru `test/delta_sync_roundtrip_test.dart` — trigger outbox,
  mute guard, datetime detik, upsert transaksi full-kolom, partial update
  anti-clobber. Full suite **105/105 PASS**.
- D1 dicek: delta +135 dari device kasir ada & applied=1 (pull jalan) —
  konsisten dengan bug apply-side, bukan jaringan.

## Cara Tes (2 device +136)
1. Trx di kasir → owner: muncul di Laporan/Dashboard < ~5 detik (WS push)
   atau < ~30 detik (fallback pull).
2. Edit produk/stok di device mana pun → layar Produk device lain refresh
   sendiri.
3. Gambar produk di device yang belum punya file: ter-hydrate otomatis
   dari R2 saat delta produk diterima; atau restart 1x dengan internet.
