# CHANGELOG v2.2.57+133

> Release: 2026-09-10
> Fix Kritis: Delta Sync Anti-Clobber + Pemulihan Foto Otomatis

## 🛠 Fix Kritis — Data Tertimpa di Device Penerima
Delta sync +132 punya bug: update parsial (mis. perubahan stok dari transaksi
kasir) ikut menimpa kolom lain dengan nilai kosong di device penerima — nama
produk jadi kosong, harga jadi 0, foto hilang.

Sekarang delta UPDATE **hanya menulis kolom yang memang dikirim**:
- Perubahan stok → cuma kolom stok
- Void transaksi → cuma status + alasan void
- Update poin pelanggan → cuma poin/level
- Berlaku untuk semua 23 tabel yang di-sync

## 📷 Pemulihan Foto Otomatis Setelah Restore
- Foto produk & karyawan otomatis ditarik dari cloud langsung setelah
  restore selesai (dulu harus restart app 2×)
- Foto hasil crop di form produk ikut ter-pulihkan (dulu ter-skip)
- Upload foto hasil crop ke cloud ikut diperbaiki

## ✅ Verifikasi
- flutter analyze: 0 error
- flutter test: 98 pass
