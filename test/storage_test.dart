import 'package:flutter_test/flutter_test.dart';

import 'package:verbal_outlet/data/note_repository.dart';
import 'package:verbal_outlet/data/note_store.dart';
import 'package:verbal_outlet/data/storage_tools.dart';
import 'package:verbal_outlet/models/day_note.dart';

/// A tombstone that was deleted [age] ago, so tests can place it either side of
/// the retention cutoff.
NoteSection _tombstone(String id, Duration age, {String text = ''}) {
  final when = DateTime.now().subtract(age);
  return NoteSection(
    id: id,
    createdAt: when,
    updatedAt: when,
    text: text,
    deleted: true,
  );
}

NoteSection _live(String id, String text) => NoteSection(
  id: id,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
  text: text,
);

void main() {
  group('formatBytes', () {
    test('counts bytes, then KB, MB and GB', () {
      expect(formatBytes(0), '0 bytes');
      expect(formatBytes(1), '1 byte');
      expect(formatBytes(512), '512 bytes');
      expect(formatBytes(1024), '1 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(20 * 1024), '20 KB');
      expect(formatBytes(1024 * 1024), '1 MB');
      expect(formatBytes(1536 * 1024), '1.5 MB');
      expect(formatBytes(3 * 1024 * 1024 * 1024), '3 GB');
    });
  });

  group('measure', () {
    test('counts days, sections and UTF-8 text bytes', () async {
      final store = NoteStore.forTesting(MemoryNoteRepository());
      await store.attachRepository(MemoryNoteRepository(), seedSamples: false);
      store.appendToDay(DateTime(2026, 3, 1), 'Hello');
      store.appendToDay(DateTime(2026, 3, 1), 'Second');
      store.appendToDay(DateTime(2026, 3, 2), '🙂');

      final report = await const StorageTools().measure(store);

      expect(report.days, 2);
      expect(report.sections, 3);
      // "Hello" (5) + "Second" (6) + the emoji (4 bytes, not 1).
      expect(report.textBytes, 5 + 6 + 4);
      expect(report.tombstones, 0);
      expect(report.hasAnythingToReclaim, isFalse);
      expect(report.oldestDay, DateTime(2026, 3, 1));
      expect(report.newestDay, DateTime(2026, 3, 2));
    });

    test('counts tombstones separately from visible text', () async {
      final store = NoteStore.forTesting(MemoryNoteRepository());
      await store.attachRepository(MemoryNoteRepository(), seedSamples: false);
      store.appendToDay(DateTime(2026, 3, 1), 'Kept');
      store.applyRemoteSection(
        DateTime(2026, 3, 1),
        _tombstone('gone', const Duration(days: 1), text: 'Deleted words'),
      );

      final report = await const StorageTools().measure(store);

      expect(report.sections, 1);
      expect(report.tombstones, 1);
      expect(report.textBytes, 4); // "Kept"
      expect(report.tombstoneBytes, 13); // "Deleted words"
      expect(report.hasAnythingToReclaim, isTrue);
    });

    test('the in-memory store has no file and no location', () async {
      final store = NoteStore.forTesting(MemoryNoteRepository());
      await store.attachRepository(MemoryNoteRepository(), seedSamples: false);

      final report = await const StorageTools().measure(store);

      expect(report.location, isNull);
      expect(report.fileBytes, 0);
      expect(report.fileSizeLabel, '0 bytes');
      expect(report.tombstoneShare, 0);
    });
  });

  group('cleanUp', () {
    test('removes only tombstones older than the retention window', () async {
      final store = NoteStore.forTesting(MemoryNoteRepository());
      await store.attachRepository(MemoryNoteRepository(), seedSamples: false);
      final day = DateTime(2026, 3, 1);
      store.appendToDay(day, 'Still here');
      store.applyRemoteSection(day, _tombstone('old', const Duration(days: 200)));
      store.applyRemoteSection(day, _tombstone('new', const Duration(days: 2)));

      final result = await const StorageTools().cleanUp(store);
      final report = await const StorageTools().measure(store);

      expect(result.sectionsRemoved, 1);
      expect(result.tombstonesCleared, 1);
      expect(report.tombstones, 1);
      expect(store.allSections.map((entry) => entry.$2.id), contains('new'));
      expect(store.allSections.map((entry) => entry.$2.id), isNot(contains('old')));
      // The visible note is untouched.
      expect(store.noteFor(day)!.body, 'Still here');
    });

    test('a second cleanup has nothing left to do', () async {
      final store = NoteStore.forTesting(MemoryNoteRepository());
      await store.attachRepository(MemoryNoteRepository(), seedSamples: false);
      store.applyRemoteSection(
        DateTime(2026, 3, 1),
        _tombstone('old', const Duration(days: 200)),
      );

      final first = await const StorageTools().cleanUp(store);
      final second = await const StorageTools().cleanUp(store);

      expect(first.changedAnything, isTrue);
      expect(second.changedAnything, isFalse);
      expect(second.summary, contains('Nothing to clean up'));
    });

    test('says so when there was nothing to remove', () async {
      final store = NoteStore.forTesting(MemoryNoteRepository());
      await store.attachRepository(MemoryNoteRepository(), seedSamples: false);
      store.appendToDay(DateTime(2026, 3, 1), 'Only visible text');

      final result = await const StorageTools().cleanUp(store);

      expect(result.changedAnything, isFalse);
      expect(result.summary, contains('Nothing to clean up'));
    });
  });

  group('countTombstonesToKeep', () {
    test('keeps recent tombstones and drops old ones', () {
      final now = DateTime.now();
      final cutoff = now.subtract(const Duration(days: 90));
      final notes = [
        DayNote(
          day: DateTime(2026, 3, 1),
          sections: [
            _live('a', 'Live'),
            _tombstone('old', const Duration(days: 200)),
            _tombstone('new', const Duration(days: 2)),
          ],
        ),
      ];

      expect(countTombstonesToKeep(notes, cutoff), 1);
    });
  });
}
