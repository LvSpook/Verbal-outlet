/// Upgrading a database made before the AI writer existed.
///
/// This is the risky path: a real install has notes in a version 1 file, and
/// opening it with version 2 code must keep every one of them. The test builds a
/// genuine v1 file, then opens it through [SqliteNoteRepository.open], which is
/// exactly what happens on the first launch after the update.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:verbal_outlet/data/note_repository.dart';
import 'package:verbal_outlet/models/day_note.dart';

/// Writes a version 1 database by hand: the old schema, no AI columns.
Future<void> _writeVersionOne(String path) async {
  final database = await openDatabase(
    path,
    version: 1,
    onCreate: (db, version) async {
      await db.execute('''
        CREATE TABLE sections (
          id TEXT PRIMARY KEY,
          day INTEGER NOT NULL,
          createdAt INTEGER NOT NULL,
          updatedAt INTEGER NOT NULL,
          text TEXT NOT NULL,
          durationMs INTEGER,
          deleted INTEGER NOT NULL DEFAULT 0
        )
      ''');
      await db.execute('CREATE INDEX idx_sections_day ON sections (day)');
    },
  );

  final day = DateTime(2026, 2, 1).millisecondsSinceEpoch;
  await database.insert('sections', {
    'id': 'old-1',
    'day': day,
    'createdAt': DateTime(2026, 2, 1, 9).millisecondsSinceEpoch,
    'updatedAt': DateTime(2026, 2, 1, 9).millisecondsSinceEpoch,
    'text': 'Written before the AI existed',
    'durationMs': null,
    'deleted': 0,
  });
  await database.insert('sections', {
    'id': 'old-deleted',
    'day': day,
    'createdAt': DateTime(2026, 2, 1, 10).millisecondsSinceEpoch,
    'updatedAt': DateTime(2026, 2, 1, 10).millisecondsSinceEpoch,
    'text': 'Gone',
    'durationMs': null,
    'deleted': 1,
  });
  await database.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory temp;
  late String path;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('vo-migrate-');
    path = p.join(temp.path, 'verbal_outlet.db');
    await _writeVersionOne(path);
  });

  tearDown(() => temp.delete(recursive: true));

  test('old notes survive, ready, showing their words', () async {
    final repository = await SqliteNoteRepository.open(path: path);
    addTearDown(repository.close);

    final notes = await repository.loadAll();

    expect(notes, hasLength(1));
    final sections = notes.single.sections;
    expect(sections.map((section) => section.id), ['old-1', 'old-deleted']);

    final kept = sections.firstWhere((section) => section.id == 'old-1');
    expect(kept.text, 'Written before the AI existed');
    // No body, but marked ready: it shows its words rather than hanging as a
    // pending entry with no way to be written.
    expect(kept.body, isEmpty);
    expect(kept.state, ComposeState.ready);
    expect(kept.content, 'Written before the AI existed');

    final deleted = sections.firstWhere((section) => section.id == 'old-deleted');
    expect(deleted.deleted, isTrue);
  });

  test('new fields round-trip after the upgrade', () async {
    final repository = await SqliteNoteRepository.open(path: path);
    addTearDown(repository.close);

    final day = DateTime(2026, 2, 2);
    await repository.saveSection(
      day,
      NoteSection(
        id: 'new-1',
        createdAt: DateTime(2026, 2, 2, 8),
        updatedAt: DateTime(2026, 2, 2, 8),
        text: 'The words',
        body: 'The written entry',
        state: ComposeState.failed,
        instruction: 'a checklist',
        composeError: 'the model was busy',
      ),
    );

    final reloaded = await repository.loadAll();
    final section =
        reloaded.expand((note) => note.sections).firstWhere(
          (entry) => entry.id == 'new-1',
        );

    expect(section.text, 'The words');
    expect(section.body, 'The written entry');
    expect(section.state, ComposeState.failed);
    expect(section.instruction, 'a checklist');
    expect(section.composeError, 'the model was busy');
  });
}
