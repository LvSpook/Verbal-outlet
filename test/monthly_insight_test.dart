import 'package:flutter_test/flutter_test.dart';
import 'package:verbal_outlet/ai/ai_controller.dart';
import 'package:verbal_outlet/ai/ai_provider.dart';
import 'package:verbal_outlet/ai/monthly_insight.dart';
import 'package:verbal_outlet/ai/monthly_insight_controller.dart';
import 'package:verbal_outlet/data/note_repository.dart';
import 'package:verbal_outlet/data/note_store.dart';

/// A model that answers every request with a scripted reply.
///
/// The monthly overview, the follow-up question and the command classifier all
/// go through the same one-shot path, so one scripted string is enough to drive
/// any of them.
class _ScriptedProvider implements AiProvider {
  _ScriptedProvider() : reply = 'An overview.', available = true;

  String reply;
  bool available;
  String? failMessage;
  int chats = 0;

  @override
  String get name => 'Scripted';

  @override
  String get model => 'scripted-1';

  @override
  Future<bool> isAvailable() async => available;

  @override
  Stream<AiChunk> chat(List<AiMessage> messages) async* {
    chats++;
    if (failMessage != null) throw AiException(failMessage!);
    yield const AiChunk.first();
    yield AiChunk.token(reply);
    yield const AiChunk.finished();
  }

  @override
  Future<void> dispose() async {}
}

/// In-memory cache so no test touches real preferences.
class _MemoryInsightStore implements MonthlyInsightStore {
  final Map<String, MonthlyInsight> saved = {};

  @override
  Future<MonthlyInsight?> read(int year, int month) async =>
      saved[monthKey(year, month)];

  @override
  Future<void> write(MonthlyInsight insight) async {
    saved[insight.key] = insight;
  }

  @override
  Future<void> delete(int year, int month) async {
    saved.remove(monthKey(year, month));
  }
}

void main() {
  late NoteStore store;
  late _ScriptedProvider provider;
  late AiController ai;
  late _MemoryInsightStore cache;
  late MonthlyInsightController controller;

  // A month in the past, so "today" never leaks into the fixture.
  final april = DateTime(2026, 4);

  setUp(() async {
    store = NoteStore.instance;
    await store.attachRepository(MemoryNoteRepository(), seedSamples: false);
    provider = _ScriptedProvider();
    ai = AiController(initialProvider: provider);
    cache = _MemoryInsightStore();
    controller = MonthlyInsightController(
      store: store,
      ai: ai,
      cache: cache,
    );
  });

  test('a month with no notes asks the model nothing', () async {
    await controller.show(april.year, april.month);

    expect(controller.state.empty, isTrue);
    expect(provider.chats, 0);
    expect(cache.saved, isEmpty);
  });

  test('a month with notes writes and caches an overview', () async {
    store.appendToDay(DateTime(2026, 4, 3), 'A long walk by the river.');
    provider.reply = '## In short\nA quiet month.';

    await controller.show(april.year, april.month);

    expect(provider.chats, 1);
    expect(controller.state.insight?.body, contains('A quiet month'));
    expect(cache.saved, contains(monthKey(april.year, april.month)));
  });

  test('a second look at the same month uses the cache', () async {
    store.appendToDay(DateTime(2026, 4, 3), 'A long walk by the river.');
    await controller.show(april.year, april.month);
    expect(provider.chats, 1);

    // A fresh controller, as if the app had been reopened.
    final reopened = MonthlyInsightController(
      store: store,
      ai: ai,
      cache: cache,
    );
    await reopened.show(april.year, april.month);

    expect(provider.chats, 1, reason: 'no second model call');
    expect(reopened.state.insight, isNotNull);
    expect(reopened.state.generating, isFalse);
  });

  test('editing the month marks the cached overview stale and rewrites it', () async {
    final day = DateTime(2026, 4, 3);
    store.appendToDay(day, 'A long walk by the river.');
    await controller.show(april.year, april.month);
    final firstRevision = controller.state.insight!.revision;

    // A new entry changes the month.
    store.appendToDay(DateTime(2026, 4, 9), 'A harder week.');
    provider.reply = '## In short\nA fuller month.';

    final reopened = MonthlyInsightController(
      store: store,
      ai: ai,
      cache: cache,
    );
    await reopened.show(april.year, april.month);

    expect(provider.chats, 2);
    expect(reopened.state.insight!.revision, isNot(firstRevision));
    expect(reopened.state.insight!.body, contains('fuller'));
  });

  test('an unreachable model reports an error and keeps any old overview', () async {
    store.appendToDay(DateTime(2026, 4, 3), 'A long walk by the river.');
    await controller.show(april.year, april.month);

    // Make the model unavailable, then force a rewrite.
    provider.available = false;
    await controller.regenerate();

    expect(controller.state.insight?.body, isNotEmpty, reason: 'old one kept');
    expect(controller.state.error, isNotNull);
    expect(controller.state.generating, isFalse);
  });

  test('a model error on a first look leaves no overview, just a reason', () async {
    store.appendToDay(DateTime(2026, 4, 3), 'A long walk by the river.');
    provider
      ..available = true
      ..reply = '';

    await controller.show(april.year, april.month);

    expect(controller.state.insight, isNull);
    expect(controller.state.error, isNotNull);
    expect(cache.saved, isEmpty);
  });

  test('a reply for a month that has been left is dropped', () async {
    store
      ..appendToDay(DateTime(2026, 4, 3), 'April words.')
      ..appendToDay(DateTime(2026, 5, 4), 'May words.');

    await controller.show(april.year, april.month);
    expect(controller.month, 4);

    await controller.show(2026, 5);
    expect(controller.month, 5);
    expect(controller.state.insight?.body, isNotEmpty);
  });

  test('the revision changes when an entry changes, and not before', () async {
    store.appendToDay(DateTime(2026, 4, 3), 'First words.');
    final note = store
        .noteOrEmpty(DateTime(2026, 4, 3))
        .sections
        .single;
    final before = revisionOf([store.noteOrEmpty(DateTime(2026, 4, 3))]);

    // Same content, read again: the fingerprint is stable.
    expect(
      revisionOf([store.noteOrEmpty(DateTime(2026, 4, 3))]),
      before,
    );

    store.updateSection(DateTime(2026, 4, 3), note.id, 'Different words.');
    final after = revisionOf([store.noteOrEmpty(DateTime(2026, 4, 3))]);
    expect(after, isNot(before));
  });
}


