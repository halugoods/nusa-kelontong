# v2.2.57+137 — Sync Benar-Benar Realtime (<1 detik)

## Latar
+136 sudah memperbaiki apply-side (transaksi masuk DB receiver), tapi latensi
masih terasa 5–30 detik. Root cause latensi:

1. **Urutan flush vs broadcast terbalik di checkout** — `broadcastUpdated()`
   jalan SEBELUM outbox di-flush. Owner menerima event WS, langsung pull,
   tapi delta belum ada di server → dapat datanya lewat tick 30 dtk berikutnya.
2. **Debounce push 2 detik** + flush safety-net 5 detik menambah delay berlapis.
3. **WS tanpa heartbeat** — koneksi TCP diam >100 detik dibunuh NAT/proxy
   secara diam-diam (half-open). Device mengira masih terhubung; event realtime
   tak pernah sampai; tanpa disadari semua device fallback ke polling.
4. **Saat resume dari background**, OS membunuh WS tanpa callback `onDone` —
   kondisi half-open bertahan sampai tick poll berikutnya.
5. **Listener app-level lama** mengonsumsi event `backup_updated` dengan
   "soft adopt timestamp" (tanpa refresh layar) — membingungkan pemahaman
   alur event; sekarang di-de-dupe (max 1 soft-pull / 2 detik) dan konsumsi
   utama tetap di DeltaSyncService.

## Perubahan

### checkout_screen.dart
- Urutan baru: `flushNow()` (delta benar-benar sudah di server) → baru
  `broadcastUpdated()` (owner pull langsung dapat datanya). Keduanya di
  helper `_pushAndAnnounce()` (unawaited — tidak memblokir UI kasir).
- `pushDelta` shim tidak lagi mengirim payload manual (trigger SQLite sudah
  menulis snapshot DB lengkap ke outbox).

### realtime_sync_service.dart
- **Heartbeat WS**: ping `ping`/`pong` tiap 60 detik (DO menjawab via
  `setWebSocketAutoResponse` tanpa membangunkan DO — gratis). Koneksi
  half-open terdeteksi dalam ≤60 detik (sink.add gagal → reconnect segera).
- **`forceReconnect()`**: dipanggil saat app resume — rebuild koneksi segera
  tanpa menunggu backoff/ping tick.

### delta_sync_service.dart
- `_pushDebounce` 2s → **500ms** (outbox tetap coalesce per (table, pk)).
- `_pullInterval` 30s → **20s** (fallback saja; jalur utama = WS event).
- **`pullNow()`** publik dengan guard `_pulling` anti tumpang-tindih + coalesce
  event beruntun (stream broadcast bisa 2 event per push: bridge 'sync' + echo).
- Event WS → `pullNow()` langsung (sebelumnya juga _pull, tapi tanpa guard).

### app.dart
- Listener `RealtimeSyncService` app-level di-de-dupe (soft pull full backup
  max 1x/2 detik) — komentar diperbarui, konsumsi utama oleh delta sync.
- Resume handler: `forceReconnect()` + `DeltaSyncService.pullNow()` segera.

## Alur realtime hasil akhir
```
Kasir tap "Bayar" → saveTransaction (trigger SQLite → outbox, 0ms)
  → flushNow() push delta ke D1 (~200–600ms tergantung jaringan)
  → broadcastUpdated() → DO Room → WS event ke device lain (<100ms)
Owner device: WS event → pullNow() → apply row → DeltaEvent BATCH
  → setState Dashboard/Laporan/Transaksi/Produk/POS
TOTAL: ~0.5–1.5 detik (dibatasi kecepatan internet, bukan timer)
```

## Posisi vs GAS (pertanyaan user)
GAS terasa realtime karena: (1) SEMUA klien baca-tulis 1 database yang sama
(Spreadsheet) — tidak ada DB lokal; (2) web memanggil ulang
`google.script.run` saat ada aksi + polling 30–60 detik untuk tabel yang
terbuka. NUSA offline-first butuh SQLite lokal per device (kasir harus tetap
jalan saat internet mati) → butuh push/pull delta. Konsepnya sekarang sama
dengan GAS: server = sumber kebenaran, perubahan langsung ditanyakan ulang
saat ada event.

## Verifikasi
- `flutter analyze` — 0 error (warning lama semua, pre-existing).
- `flutter test` — **105/105 PASS** (termasuk 7 test roundtrip +136).
