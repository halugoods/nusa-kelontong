# CHANGELOG v2.2.57+132

> Release: 2026-09-10
> Delta Sync Lengkap — SEMUA Perubahan Data Tersinkron Antar-Device

## 🔄 Delta Sync: Cakupan Diperluas ke SEMUA Data
Sebelumnya hanya 4 domain yang tersinkron realtime (produk, transaksi, role, karyawan).
Sekarang **23 tabel** ikut delta sync — perubahan apa pun muncul di device lain dalam
~2 detik (realtime) atau ≤30 detik (fallback), tanpa menunggu backup penuh.

### Yang baru tersinkron realtime:
- **Cabang** — tambah/ubah/hapus
- **Kategori** — tambah/hapus/rename (produk terkait ikut ter-update)
- **Pelanggan** — data, poin, total belanja, level
- **Promo** — tambah/ubah/hapus, status, jumlah pemakaian
- **Pengaturan** — nama toko, alamat, struk, min. belanja, dsb (~15 field)
- **Hutang & Piutang** — hutang baru, cicilan, jatuh tempo, pembayaran
- **Void Transaksi** — status void + stok produk balik otomatis + hutang terkait
- **Keuangan** — pengeluaran, kategori pengeluaran, pengeluaran rutin, payroll, waste, liquidity
- **Presensi & Shift** — check-in/out, uang petty/final, tutup shift
- **Stok Opname** — sesi + item opname
- **Order Online** — order baru + perubahan status
- **Order Cetak (Percetakan)** — order baru/status/edit/hapus
- **Pembelian (Restock)** — purchase order + stok & HPP produk
- **Stok** — semua perubahan stok lewat satu titik terpusat (kasir, retur, restock, opname, order online)
- **Supplier** — tambah/ubah/hapus

## 🔧 Perbaikan Teknis
- Konsistensi nama tabel snake_case di push & apply (cekak antar-device)
- Invoice transaksi diambil persis dari DB (bukan di-generate ulang)
- Settings diterapkan sebagai partial update (field yang dikirim saja)
- Kategori di-match by name (id lokal bisa beda antar-device)

## ✅ Verifikasi
- flutter analyze: 0 error
- flutter test: 98 pass
- Worker/dashboard TIDAK berubah (sync_queue sudah table-agnostic)

## 📦 Catatan
Rilis pilot varian Kelontong untuk testing. Varian lain menyusul setelah konfirmasi.
