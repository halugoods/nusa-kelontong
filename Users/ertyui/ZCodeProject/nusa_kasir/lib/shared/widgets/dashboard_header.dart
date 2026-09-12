import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:nusa_kasir/core/config/nusa_config.dart';
import 'package:nusa_kasir/core/services/auto_sync_service.dart';
import 'package:nusa_kasir/core/utils/icon_loader.dart';

/// NUSA-branded app header: logo + user info + notification bell.
///
/// Matches the reference design:
///   - "NUSA" wordmark in brand red (24px extrabold)
///   - Vertical divider, then user name (13px semibold) + role • branch (11px)
///   - Bell icon (44x44 tap target) with red notification dot
class DashboardHeader extends StatelessWidget {
  final String userName;
  final String role;
  final String branch;
  final bool hasNotification;
  final VoidCallback? onBellTap;
  final VoidCallback? onLogout;
  final String? branchName;
  final bool showBranchIcon;
  final VoidCallback? onBranchTap;

  DashboardHeader({
    super.key,
    this.userName = '',
    this.role = '',
    this.branch = '',
    this.hasNotification = false,
    this.onBellTap,
    this.onLogout,
    this.branchName,
    this.showBranchIcon = false,
    this.onBranchTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          // Left: Logo + NUSA wordmark (horizontal)
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(splashLogoPath(), height: 40, fit: BoxFit.contain),
                SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'NUSA',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                        color: NusaConfig.activePrimary,
                        height: 1,
                      ),
                    ),
                    if (branchName != null && branchName!.isNotEmpty) ...[
                      SizedBox(height: 3),
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: NusaConfig.activePrimary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          branchName!,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: NusaConfig.activePrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),

          // Right: status backup cloud (v2.2.55) + Bell button
          // v2.2.57+116: spacing antar elemen kanan 2px (user: 4px masih
          // longgar). Ikon tetap 44x44 (tap target).
          const _CloudSyncChip(),
          SizedBox(width: 2),
          GestureDetector(
            onTap: onBellTap,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    Icons.notifications_outlined,
                    size: 22,
                    color: isDark
                        ? NusaConfig.darkTextPrimary
                        : NusaConfig.textPrimary,
                  ),
                  if (hasNotification)
                    Positioned(
                      top: 9,
                      right: 10,
                      child: Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: NusaConfig.activePrimary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          // Branch icon — antara lonceng dan logout. Tap → bottom sheet
          // pemilih cabang (slide-up). Hanya muncul jika ada cabang > 1.
          if (showBranchIcon && onBranchTap != null) ...[
            SizedBox(width: 2),
            GestureDetector(
              onTap: onBranchTap,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Center(
                  child: Icon(
                    Icons.storefront_rounded,
                    size: 22,
                    color: isDark
                        ? NusaConfig.darkTextPrimary
                        : NusaConfig.textPrimary,
                  ),
                ),
              ),
            ),
          ],
          if (onLogout != null) ...[
            SizedBox(width: 2),
            // Logout / Ganti Pengguna — switch role tanpa buka ulang app
            GestureDetector(
              onTap: onLogout,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Icon(
                  Icons.logout_rounded,
                  size: 22,
                  color: isDark
                      ? NusaConfig.darkTextPrimary
                      : NusaConfig.textPrimary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Ikon awan status backup cloud otomatis (v2.2.55).
///
/// Tujuan: user TAHU kapan data sudah aman di cloud SEBELUM menghapus
/// data aplikasi (kasus nyata: produk/karyawan hilang karena device
/// dibersihkan saat upload autosync masih berjalan — dulu silent).
///   hijau cloud_done  = backup terakhir HH:MM sudah tersimpan
///   amber cloud_upload= sedang mengunggah
///   merah cloud_off   = upload terakhir gagal (cek koneksi)
///   abu  cloud        = belum ada backup
/// Tap → penjelasan singkat.
class _CloudSyncChip extends StatelessWidget {
  const _CloudSyncChip();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ValueListenableBuilder<AutoSyncStatus>(
      valueListenable: AutoSyncService.status,
      builder: (context, st, _) {
        final IconData icon;
        final Color color;
        switch (st.phase) {
          case AutoSyncPhase.uploading:
            icon = Icons.cloud_upload_outlined;
            color = NusaConfig.warning;
          case AutoSyncPhase.ok:
            icon = Icons.cloud_done_outlined;
            color = NusaConfig.success;
          case AutoSyncPhase.failed:
            icon = Icons.cloud_off_outlined;
            color = NusaConfig.error;
          case AutoSyncPhase.idle:
            icon = Icons.cloud_outlined;
            color = isDark
                ? NusaConfig.darkTextTertiary
                : NusaConfig.textTertiary;
        }
        return GestureDetector(
          onTap: () => _explain(context, st),
          // v2.2.57+115: semua ikon header 44x44 (tap target seragam) dan
          // gap 8px diatur parent Row — spacing kanan-kiri ikon seragam.
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
            ),
            child: Icon(icon, size: 22, color: color),
          ),
        );
      },
    );
  }

  void _explain(BuildContext context, AutoSyncStatus st) {
    final time = st.lastOkAt == null
        ? ''
        : ' terakhir ${DateFormat('HH:mm').format(st.lastOkAt!)}';
    final String msg;
    switch (st.phase) {
      case AutoSyncPhase.uploading:
        msg = 'Mengunggah backup ke cloud…';
      case AutoSyncPhase.ok:
        msg = 'Backup cloud aman (sukses$time).';
      case AutoSyncPhase.failed:
        msg = 'Backup cloud GAGAL${time.isEmpty ? '' : ' (sukses terakhir$time)'}. '
            'Periksa koneksi — akan dicoba ulang otomatis.';
      case AutoSyncPhase.idle:
        msg = 'Belum ada backup cloud. Perubahan data akan otomatis '
            'tersinkron setelah disimpan.';
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}
