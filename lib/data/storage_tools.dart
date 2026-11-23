/// How much room the notes take up, and what can be done about it.
///
/// Two numbers matter and they are not the same:
///
/// * **On disk** — the size of the SQLite file, which is what a backup or a
///   disk-full message will quote. It also holds free pages left by deletes,
///   until the file is compacted.
/// * **In the notes** — the characters of actual text, tombstones included.
///   This is what grows as you write, and is the honest answer to "how much of
///   this is my writing".
///
/// Almost all of the file, in practice, is gone over the years by two things
/// this app controls: deleted sections kept as tombstones so a delete can reach
/// another device, and free pages SQLite will not give back until asked. Both
/// can be reclaimed safely, which is what [StorageCleanup] does.
library;

import 'dart:io';

import '../models/day_note.dart';
import 'note_store.dart';

/// A snapshot of what the notes are using.
class StorageReport {
  const StorageReport({
    required this.fileBytes,
    required this.location,
    required this.days,
    required this.sections,
    required this.tombstones,
    required this.textBytes,
    required this.tombstoneBytes,
    required this.oldestDay,
    required this.newestDay,
  });

  /// Size of the database file, or 0 when there is no file (tests, previews).
  final int fileBytes;

  /// The file's path, for the "where is it" line. Null when in memory.
  final String? location;

  /// Days with at least one visible section.
  final int days;

  /// Visible sections across every day.
  final int sections;

  /// Deleted sections still kept so the deletion can reach another device.
  final int tombstones;

  /// UTF-8 bytes of visible text, which is roughly what the words themselves
  /// cost before any database overhead.
  final int textBytes;

  /// UTF-8 bytes sitting in tombstones: text that has been deleted and will
  /// never be shown again, only synchronised.
  final int tombstoneBytes;

  final DateTime? oldestDay;
  final DateTime? newestDay;

  /// Share of the file taken by tombstones, 0–1.
  ///
  /// Zero when there is no file, because the share of nothing says nothing.
  double get tombstoneShare {
    if (fileBytes <= 0) return 0;
    return (tombstoneBytes / fileBytes).clamp(0.0, 1.0);
  }

  bool get hasAnythingToReclaim => tombstones > 0;

  /// A phrase for the size, e.g. "128 KB" or "1.4 MB".
  String get fileSizeLabel => formatBytes(fileBytes);

  String get textSizeLabel => formatBytes(textBytes);
}

/// What a cleanup achieved, in terms a person can read.
class CleanupResult {
  const CleanupResult({
    required this.bytesBefore,
    required this.bytesAfter,
    required this.sectionsRemoved,
    required this.tombstonesCleared,
  });

  final int bytesBefore;
  final int bytesAfter;

  /// Sections physically deleted from storage.
  final int sectionsRemoved;

  /// Deleted sections that had become tombstones and are now gone.
  final int tombstonesCleared;

  int get bytesFreed => bytesBefore - bytesAfter < 0
      ? 0
      : bytesBefore - bytesAfter;

  bool get changedAnything => sectionsRemoved > 0;

  /// One sentence for a snack bar.
  String get summary {
    if (!changedAnything) {
      return 'Nothing to clean up — everything is already current.';
    }
    final what = sectionsRemoved == 1
        ? '1 old deleted entry'
        : '$sectionsRemoved old deleted entries';
    final freed = formatBytes(bytesFreed);
    return bytesFreed > 0 ? 'Removed $what, freeing $freed.' : 'Removed $what.';
  }
}

/// Measures the notes and reclaims what is safe to reclaim.
///
/// Everything here is deliberately conservative: the only things deleted are
/// tombstones old enough that every device has had a fair chance to hear about
/// them. Nothing visible is ever touched.
class StorageTools {
  const StorageTools();

  /// How long a deletion is kept before it can be discarded.
  ///
  /// Matches the prune the store already does at startup, and is generous: it
  /// is measured in months because the trade-off is "a device that was offline
  /// for a year might resurrect a deleted note", and that is a very unusual
  /// device.
  static const Duration tombstoneRetention = Duration(days: 90);

  /// Reads the current usage.
  ///
  /// The file size comes from the disk, the counts from [store]'s memory, so
  /// the numbers agree with what the app is showing.
  Future<StorageReport> measure(NoteStore store) async {
    final location = store.storageLocation;
    var fileBytes = 0;
    if (location != null) {
      try {
        final file = File(location);
        if (await file.exists()) fileBytes = await file.length();
      } on FileSystemException {
        // A missing or unreadable file means "unknown size", not a crash; the
        // rest of the report is still useful.
        fileBytes = 0;
      }
    }

    var days = 0;
    var sections = 0;
    var tombstones = 0;
    var textBytes = 0;
    var tombstoneBytes = 0;
    DateTime? oldest;
    DateTime? newest;

    for (final note in store.allNotes) {
      final visible = note.visible;
      if (visible.isNotEmpty) {
        days++;
        oldest ??= note.day;
        newest = note.day;
      }
      for (final section in note.sections) {
        final bytes = _utf8Length(section.text);
        if (section.deleted) {
          tombstones++;
          tombstoneBytes += bytes;
        } else {
          sections++;
          textBytes += bytes;
        }
      }
    }

    return StorageReport(
      fileBytes: fileBytes,
      location: location,
      days: days,
      sections: sections,
      tombstones: tombstones,
      textBytes: textBytes,
      tombstoneBytes: tombstoneBytes,
      oldestDay: oldest,
      newestDay: newest,
    );
  }

  /// Drops tombstones older than [olderThan] and compacts the file.
  ///
  /// Returns what changed. Safe to run at any time: a tombstone that is dropped
  /// while another device is offline means that device could, on its next sync,
  /// bring the deleted section back. That is why the cutoff is measured in
  /// months rather than days, and why the app does the same prune at startup.
  Future<CleanupResult> cleanUp(
    NoteStore store, {
    Duration olderThan = tombstoneRetention,
  }) async {
    final before = await measure(store);
    final cutoff = DateTime.now().subtract(olderThan);

    // Count what is about to go, so the report can say something specific.
    var doomed = 0;
    for (final (_, section) in store.allSections) {
      if (section.deleted && !section.modifiedAt.isAfter(cutoff)) doomed++;
    }

    await store.purgeTombstonesBefore(cutoff);

    final after = await measure(store);
    return CleanupResult(
      bytesBefore: before.fileBytes,
      bytesAfter: after.fileBytes,
      sectionsRemoved: doomed,
      tombstonesCleared: before.tombstones - after.tombstones,
    );
  }

  /// UTF-8 length of [text] without allocating a whole encoded buffer for every
  /// short note.
  ///
  /// Correct for surrogate pairs, which matters because an emoji is one
  /// character to Dart and four bytes on disk.
  static int _utf8Length(String text) {
    var bytes = 0;
    for (final rune in text.runes) {
      if (rune <= 0x7F) {
        bytes += 1;
      } else if (rune <= 0x7FF) {
        bytes += 2;
      } else if (rune <= 0xFFFF) {
        bytes += 3;
      } else {
        bytes += 4;
      }
    }
    return bytes;
  }
}

/// "512 bytes", "128 KB", "1.4 MB".
///
/// Deliberately short: it is shown beside a label, not in a table of figures.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes ${bytes == 1 ? 'byte' : 'bytes'}';
  final kb = bytes / 1024;
  if (kb < 1024) {
    return kb < 10 ? '${_trim(kb)} KB' : '${kb.round()} KB';
  }
  final mb = kb / 1024;
  if (mb < 1024) {
    return mb < 10 ? '${_trim(mb)} MB' : '${mb.round()} MB';
  }
  return '${_trim(mb / 1024)} GB';
}

String _trim(double value) {
  final rounded = (value * 10).round() / 10;
  return rounded == rounded.roundToDouble()
      ? rounded.toStringAsFixed(0)
      : rounded.toStringAsFixed(1);
}

/// Sections that will survive a cleanup, for a preview line.
int countTombstonesToKeep(Iterable<DayNote> notes, DateTime cutoff) {
  var kept = 0;
  for (final note in notes) {
    for (final section in note.sections) {
      if (section.deleted && section.modifiedAt.isAfter(cutoff)) kept++;
    }
  }
  return kept;
}
