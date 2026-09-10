import 'dart:convert' as dart_convert;
import 'package:nusa_kasir/core/services/delta_sync_service.dart';
import 'package:nusa_kasir/data/database/app_database.dart';
import 'package:drift/drift.dart';

class SettingsRepository {
  final AppDatabase db;
  SettingsRepository(this.db);

  /// Push settings delta to cloud (settings is single-row table, id=1).
  void _pushDelta(String field, dynamic value) {
    DeltaSyncService.I.pushDelta(
      table: 'settings',
      recordId: '1',
      operation: 'UPDATE',
      data: {'id': 1, field: value},
    );
  }

  Future<String> getStoreName() async {
    final row = await db.select(db.settings).getSingleOrNull();
    return row?.storeName ?? '';
  }

  /// Get the Owner employee's name from the Employees table.
  Future<String> getOwnerName() async {
    try {
      final owner = await (db.select(db.employees)
            ..where((t) => t.role.equals('Owner'))
            ..limit(1))
          .getSingleOrNull();
      return owner?.name ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> ensureRow() async {
    if (await db.select(db.settings).getSingleOrNull() == null) {
      await db.into(db.settings).insert(SettingsCompanion.insert());
    }
  }

  Future<String> getStorePhone() async {
    final row = await db.select(db.settings).getSingleOrNull();
    return row?.storePhone ?? '';
  }

  Future<void> setStoreName(String name) async {
    await ensureRow();
    await (db.update(db.settings)..where((t) => t.id.equals(1)))
        .write(SettingsCompanion(storeName: Value(name)));
    _pushDelta('storeName', name);
  }

  /// v2.2.57+112: setter no. HP toko — kolom storePhone sudah ada sejak lama,
  /// tapi tidak pernah ditulis dari app (dulu cuma dari toko online cloud).
  Future<void> setStorePhone(String phone) async {
    await ensureRow();
    await (db.update(db.settings)..where((t) => t.id.equals(1)))
        .write(SettingsCompanion(storePhone: Value(phone)));
    _pushDelta('storePhone', phone);
  }

  /// v2.2.57+112: setter alamat toko — kolom storeAddress sudah ada sejak lama,
  /// tapi tidak pernah dipakai (dulu cuma dari toko online cloud).
  Future<void> setStoreAddress(String address) async {
    await ensureRow();
    await (db.update(db.settings)..where((t) => t.id.equals(1)))
        .write(SettingsCompanion(storeAddress: Value(address)));
    _pushDelta('storeAddress', address);
  }

  Future<String> getStoreAddress() async {
    final row = await db.select(db.settings).getSingleOrNull();
    return row?.storeAddress ?? '';
  }

  Future<void> setQris(String v) async {
    await ensureRow();
    await (db.update(db.settings)..where((t) => t.id.equals(1)))
        .write(SettingsCompanion(qrisString: Value(v)));
    _pushDelta('qrisString', v);
  }

  Future<String?> getQris() async =>
      (await db.select(db.settings).getSingleOrNull())?.qrisString;

  Future<String?> getThemeMode() async =>
      (await db.select(db.settings).getSingleOrNull())?.themeMode;

  Future<void> setThemeMode(String mode) async {
    await ensureRow();
    await (db.update(db.settings)..where((t) => t.id.equals(1)))
        .write(SettingsCompanion(themeMode: Value(mode)));
    _pushDelta('themeMode', mode);
  }

  Future<String?> getPrinterAddress() async =>
      (await db.select(db.settings).getSingleOrNull())?.posPrefix;

  Future<void> setPrinterAddress(String address) async {
    await ensureRow();
    await (db.update(db.settings)..where((t) => t.id.equals(1)))
        .write(SettingsCompanion(posPrefix: Value(address)));
    _pushDelta('posPrefix', address);
  }

  // Grid columns for POS screen (1, 2, or 3)
  Future<int> getPosGridColumns() async =>
      (await db.select(db.settings).getSingleOrNull())?.posGridColumns ?? 2;

  Future<void> setPosGridColumns(int cols) async {
    await ensureRow();
    await (db.update(db.settings)..where((t) => t.id.equals(1)))
        .write(SettingsCompanion(posGridColumns: Value(cols)));
    _pushDelta('posGridColumns', cols);
  }

  // Grid columns for Products screen (1 or 2)
  Future<int> getProductsGridColumns() async {
    // Reuse the posGridColumns field for simplicity, default to 2
    final row = await db.select(db.settings).getSingleOrNull();
    return row?.posGridColumns != null ? (row!.posGridColumns > 2 ? 2 : row.posGridColumns) : 2;
  }

  Future<void> setProductsGridColumns(int cols) async {
    await ensureRow();
    // Store products grid in the same field — they share the same preference
    // but we limit to 1-2 for products screen
    final clamped = cols.clamp(1, 2);
    await (db.update(db.settings)..where((t) => t.id.equals(1)))
        .write(SettingsCompanion(posGridColumns: Value(clamped)));
  }

  // Bank transfer settings
  Future<String?> getBankName() async =>
      (await db.select(db.settings).getSingleOrNull())?.bankName;

  Future<String?> getBankAccount() async =>
      (await db.select(db.settings).getSingleOrNull())?.bankAccount;

  Future<String?> getBankHolder() async =>
      (await db.select(db.settings).getSingleOrNull())?.bankHolder;

  Future<void> setBankInfo({String? name, String? account, String? holder}) async {
    await ensureRow();
    final c = SettingsCompanion(
      bankName: name != null ? Value(name) : const Value.absent(),
      bankAccount: account != null ? Value(account) : const Value.absent(),
      bankHolder: holder != null ? Value(holder) : const Value.absent(),
    );
    await (db.update(db.settings)..where((t) => t.id.equals(1))).write(c);
    if (name != null) _pushDelta('bankName', name);
    if (account != null) _pushDelta('bankAccount', account);
    if (holder != null) _pushDelta('bankHolder', holder);
  }

  // ── Receipt footer ──
  Future<String?> getReceiptFooter() async =>
      (await db.select(db.settings).getSingleOrNull())?.receiptFooter;

  Future<void> setReceiptFooter(String text) async {
    await ensureRow();
    await (db.update(db.settings)..where((t) => t.id.equals(1)))
        .write(SettingsCompanion(receiptFooter: Value(text)));
    _pushDelta('receiptFooter', text);
  }

  // ── QRIS Image (replaces qrisString) ──
  Future<String?> getQrisImagePath() async =>
      (await db.select(db.settings).getSingleOrNull())?.qrisImagePath;

  Future<void> setQrisImagePath(String? path) async {
    await ensureRow();
    await (db.update(db.settings)..where((t) => t.id.equals(1)))
        .write(SettingsCompanion(qrisImagePath: Value(path)));
    _pushDelta('qrisImagePath', path);
  }

  // ── Receipt advanced ──
  Future<String?> getReceiptHeader() async =>
      (await db.select(db.settings).getSingleOrNull())?.receiptHeader;

  Future<void> setReceiptHeader(String text) async {
    await ensureRow();
    await (db.update(db.settings)..where((t) => t.id.equals(1)))
        .write(SettingsCompanion(receiptHeader: Value(text)));
    _pushDelta('receiptHeader', text);
  }

  // ── Receipt sub-header (alamat toko — v2.2.30) ──
  Future<String?> getReceiptSubHeader() async =>
      (await db.select(db.settings).getSingleOrNull())?.receiptSubHeader;

  Future<void> setReceiptSubHeader(String text) async {
    await ensureRow();
    await (db.update(db.settings)..where((t) => t.id.equals(1)))
        .write(SettingsCompanion(receiptSubHeader: Value(text)));
    _pushDelta('receiptSubHeader', text);
  }

  Future<String> getReceiptPaperSize() async =>
      (await db.select(db.settings).getSingleOrNull())?.receiptPaperSize ?? '58mm';

  Future<void> setReceiptPaperSize(String size) async {
    await ensureRow();
    await (db.update(db.settings)..where((t) => t.id.equals(1)))
        .write(SettingsCompanion(receiptPaperSize: Value(size)));
    _pushDelta('receiptPaperSize', size);
  }

  Future<Map<String, bool>> getReceiptToggles() async {
    final row = await db.select(db.settings).getSingleOrNull();
    return {
      'showLogo': row?.receiptShowLogo ?? true,
      'showCashier': row?.receiptShowCashier ?? true,
      'showInvoice': row?.receiptShowInvoice ?? true,
      'showDate': row?.receiptShowDate ?? true,
    };
  }

  Future<void> setReceiptToggles(Map<String, bool> toggles) async {
    await ensureRow();
    await (db.update(db.settings)..where((t) => t.id.equals(1)))
        .write(SettingsCompanion(
      receiptShowLogo: Value(toggles['showLogo'] ?? true),
      receiptShowCashier: Value(toggles['showCashier'] ?? true),
      receiptShowInvoice: Value(toggles['showInvoice'] ?? true),
      receiptShowDate: Value(toggles['showDate'] ?? true),
    ));
    _pushDelta('receiptToggles', toggles);
  }

  // ── Store logo path ──
  Future<String?> getStoreLogoPath() async =>
      (await db.select(db.settings).getSingleOrNull())?.storeLogoPath;

  Future<void> setStoreLogoPath(String path) async {
    await ensureRow();
    await (db.update(db.settings)..where((t) => t.id.equals(1)))
        .write(SettingsCompanion(storeLogoPath: Value(path)));
    _pushDelta('storeLogoPath', path);
  }

  // ── WA Templates ──
  Future<List<Map<String, String>>> getWaTemplates() async {
    final row = await db.select(db.settings).getSingleOrNull();
    final json = row?.waTemplates;
    if (json == null || json.isEmpty) return _defaultTemplates();
    try {
      final list = (dart_convert.jsonDecode(json) as List)
          .cast<Map<String, dynamic>>();
      return list.map((m) => {
        'name': '${m['name'] ?? ''}',
        'body': '${m['body'] ?? ''}',
      }).toList();
    } catch (_) {
      return _defaultTemplates();
    }
  }

  List<Map<String, String>> _defaultTemplates() => [
    {'name': 'Pesanan Siap', 'body': 'Halo {nama}, pesanan Anda dengan invoice {invoice} sudah siap! Total: {total}. Terima kasih sudah berbelanja di {toko} 🥟'},
    {'name': 'Info Toko', 'body': 'Halo {nama}, terima kasih sudah berkunjung ke {toko}. Ada promo terbaru nih, jangan sampai kelewatan! 🎉'},
    {'name': 'Promo', 'body': 'Halo {nama}, dapatkan promo spesial di {toko}! Buruan check out sebelum kehabisan 🏃'},
  ];

  Future<void> saveWaTemplates(List<Map<String, String>> templates) async {
    await ensureRow();
    final json = dart_convert.jsonEncode(templates);
    await (db.update(db.settings)..where((t) => t.id.equals(1)))
        .write(SettingsCompanion(waTemplates: Value(json)));
  }

  // ── PIN length config (4 or 6) ──
  Future<int> getPinLength() async =>
      (await db.select(db.settings).getSingleOrNull())?.pinLength ?? 6;

  Future<void> setPinLength(int length) async {
    assert(length == 4 || length == 6);
    await ensureRow();
    await (db.update(db.settings)..where((t) => t.id.equals(1)))
        .write(SettingsCompanion(pinLength: Value(length)));
  }

  // ── Point system config ──
  Future<Map<String, int>> getPointConfig() async {
    final row = await db.select(db.settings).getSingleOrNull();
    return {
      'pointsPerRupiah': row?.pointsPerRupiah ?? 100,
      'silverThreshold': row?.silverThreshold ?? 0,
      'goldThreshold': row?.goldThreshold ?? 1000,
      'platinumThreshold': row?.platinumThreshold ?? 5000,
    };
  }

  Future<void> savePointConfig({
    required int pointsPerRupiah,
    required int silverThreshold,
    required int goldThreshold,
    required int platinumThreshold,
  }) async {
    await ensureRow();
    await (db.update(db.settings)..where((t) => t.id.equals(1)))
        .write(SettingsCompanion(
      pointsPerRupiah: Value(pointsPerRupiah),
      silverThreshold: Value(silverThreshold),
      goldThreshold: Value(goldThreshold),
      platinumThreshold: Value(platinumThreshold),
    ));
  }
}
