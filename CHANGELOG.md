# v2.2.57+138 — Fix Flip Card Owner 0 + Animasi Progress Restore

## Latar
Dua keluhan user:
1. **Card flip "Ringkasan Hari Ini" di dashboard owner menampilkan semua 0** (laba, penjualan, transaksi) padahal sudah ada transaksi — padahal front card (omzet/laporan) tetap benar.
2. **Restore cloud backup tidak ada feedback progress** — user hanya melihat spinner kecil di tombol atau layar diam, tidak tahu apakah data sedang diunduh, di-unpack, atau mengunduh gambar.

Plus pertanyaan: **apakah realtime sync +137 aman tidak seperti kasus Supabase?** (dijawab di bawah).

## Jawaban: keamanan realtime vs kasus Supabase

TIDAK akan terulang. Kasus Supabase = **egress bom dari full-backup berulang** (upload/unduh seluruh DB + 17MB base64 + 352 gambar tiap siklus). Delta sync +137/+138 justru DIBUAT untuk menghentikan itu:
- Yang dikirim per transaksi = **1 baris kecil (~3KB)**, bukan seluruh database
- Broadcast WS = event JSON < 1KB (tanpa payload data — penerima yang narik)
- Gambar TIDAK ikut delta (base64 dibuang dari payload; gambar via R2 sekali saja)
- Poll fallback 20 dtk = query "sejak terakhir" (kosong = respons kecil)
- Heartbeat = 4 byte 'ping' per menit
- Hard-stop: kalau push gagal, outbox di SQLite menahan retry (tidak spam)
Bandwith kasus Supabase vs sekarang beda ribuan kali lipat.

## Fix 1: Card flip owner 0 semua

Root cause (2 lapis):
- **Lapis 1 (pemicu):** `_fetchCardData(employeeId)` di `dashboard_screen.dart:1183` `if (employeeId == null) return;` — kalau sesi karyawan owner tidak terbaca (restore, sesi expired 8 jam, login via jalur lama), role UI tetap tampil 'Owner' (`session?.role ?? 'Owner'`) dan card boleh flip, tapi data TIDAK PERNAH di-fetch → semua nilai fallback `?? 0`.
- **Lapis 2 (penyembunyi):** seluruh body `_fetchCardData` dibungkus `catch (_) {}` (baris 1276) — exception apa pun hilang diam-diam. Kandidat throw nyata: unsafe cast di `report_repository.dart` `profitLoss()`: `it['productId'] as int?` pada JSON item yang berisi `num`/`double` (produk dari delta sync/lama punya `5.0`) → TypeError → seluruh fetch batal.

Perbaikan:
1. `dashboard_screen.dart` `_fetchCardData`: hilangkan early-return; kalau `employeeId == null` tetap fetch statistik global (penjualan/laba/trx/bulanan — semua query sudah support null employeeId) dan lewati HANYA bagian yang butuh employeeId (attendance/laci/shift).
2. `report_repository.dart`: ganti cast jadi aman — `(it['productId'] as num?)?.toInt()` dan `(it['qty'] as num?)?.toInt() ?? 0` di semua 4 lokasi.
3. `catch (_) {}` → `catch (e) { debugPrint('[Dashboard] fetchCardData error: $e'); }` supaya bug berikutnya tidak nyamar lagi.
4. Bonus: tambah `dispose()` di _DashboardScreenState untuk cancel subscription delta (kebocoran minor).

## Fix 2: Animasi progress restore + download gambar

Arsitektur: provider global `restoreProgressProvider` (pola clone dari `updateProgressProvider`) + dialog `RestoreProgressDialog` reusable, dipakai 3 jalur restore manual. Startup otomatis tetap senyap.

### Provider baru `lib/core/providers/restore_progress_provider.dart`
- `RestoreProgress { phase, filesDone, filesTotal, error }`
- phase: `download` → `unpack` → `images` → `done/error`
- API: `start()`, `phase(...)`, `updateFiles(done, total)`, `done()`, `fail(msg)`

### Dialog `lib/shared/widgets/restore_progress_dialog.dart`
- Clone tampilan dialog update `settings_screen.dart:1826-1865`
- Ikon fase (spinner/check/error) + label fase + LinearProgressIndicator "Mengunduh gambar 3/24" + teks "Jangan tutup aplikasi…"
- barrierDismissible: false

### Instrumentasi backend (parameter opsional, default null — caller lama tak berubah)
- `DeltaSyncService.hydrateAllImages({onProgress})`: refactor dua-pass — pass 1 kumpulkan kandidat → total diketahui → pass 2 download dengan callback per file.
- `_relinkImagesFromCloud({onProgress})` di main.dart: pola sama.
- `ActivationRepository.restoreDirect({onPhase})` & `restoreFromCloud({onPhase})`: callback `download` → `unpack`.

### Wiring 3 jalur manual
1. **Activation "Data Ditemukan"** (`activation_screen.dart:536-557`): tampilkan dialog → `restoreDirect(onPhase:)` → `hydrateAllImages(onProgress:)` → tutup dialog → toast.
2. **RestoreBackupFlow.runIfNeeded** (`restore_backup_flow.dart:156-194`): sama persis.
3. **Settings "Download dari Cloud"** (`settings_screen.dart:950-991`): ganti spinner kecil → dialog progress (fase download saja; gambar menyusul otomatis setelah restart).

## Verifikasi
- `flutter analyze` — 0 error.
- `flutter test` — **105/105 PASS**.
