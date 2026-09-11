# v2.2.57+140 — Image Hydration Animasi + Landing Page Revert

## Ringkasan
- **Image Hydration Glassmorphism Animation**: Per-card overlay progress real-time saat download gambar produk, tanpa restart app
- **Landing Page Revert**: Kembalikan design light NUSA (no glassmorphism AI-slop), update konten Pro/Lite + Servis

## Perubahan

### 1. Image Hydration Real-Time (delta_sync_service.dart + nusa_product_image.dart)

**Latar belakang**: Sebelumnya +138 fix hydrate gambar produk, tapi UI tidak update sampai user restart app. +139 tambah dialog progress tapi tidak ada feedback per-kartu produk.

**Solusi +140**:
- Tambah `ImageHydrationEvent` + `hydrationStream` di `DeltaSyncService` (broadcast per-product)
- `hydrateAllImages` emit event:
  - `0.0` saat mulai download
  - tick `0.06` per 100ms (0.0 → 0.9) selama download — ANTI STUCK
  - `1.0` saat selesai (beserta `localPath`)
- `NusaProductImage` widget jadi `StatefulWidget`, listen stream filtered by `productId`
- Saat progress > 0: render overlay **glassmorphism** (BackdropFilter blur 6 + tint color sesuai tema) di DALAM container image (bukan full card)
- Persentase `%` di tengah container + LinearProgressIndicator kecil di bawah
- Begitu download selesai → overlay hilang, gambar asli langsung muncul

**Warna tint**: Default biru, dioverride per-caller via `tintColor` (mis. `NusaConfig.activePrimary` = sesuai tema varian: oranye kelontong, merah fnb, dll)

**File berubah**:
- `lib/core/services/delta_sync_service.dart` (+62 baris: ImageHydrationEvent, hydrationStream, downloadWithProgress)
- `lib/shared/widgets/nusa_product_image.dart` (rewrite → StatefulWidget + glassmorphism overlay)
- Caller update (4 lokasi) — `pos_screen.dart`, `products_screen.dart` (2x), `label_print_sheet.dart`

**Safety**: 
- Stream listener di-dispose dengan widget lifecycle
- Tidak ada efek kalau `productId == null` (widget jalan seperti Stateles lama)
- Tidak menganggu fallback base64/file lokal existing

### 2. Landing Page Revert (nusa-online page.tsx)

**Latar belakang**: +139 redesign landing ke dark glassmorphism — user anggap AI-slop, tidak sesuai design sistem NUSA (light/orange).

**Solusi +140**: Restore page.tsx ke commit 978569f^ (design original light, orange accents, `bg-white/80 backdrop-blur-lg` navbar, `bg-gray-50/50` sections, `bg-primary-soft` highlights), update konten:
- App: `nusa-servicehp` "Service HP" → `nusa-servis` "Servis", desc "Servis HP, elektronik & gadget"
- Pricing: split jadi 2 tier (`proTiers` Rp 99K/499K + `liteTiers` Rp 49K/249K) dengan toggle pill button "NUSA Pro / NUSA Lite"
- Comparison table: pricing row sekarang tampil Pro Rp 99K/499K + Lite Rp 49K/249K (sebelumnya flat Rp 49K/249K)
- FAQ: tambah "Apa beda NUSA Pro dan Lite?" dengan penjelasan lengkap
- Step 2: "Download & Aktivasi" jelaskan beda Pro (Google Sign-In) vs Lite (email + key)
- Verify: `curl nusa-online.vercel.app` → "Servis", "NUSA Pro", "NUSA Lite", 4 harga (Rp 99K, Rp 49K, Rp 499K, Rp 249K) hadir ✓

**File berubah**:
- `nusa-online/src/app/page.tsx` (~700 baris, restore dari 978569f^ + patch)

## Test
- `flutter analyze lib/` → 0 error (hanya info-level lints yang sudah ada sebelumnya)
- `flutter test` → **105/105 PASS**
- Vercel deploy → `nusa-online.vercel.app` live dengan konten baru ✓

## Build
- `+140` build kelontong PRO+LITE via `_build_all.py kelontong` (akan dijadwalkan setelah konfirmasi)
- 7 varian lain menyusul

## Catatan
- Tidak mengubah sync logic, db schema, atau worker nusa-cloud
- Stream broadcast = aman untuk multiple listener (POS + products grid concurrent)
- Glassmorph: pakai `ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6)` — performance aman untuk overlay container kecil
- 1 use BackdropFilter per card aktif; tidak spam karena listener auto-removed saat progress=null
