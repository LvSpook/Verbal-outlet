import 'package:flutter_test/flutter_test.dart';
import 'package:verbal_outlet/voice/voice_command.dart';

void main() {
  group('reading the classifier reply', () {
    test('a clean object becomes the right command', () {
      final command = parseVoiceCommand(
        '{"intent":"search","value":"the trip"}',
        'search my notes for the trip',
      );
      expect(command, isA<SearchCommand>());
      expect((command as SearchCommand).query, 'the trip');
    });

    test('prose around the JSON is tolerated', () {
      final command = parseVoiceCommand(
        'Sure! {"intent": "open_day", "value": "yesterday"} Hope that helps.',
        'open yesterday',
      );
      expect(command, isA<OpenDayCommand>());
      expect((command as OpenDayCommand).date, 'yesterday');
    });

    test('a code fence and a different key still parse', () {
      final command = parseVoiceCommand(
        '```json\n{"action":"next_month","value":""}\n```',
        'next month',
      );
      expect(command, isA<ChangeMonthCommand>());
      expect((command as ChangeMonthCommand).forward, isTrue);
    });

    test('trailing prose containing a brace does not spoil the object', () {
      final command = parseVoiceCommand(
        '{"intent":"delete_entry","value":"the walk"} (that is what I mean)',
        'delete the walk one',
      );
      expect(command, isA<DeleteEntryCommand>());
      expect((command as DeleteEntryCommand).target, 'the walk');
    });

    test('ordinary speech classified as none becomes a note', () {
      final command = parseVoiceCommand(
        '{"intent":"none","value":""}',
        'I felt tired after the walk.',
      );
      expect(command, isA<AddNoteCommand>());
      expect((command as AddNoteCommand).text, 'I felt tired after the walk.');
    });

    test('unreadable or missing replies fall back to a note', () {
      for (final reply in [null, '', 'no idea', '{"intent":']) {
        final command = parseVoiceCommand(reply, 'a thought worth keeping');
        expect(command, isA<AddNoteCommand>(), reason: 'for reply $reply');
        expect((command as AddNoteCommand).text, 'a thought worth keeping');
      }
    });

    test('an unknown intent falls back too', () {
      final command = parseVoiceCommand(
        '{"intent":"teleport","value":""}',
        'beam me up',
      );
      expect(command, isA<AddNoteCommand>());
    });
  });

  group('destructive commands', () {
    test('delete and edit are destructive, nothing else is', () {
      expect(isDestructive(const DeleteEntryCommand(target: 'last')), isTrue);
      expect(
        isDestructive(
          const EditEntryCommand(target: 'last', instruction: 'say it better'),
        ),
        isTrue,
      );
      expect(isDestructive(const SearchCommand('trip')), isFalse);
      expect(isDestructive(const AddNoteCommand('hello there')), isFalse);
      expect(isDestructive(const ChangeMonthCommand(forward: true)), isFalse);
    });

    test('the confirmation label matches the action', () {
      expect(confirmLabelFor(const DeleteEntryCommand(target: 'last')), 'Delete it');
      expect(
        confirmLabelFor(
          const EditEntryCommand(target: 'last', instruction: 'change it'),
        ),
        'Change it',
      );
    });
  });
}
