import 'dart:io';
import 'package:flutter/material.dart';
import 'package:nusa_kasir/core/config/nusa_config.dart';
import 'package:nusa_kasir/core/utils/format_rupiah.dart';
import 'package:nusa_kasir/shared/widgets/animated_builder.dart'
    show NusaAnimatedBuilder;

/// EmployeeCardData -- pre-fetched data for the flip card back side.
class EmployeeCardData {
  final int penjualan;
  final int laba;
  final int trxCount;
  final int modalAwal;
  final int totalLaci;
  final int selisihLaci;
  final String? shiftHours;
  final int omzet;
  final int transaksiBulan;
  final int hadirDays;
  final int totalDays;
  final int pendingItems;

  EmployeeCardData({
    this.penjualan = 0,
    this.laba = 0,
    this.trxCount = 0,
    this.modalAwal = 0,
    this.totalLaci = 0,
    this.selisihLaci = 0,
    this.shiftHours,
    this.omzet = 0,
    this.transaksiBulan = 0,
    this.hadirDays = 0,
    this.totalDays = 0,
    this.pendingItems = 0,
  });
}

/// Red gradient profile card with 3D flip.
///
/// **Front:** Avatar + name/role/jam hadir/cabang beside photo,
/// 3 KPI stats (PENJUALAN, TRANSAKSI, JAM SHIFT),
/// flip icon on the right edge.
///
/// **Back:** Role-adaptive:
///   - Owner  -> Laba + Penjualan + Transaksi + hubungi karyawan + pending alert
///   - Kasir/Manager -> 2 big quick-action attendance buttons
///
/// v2.2.47: Redesign per user request.
class ProfileStatsCard extends StatefulWidget {
  // -- Front display fields --
  final String? photoPath;
  final String initials;
  final String userName;
  final String role;
  final String branch;
  /// e.g. "09:00" or "Belum absen"
  final String attendanceStatus;
  final String salesValue;
  final String transactionCount;
  /// e.g. "3j 45m" -- shift duration
  final String shiftDuration;
  final String avgValue;
  final String topProduct;

  // -- Flip / back-side fields --
  final String viewerRole;
  final int? viewerEmployeeId;
  final int? employeeId;
  final EmployeeCardData? cardData;
  final Future<bool> Function()? onAuthOwner;
  final VoidCallback? onAbsenMasuk;
  final VoidCallback? onAbsenKeluar;
  final VoidCallback? onKontakWa;
  final VoidCallback? onLogout;

  const ProfileStatsCard({
    super.key,
    this.photoPath,
    this.initials = '?',
    this.userName = 'Belum ada sesi kasir',
    this.role = '',
    this.branch = '',
    this.attendanceStatus = 'Buka Kasir untuk memulai',
    this.salesValue = 'Rp 0',
    this.transactionCount = '0',
    this.shiftDuration = '0j 0m',
    this.avgValue = 'Rp 0',
    this.topProduct = '--',
    this.viewerRole = 'Kasir',
    this.viewerEmployeeId,
    this.employeeId,
    this.cardData,
    this.onAuthOwner,
    this.onAbsenMasuk,
    this.onAbsenKeluar,
    this.onKontakWa,
    this.onLogout,
  });

  @override
  State<ProfileStatsCard> createState() => _ProfileStatsCardState();
}

class _ProfileStatsCardState extends State<ProfileStatsCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;
  bool _isFlipped = false;

  bool get _isSelf =>
      widget.viewerEmployeeId != null &&
      widget.employeeId != null &&
      widget.viewerEmployeeId == widget.employeeId;

  bool get _canFlip =>
      _isSelf || widget.viewerRole == 'Owner';

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 500),
    );
    _anim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _toggleFlip() async {
    if (_isFlipped) {
      _ctrl.reverse();
      setState(() => _isFlipped = false);
      return;
    }
    if (!_canFlip) return;

    if (widget.viewerRole == 'Owner' &&
        widget.onAuthOwner != null &&
        !_isSelf) {
      final ok = await widget.onAuthOwner!();
      if (!ok) return;
    }

    _ctrl.forward();
    setState(() => _isFlipped = true);
  }

  // ─────────────────────────────────────────────────
  // FRONT SIDE
  // ─────────────────────────────────────────────────

  Widget _buildFront() {
    final hasPhoto = widget.photoPath != null &&
        widget.photoPath!.isNotEmpty &&
        File(widget.photoPath!).existsSync();

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: NusaConfig.activePrimary,
      ),
      clipBehavior: Clip.antiAlias,
      padding: EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Row 1: Photo + info + flip icon
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Avatar
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: Colors.white.withValues(alpha: 0.22),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
                  image: hasPhoto
                      ? DecorationImage(
                          image: FileImage(File(widget.photoPath!), scale: 1.0),
                          fit: BoxFit.cover,
                          filterQuality: FilterQuality.low)
                      : null,
                ),
                alignment: Alignment.center,
                child: hasPhoto
                    ? null
                    : Text(widget.initials,
                        style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Colors.white)),
              ),
              SizedBox(width: 14),

              // Name + role + jam hadir + cabang
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.userName,
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          letterSpacing: -0.2,
                          color: Colors.white,
                          height: 1.3),
                    ),
                    SizedBox(height: 2),
                    Text(widget.role,
                        style: TextStyle(
                            fontSize: 12, color: Colors.white.withValues(alpha: 0.9))),
                    SizedBox(height: 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.access_time,
                            size: 12, color: Colors.white.withValues(alpha: 0.7)),
                        SizedBox(width: 4),
                        Text(widget.attendanceStatus,
                            style: TextStyle(
                                fontSize: 11, color: Colors.white.withValues(alpha: 0.95))),
                      ],
                    ),
                    if (widget.branch.isNotEmpty) ...[
                      SizedBox(height: 3),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.store_outlined,
                              size: 12, color: Colors.white.withValues(alpha: 0.7)),
                          SizedBox(width: 4),
                          Text(widget.branch,
                              style: TextStyle(
                                  fontSize: 11, color: Colors.white.withValues(alpha: 0.8))),
                        ],
                      ),
                    ],
                  ],
                ),
              ),

              // Flip icon -- right edge, visible hint
              if (_canFlip)
                GestureDetector(
                  onTap: _toggleFlip,
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: Icon(Icons.flip,
                        size: 18, color: Colors.white.withValues(alpha: 0.9)),
                  ),
                ),
            ],
          ),

          SizedBox(height: 18),
          Container(height: 1, color: Colors.white.withValues(alpha: 0.18)),
          SizedBox(height: 18),

          // Row 2: 3 KPI stats -- PENJUALAN, TRANSAKSI, JAM SHIFT
          _buildFrontStats(),
        ],
      ),
    );
  }

  Widget _buildFrontStats() {
    final stats = [
      _StatData(icon: Icons.monetization_on_outlined,
          value: widget.salesValue, label: 'PENJUALAN'),
      _StatData(icon: Icons.shopping_cart_outlined,
          value: widget.transactionCount, label: 'TRANSAKSI'),
      _StatData(icon: Icons.access_time_rounded,
          value: widget.shiftDuration.isEmpty ? '--' : widget.shiftDuration,
          label: 'JAM SHIFT'),
    ];
    return Row(
      children: stats.map((s) => Expanded(child: _frontStatItem(s))).toList(),
    );
  }

  Widget _frontStatItem(_StatData s) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: Colors.white.withValues(alpha: 0.2),
          ),
          alignment: Alignment.center,
          child: Icon(s.icon, size: 17, color: Colors.white),
        ),
        SizedBox(height: 7),
        Text(s.value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                letterSpacing: -0.2,
                color: Colors.white,
                height: 1.2)),
        SizedBox(height: 3),
        Text(s.label,
            style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.8,
                color: Colors.white.withValues(alpha: 0.85))),
      ],
    );
  }

  // ─────────────────────────────────────────────────
  // BACK CONTENT
  // ─────────────────────────────────────────────────

  Widget _buildBackContent() {
    switch (widget.viewerRole) {
      case 'Kasir':
        return _buildKasirBack(widget.cardData);
      case 'Manager':
        return _buildManagerBack(widget.cardData);
      default:
        return _buildOwnerBack(widget.cardData);
    }
  }

  // -- Kasir: quick-action attendance --

  Widget _buildKasirBack(EmployeeCardData? data) {
    return Padding(
      padding: EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _backHeader(Icons.point_of_sale, 'Aksi Cepat'),
          SizedBox(height: 16),
          _bigActionBtn('Absen Masuk', Icons.login_rounded,
              Colors.white, widget.onAbsenMasuk),
          SizedBox(height: 12),
          _bigActionBtn('Absen Keluar', Icons.logout_rounded,
              Colors.white, widget.onAbsenKeluar),
        ],
      ),
    );
  }

  // -- Manager: quick-action attendance --

  Widget _buildManagerBack(EmployeeCardData? data) {
    return Padding(
      padding: EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _backHeader(Icons.person_outline, 'Aksi Cepat'),
          SizedBox(height: 16),
          _bigActionBtn('Absen Masuk', Icons.login_rounded,
              Colors.white, widget.onAbsenMasuk),
          SizedBox(height: 12),
          _bigActionBtn('Absen Keluar', Icons.logout_rounded,
              Colors.white, widget.onAbsenKeluar),
          SizedBox(height: 16),
          Container(height: 1, color: Colors.white.withValues(alpha: 0.18)),
          SizedBox(height: 16),
          _smallActionBtn('Hubungi WA', Icons.chat_rounded, widget.onKontakWa),
        ],
      ),
    );
  }

  // -- Owner: Laba + hubungi karyawan --

  Widget _buildOwnerBack(EmployeeCardData? data) {
    // v2.2.57+139: error state — kalau fetch gagal, tampilkan pesan, bukan 0
    if (data == null) {
      return Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _backHeader(Icons.insights, 'Ringkasan Hari Ini'),
            SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                children: [
                  Icon(Icons.error_outline,
                      color: Colors.white.withValues(alpha: 0.7), size: 32),
                  SizedBox(height: 8),
                  Text('Gagal memuat data',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 14)),
                  SizedBox(height: 4),
                  Text('Pull untuk refresh atau coba lagi nanti',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 11)),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final isRed = (data?.selisihLaci ?? 0) < 0;

    return Padding(
      padding: EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _backHeader(Icons.insights, 'Ringkasan Hari Ini'),
          SizedBox(height: 16),

          // Laba penjualan -- hero stat
          Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(vertical: 16, horizontal: 18),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              children: [
                Text('LABA PENJUALAN',
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.0,
                        color: Colors.white.withValues(alpha: 0.75))),
                SizedBox(height: 6),
                Text(formatRupiah(data?.laba ?? 0),
                    style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.5,
                        color: Colors.white)),
              ],
            ),
          ),

          SizedBox(height: 14),

          // Penjualan + Transaksi row
          Row(
            children: [
              Expanded(child: _backMiniStat('Penjualan', formatRupiah(data?.penjualan ?? 0))),
              SizedBox(width: 10),
              Expanded(child: _backMiniStat('Transaksi', '${data?.trxCount ?? 0}')),
            ],
          ),

          // Selisih laci
          if ((data?.selisihLaci ?? 0) != 0) ...[
            SizedBox(height: 10),
            _backMiniStat('Selisih Laci', formatRupiah(data!.selisihLaci.abs()),
                valueColor: isRed ? NusaConfig.accentGold : Color(0xFF4ADE80),
                suffix: isRed ? ' (kurang)' : ' (lebih)'),
          ],

          // Pending items alert
          if ((data?.pendingItems ?? 0) > 0) ...[
            SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.notifications_active,
                      size: 15, color: NusaConfig.accentGold),
                  SizedBox(width: 6),
                  Text('${data!.pendingItems} pesanan perlu diproses',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.white)),
                ],
              ),
            ),
          ],

          SizedBox(height: 16),
          Container(height: 1, color: Colors.white.withValues(alpha: 0.18)),
          SizedBox(height: 16),

          // Hubungi karyawan button
          _bigActionBtn('Hubungi Karyawan', Icons.chat_rounded,
              Colors.white.withValues(alpha: 0.9), widget.onKontakWa),
        ],
      ),
    );
  }

  // -- Shared back helpers --

  Widget _backHeader(IconData icon, String title) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
        SizedBox(width: 10),
        Expanded(
          child: Text(title,
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: Colors.white)),
        ),
        GestureDetector(
          onTap: _toggleFlip,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.flip,
                size: 16, color: Colors.white.withValues(alpha: 0.85)),
          ),
        ),
      ],
    );
  }

  /// Big rounded button -- quick-action attendance & hubungi karyawan.
  Widget _bigActionBtn(
      String label, IconData icon, Color color, VoidCallback? onTap) {
    return Material(
      color: Colors.white.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(vertical: 16),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: color),
              SizedBox(width: 10),
              Text(label,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: color)),
            ],
          ),
        ),
      ),
    );
  }

  /// Small secondary button.
  Widget _smallActionBtn(
      String label, IconData icon, VoidCallback? onTap) {
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: EdgeInsets.symmetric(vertical: 12),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 17,
                    color: Colors.white.withValues(alpha: 0.85)),
                SizedBox(width: 7),
                Text(label,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.white.withValues(alpha: 0.9))),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _backMiniStat(String label, String value,
      {Color? valueColor, String suffix = ''}) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(vertical: 10, horizontal: 14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style:
                  TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.75))),
          Text('$value$suffix',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: valueColor ?? Colors.white,
              )),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────
  // BACK WRAPPER
  // ─────────────────────────────────────────────────

  Widget _buildBack() {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: NusaConfig.activePrimary,
      ),
      clipBehavior: Clip.antiAlias,
      child: _buildBackContent(),
    );
  }

  // ─────────────────────────────────────────────────
  // 3D FLIP BUILD
  // ─────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 20),
      child: GestureDetector(
        onTap: _toggleFlip,
        child: NusaAnimatedBuilder(
          animation: _anim,
          builder: (context, child) {
            final isFrontVisible = _anim.value <= 0.5;
            return Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.001)
                ..rotateY(_anim.value * 3.14159),
              child: isFrontVisible
                  ? _buildFront()
                  : Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.identity()..rotateY(3.14159),
                      child: _buildBack(),
                    ),
            );
          },
        ),
      ),
    );
  }
}

class _StatData {
  final IconData icon;
  final String value;
  final String label;
  _StatData(
      {required this.icon, required this.value, required this.label});
}
