import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:verbal_outlet/data/note_export.dart';
import 'package:verbal_outlet/data/note_import.dart';
import 'package:verbal_outlet/data/note_repository.dart';
import 'package:verbal_outlet/data/note_store.dart';

/// A store of its own, so tests do not touch the app-wide one.
Future<NoteStore> _store() async {
  final store = NoteStore.forTesting(MemoryNoteRepository());
  await store.attachRepository(MemoryNoteRepository());
  return store;
}

/// JSON in the shape the exporter writes.
String _exportJson(List<Map<String, Object?>> notes) =>
    jsonEncode({'app': 'verbal-outlet', 'notes': notes});

Map<String, Object?> _day(String day, List<Map<String, Object?>> sections) => {
  'day': day,
  'sections': sections,
};

Map<String, Object?> _section(
  String id,
  String createdAt,
  String text, {
  bool deleted = false,
  String? updatedAt,
}) => {
  'id': id,
  'createdAt': createdAt,
  'text': text,
  'deleted': deleted,
  'updatedAt': ?updatedAt,
};

void main() {
  group('importing', () {
    test('adds every day and section from a file', () async {
      final store = await _store();

      final report = await const NoteImporter().importText(
        _exportJson([
          _day('2026-03-02', [
            _section('a', '2026-03-02T08:00:00.000', 'First day.'),
          ]),
          _day('2026-03-04', [
            _section('b', '2026-03-04T09:00:00.000', 'Morning.'),
            _section('c', '2026-03-04T21:00:00.000', 'Evening.'),
          ]),
        ]),
        store: store,
      );

      expect(report.days, 2);
      expect(report.added, 3);
      expect(report.updated, 0);
      expect(report.unchanged, 0);
      expect(store.allNotes, hasLength(2));
      expect(store.noteFor(DateTime(2026, 3, 4))!.body, contains('Evening.'));
    });

    test('a second import of the same file changes nothing', () async {
      final store = await _store();
      final json = _exportJson([
        _day('2026-03-02', [
          _section('a', '2026-03-02T08:00:00.000', 'Once.'),
        ]),
      ]);

      await const NoteImporter().importText(json, store: store);
      final second = await const NoteImporter().importText(json, store: store);

      expect(second.added, 0);
      expect(second.updated, 0);
      expect(second.unchanged, 1);
      expect(second.changedNothing, isTrue);
      expect(second.summary, contains('up to date'));
      expect(store.noteFor(DateTime(2026, 3, 2))!.sectionCount, 1);
    });

    test('an older copy does not overwrite a newer edit', () async {
      final store = await _store();
      store.appendToDay(DateTime(2026, 3, 2), 'Newer text.');
      final existing = store.noteFor(DateTime(2026, 3, 2))!.sections.single;

      // Same id, but an edit from before the local one.
      final report = await const NoteImporter().importText(
        _exportJson([
          _day('2026-03-02', [
            _section(
              existing.id,
              existing.createdAt.toIso8601String(),
              'Old text.',
              updatedAt: existing.createdAt
                  .subtract(const Duration(days: 1))
                  .toIso8601String(),
            ),
          ]),
        ]),
        store: store,
      );

      expect(report.updated, 0);
      expect(store.noteFor(DateTime(2026, 3, 2))!.body, 'Newer text.');
    });

    test('a newer copy replaces the local one', () async {
      final store = await _store();
      store.appendToDay(DateTime(2026, 3, 2), 'Old text.');
      final existing = store.noteFor(DateTime(2026, 3, 2))!.sections.single;

      final report = await const NoteImporter().importText(
        _exportJson([
          _day('2026-03-02', [
            _section(
              existing.id,
              existing.createdAt.toIso8601String(),
              'Edited elsewhere.',
              updatedAt: DateTime.now()
                  .add(const Duration(days: 1))
                  .toIso8601String(),
            ),
          ]),
        ]),
        store: store,
      );

      expect(report.updated, 1);
      expect(store.noteFor(DateTime(2026, 3, 2))!.body, 'Edited elsewhere.');
    });

    test('a tombstone in the file deletes the local section', () async {
      final store = await _store();
      store.appendToDay(DateTime(2026, 3, 2), 'Gone elsewhere.');
      final existing = store.noteFor(DateTime(2026, 3, 2))!.sections.single;

      await const NoteImporter().importText(
        _exportJson([
          _day('2026-03-02', [
            _section(
              existing.id,
              existing.createdAt.toIso8601String(),
              '',
              deleted: true,
              updatedAt: DateTime.now()
                  .add(const Duration(days: 1))
                  .toIso8601String(),
            ),
          ]),
        ]),
        store: store,
      );

      expect(store.noteFor(DateTime(2026, 3, 2))!.visible, isEmpty);
    });

    test('a section with no id gets one, and re-import still does not duplicate',
        () async {
      final store = await _store();
      final json = _exportJson([
        _day('2026-03-02', [
          {
            'createdAt': '2026-03-02T08:00:00.000',
            'text': 'Older export.',
          },
        ]),
      ]);

      await const NoteImporter().importText(json, store: store);
      await const NoteImporter().importText(json, store: store);

      expect(store.noteFor(DateTime(2026, 3, 2))!.sectionCount, 1);
    });

    test('a single-day export is accepted too', () async {
      final store = await _store();

      final report = await const NoteImporter().importText(
        jsonEncode(
          _day('2026-03-02', [
            _section('a', '2026-03-02T08:00:00.000', 'One day.'),
          ]),
        ),
        store: store,
      );

      expect(report.days, 1);
      expect(store.noteFor(DateTime(2026, 3, 2))!.body, 'One day.');
    });

    test('epoch timestamps are accepted', () async {
      final store = await _store();
      final when = DateTime(2026, 3, 2, 8);

      await const NoteImporter().importText(
        jsonEncode({
          'notes': [
            {
              'day': '2026-03-02',
              'sections': [
                {
                  'id': 'x',
                  'createdAt': when.millisecondsSinceEpoch,
                  'text': 'From the database.',
                },
              ],
            },
          ],
        }),
        store: store,
      );

      expect(
        store.noteFor(DateTime(2026, 3, 2))!.sections.single.createdAt,
        when,
      );
    });

    test('a file that is not JSON is refused with a readable message', () async {
      await expectLater(
        const NoteImporter().importText('not json at all', store: await _store()),
        throwsA(
          isA<ImportException>().having(
            (e) => e.message,
            'message',
            contains('not JSON'),
          ),
        ),
      );
    });

    test('JSON that is not a note export is refused', () async {
      await expectLater(
        const NoteImporter().importText('{"hello": "world"}', store: await _store()),
        throwsA(isA<ImportException>()),
      );
    });

    test('an empty file is refused rather than silently doing nothing', () async {
      await expectLater(
        const NoteImporter().importText('{"notes": []}', store: await _store()),
        throwsA(
          isA<ImportException>().having(
            (e) => e.message,
            'message',
            contains('no notes'),
          ),
        ),
      );
    });

    test('a file the user points at is read from disk', () async {
      final store = await _store();
      final temp = Directory.systemTemp.createTempSync('vo-import-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = File('${temp.path}/export.json')
        ..writeAsStringSync(
          _exportJson([
            _day('2026-03-02', [
              _section('a', '2026-03-02T08:00:00.000', 'From a file.'),
            ]),
          ]),
        );

      final report = await const NoteImporter().importFile(file, store: store);

      expect(report.fileName, 'export.json');
      expect(store.noteFor(DateTime(2026, 3, 2))!.body, 'From a file.');
    });

    test('a missing file gives a message, not a crash', () async {
      final store = await _store();
      await expectLater(
        const NoteImporter().importFile(
          File(r'C:\definitely\not\here\nope.json'),
          store: store,
        ),
        throwsA(isA<ImportException>()),
      );
    });
  });

  group('export and import together', () {
    test('a full round trip restores a fresh store exactly', () async {
      final original = await _store();
      original.appendToDay(DateTime(2026, 2, 1), 'February.');
      original.appendToDay(DateTime(2026, 2, 1), 'Second thought.');
      original.appendToDay(DateTime(2026, 3, 9), 'March.');
      await original.flush();

      // Export to a file the way the app does, then read it into an empty store.
      final temp = Directory.systemTemp.createTempSync('vo-round-trip-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = await NoteExporter(directory: temp).exportAll(
        original.allNotes,
        format: ExportFormat.json,
      );

      final restored = await _store();
      final report = await const NoteImporter().importFile(
        file,
        store: restored,
      );

      expect(report.added, 3);
      expect(restored.allNotes, hasLength(2));
      expect(restored.noteFor(DateTime(2026, 2, 1))!.body,
          'February.\n\nSecond thought.');
      expect(restored.noteFor(DateTime(2026, 3, 9))!.body, 'March.');
    });

    test('re-importing an export changes nothing and reports it', () async {
      final store = await _store();
      store.appendToDay(DateTime(2026, 2, 1), 'Same.');
      await store.flush();

      final temp = Directory.systemTemp.createTempSync('vo-reimport-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = await NoteExporter(directory: temp).exportAll(
        store.allNotes,
        format: ExportFormat.json,
      );

      final report = await const NoteImporter().importFile(
        file,
        store: store,
      );

      expect(report.changedNothing, isTrue);
      expect(store.noteFor(DateTime(2026, 2, 1))!.sectionCount, 1);
    });
  });
}
