# Changelog v2.2.57+139

## Bug Fix

### Card flip "Ringkasan Hari Ini" masih 0
**Root cause:** `_fetchCardData` di `dashboard_screen.dart` punya `catch (e)` yang swallow exception. Kalau satu section throw (summary/profitLoss/attendance), seluruh fungsi batal → `_cardData` never set → UI fallback ke 0.

**Fix:**
- Safe cast: `as int` → `(value as num?)?.toInt() ?? 0` di 5 tempat
- Per-section try-catch: bungkus summary, profitLoss, attendance, monthly, pending masing-masing — kalau satu gagal, sisanya tetap jalan
- Error state di UI: tampilkan "Gagal memuat data — Pull untuk refresh" bukan 0 diam-diam

## Refactor

### Rename "Full" → "Pro" (seluruh ekosistem)
**Worker (nusa-cloud):**
- `schema.sql`: `mode TEXT DEFAULT 'pro'` (was 'full')
- `license_manager.ts`: validasi accept 'full' as alias for backward compat, default 'pro'
- `backup_recovery.ts`: default 'pro'

**Dashboard (nusa-online):**
- `license-manager.ts`: `LicenseMode = "pro" | "lite"`
- `page.tsx` + `BackupRecoveryTab.tsx`: label dropdown "Pro — AI, Cabang, Spreadsheet, Toko Online"

**App (nusa_kasir):**
- `_build_all.py`: log "PRO (cloud)" (was "FULL (cloud)")

### Landing Page (nusa-online.vercel.com)
- Tier "Fleksibel" → "Bulanan"
- Tambah badge Pro/Lite di 8 varian
- Tambah feature comparison table (Pro vs Lite)
- Hero copy: "NUSA Pro (Cloud) & NUSA Lite (Offline)"

## Files Changed
- `lib/features/dashboard/dashboard_screen.dart` — `_fetchCardData` per-section try-catch + safe cast
- `lib/shared/widgets/profile_stats_card.dart` — error state untuk null data
- `_build_all.py` — log "PRO (cloud)"
- `pubspec.yaml` — bump +139

## Server-side Changes (tidak perlu rebuild APK)
- `nusa-cloud/schema.sql`
- `nusa-cloud/src/fn/license_manager.ts`
- `nusa-cloud/src/fn/backup_recovery.ts`
- `nusa-online/src/lib/license-manager.ts`
- `nusa-online/src/app/dashboard/page.tsx`
- `nusa-online/src/app/dashboard/_components/BackupRecoveryTab.tsx`
- `nusa-online/src/app/page.tsx` (landing page)

## Test
- flutter analyze: pass
- flutter test: 105/105 pass

## Safety
- Worker terima 'full' sebagai alias 'pro' (backward compat)
- APK filename tetap `nusa-{vid}.apk` (Pro) & `nusa-{vid}_lite.apk` (Lite)
- Tidak ubah sync logic
