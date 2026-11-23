/// Where notes are kept between launches.
///
/// The store above this is a synchronous in-memory cache so the UI never has to
/// await a database read. This layer is the slow half: it is written to after
/// each change, and read once at startup.
///
/// Two implementations exist: SQLite for the app, and an in-memory one for
/// tests, which keeps them fast and independent of platform plugins.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
// Both are needed: `sqflite` registers the platform database factory on
// phones, and the FFI package supplies one for desktop. Their shared types
// overlap, hence the ignored lint below.
// ignore: unnecessary_import
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/day_note.dart';

/// Durable storage for notes.
abstract interface class NoteRepository {
  /// Every note, oldest first.
  Future<List<DayNote>> loadAll();

  /// Inserts or replaces one section. [day] is the section's calendar day.
  Future<void> saveSection(DateTime day, NoteSection section);

  /// Physically removes sections that were deleted long ago, so tombstones do
  /// not accumulate forever.
  Future<void> pruneDeletedBefore(DateTime cutoff);

  /// Reclaims space left behind by [pruneDeletedBefore].
  ///
  /// In SQLite a delete only marks pages free for reuse; the file stays the
  /// same size until it is compacted. Call this after a clean-up so the saving
  /// is visible on disk.
  Future<void> compact();

  /// Where the notes physically live, or null when there is no file (the
  /// in-memory store used by tests).
  String? get location;
}

/// A repository that forgets everything when the process ends.
class MemoryNoteRepository implements NoteRepository {
  MemoryNoteRepository([Iterable<DayNote> seed = const []]) {
    for (final note in seed) {
      _notes[dateOnlyKey(note.day)] = note;
    }
  }

  final Map<String, DayNote> _notes = {};

  @override
  Future<List<DayNote>> loadAll() async => _notes.values.toList();

  @override
  Future<void> saveSection(DateTime day, NoteSection section) async {
    final key = dateOnlyKey(day);
    final existing = _notes[key];
    final sections = [...?existing?.sections];
    final index = sections.indexWhere((entry) => entry.id == section.id);
    if (index == -1) {
      sections.add(section);
    } else {
      sections[index] = section;
    }
    sections.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    _notes[key] = DayNote(day: dateOnly(day), sections: sections);
  }

  @override
  Future<void> pruneDeletedBefore(DateTime cutoff) async {
    for (final entry in _notes.entries.toList()) {
      final kept = entry.value.sections
          .where(
            (section) => !section.deleted || section.modifiedAt.isAfter(cutoff),
          )
          .toList();
      if (kept.isEmpty) {
        _notes.remove(entry.key);
      } else {
        _notes[entry.key] = DayNote(day: entry.value.day, sections: kept);
      }
    }
  }

  /// Nothing to reclaim: the in-memory store has no file behind it.
  @override
  Future<void> compact() async {}

  @override
  String? get location => null;
}

/// The real store: one row per section, in a single SQLite file.
///
/// Sections rather than notes, because a section is the smallest thing that can
/// change, and syncing compares them one by one.
class SqliteNoteRepository implements NoteRepository {
  SqliteNoteRepository._(this._database);

  final Database _database;

  static const String _table = 'sections';
  static const int _schemaVersion = 2;

  /// Opens (and migrates) the database.
  ///
  /// Desktop has no bundled SQLite in Flutter, so the FFI implementation is
  /// initialised there. Phones use the platform one through `sqflite`.
  static Future<SqliteNoteRepository> open({String? path}) async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final file = path ?? await _defaultPath();
    final database = await openDatabase(
      file,
      version: _schemaVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_table (
            id TEXT PRIMARY KEY,
            day INTEGER NOT NULL,
            createdAt INTEGER NOT NULL,
            updatedAt INTEGER NOT NULL,
            text TEXT NOT NULL,
            durationMs INTEGER,
            deleted INTEGER NOT NULL DEFAULT 0,
            body TEXT NOT NULL DEFAULT '',
            state TEXT NOT NULL DEFAULT 'ready',
            instruction TEXT NOT NULL DEFAULT '',
            composeError TEXT
          )
        ''');
        await db.execute('CREATE INDEX idx_sections_day ON $_table (day)');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // Version 2 added the AI-written body. Existing sections are marked
        // ready with an empty body, which makes them show their original words
        // — the same thing they showed before the upgrade.
        if (oldVersion < 2) {
          await db.execute(
            "ALTER TABLE $_table ADD COLUMN body TEXT NOT NULL DEFAULT ''",
          );
          await db.execute(
            "ALTER TABLE $_table ADD COLUMN state TEXT NOT NULL DEFAULT 'ready'",
          );
          await db.execute(
            "ALTER TABLE $_table ADD COLUMN instruction TEXT NOT NULL DEFAULT ''",
          );
          await db.execute(
            'ALTER TABLE $_table ADD COLUMN composeError TEXT',
          );
        }
      },
    );
    return SqliteNoteRepository._(database);
  }

  static Future<String> _defaultPath() async {
    final directory = await getApplicationSupportDirectory();
    await Directory(directory.path).create(recursive: true);
    return p.join(directory.path, 'verbal_outlet.db');
  }

  @override
  Future<List<DayNote>> loadAll() async {
    final rows = await _database.query(_table, orderBy: 'day ASC, createdAt ASC');
    final byDay = <DateTime, List<NoteSection>>{};
    for (final row in rows) {
      final day = DateTime.fromMillisecondsSinceEpoch((row['day'] as num).toInt());
      final durationMs = row['durationMs'];
      final section = NoteSection(
        id: row['id'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          (row['createdAt'] as num).toInt(),
        ),
        text: row['text'] as String,
        body: row['body'] as String? ?? '',
        state: NoteSection.stateFromName(row['state']),
        instruction: row['instruction'] as String? ?? '',
        composeError: row['composeError'] as String?,
        duration: durationMs == null
            ? null
            : Duration(milliseconds: (durationMs as num).toInt()),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
          (row['updatedAt'] as num).toInt(),
        ),
        deleted: (row['deleted'] as num).toInt() == 1,
      );
      byDay.putIfAbsent(day, () => []).add(section);
    }
    return [
      for (final entry in byDay.entries)
        DayNote(day: entry.key, sections: entry.value),
    ];
  }

  @override
  Future<void> saveSection(DateTime day, NoteSection section) async {
    await _database.insert(_table, {
      'id': section.id,
      'day': dateOnly(day).millisecondsSinceEpoch,
      'createdAt': section.createdAt.millisecondsSinceEpoch,
      'updatedAt': section.modifiedAt.millisecondsSinceEpoch,
      'text': section.text,
      'body': section.body,
      'state': section.state.name,
      'instruction': section.instruction,
      'composeError': section.composeError,
      'durationMs': section.duration?.inMilliseconds,
      'deleted': section.deleted ? 1 : 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> pruneDeletedBefore(DateTime cutoff) async {
    await _database.delete(
      _table,
      where: 'deleted = 1 AND updatedAt < ?',
      whereArgs: [cutoff.millisecondsSinceEpoch],
    );
  }

  /// Rewrites the database file so freed pages are actually returned to disk.
  @override
  Future<void> compact() async {
    try {
      await _database.execute('VACUUM');
    } catch (error, stack) {
      // A busy database refuses to vacuum. The cleanup has still happened, so
      // this is a missed opportunity rather than a failure worth surfacing.
      debugPrint('Compacting the notes database failed: $error\n$stack');
    }
  }

  /// Where the database file lives, when it is a file at all.
  ///
  /// Desktop and phones both use a real SQLite file; tests may pass `:memory:`,
  /// in which case there is nothing to measure.
  @override
  String? get location =>
      _database.path.startsWith(':') ? null : _database.path;

  Future<void> close() => _database.close();
}

/// The day, normalised to midnight, as a stable string key.
String dateOnlyKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// The day, normalised to midnight, as a `DateTime` key.
DateTime dateOnly(DateTime date) => DateTime(date.year, date.month, date.day);
