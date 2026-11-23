import 'package:flutter_test/flutter_test.dart';
import 'package:verbal_outlet/ai/ai_controller.dart';
import 'package:verbal_outlet/ai/ai_provider.dart';

/// A model that answers every request with whatever it was last told to.
class _ScriptedProvider implements AiProvider {
  _ScriptedProvider(this.reply);

  String reply;
  bool available = true;
  bool throwOnChat = false;
  final List<List<AiMessage>> received = [];

  @override
  String get name => 'Scripted';

  @override
  String get model => 'scripted-1';

  @override
  Future<bool> isAvailable() async => available;

  @override
  Stream<AiChunk> chat(List<AiMessage> messages) async* {
    received.add(messages);
    if (throwOnChat) {
      throw const AiException('The model went away.');
    }
    yield const AiChunk.first();
    yield AiChunk.token(reply);
    yield const AiChunk.finished();
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  group('asking one follow-up question', () {
    test('a short thought is not worth a question', () async {
      final provider = _ScriptedProvider('Who was that?');
      final ai = AiController(initialProvider: provider);

      final question = await ai.followUpQuestion(transcript: 'Went out.');

      expect(question, isNull);
      expect(provider.received, isEmpty, reason: 'no model call at all');
    });

    test('a question is returned and read as one question', () async {
      final provider = _ScriptedProvider('  "Who was that?"  ');
      final ai = AiController(initialProvider: provider);

      final question = await ai.followUpQuestion(
        transcript: 'I went out with that person from the thing again.',
      );

      expect(question, 'Who was that?');
    });

    test('NOTHING means stay quiet', () async {
      final provider = _ScriptedProvider('NOTHING');
      final ai = AiController(initialProvider: provider);

      final question = await ai.followUpQuestion(
        transcript: 'I walked down to the river and sat there for an hour.',
      );
      expect(question, isNull);
    });

    test('a second question in one reply is rejected', () async {
      final provider = _ScriptedProvider('Who was that? And where did you go?');
      final ai = AiController(initialProvider: provider);

      final question = await ai.followUpQuestion(
        transcript: 'I went out with someone from the old place yesterday.',
      );
      expect(question, isNull);
    });

    test('an over-long reply is rejected', () async {
      final provider = _ScriptedProvider(
        'What exactly did you mean when you said you were feeling quite '
        'tired after the long walk down by the river that afternoon?',
      );
      final ai = AiController(initialProvider: provider);

      final question = await ai.followUpQuestion(
        transcript: 'I was tired after the walk down by the river today.',
      );
      expect(question, isNull);
    });

    test('a question already asked is not asked again', () async {
      final provider = _ScriptedProvider('Who was that?');
      final ai = AiController(initialProvider: provider);

      final question = await ai.followUpQuestion(
        transcript: 'I met someone by the river and we talked a while.',
        alreadyAsked: {'who was that?'},
      );
      expect(question, isNull);
    });

    test('a missing model never throws', () async {
      final provider = _ScriptedProvider('Who was that?')..throwOnChat = true;
      final ai = AiController(initialProvider: provider);

      final question = await ai.followUpQuestion(
        transcript: 'I met someone by the river and we talked a while.',
      );
      expect(question, isNull);
    });
  });

  group('classifying a spoken command', () {
    test('the reply is passed through for the parser', () async {
      final provider = _ScriptedProvider('{"intent":"search","value":"trip"}');
      final ai = AiController(initialProvider: provider);

      final reply = await ai.classifyCommand(
        transcript: 'search my notes for the trip',
        context: 'the note for this day',
      );
      expect(reply, contains('search'));
      expect(provider.received, hasLength(1));
    });

    test('an empty reply is null, and a failure never throws', () async {
      final provider = _ScriptedProvider('');
      final ai = AiController(initialProvider: provider);
      expect(
        await ai.classifyCommand(transcript: 'anything', context: ''),
        isNull,
      );

      provider.throwOnChat = true;
      expect(
        await ai.classifyCommand(transcript: 'anything', context: ''),
        isNull,
      );
    });
  });

  group('judging transcription joins', () {
    test('the broken joins are counted', () async {
      final provider = _ScriptedProvider('{"broken":[1,3]}');
      final ai = AiController(initialProvider: provider);

      final broken = await ai.countBrokenJoins([
        '"I wanted to ask you about" then "the job"',
        '"That was that." then "Tomorrow I rest."',
        '"It felt" then "much harder than before"',
      ]);

      expect(broken, 2);
      expect(provider.received, hasLength(1));
    });

    test('an empty list is a normal answer', () async {
      final provider = _ScriptedProvider('{"broken":[]}');
      final ai = AiController(initialProvider: provider);

      expect(await ai.countBrokenJoins(['"a" then "b"']), 0);
    });

    test('numbers outside the list are ignored, and duplicates collapse', () async {
      final provider = _ScriptedProvider('{"broken":[1,1,7,"2"]}');
      final ai = AiController(initialProvider: provider);
      expect(await ai.countBrokenJoins(['"a" then "b"', '"c" then "d"']), 2);
    });

    test('a chatty reply is still read', () async {
      final provider = _ScriptedProvider(
        'Sure - here it is:\n{"broken":[2]}\nHope that helps.',
      );
      final ai = AiController(initialProvider: provider);
      expect(await ai.countBrokenJoins(['"a" then "b"', '"c" then "d"']), 1);
    });

    test('no joins means no call', () async {
      final provider = _ScriptedProvider('{"broken":[1]}');
      final ai = AiController(initialProvider: provider);
      expect(await ai.countBrokenJoins(const []), 0);
      expect(provider.received, isEmpty);
    });

    test('an unreadable reply or a missing model counts as zero', () async {
      final provider = _ScriptedProvider('I cannot tell.');
      final ai = AiController(initialProvider: provider);
      expect(await ai.countBrokenJoins(['"a" then "b"']), 0);

      provider.reply = '{"broken":[1]}';
      provider.throwOnChat = true;
      expect(await ai.countBrokenJoins(['"a" then "b"']), 0);
    });
  });

  group('the monthly overview', () {
    test('an empty overview is an error worth reporting', () async {
      final provider = _ScriptedProvider('');
      final ai = AiController(initialProvider: provider);

      await expectLater(
        ai.monthlyInsight(year: 2026, month: 4, notes: 'A note.'),
        throwsA(isA<AiException>()),
      );
    });
  });
}
