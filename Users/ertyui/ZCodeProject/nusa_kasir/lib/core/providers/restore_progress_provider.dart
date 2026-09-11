import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Fase restore — urutan: download blob → unpack di isolate → hydrate gambar.
enum RestorePhase { idle, download, unpack, images, done, error }

/// Status restore backup global — dibagikan ke dialog progress di semua
/// jalur restore manual (aktivasi, login flow, settings download cloud).
/// Pola sama dengan [update_progress_provider.dart].
class RestoreProgress {
  final RestorePhase phase;
  final int filesDone;
  final int filesTotal;
  final String? error;

  const RestoreProgress({
    this.phase = RestorePhase.idle,
    this.filesDone = 0,
    this.filesTotal = 0,
    this.error,
  });

  RestoreProgress copyWith({
    RestorePhase? phase,
    int? filesDone,
    int? filesTotal,
    String? error,
  }) =>
      RestoreProgress(
        phase: phase ?? this.phase,
        filesDone: filesDone ?? this.filesDone,
        filesTotal: filesTotal ?? this.filesTotal,
        error: error ?? this.error,
      );

  bool get isActive =>
      phase == RestorePhase.download ||
      phase == RestorePhase.unpack ||
      phase == RestorePhase.images;

  /// Label fase untuk UI.
  String get label {
    switch (phase) {
      case RestorePhase.download:
        return 'Mengunduh backup…';
      case RestorePhase.unpack:
        return 'Menyiapkan data…';
      case RestorePhase.images:
        return filesTotal > 0
            ? 'Mengunduh gambar ${filesDone}/${filesTotal}'
            : 'Mengunduh gambar…';
      case RestorePhase.done:
        return 'Selesai';
      case RestorePhase.error:
        return error ?? 'Gagal';
      case RestorePhase.idle:
        return '';
    }
  }

  /// Progress determinate (0.0-1.0) hanya saat fase images & total > 0.
  double? get determinate =>
      (phase == RestorePhase.images && filesTotal > 0)
          ? (filesDone / filesTotal).clamp(0.0, 1.0)
          : null;

  /// Sub-label saat images.
  String get imageLabel =>
      filesTotal > 0 ? '$filesDone dari $filesTotal file' : '';
}

class RestoreProgressNotifier extends StateNotifier<RestoreProgress> {
  RestoreProgressNotifier() : super(const RestoreProgress());

  void start() => state = const RestoreProgress(phase: RestorePhase.download);

  void phase(RestorePhase p) => state = state.copyWith(phase: p);

  void updateFiles(int done, int total) =>
      state = state.copyWith(phase: RestorePhase.images, filesDone: done, filesTotal: total);

  void advanceFile(int done) =>
      state = state.copyWith(filesDone: done);

  void done() => state = const RestoreProgress(phase: RestorePhase.done);

  void fail(String msg) =>
      state = state.copyWith(phase: RestorePhase.error, error: msg);
}

final restoreProgressProvider =
    StateNotifierProvider<RestoreProgressNotifier, RestoreProgress>(
        (ref) => RestoreProgressNotifier());
