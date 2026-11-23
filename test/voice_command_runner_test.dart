import 'package:flutter_test/flutter_test.dart';
import 'package:verbal_outlet/capture/app_request.dart';
import 'package:verbal_outlet/data/note_repository.dart';
import 'package:verbal_outlet/data/note_store.dart';
import 'package:verbal_outlet/voice/voice_command.dart';
import 'package:verbal_outlet/voice/voice_command_runner.dart';

/// Pins "today" so the relative dates are stable.
DateTime _today() => DateTime(2026, 4, 15);

void main() {
  group('reading a spoken date', () {
    final now = _today();

    test('the words people actually say', () {
      expect(parseSpokenDate('today', now: now), DateTime(2026, 4, 15));
      expect(parseSpokenDate('yesterday', now: now), DateTime(2026, 4, 14));
      expect(parseSpokenDate('the day before yesterday', now: now), DateTime(2026, 4, 13));
    });

    test('an ISO date, which is what the prompt asks for', () {
      expect(parseSpokenDate('2026-03-02', now: now), DateTime(2026, 3, 2));
    });

    test('a month and a day in either order', () {
      expect(parseSpokenDate('3 april', now: now), DateTime(2026, 4, 3));
      expect(parseSpokenDate('april 3', now: now), DateTime(2026, 4, 3));
      expect(parseSpokenDate('3rd april 2025', now: now), DateTime(2025, 4, 3));
    });

    test('last friday means the most recent one, never today', () {
      // The 15th is a Wednesday, so the 10th was the Friday before.
      expect(parseSpokenDate('last friday', now: now), DateTime(2026, 4, 10));
      expect(parseSpokenDate('friday', now: now), DateTime(2026, 4, 10));
    });

    test('a bare day number means this month', () {
      expect(parseSpokenDate('the 3rd', now: now), DateTime(2026, 4, 3));
      expect(parseSpokenDate('3', now: now), DateTime(2026, 4, 3));
    });

    test('nonsense returns null rather than guessing', () {
      expect(parseSpokenDate('whenever', now: now), isNull);
      expect(parseSpokenDate('', now: now), isNull);
    });
  });

  group('running commands', () {
    late NoteStore store;
    late AppRequestMailbox mailbox;
    late VoiceCommandRunner runner;

    setUp(() async {
      store = NoteStore.instance;
      await store.attachRepository(MemoryNoteRepository(), seedSamples: false);
      mailbox = AppRequestMailbox();
      runner = VoiceCommandRunner(
        store: store,
        mailbox: mailbox,
        clock: _today,
      );
    });

    test('a note is written', () async {
      final outcome = await runner.run(
        const AddNoteCommand('Walked to the river.'),
        day: _today(),
      );
      expect(outcome.done, isTrue);
      expect(store.noteOrEmpty(_today()).sectionCount, 1);
    });

    test('search asks the app to open the search', () async {
      final outcome = await runner.run(
        const SearchCommand('the trip'),
        day: _today(),
      );
      expect(outcome.done, isTrue);
      final request = mailbox.take();
      expect(request?.action, AppAction.searchAll);
      expect(request?.query, 'the trip');
    });

    test('opening a day posts the resolved date', () async {
      await runner.run(const OpenDayCommand('yesterday'), day: _today());
      final request = mailbox.take();
      expect(request?.action, AppAction.openDay);
      expect(request?.day, DateTime(2026, 4, 14));
    });

    test('changing month posts forward or back', () async {
      await runner.run(const ChangeMonthCommand(forward: true), day: _today());
      expect(mailbox.take()?.action, AppAction.nextMonth);

      await runner.run(const ChangeMonthCommand(forward: false), day: _today());
      expect(mailbox.take()?.action, AppAction.previousMonth);
    });
  });

  group('the confirmation gate', () {
    late NoteStore store;
    late VoiceCommandRunner runner;
    late String sectionId;

    setUp(() async {
      store = NoteStore.instance;
      await store.attachRepository(MemoryNoteRepository(), seedSamples: false);
      store.appendToDay(_today(), 'I went for a long walk by the river.');
      sectionId = store.noteOrEmpty(_today()).sections.single.id;
      runner = VoiceCommandRunner(
        store: store,
        mailbox: AppRequestMailbox(),
        clock: _today,
      );
    });

    test('a delete does nothing until it is confirmed', () async {
      const command = DeleteEntryCommand(target: 'walk');

      final first = await runner.run(command, day: _today());
      expect(first.needsConfirmation, isTrue);
      expect(first.message, contains('Delete'));
      expect(store.noteOrEmpty(_today()).sectionCount, 1);
      expect(store.noteOrEmpty(_today()).sections.single.id, sectionId);

      final second = await runner.run(command, day: _today(), confirmed: true);
      expect(second.done, isTrue);
      expect(store.noteOrEmpty(_today()).isEmpty, isTrue);
    });

    test('an edit does nothing until it is confirmed', () async {
      const command = EditEntryCommand(target: 'walk', instruction: 'A short stroll.');

      final first = await runner.run(command, day: _today());
      expect(first.needsConfirmation, isTrue);
      expect(
        store.noteOrEmpty(_today()).sections.single.text,
        'I went for a long walk by the river.',
      );

      final second = await runner.run(command, day: _today(), confirmed: true);
      expect(second.done, isTrue);
      expect(store.noteOrEmpty(_today()).sections.single.text, 'A short stroll.');
    });

    test('an empty replacement asks rather than blanking the entry', () async {
      final outcome = await runner.run(
        const EditEntryCommand(target: 'walk', instruction: ''),
        day: _today(),
        confirmed: true,
      );
      expect(outcome.done, isFalse);
      expect(outcome.message, contains('instead'));
      expect(
        store.noteOrEmpty(_today()).sections.single.text,
        'I went for a long walk by the river.',
      );
    });

    test('deleting when the day is empty says so instead of throwing', () async {
      final outcome = await runner.run(
        const DeleteEntryCommand(target: 'last'),
        day: DateTime(2020, 1, 1),
        confirmed: true,
      );
      expect(outcome.done, isFalse);
    });
  });
}

