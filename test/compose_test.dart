import 'package:flutter_test/flutter_test.dart';

import 'package:verbal_outlet/ai/ai_controller.dart';
import 'package:verbal_outlet/ai/compose_queue.dart';
import 'package:verbal_outlet/data/note_repository.dart';
import 'package:verbal_outlet/data/note_store.dart';
import 'package:verbal_outlet/models/day_note.dart';
import 'package:verbal_outlet/widgets/ai/entry_view.dart';

import 'support/fake_composer_provider.dart';

/// A store with no shared state, so tests cannot leak into each other.
Future<NoteStore> _store() async {
  final store = NoteStore.forTesting(MemoryNoteRepository());
  await store.attachRepository(MemoryNoteRepository(), seedSamples: false);
  return store;
}

AiController _ai(FakeComposerProvider provider) =>
    AiController(initialProvider: provider);

void main() {
  group('holding an entry', () {
    test('adding keeps the words but shows nothing until written', () async {
      final store = await _store();
      final day = DateTime(2026, 4, 2);

      store.holdForCompose(day, '  A thought with spaces  ');

      final note = store.noteFor(day)!;
      // Held back from the note itself...
      expect(note.isEmpty, isTrue);
      expect(note.held, hasLength(1));
      // ...but the words are already safe.
      expect(note.sections.single.text, 'A thought with spaces');
      expect(note.sections.single.state, ComposeState.pending);
    });

    test('an instruction travels with the entry', () async {
      final store = await _store();
      final day = DateTime(2026, 4, 2);

      store.holdForCompose(day, 'Bought milk and eggs', instruction: 'list');

      expect(store.noteFor(day)!.sections.single.instruction, 'list');
    });

    test('empty text is not held', () async {
      final store = await _store();
      final day = DateTime(2026, 4, 2);

      store.holdForCompose(day, '   ');

      expect(store.noteFor(day), isNull);
    });
  });

  group('composing', () {
    test('writes the AI version and shows it', () async {
      final store = await _store();
      final provider = FakeComposerProvider();
      final queue = ComposeQueue(store: store, ai: _ai(provider));
      final day = DateTime(2026, 4, 2);

      store.holdForCompose(day, 'Slept badly, long day at work.');
      final held = store.noteFor(day)!.sections.single;

      final outcome = await queue.compose(day, held);

      expect(outcome, ComposeOutcome.written);
      final written = store.noteFor(day)!.sections.single;
      expect(written.state, ComposeState.ready);
      expect(written.body, 'Written: Slept badly, long day at work.');
      // The original words survive untouched.
      expect(written.text, 'Slept badly, long day at work.');
      expect(store.noteFor(day)!.isNotEmpty, isTrue);
    });

    test('sends the instruction in the prompt', () async {
      final store = await _store();
      final provider = FakeComposerProvider();
      final queue = ComposeQueue(store: store, ai: _ai(provider));
      final day = DateTime(2026, 4, 2);

      store.holdForCompose(day, 'Milk, eggs', instruction: 'make a checklist');
      await queue.compose(day, store.noteFor(day)!.sections.single);

      final prompt = provider.received.single.last.text;
      expect(prompt, contains('make a checklist'));
      expect(prompt, contains('Milk, eggs'));
    });

    test('a dropped connection leaves it waiting, not failed', () async {
      final store = await _store();
      final provider = FakeComposerProvider(
        failMessage: 'Could not reach the local model.',
      );
      final queue = ComposeQueue(store: store, ai: _ai(provider));
      final day = DateTime(2026, 4, 2);

      store.holdForCompose(day, 'Something to keep');
      final outcome = await queue.compose(
        day,
        store.noteFor(day)!.sections.single,
      );

      expect(outcome, ComposeOutcome.unavailable);
      final section = store.noteFor(day)!.sections.single;
      expect(section.state, ComposeState.pending);
      expect(section.text, 'Something to keep');
    });

    test('a real model error is reported on the entry', () async {
      final store = await _store();
      final provider = FakeComposerProvider(
        failMessage: 'The model returned nothing. Try rephrasing.',
      );
      final queue = ComposeQueue(store: store, ai: _ai(provider));
      final day = DateTime(2026, 4, 2);

      store.holdForCompose(day, 'Something odd');
      final outcome = await queue.compose(
        day,
        store.noteFor(day)!.sections.single,
      );

      expect(outcome, ComposeOutcome.failed);
      final section = store.noteFor(day)!.sections.single;
      expect(section.state, ComposeState.failed);
      expect(section.composeError, contains('returned nothing'));
    });

    test('a rejected API key is reported, not held forever', () async {
      final store = await _store();
      final provider = FakeComposerProvider(
        failMessage: 'The provider refused the request: invalid api key',
      );
      final queue = ComposeQueue(store: store, ai: _ai(provider));
      final day = DateTime(2026, 4, 2);

      store.holdForCompose(day, 'Something to keep');
      final outcome = await queue.compose(
        day,
        store.noteFor(day)!.sections.single,
      );

      // A bad key is an answer, not an outage: say so on the entry so it can be
      // fixed, rather than leaving it waiting forever.
      expect(outcome, ComposeOutcome.failed);
      final section = store.noteFor(day)!.sections.single;
      expect(section.state, ComposeState.failed);
      expect(section.composeError, contains('refused'));
    });

    test('a retry after success is harmless', () async {
      final store = await _store();
      final queue = ComposeQueue(store: store, ai: _ai(FakeComposerProvider()));
      final day = DateTime(2026, 4, 2);

      store.holdForCompose(day, 'One');
      await queue.compose(day, store.noteFor(day)!.sections.single);
      final again = await queue.compose(day, store.noteFor(day)!.sections.single);

      expect(again, ComposeOutcome.written);
      expect(store.noteFor(day)!.sections, hasLength(1));
    });
  });

  group('a whole pass', () {
    test('writes every waiting entry', () async {
      final store = await _store();
      final provider = FakeComposerProvider();
      final queue = ComposeQueue(store: store, ai: _ai(provider));

      store.holdForCompose(DateTime(2026, 4, 1), 'First');
      store.holdForCompose(DateTime(2026, 4, 2), 'Second');
      await queue.kick();

      expect(store.pendingCompositions, isEmpty);
      expect(store.noteFor(DateTime(2026, 4, 1))!.body, 'Written: First');
      expect(store.noteFor(DateTime(2026, 4, 2))!.body, 'Written: Second');
      expect(provider.received, hasLength(2));
    });

    test('stops at the first refusal rather than failing every entry', () async {
      final store = await _store();
      // isAvailable false: the model is simply not there.
      final queue = ComposeQueue(
        store: store,
        ai: _ai(FakeComposerProvider(available: false)),
      );

      store.holdForCompose(DateTime(2026, 4, 1), 'First');
      store.holdForCompose(DateTime(2026, 4, 2), 'Second');
      await queue.kick();

      // Both still waiting, nothing marked failed, and an explanation ready.
      expect(store.pendingCompositions, hasLength(2));
      expect(queue.blockedReason, isNotNull);
      expect(
        store.pendingCompositions.every(
          (entry) => entry.$2.state == ComposeState.pending,
        ),
        isTrue,
      );
    });

    test('does nothing when there is no work', () async {
      final store = await _store();
      final provider = FakeComposerProvider();
      final queue = ComposeQueue(store: store, ai: _ai(provider));

      await queue.kick();

      expect(provider.received, isEmpty);
      expect(queue.blockedReason, isNull);
    });
  });

  group('editing an entry', () {
    test('clears the old AI version so it is written again', () async {
      final store = await _store();
      final queue = ComposeQueue(store: store, ai: _ai(FakeComposerProvider()));
      final day = DateTime(2026, 4, 2);

      store.holdForCompose(day, 'Original words');
      await queue.compose(day, store.noteFor(day)!.sections.single);
      final id = store.noteFor(day)!.sections.single.id;

      store.updateSection(day, id, 'Changed words');

      final section = store.noteFor(day)!.sections.single;
      expect(section.text, 'Changed words');
      expect(section.body, isEmpty);
      expect(section.state, ComposeState.pending);
      expect(store.pendingCompositions, hasLength(1));
    });

    test('an untouched section keeps its AI version', () async {
      final store = await _store();
      final day = DateTime(2026, 4, 2);
      store.appendToDay(day, 'Plain, never composed');

      final id = store.noteFor(day)!.sections.single.id;
      store.updateSection(day, id, 'Slightly different');

      // No body existed, so there is nothing stale to throw away.
      expect(store.noteFor(day)!.sections.single.state, ComposeState.ready);
      expect(store.noteFor(day)!.isNotEmpty, isTrue);
    });
  });

  group('search', () {
    test('finds an entry by either the words or the AI version', () async {
      final store = await _store();
      final day = DateTime(2026, 4, 2);
      store.holdForCompose(day, 'The plumber is coming Tuesday');
      final queue = ComposeQueue(
        store: store,
        ai: _ai(FakeComposerProvider()),
      );
      await queue.compose(day, store.noteFor(day)!.sections.single);

      final section = store.noteFor(day)!.sections.single;
      expect(section.searchableText, contains('plumber'));
      expect(section.searchableText, contains('Written:'));
    });
  });

  group('reading a composed entry', () {
    test('plain words are one paragraph', () {
      final blocks = parseEntry('A quiet day, mostly reading.');

      expect(blocks, hasLength(1));
      expect((blocks.single as ParagraphBlock).text, contains('quiet day'));
    });

    test('a lead sentence and bullets stay separate', () {
      final blocks = parseEntry(
        'A good day.\n\n- Walked the dog\n- Cooked dinner',
      );

      expect(blocks[0], isA<ParagraphBlock>());
      expect(blocks.whereType<BulletBlock>(), hasLength(2));
      expect(blocks.whereType<BulletBlock>().first.text, 'Walked the dog');
    });

    test('a checklist is read as checked and unchecked', () {
      final blocks = parseEntry('- [ ] Call the bank\n- [x] Post the form');

      final bullets = blocks.whereType<BulletBlock>().toList();
      expect(bullets[0].checked, isFalse);
      expect(bullets[1].checked, isTrue);
    });

    test('a chart fence becomes a chart block', () {
      final blocks = parseEntry(
        'Hours this week:\n\n'
        '```chart\n'
        '{"type":"bar","title":"Hours","labels":["Mon"],"values":[7]}\n'
        '```',
      );

      final chart = blocks.whereType<ChartBlock>().single;
      expect(chart.data.labels, ['Mon']);
      expect(chart.data.values, [7]);
    });

    test('a dot fence becomes a diagram block', () {
      final blocks = parseEntry(
        '```dot\n'
        'digraph entry {\n'
        '  a [label="Late night"];\n'
        '}\n'
        '```',
      );

      expect(blocks.whereType<DiagramBlock>(), hasLength(1));
    });

    test('headings and quotes are recognised', () {
      final blocks = parseEntry('## Sunday\n\n> Something I want to keep');

      expect((blocks[0] as HeadingBlock).level, 2);
      expect((blocks[1] as QuoteBlock).text, 'Something I want to keep');
    });

    test('unknown fences degrade to readable text, not nothing', () {
      final blocks = parseEntry('```\nnot a diagram\n```');

      expect(blocks, hasLength(1));
      expect((blocks.single as ParagraphBlock).text, contains('not a diagram'));
    });

    test('empty input has no blocks', () {
      expect(parseEntry('   \n\n  '), isEmpty);
    });
  });
}
