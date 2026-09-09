/**
 * fn/index.ts — barrel registrasi semua modul fn.
 *
 * Setiap modul mendaftarkan routenya sendiri via Router.registerAll(...)
 * sebagai side-effect saat di-import — file ini hanya perlu meng-import
 * modulnya agar registrasinya jalan.
 */
// ── License & aktivasi ───────────────────────────────────────────────
import './license_manager';
import './license_cron';
import './register_activation';
import './app_ping';

// ── Toko online ──────────────────────────────────────────────────────
import './online_store';

// ── Sheets / tutorial / AI / payment (ditambahkan agent port kedua) ──
import './sheets_admin';
import './sheets_archive_cron';
import './tutorial_manager';
import './ai_assistant';
import './midtrans';
import './instanpay';

// ── Export & backup recovery ─────────────────────────────────────────
import './export_backup';
import './backup_cron';
import './backup_recovery';

// ── Delta sync ───────────────────────────────────────────────────────
import './sync_delta';
