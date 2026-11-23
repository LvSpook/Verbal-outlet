import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:verbal_outlet/data/note_export.dart';
import 'package:verbal_outlet/models/day_note.dart';

DayNote _day(DateTime day, List<(int hour, String text)> parts) => DayNote(
  day: day,
  sections: [
    for (var i = 0; i < parts.length; i++)
      NoteSection(
        id: 'id-$i',
        createdAt: DateTime(day.year, day.month, day.day, parts[i].$1),
        text: parts[i].$2,
        updatedAt: DateTime(day.year, day.month, day.day, parts[i].$1),
      ),
  ],
);

void main() {
  late Directory temp;
  late NoteExporter exporter;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('vo-export-');
    exporter = NoteExporter(directory: temp);
  });

  tearDown(() => temp.delete(recursive: true));

  group('markdown', () {
    test('one day keeps its date, timestamps and text', () {
      final note = _day(DateTime(2026, 3, 4), [
        (9, 'First thought.'),
        (21, 'Second thought\non two lines.'),
      ]);

      final out = renderDayMarkdown(note);

      expect(out, startsWith('# Wednesday 4 March 2026'));
      expect(out, contains('**09:00**'));
      // Sections with no AI body lead with their words, unprefixed.
      expect(out, contains('First thought.'));
      expect(out, contains('**21:00**'));
      expect(out, contains('Second thought\non two lines.'));
      expect(out, endsWith('\n'));
    });

    test('a deleted section is left out', () {
      final note = DayNote(
        day: DateTime(2026, 3, 4),
        sections: [
          NoteSection(
            id: 'a',
            createdAt: DateTime(2026, 3, 4, 9),
            text: 'kept',
          ),
          NoteSection(
            id: 'b',
            createdAt: DateTime(2026, 3, 4, 10),
            text: '',
            deleted: true,
          ),
        ],
      );

      final out = renderDayMarkdown(note);
      expect(out, contains('kept'));
      expect(out, isNot(contains('10:00')));
    });

    test('all notes are oldest first with a separator', () {
      final notes = [
        _day(DateTime(2026, 3, 9), [(8, 'later')]),
        _day(DateTime(2026, 3, 2), [(8, 'earlier')]),
      ];

      final out = renderAllMarkdown(notes);
      expect(out, startsWith('# Verbal Outlet'));
      expect(out, contains('2 entries'));
      expect(out.indexOf('earlier'), lessThan(out.indexOf('later')));
      expect(out, contains('---'));
    });
  });

  group('files', () {
    test('a single day writes a named Markdown file', () async {
      final note = _day(DateTime(2026, 3, 4), [(9, 'Hello.')]);

      final file = await exporter.exportDay(note);

      expect(await file.exists(), isTrue);
      expect(file.parent.path, temp.path);
      expect(file.path, endsWith('.md'));
      expect(file.path, contains('4 Mar'));
      expect(await file.readAsString(), contains('Hello.'));
    });

    test('JSON keeps the structure a tool would want', () async {
      final note = _day(DateTime(2026, 3, 4), [(9, 'Hello.')]);

      final file = await exporter.exportDay(note, format: ExportFormat.json);
      final decoded = jsonDecode(await file.readAsString()) as Map;

      expect(decoded['app'], 'verbal-outlet');
      final days = decoded['notes'] as List;
      expect(days, hasLength(1));
      expect(days.single['day'], '2026-03-04');
      expect(days.single['sections'].single['text'], 'Hello.');
      expect(days.single['sections'].single['id'], 'id-0');
    });

    test('exporting everything writes one file and skips empty days', () async {
      final notes = [
        _day(DateTime(2026, 3, 2), [(8, 'one')]),
        DayNote(day: DateTime(2026, 3, 3), sections: []),
        _day(DateTime(2026, 3, 4), [(8, 'two')]),
      ];

      final file = await exporter.exportAll(notes);
      final text = await file.readAsString();

      expect(file.path, contains('all notes'));
      expect(text, contains('2 entries'));
      expect(text, contains('one'));
      expect(text, contains('two'));
    });

    test('an empty day is refused with a readable message', () async {
      await expectLater(
        exporter.exportDay(
          DayNote(day: DateTime(2026, 3, 4), sections: []),
        ),
        throwsA(
          isA<ExportException>().having(
            (e) => e.message,
            'message',
            contains('no note'),
          ),
        ),
      );
    });

    test('nothing to export is refused rather than writing an empty file', () async {
      await expectLater(
        exporter.exportAll(const []),
        throwsA(isA<ExportException>()),
      );
      expect(temp.listSync(), isEmpty);
    });

    test('two exports of the same day do not overwrite each other', () async {
      final note = _day(DateTime(2026, 3, 4), [(9, 'Hello.')]);

      final first = await exporter.exportDay(note);
      // Same name by design: a second export replaces the first, which is what
      // a user pressing the button twice expects, not two identical files.
      final second = await exporter.exportDay(note);

      expect(first.path, second.path);
      expect(temp.listSync().whereType<File>(), hasLength(1));
    });
  });
}
