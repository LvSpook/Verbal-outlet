/// A model that answers instantly with a fixed entry.
///
/// The app's default write path goes through the AI, so any widget test that
/// types into the composer needs a model. This one is deliberately plain: it
/// echoes the entry as a single short paragraph, wrapped in the request, so a
/// test can assert that the AI's text (not the raw words) is what the note
/// shows.
library;

import 'package:verbal_outlet/ai/ai_provider.dart';

class FakeComposerProvider implements AiProvider {
  FakeComposerProvider({this.available = true, this.failMessage});

  /// Whether [isAvailable] answers true. Set false to stand in for "Ollama is
  /// not running". Mutable so a test can bring the model back mid-test, which
  /// is the event the automatic retry exists for.
  bool available;

  /// When set, every chat throws an [AiException] with this message.
  final String? failMessage;

  /// Every request this provider was asked to answer, so a test can inspect the
  /// prompt or count the calls.
  final List<List<AiMessage>> received = [];

  @override
  String get name => 'Fake';

  @override
  String get model => 'fake-1';

  @override
  Future<bool> isAvailable() async => available;

  @override
  Stream<AiChunk> chat(List<AiMessage> messages) async* {
    received.add(messages);
    if (failMessage != null) {
      throw AiException(failMessage!);
    }

    // The composed entry is prefixed so tests can tell it apart from the words
    // the person typed, without needing a real model to paraphrase.
    final prompt = messages.last.text;
    final words = _between(prompt, '---\n', '\n---') ?? prompt;
    yield const AiChunk.first();
    yield AiChunk.token('Written: ${words.trim()}');
    yield const AiChunk.finished();
  }

  @override
  Future<void> dispose() async {}

  static String? _between(String text, String start, String end) {
    final from = text.indexOf(start);
    if (from == -1) return null;
    final to = text.indexOf(end, from + start.length);
    if (to == -1) return null;
    return text.substring(from + start.length, to);
  }
}
