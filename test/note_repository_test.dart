import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:verbal_outlet/data/note_repository.dart';
import 'package:verbal_outlet/data/note_store.dart';
import 'package:verbal_outlet/models/day_note.dart';

NoteSection section(
  String id, {
  String text = 'a thought',
  DateTime? at,
  DateTime? updatedAt,
  bool deleted = false,
}) {
  final created = at ?? DateTime(2026, 3, 4, 9);
  return NoteSection(
    id: id,
    createdAt: created,
    text: text,
    updatedAt: updatedAt ?? created,
    deleted: deleted,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SqliteNoteRepository', () {
    late SqliteNoteRepository repository;

    setUp(() async {
      repository = await SqliteNoteRepository.open(path: inMemoryDatabasePath);
    });

    tearDown(() => repository.close());

    test('round-trips sections grouped by day', () async {
      final day = DateTime(2026, 3, 4);
      await repository.saveSection(
        day,
        section('a', text: 'first', at: DateTime(2026, 3, 4, 8)),
      );
      await repository.saveSection(
        day,
        section('b', text: 'second', at: DateTime(2026, 3, 4, 20)),
      );
      await repository.saveSection(
        DateTime(2026, 3, 5),
        section('c', text: 'next day'),
      );

      final notes = await repository.loadAll();
      expect(notes, hasLength(2));

      final first = notes.firstWhere((note) => note.day.day == 4);
      expect(first.sections.map((s) => s.id), ['a', 'b']);
      expect(first.body, contains('first'));
      expect(first.body, contains('second'));

      final second = notes.firstWhere((note) => note.day.day == 5);
      expect(second.sections.single.text, 'next day');
    });

    test('an edit replaces the row instead of adding one', () async {
      final day = DateTime(2026, 3, 4);
      await repository.saveSection(day, section('a', text: 'before'));
      await repository.saveSection(
        day,
        section('a', text: 'after', updatedAt: DateTime(2026, 3, 4, 22)),
      );

      final notes = await repository.loadAll();
      expect(notes.single.sections, hasLength(1));
      expect(notes.single.sections.single.text, 'after');
    });

    test('tombstones survive a round trip but stay hidden', () async {
      final day = DateTime(2026, 3, 4);
      await repository.saveSection(day, section('a', text: 'live'));
      await repository.saveSection(
        day,
        section('b', text: '', deleted: true),
      );

      final note = (await repository.loadAll()).single;
      expect(note.sections, hasLength(2));
      expect(note.visible.map((s) => s.id), ['a']);
    });

    test('prune removes only tombstones older than the cutoff', () async {
      final day = DateTime(2026, 3, 4);
      final old = DateTime(2026, 1, 1);
      final recent = DateTime(2026, 3, 1);

      await repository.saveSection(
        day,
        section('old', text: '', deleted: true, updatedAt: old),
      );
      await repository.saveSection(
        day,
        section('recent', text: '', deleted: true, updatedAt: recent),
      );
      await repository.saveSection(day, section('live', at: old));

      await repository.pruneDeletedBefore(DateTime(2026, 2, 1));

      final note = (await repository.loadAll()).single;
      expect(note.sections.map((s) => s.id), ['live', 'recent']);
    });

    test('prune keeps live sections regardless of age', () async {
      final day = DateTime(2026, 3, 4);
      final old = DateTime(2025, 1, 1);
      await repository.saveSection(day, section('live', at: old));
      await repository.pruneDeletedBefore(DateTime(2026, 2, 1));

      expect((await repository.loadAll()).single.visible, hasLength(1));
    });
  });

  group('MemoryNoteRepository', () {
    test('seeds from notes and replaces sections by id', () async {
      final repository = MemoryNoteRepository([
        DayNote(day: DateTime(2026, 3, 4), sections: [section('a')]),
      ]);
      await repository.saveSection(
        DateTime(2026, 3, 4),
        section('b', at: DateTime(2026, 3, 4, 11)),
      );
      await repository.saveSection(
        DateTime(2026, 3, 4),
        section('a', text: 'changed'),
      );

      final note = (await repository.loadAll()).single;
      expect(note.sections.map((s) => s.id), ['a', 'b']);
      expect(note.sections.first.text, 'changed');
    });
  });

  group('NoteStore', () {
    test('appending writes through to the repository', () async {
      final repository = MemoryNoteRepository();
      final store = await _storeOn(repository);

      final note = store.appendToDay(DateTime(2026, 3, 4), '  hello  ');
      expect(note.body, 'hello');
      expect(store.noteFor(DateTime(2026, 3, 4))!.body, 'hello');

      await store.flush();
      final saved = (await repository.loadAll()).single;
      expect(saved.body, 'hello');
    });

    test('ids are unique across appends', () async {
      final store = await _storeOn(MemoryNoteRepository());
      store.appendToDay(DateTime(2026, 3, 4), 'one');
      store.appendToDay(DateTime(2026, 3, 4), 'two');
      await store.flush();

      final ids = store.noteFor(DateTime(2026, 3, 4))!.sections
          .map((s) => s.id)
          .toList();
      expect(ids.toSet(), hasLength(2));
    });

    test('clearing a section leaves a hidden tombstone', () async {
      final repository = MemoryNoteRepository();
      final store = await _storeOn(repository);
      store.appendToDay(DateTime(2026, 3, 4), 'something');
      await store.flush();

      final id = store.noteFor(DateTime(2026, 3, 4))!.sections.single.id;
      store.updateSection(DateTime(2026, 3, 4), id, '   ');

      expect(store.hasNote(DateTime(2026, 3, 4)), isFalse);
      expect(
        store.noteFor(DateTime(2026, 3, 4))!.sections.single.deleted,
        isTrue,
      );

      await store.flush();
      final saved = (await repository.loadAll()).single;
      expect(saved.sections.single.deleted, isTrue);
    });

    test('editing sets a newer modifiedAt than the original', () async {
      final store = await _storeOn(MemoryNoteRepository());
      store.appendToDay(DateTime(2026, 3, 4), 'draft');
      final before = store.noteFor(DateTime(2026, 3, 4))!.sections.single;

      await Future<void>.delayed(const Duration(milliseconds: 5));
      store.updateSection(DateTime(2026, 3, 4), before.id, 'final');

      final after = store.noteFor(DateTime(2026, 3, 4))!.sections.single;
      expect(after.text, 'final');
      expect(after.modifiedAt.isAfter(before.modifiedAt), isTrue);
    });

    test('a newer remote section wins, an older one is ignored', () async {
      final store = await _storeOn(MemoryNoteRepository());
      store.appendToDay(DateTime(2026, 3, 4), 'mine');
      final local = store.noteFor(DateTime(2026, 3, 4))!.sections.single;

      // Older: ignored.
      store.applyRemoteSection(
        DateTime(2026, 3, 4),
        local.copyWith(
          text: 'stale',
          updatedAt: local.modifiedAt.subtract(const Duration(hours: 1)),
        ),
      );
      expect(store.noteFor(DateTime(2026, 3, 4))!.body, 'mine');

      // Newer: wins.
      store.applyRemoteSection(
        DateTime(2026, 3, 4),
        local.copyWith(
          text: 'their edit',
          updatedAt: local.modifiedAt.add(const Duration(hours: 1)),
        ),
      );
      expect(store.noteFor(DateTime(2026, 3, 4))!.body, 'their edit');
    });

    test('a remote tombstone hides the section everywhere', () async {
      final store = await _storeOn(MemoryNoteRepository());
      store.appendToDay(DateTime(2026, 3, 4), 'to be deleted');
      final local = store.noteFor(DateTime(2026, 3, 4))!.sections.single;

      store.applyRemoteSection(
        DateTime(2026, 3, 4),
        local.copyWith(
          text: '',
          deleted: true,
          updatedAt: local.modifiedAt.add(const Duration(minutes: 1)),
        ),
      );

      expect(store.hasNote(DateTime(2026, 3, 4)), isFalse);
    });

    test('a remote section for an unseen day creates that note', () async {
      final store = await _storeOn(MemoryNoteRepository());
      store.applyRemoteSection(
        DateTime(2026, 3, 9),
        section('remote', text: 'from the phone'),
      );

      expect(store.noteFor(DateTime(2026, 3, 9))!.body, 'from the phone');
      expect(store.daysWithNotesIn(2026, 3), contains(DateTime(2026, 3, 9)));
    });

    test('attaching a repository replaces the samples with stored notes', () async {
      final repository = MemoryNoteRepository([
        DayNote(day: DateTime(2026, 2, 2), sections: [section('stored')]),
      ]);
      final store = await _storeOn(repository);

      expect(store.yearsWithNotes, [2026]);
      expect(store.noteFor(DateTime(2026, 2, 2)), isNotNull);
      expect(store.isLoaded, isTrue);
    });
  });
}

/// A fresh store on [repository], with the samples cleared.
///
/// Only [NoteStore.instance] is constructed by the app; a test store is built
/// through the same code path by seeding an empty repository, which the
/// attach step treats as "nothing stored yet".
Future<NoteStore> _storeOn(NoteRepository repository) async {
  final store = NoteStore.forTesting(repository);
  await store.attachRepository(repository);
  return store;
}
