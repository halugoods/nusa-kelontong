# CHANGELOG v2.2.57+131

> Release: 2026-09-10
> Delta Sync + Dashboard + Optimizations

## 🔄 Delta Sync (Pengganti Full Backup Upload)
Arsitektur baru: record-level delta sync. Setiap perubahan (insert/update/delete) di-push langsung ke cloud. Device lain pull delta dalam ~1 detik.
- **Egress: 8-12x lebih ringan** dari full backup upload
- Coverage: SEMUA role (kasir, owner, karyawan)
- Offline support: queue changes saat offline, flush saat online
- Conflict resolution: last-write-wins + transaction immutable

### Worker (Cloudflare)
- **New endpoints:**
  - `POST /api/sync-delta/push` — terima delta dari device
  - `POST /api/sync-delta/pull` — ambil delta by timestamp/IDs
  - `POST /api/sync-delta/ack` — konfirmasi diterima
  - `GET /api/sync-delta/status` — status sync per user
  - `POST /api/sync-delta/register-device` — registrasi device
- **New tables:**
  - `sync_queue` — antrian delta (id, uid, table, record_id, operation, data, device_id, applied)
  - `sync_devices` — device registry (device_id, uid, last_seen, last_pull)
  - `sync_state` — sync state per user
- RoomDO: broadcast sync events via WebSocket
- 10 performance indexes untuk query cepat

### App (Flutter)
- **DeltaSyncService** — singleton, auto-reconnect, offline queue
- **RealtimeOrderService** — global orders listener (app lifetime, bukan screen-scoped)
- Hook di checkout & product form untuk push delta otomatis

## 🖥️ Dashboard NUSA Online (4 Tab Baru)

### Backup & Recovery (existing, improved)
- File viewer: decrypt .nus1 → spreadsheet-like table view
- Image tooltip/lightbox untuk foto produk
- Export CSV per tabel

### Diagnostic & Recovery
- TAMPILAN DEFAULT: semua user muncul sebagai tabel (tanpa wajib search)
- Stats bar: total user, active licenses, stale backup, issues
- Search: optional filter (real-time, min 2 karakter)
- Expandable rows: klik user → detail panel + repair actions
- One-click repair: Force Backup, Force Sync, Repair Data, Re-sync Images
- Pagination jika user > 100

### Support Center
- FAQ accordion (6 top issues)
- WA Template Generator:
  - Pilih template (Lisensi Expired, Backup Gagal, Sync Error, Gambar Hilang)
  - Isi nama customer + nomor WA
  - Auto-open WhatsApp dengan pesan terformat
  - Copy text button

### Notifications Center
- Notification list: backup gagal, sync error, license expiring, update available
- Filter: all / unread
- Mark as read (single / all)
- Type-based icons (🔴 backup failed, 🟡 sync error, 🟠 license expiring, 🔵 update)

## ⚡ Optimizations

### App
- **ImageCompressService** — resize max 800px, JPEG quality 80%
- **WebSocket exponential backoff** — 1s → 2s → 4s → ... → 30s max (dari 5s fixed)
- **Parallel startup** — independent steps run in parallel
- **SQLite indexes** — products, transactions, customers

### Worker
- Edge caching middleware (Cache-Control headers)
- Rate limiting middleware (10-60 req/min per IP)
- 10 D1 performance indexes

## 🐛 Bug Fixes
- **Laba flip card** — dashboard card sekarang pakai `profitLoss()` (real P&L), bukan `penjualan * 0.9`
- WS import fix di `realtime_order_service.dart`

## 📦 Build
- 16 APK (8 varian full + lite) di `nusa_builds/`
- Version: 2.2.57+131

## 🎯 Target Hasil
| Aksi | Device Lain |
|------|-------------|
| Kasir jual produk | Owner lihat di Laporan < 3 detik |
| Owner edit harga | Semua device lihat harga baru < 3 detik |
| Karyawan adjust stok | Semua device lihat stok update |
| Order online masuk | Semua device dapat notif + data |
| Attendance check-in | Owner lihat realtime |
| Pengeluaran dicatat | Laporan update langsung |
