import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart';
import 'package:path_provider/path_provider.dart';
import 'package:nusa_kasir/core/services/delta_sync_service.dart';
import 'package:nusa_kasir/data/database/app_database.dart';

class AttendanceRepository {
  final AppDatabase db;
  AttendanceRepository(this.db);

  // ---- Employees ----
  Future<List<Employee>> getEmployees() =>
      (db.select(db.employees)..orderBy([
            (t) => OrderingTerm(expression: t.name, mode: OrderingMode.asc),
          ]))
          .get();

  Future<Employee?> getEmployee(int id) => (db.select(
    db.employees,
  )..where((t) => t.id.equals(id))).getSingleOrNull();

  /// Find an active Owner/Manager whose PIN can be used as a secure override
  /// when a cashier's PIN is blocked/unavailable. This grants access to the
  /// PIN-gated action WITHOUT switching the current session.
  Future<Employee?> findOverrideEmployee() async {
    final emps = await getEmployees();
    for (final e in emps) {
      if (e.status == 'Nonaktif') continue;
      if (e.role == 'Owner' || e.role == 'Manager') return e;
    }
    return null;
  }

  Future<int> addEmployee({
    required String name,
    required String pin,
    required String role,
    int? branchId,
    String? phone,
    String? photoPath,
    String? photoBase64,
    int? baseSalary,
    DateTime? startDate,
    String? status,
    String? workStart,
    String? workEnd,
    bool requiresCashOpen = false,
    bool requiresCashClose = false,
    String? barcode,
    bool isServiceStaff = true,
    double commissionPercent = 10.0,
  }) {
    return db
        .into(db.employees)
        .insert(
          EmployeesCompanion.insert(
            name: name,
            pin: pin,
            role: role,
            branchId: Value(branchId),
            phone: Value(phone),
            photoPath: Value(photoPath),
            photoBase64: Value(photoBase64),
            baseSalary: Value(baseSalary),
            startDate: Value(startDate),
            status: Value(status),
            workStart: Value(workStart),
            workEnd: Value(workEnd),
            requiresCashOpen: Value(requiresCashOpen),
            requiresCashClose: Value(requiresCashClose),
            barcode: Value(barcode),
            isServiceStaff: Value(isServiceStaff),
            commissionPercent: Value(commissionPercent),
          ),
        );
  }

  Future<void> updateEmployee({
    required int id,
    required String name,
    required String pin,
    required String role,
    int? branchId,
    String? phone,
    String? photoPath,
    String? photoBase64,
    int? baseSalary,
    DateTime? startDate,
    String? status,
    String? workStart,
    String? workEnd,
    bool requiresCashOpen = false,
    bool requiresCashClose = false,
    String? barcode,
    bool isServiceStaff = true,
    double? commissionPercent,
  }) => (db.update(db.employees)..where((t) => t.id.equals(id))).write(
    EmployeesCompanion(
      name: Value(name),
      pin: Value(pin),
      role: Value(role),
      branchId: Value(branchId),
      phone: Value(phone),
      photoPath: Value(photoPath),
      photoBase64: Value(photoBase64),
      baseSalary: Value(baseSalary),
      startDate: Value(startDate),
      status: Value(status),
      workStart: Value(workStart),
      workEnd: Value(workEnd),
      requiresCashOpen: Value(requiresCashOpen),
      requiresCashClose: Value(requiresCashClose),
      barcode: Value(barcode),
      isServiceStaff: Value(isServiceStaff),
      // null = jangan sentuh kolom (Value.absent).
      commissionPercent: commissionPercent == null
          ? const Value.absent()
          : Value(commissionPercent),
    ),
  );

  Future<void> updateEmployeePhone(int id, String phone) =>
      (db.update(db.employees)..where((t) => t.id.equals(id))).write(
        EmployeesCompanion(phone: Value(phone)),
      );

  Future<void> updateEmployeeStatus(int id, String status) =>
      (db.update(db.employees)..where((t) => t.id.equals(id))).write(
        EmployeesCompanion(status: Value(status)),
      );

  /// Find an employee by their custom barcode (id-card) — B8. Mencocokkan
  /// barcode persis (sudah di-normalize oleh pemanggil via normalizeBarcode).
  Future<Employee?> getByBarcode(String barcode, {String? status}) {
    final query = db.select(db.employees)
      ..where((t) => t.barcode.equals(barcode));
    if (status != null) {
      query.where((t) => t.status.equals(status));
    }
    return query.getSingleOrNull();
  }

  /// Store / change the custom barcode for an employee.
  Future<void> setBarcode(int employeeId, String barcode) =>
      (db.update(db.employees)..where((t) => t.id.equals(employeeId))).write(
        EmployeesCompanion(barcode: Value(barcode)),
      );

  /// Clear the barcode from an employee (set back to null / unused).
  Future<void> clearBarcode(int employeeId) =>
      (db.update(db.employees)..where((t) => t.id.equals(employeeId))).write(
        EmployeesCompanion(barcode: const Value.absent()),
      );

  /// Bulk-migrate all employee PINs when changing PIN length.
  /// - When shrinking (e.g. 6→4): take the first [newLength] digits
  /// - When expanding (e.g. 4→6): pad with '0' on the right
  Future<void> migrateAllPins(int oldLength, int newLength) async {
    if (oldLength == newLength) return;
    final emps = await getEmployees();
    for (final e in emps) {
      String newPin;
      if (newLength < oldLength) {
        // 6→4: take first 4 digits
        newPin = e.pin.substring(0, newLength);
      } else {
        // 4→6: pad with zeros on the right
        newPin = e.pin.padRight(newLength, '0');
      }
      await (db.update(db.employees)..where((t) => t.id.equals(e.id))).write(
        EmployeesCompanion(pin: Value(newPin)),
      );
    }
  }

  Future<void> deleteEmployee(int id) =>
      (db.delete(db.employees)..where((t) => t.id.equals(id))).go();

  /// Find employee by their NFC tag hash (for tap-to-login).
  Future<Employee?> getByNfcTag(String tagHash) => (db.select(
    db.employees,
  )..where((t) => t.nfcTag.equals(tagHash))).getSingleOrNull();

  /// Store the NFC tag hash for an employee.
  Future<void> setNfcTag(int employeeId, String tagHash) =>
      (db.update(db.employees)..where((t) => t.id.equals(employeeId))).write(
        EmployeesCompanion(nfcTag: Value(tagHash)),
      );

  /// Remove the NFC tag assignment from an employee.
  Future<void> clearNfcTag(int employeeId) =>
      (db.update(db.employees)..where((t) => t.id.equals(employeeId))).write(
        EmployeesCompanion(nfcTag: const Value.absent()),
      );

  /// B1 (v2.2.45): pulihkan file foto profil karyawan dari BASE64 (kolom
  /// photo_base64) ke disk. photoPath cuma path lokal yang TIDAK ikut backup
  /// cloud — setelah restore di device baru file-nya tidak ada. Di sini foto
  /// ditulis ulang ke documents dir lalu photoPath diperbarui supaya SEMUA UI
  /// (list karyawan, detail, presensi, kartu ID) langsung tampil.
  /// Dipanggil sekali setelah restore / saat app buka. Idempoten.
  Future<int> hydratePhotos() async {
    final emps = await getEmployees();
    var restored = 0;
    for (final e in emps) {
      final b64 = e.photoBase64;
      if (b64 == null || b64.isEmpty) continue;
      final path = e.photoPath;
      final exists = path != null &&
          path.isNotEmpty &&
          File(path).existsSync();
      if (exists) continue;
      try {
        final bytes = base64Decode(b64);
        final name =
            'photo_${e.id}_${DateTime.now().millisecondsSinceEpoch}.jpg';
        final dir = await getApplicationDocumentsDirectory();
        final dest = File('${dir.path}/$name');
        await dest.writeAsBytes(bytes, flush: true);
        await (db.update(db.employees)..where((t) => t.id.equals(e.id)))
            .write(EmployeesCompanion(photoPath: Value(dest.path)));
        restored++;
      } catch (_) {
        // foto rusak → skip, jangan sampai hydrate gagal total
      }
    }
    return restored;
  }

  // ---- Attendance ----
  Future<AttendanceData?> getToday(int employeeId) async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final end = start.add(const Duration(days: 1));
    final list =
        await (db.select(db.attendance)
              ..where(
                (t) =>
                    t.employeeId.equals(employeeId) &
                    t.date.isBiggerThanValue(start) &
                    t.date.isSmallerThanValue(end),
              )
              ..orderBy([
                (t) =>
                    OrderingTerm(expression: t.date, mode: OrderingMode.desc),
              ])
              ..limit(1))
            .get();
    return list.isNotEmpty ? list.first : null;
  }

  /// Get today's attendance for ALL employees.
  Future<Map<int, AttendanceData?>> getAllToday() async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final end = start.add(const Duration(days: 1));
    final list = await (db.select(
      db.attendance,
    )..where((t) => t.date.isBetweenValues(start, end))).get();
    final map = <int, AttendanceData?>{};
    for (final a in list) {
      if (!map.containsKey(a.employeeId)) {
        map[a.employeeId] = a;
      }
    }
    return map;
  }

  /// Today's summary: {hadir, terlambat, izin, belum}
  Future<Map<String, int>> getTodaySummary() async {
    final emps = await getEmployees();
    final todayMap = await getAllToday();
    int hadir = 0, terlambat = 0, izin = 0, belum = 0;
    for (final e in emps) {
      final att = todayMap[e.id];
      if (att == null || att.checkIn == null) {
        if (att?.status == 'Izin' || att?.status == 'Sakit') {
          izin++;
        } else {
          belum++;
        }
      } else {
        final parts = (att.checkIn ?? '').split(':');
        if (parts.length >= 2) {
          final h = int.tryParse(parts[0]) ?? 0;
          final m = int.tryParse(parts[1]) ?? 0;
          // Use per-employee workStart + 15 min grace
          final ws = e.workStart ?? '08:00';
          final wsParts = ws.split(':');
          final wsH = int.tryParse(wsParts.isNotEmpty ? wsParts[0] : '8') ?? 8;
          final wsM = wsParts.length >= 2 ? (int.tryParse(wsParts[1]) ?? 0) : 0;
          final threshold = wsH * 60 + wsM + 15;
          if ((h * 60 + m) > threshold) {
            terlambat++;
          } else {
            hadir++;
          }
        } else {
          hadir++;
        }
      }
    }
    return {
      'hadir': hadir,
      'terlambat': terlambat,
      'izin': izin,
      'belum': belum,
    };
  }

  Future<void> checkIn(int employeeId) async {
    final now = DateTime.now();
    final today = await getToday(employeeId);
    final time =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    if (today == null) {
      final newId = await db
          .into(db.attendance)
          .insert(
            AttendanceCompanion.insert(
              employeeId: employeeId,
              checkIn: Value(time),
            ),
          );
      DeltaSyncService.I.pushDelta(
        table: 'attendance',
        recordId: newId.toString(),
        operation: 'INSERT',
        data: {
          'id': newId,
          'employeeId': employeeId,
          'checkIn': time,
          'date': now.toIso8601String(),
        },
      );
      return;
    } else if (today.checkIn == null) {
      await (db.update(db.attendance)..where((t) => t.id.equals(today.id)))
          .write(AttendanceCompanion(checkIn: Value(time)));
      DeltaSyncService.I.pushDelta(
        table: 'attendance',
        recordId: today.id.toString(),
        operation: 'UPDATE',
        data: {'id': today.id, 'employeeId': employeeId, 'checkIn': time},
      );
    }
  }

  Future<void> checkOut(int employeeId) async {
    final now = DateTime.now();
    final today = await getToday(employeeId);
    final time =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    if (today == null) {
      final newId = await db
          .into(db.attendance)
          .insert(
            AttendanceCompanion.insert(
              employeeId: employeeId,
              checkOut: Value(time),
            ),
          );
      DeltaSyncService.I.pushDelta(
        table: 'attendance',
        recordId: newId.toString(),
        operation: 'INSERT',
        data: {
          'id': newId,
          'employeeId': employeeId,
          'checkOut': time,
          'date': now.toIso8601String(),
        },
      );
      return;
    } else if (today.checkOut == null) {
      await (db.update(db.attendance)..where((t) => t.id.equals(today.id)))
          .write(AttendanceCompanion(checkOut: Value(time)));
      DeltaSyncService.I.pushDelta(
        table: 'attendance',
        recordId: today.id.toString(),
        operation: 'UPDATE',
        data: {'id': today.id, 'employeeId': employeeId, 'checkOut': time},
      );
    }
  }

  Future<void> setPettyCash(int attendanceId, int amount) async {
    await (db.update(db.attendance)..where((t) => t.id.equals(attendanceId))).write(
      AttendanceCompanion(pettyCash: Value(amount)),
    );
    DeltaSyncService.I.pushDelta(
      table: 'attendance',
      recordId: attendanceId.toString(),
      operation: 'UPDATE',
      data: {'id': attendanceId, 'pettyCash': amount},
    );
  }

  Future<void> setPettyCashForToday(int employeeId, int amount) async {
    final today = await getToday(employeeId);
    final id =
        today?.id ??
        await db
            .into(db.attendance)
            .insert(AttendanceCompanion.insert(employeeId: employeeId));
    await setPettyCash(id, amount);
  }

  Future<void> setFinalCashForToday(int employeeId, int amount) async {
    final today = await getToday(employeeId);
    final id =
        today?.id ??
        await db
            .into(db.attendance)
            .insert(AttendanceCompanion.insert(employeeId: employeeId));
    await (db.update(db.attendance)..where((t) => t.id.equals(id))).write(
      AttendanceCompanion(finalCash: Value(amount)),
    );
    DeltaSyncService.I.pushDelta(
      table: 'attendance',
      recordId: id.toString(),
      operation: 'UPDATE',
      data: {'id': id, 'employeeId': employeeId, 'finalCash': amount},
    );
  }

  Future<void> checkInWithCash(int employeeId, int cash) async {
    await checkIn(employeeId);
    await setPettyCashForToday(employeeId, cash);
  }

  Future<void> checkOutWithCash(int employeeId, int cash) async {
    await checkOut(employeeId);
    await setFinalCashForToday(employeeId, cash);
  }

  Future<void> markStatus(int attendanceId, String status) async {
      await (db.update(db.attendance)..where((t) => t.id.equals(attendanceId))).write(
        AttendanceCompanion(status: Value(status)),
      );
      DeltaSyncService.I.pushDelta(
        table: 'attendance',
        recordId: attendanceId.toString(),
        operation: 'UPDATE',
        data: {'id': attendanceId, 'status': status},
      );
    }

  /// Create a blank attendance record if none exists today, or mark existing as given status.
  Future<void> markTodayStatus(int employeeId, String status) async {
    final now = DateTime.now();
    var today = await getToday(employeeId);
    if (today == null) {
      final id = await db
          .into(db.attendance)
          .insert(AttendanceCompanion.insert(employeeId: employeeId));
      today = AttendanceData(
        id: id,
        employeeId: employeeId,
        date: DateTime(now.year, now.month, now.day),
        checkIn: null,
        checkOut: null,
        pettyCash: null,
        finalCash: null,
        status: null,
      );
    }
    await markStatus(today.id, status);
  }

  Future<List<AttendanceData>> history({int? employeeId}) {
    final q = db.select(db.attendance);
    if (employeeId != null) {
      q.where((t) => t.employeeId.equals(employeeId));
    }
    q.orderBy([
      (t) => OrderingTerm(expression: t.date, mode: OrderingMode.desc),
    ]);
    return q.get();
  }

  Future<List<AttendanceData>> getMonthly({
    required int year,
    required int month,
    int? employeeId,
  }) {
    final start = DateTime(year, month, 1);
    final end = month == 12
        ? DateTime(year + 1, 1, 1)
        : DateTime(year, month + 1, 1);
    final q = db.select(db.attendance)
      ..where(
        (t) => t.date.isBiggerThanValue(start) & t.date.isSmallerThanValue(end),
      );
    if (employeeId != null) {
      q.where((t) => t.employeeId.equals(employeeId));
    }
    q.orderBy([
      (t) => OrderingTerm(expression: t.date, mode: OrderingMode.asc),
    ]);
    return q.get();
  }

  Future<Map<int, Map<String, dynamic>>> getMonthlySummary({
    required int year,
    required int month,
  }) async {
    final emps = await getEmployees();
    final allAtt = await getMonthly(year: year, month: month);
    final result = <int, Map<String, dynamic>>{};
    for (final e in emps) {
      final atts = allAtt.where((a) => a.employeeId == e.id).toList();
      int hadir = 0, terlambat = 0, izin = 0, alpha = 0, totalMin = 0;
      for (final a in atts) {
        if (a.status == 'Izin' || a.status == 'Sakit') {
          izin++;
          continue;
        }
        if (a.checkIn == null) {
          alpha++;
          continue;
        }
        final parts = (a.checkIn ?? '').split(':');
        final h = int.tryParse(parts[0]) ?? 0;
        final m = int.tryParse(parts[1]) ?? 0;
        // Use per-employee workStart + 15 min grace
        final ws = e.workStart ?? '08:00';
        final wsParts = ws.split(':');
        final wsH = int.tryParse(wsParts.isNotEmpty ? wsParts[0] : '8') ?? 8;
        final wsM = wsParts.length >= 2 ? (int.tryParse(wsParts[1]) ?? 0) : 0;
        final threshold = wsH * 60 + wsM + 15;
        if ((h * 60 + m) > threshold) {
          terlambat++;
        } else {
          hadir++;
        }
        if (a.checkOut != null) {
          final inParts = (a.checkIn ?? '00:00').split(':');
          final outParts = (a.checkOut ?? '00:00').split(':');
          final inMin =
              (int.tryParse(inParts[0]) ?? 0) * 60 +
              (int.tryParse(inParts[1]) ?? 0);
          final outMin =
              (int.tryParse(outParts[0]) ?? 0) * 60 +
              (int.tryParse(outParts[1]) ?? 0);
          if (outMin > inMin) totalMin += (outMin - inMin);
        }
      }
      result[e.id] = {
        'hadir': hadir,
        'terlambat': terlambat,
        'izin': izin,
        'alpha': alpha,
        'totalJam': totalMin ~/ 60,
        'totalMenit': totalMin % 60,
        'totalHadir': hadir + terlambat,
      };
    }
    return result;
  }

  Future<Map<String, List<AttendanceData>>> getHistoryGrouped({
    required int year,
    required int month,
  }) async {
    final emps = await getEmployees();
    final allAtt = await getMonthly(year: year, month: month);
    final result = <String, List<AttendanceData>>{};
    for (final e in emps) {
      result[e.name] = allAtt.where((a) => a.employeeId == e.id).toList();
    }
    return result;
  }

  // ═══ Shift Management (merged into Presensi) ═══

  /// Set expected cash for today's active shift.
  Future<void> setExpectedCash(int employeeId, int amount) async {
    final today = await getToday(employeeId);
    if (today == null) return;
    await (db.update(db.attendance)..where((t) => t.id.equals(today.id))).write(
      AttendanceCompanion(expectedCash: Value(amount)),
    );
    DeltaSyncService.I.pushDelta(
      table: 'attendance',
      recordId: today.id.toString(),
      operation: 'UPDATE',
      data: {'id': today.id, 'employeeId': employeeId, 'expectedCash': amount},
    );
  }

  /// Close the shift: record final cash, calculate difference from expected,
  /// and optionally store notes. Returns the difference (finalCash - expectedCash).
  Future<int> closeShift({
    required int employeeId,
    required int actualCash,
    String? notes,
  }) async {
    final today = await getToday(employeeId);
    if (today == null) return 0;

    final expected = today.expectedCash ?? today.pettyCash ?? 0;
    final diff = actualCash - expected;

    await (db.update(db.attendance)..where((t) => t.id.equals(today.id))).write(
      AttendanceCompanion(
        finalCash: Value(actualCash),
        expectedCash: Value(expected),
        shiftNotes: Value(notes),
      ),
    );
    DeltaSyncService.I.pushDelta(
      table: 'attendance',
      recordId: today.id.toString(),
      operation: 'UPDATE',
      data: {
        'id': today.id,
        'employeeId': employeeId,
        'finalCash': actualCash,
        'expectedCash': expected,
        'shiftNotes': notes,
      },
    );

    return diff;
  }

  /// Get shift history for an employee (attendance records with expectedCash set).
  Future<List<AttendanceData>> getShiftHistory({
    int? employeeId,
    int limit = 30,
  }) {
    final q = db.select(db.attendance);
    if (employeeId != null) {
      q.where((t) => t.employeeId.equals(employeeId));
    }
    q.where((t) => t.expectedCash.isNotNull());
    q.orderBy([
      (t) => OrderingTerm(expression: t.date, mode: OrderingMode.desc),
    ]);
    q.limit(limit);
    return q.get();
  }
}
