/// Owns the current [AiProvider] and the conversation, so the UI only has to
/// talk to one object.
///
/// Responsibilities, in order of importance:
///
/// * Build the right provider from saved settings (local Ollama, or cloud with
///   an API key), and rebuild it when the user changes settings.
/// * Turn a day's notes into a prompt, and stream the answer back as text.
/// * Notice a `dot` or `chart` block in the reply and expose it as structured
///   data, so the app can draw it instead of printing code at the user.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/day_note.dart';
import '../utils/date_format.dart';
import 'ai_provider.dart';
import 'ai_settings.dart';
import 'cloud_provider.dart';
import 'ollama_provider.dart';
import 'prompts.dart';

/// A diagram or chart lifted out of a model reply.
class RenderedBlock {
  const RenderedBlock({
    required this.kind,
    required this.source,
    this.chart,
    this.error,
  });

  final RenderedBlockKind kind;

  /// The block's body exactly as the model wrote it.
  final String source;

  /// Parsed chart data, when [kind] is chart and it parsed cleanly.
  final ChartData? chart;

  /// Why the block could not be read, in plain language.
  final String? error;
}

enum RenderedBlockKind { diagram, chart }

/// Chart data in the shape the widget wants.
class ChartData {
  const ChartData({
    required this.type,
    required this.title,
    required this.labels,
    required this.values,
  });

  final ChartType type;
  final String title;
  final List<String> labels;
  final List<double> values;
}

enum ChartType { bar, line, pie }

/// One exchange in the AI panel.
class AiTurn {
  AiTurn.user(this.text) : isUser = true, blocks = const [], pending = false;

  AiTurn.assistant(this.text, {this.blocks = const [], this.pending = false})
    : isUser = false;

  final String text;
  final bool isUser;

  /// Diagrams and charts pulled out of [text]. Empty for user turns.
  final List<RenderedBlock> blocks;

  /// True while tokens are still arriving.
  final bool pending;

  AiTurn copyWith({String? text, List<RenderedBlock>? blocks, bool? pending}) =>
      AiTurn.assistant(
        text ?? this.text,
        blocks: blocks ?? this.blocks,
        pending: pending ?? this.pending,
      );
}

  /// Builds notes into the plain text block the prompts expect.
String notesToPromptText(List<DayNote> notes) {
  final sorted = [...notes]..sort((a, b) => a.day.compareTo(b.day));
  final buffer = StringBuffer();
  for (final note in sorted) {
    final day =
        '${note.day.day} '
        '${monthNames[note.day.month - 1]} ${note.day.year}';
    buffer.writeln('[$day]');
    for (final section in note.visible) {
      final time = formatClock(section.createdAt);
      // The written-up version is what the note contains, so it is what the
      // assistant should read back. Older sections have no body and fall back
      // to their words.
      buffer.writeln('- $time: ${section.content.trim()}');
    }
    buffer.writeln();
  }
  return buffer.toString();
}

/// Drives one conversation with the configured model.
class AiController {
  AiController({
    AiSettingsStore? store,
    OllamaProvider? localProvider,
    AiProvider? initialProvider,
  }) : _store = store ?? AiSettingsStore(),
       _localOverride = localProvider,
       _provider = initialProvider;

  final AiSettingsStore _store;
  final OllamaProvider? _localOverride;

  AiSettings _settings = const AiSettings();
  AiProvider? _provider;

  /// The provider for local models. Kept separate from [_provider] because
  /// settings can also query it for installed models.
  OllamaProvider? _local;

  StreamSubscription<AiChunk>? _subscription;
  bool _cancelled = false;

  AiSettings get settings => _settings;

  /// Name of the engine currently answering, for the UI header.
  String get engineLabel => _settings.engine == AiEngineKind.local
      ? 'On this device'
      : _settings.cloudName;

  String get modelLabel => _settings.engine == AiEngineKind.local
      ? _settings.localModel
      : _settings.cloudModel;

  /// Loads saved settings and prepares the provider. Safe to call twice.
  ///
  /// A provider injected at construction (tests, previews) is left in place.
  Future<void> init() async {
    _settings = await _store.load();
    _provider ??= await _buildProvider();
  }

  Future<AiProvider> _buildProvider() async {
    if (_settings.engine == AiEngineKind.cloud) {
      final key = await _store.readApiKey() ?? '';
      return CloudProvider(
        baseUrl: _settings.cloudBaseUrl,
        apiKey: key,
        model: _settings.cloudModel,
        displayName: _settings.cloudName,
      );
    }

    final local = _local ??=
        _localOverride ??
        OllamaProvider(
          baseUrl: _settings.localBaseUrl,
          model: _settings.localModel,
        );
    return local;
  }

  /// The local Ollama handle, for settings screens that list or fetch models.
  OllamaProvider get local => _local ??=
      _localOverride ??
      OllamaProvider(
        baseUrl: _settings.localBaseUrl,
        model: _settings.localModel,
      );

  Future<void> applySettings(AiSettings settings) async {
    final engineChanged =
        settings.engine != _settings.engine ||
        settings.localModel != _settings.localModel ||
        settings.localBaseUrl != _settings.localBaseUrl ||
        settings.cloudBaseUrl != _settings.cloudBaseUrl ||
        settings.cloudModel != _settings.cloudModel;

    _settings = settings;
    await _store.save(settings);

    if (engineChanged) {
      await _provider?.dispose();
      // The local handle holds the old model name, so drop it and rebuild.
      _local = null;
      _provider = await _buildProvider();
    }
  }

  /// Whether the configured provider can answer right now, with a reason if
  /// not. Used to show readiness in the settings screen.
  Future<(bool, String?)> readiness() async {
    if (_settings.engine == AiEngineKind.local) {
      final local = this.local;
      if (!await local.isAvailable()) {
        return (false, 'Ollama is not running. Start it, then check again.');
      }
      if (!await local.hasModel()) {
        return (
          false,
          'Ollama is running, but ${_settings.localModel} is not downloaded yet.',
        );
      }
      return (true, null);
    }

    if (!_settings.hasApiKey) {
      return (false, 'Add an API key to use the cloud model.');
    }
    return (true, null);
  }

  /// Stops whatever is being generated. The partial answer stays visible.
  void cancel() {
    _cancelled = true;
    _subscription?.cancel();
    _subscription = null;
  }

  /// Whether the configured AI can write an entry right now.
  ///
  /// Used before composing so a missing model holds the entry instead of
  /// failing it. A small delay is acceptable here: it runs rarely.
  Future<bool> canCompose() async {
    if (_provider == null) {
      try {
        await init();
      } catch (_) {
        return false;
      }
    }
    if (_settings.engine == AiEngineKind.cloud && !_settings.hasApiKey) {
      return false;
    }
    final provider = _provider;
    if (provider == null) return false;
    try {
      return await provider.isAvailable();
    } catch (_) {
      return false;
    }
  }

  /// Turns one entry into the note text the app will show.
  ///
  /// A separate request from [run]: it has its own prompt and does not touch
  /// the panel's conversation, so composing never inserts turns into the chat.
  /// Throws [AiException] when the model cannot be reached.
  Future<String> compose({
    required String text,
    String? instruction,
  }) async {
    final reply = await _oneShot(
      system: composeSystemPrompt,
      user: buildComposePrompt(text: text, instruction: instruction),
    );
    if (reply.isEmpty) {
      throw const AiException(
        'The model sent back an empty entry.',
        hint: 'Check the model is fully downloaded, then try again.',
      );
    }
    return reply;
  }

  /// Asks for one follow-up question to put to someone who is mid-thought.
  ///
  /// Returns null when there is nothing worth asking, which is the common and
  /// correct answer. Never throws: a question is a bonus, and an AI that is
  /// down must not interrupt the person speaking. The same one is not asked
  /// twice in a row ([alreadyAsked]).
  Future<String?> followUpQuestion({
    required String transcript,
    String earlierToday = '',
    String earlierNotes = '',
    Set<String> alreadyAsked = const {},
  }) async {
    final words = transcript.trim();
    // One short clause is not enough to know what would help.
    if (words.split(RegExp(r'\s+')).length < 6) return null;

    try {
      final reply = await _oneShot(
        system: followUpSystemPrompt,
        user: buildFollowUpPrompt(
          transcript: words,
          earlierToday: earlierToday,
          earlierNotes: earlierNotes,
        ),
      );
      return _cleanQuestion(reply, alreadyAsked);
    } catch (error) {
      debugPrint('Asking the AI for a follow-up failed: $error');
      return null;
    }
  }

  /// Turns a sentence into one line of JSON, or null when nothing usable came
  /// back. Never throws, for the same reason as [followUpQuestion].
  Future<String?> classifyCommand({
    required String transcript,
    required String context,
  }) async {
    try {
      final reply = await _oneShot(
        system: commandSystemPrompt,
        user: buildCommandPrompt(transcript: transcript, context: context),
      );
      return reply.isEmpty ? null : reply;
    } catch (error) {
      debugPrint('Classifying a voice command failed: $error');
      return null;
    }
  }

  /// How many of these transcript joins really broke a thought.
  ///
  /// Used to tune the pause length: only joins the model is confident about
  /// count, and anything unreadable counts as zero, because a suggestion made
  /// on a guess is worse than no suggestion. Never throws, like
  /// [followUpQuestion].
  Future<int> countBrokenJoins(List<String> joins) async {
    if (joins.isEmpty) return 0;
    try {
      final reply = await _oneShot(
        system: pauseJudgeSystemPrompt,
        user: buildPauseJudgePrompt(joins),
      );
      return _brokenFromReply(reply, joins.length);
    } catch (error) {
      debugPrint('Judging transcription joins failed: $error');
      return 0;
    }
  }

  /// Pulls the count out of `{"broken":[...]}`, tolerating a chatty reply.
  static int _brokenFromReply(String reply, int total) {
    final start = reply.indexOf('{');
    final end = reply.lastIndexOf('}');
    if (start == -1 || end <= start) return 0;
    try {
      final decoded = jsonDecode(reply.substring(start, end + 1));
      if (decoded is! Map) return 0;
      final raw = decoded['broken'];
      if (raw is! List) return 0;
      final seen = <int>{};
      for (final item in raw) {
        final number = item is int
            ? item
            : item is String
            ? int.tryParse(item.trim())
            : null;
        if (number != null && number >= 1 && number <= total) {
          seen.add(number);
        }
      }
      return seen.length;
    } catch (_) {
      return 0;
    }
  }

  /// Writes a short overview of one month of notes.
  ///
  /// Throws [AiException] when the model cannot be reached, so the caller can
  /// leave a cached overview in place rather than showing nothing.
  Future<String> monthlyInsight({
    required int year,
    required int month,
    required String notes,
    String? monthName,
  }) async {
    final reply = await _oneShot(
      system: monthlyInsightSystemPrompt,
      user: buildMonthlyInsightPrompt(
        year: year,
        month: month,
        notes: notes,
        monthName: monthName,
      ),
    );
    if (reply.isEmpty) {
      throw const AiException('The model sent back an empty overview.');
    }
    return reply;
  }

  /// One request, one reply. Shared by the small one-shot features so they all
  /// build the provider and read the stream the same way.
  Future<String> _oneShot({required String system, required String user}) async {
    final provider = _provider ?? await _buildProvider();
    final messages = [
      AiMessage(role: AiRole.system, text: system),
      AiMessage.user(user),
    ];

    final buffer = StringBuffer();
    await for (final chunk in provider.chat(messages)) {
      if (chunk.done) break;
      buffer.write(chunk.text);
    }
    return buffer.toString().trim();
  }

  /// Streams an answer to [task] over [notes].
  ///
  /// Each event is the turn so far, so the UI can simply render the latest one.
  Stream<AiTurn> run({
    required AiTask task,
    required List<DayNote> notes,
    String? question,
  }) async* {
    _cancelled = false;
    final provider = _provider ?? await _buildProvider();

    final messages = [
      AiMessage(role: AiRole.system, text: buildSystemPrompt()),
      AiMessage.user(
        buildTaskPrompt(
          task: task,
          notes: notesToPromptText(notes),
          question: question,
        ),
      ),
    ];

    var text = '';
    yield AiTurn.assistant('', pending: true);

    // Iterate the provider's stream directly. An intermediate controller
    // looked tidier but left the generator waiting for a close event that
    // could arrive after the subscription handle was dropped, so replies
    // never finished streaming. Cancelling the consumer of this stream also
    // cancels the provider request, because an async* generator closes its
    // `await for` when its own stream is cancelled.
    await for (final chunk in provider.chat(messages)) {
      if (_cancelled) break;
      text += chunk.text;
      if (chunk.done || chunk.text.isEmpty) continue;
      // Blocks are parsed only once the reply is complete: a half-written DOT
      // block cannot be read yet.
      yield AiTurn.assistant(text, pending: true);
    }

    yield AiTurn.assistant(text, blocks: parseBlocks(text));
  }

  Future<void> dispose() async {
    cancel();
    await _provider?.dispose();
  }
}

/// Strips the wrappers a small model sometimes adds and rejects a repeat.
///
/// Returns null for the "nothing worth asking" answer, for anything too long to
/// be a single question, and for a question already asked this session.
String? _cleanQuestion(String reply, Set<String> alreadyAsked) {
  var text = reply.trim();
  if (text.isEmpty) return null;

  // The sentinel, possibly with punctuation or quotes around it.
  final normalized = text.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  if (normalized == 'nothing') return null;

  // Strip a leading "Question:" style label and wrapping quotes.
  text = text.replaceFirst(RegExp(r'^(question|q)\s*:\s*', caseSensitive: false), '');
  text = text.replaceAll(RegExp(r'^["“”\x27]+|["“”\x27]+$'), '').trim();

  // A question mark is what makes it a question; anything else is prose.
  if (!text.endsWith('?')) {
    // Models sometimes drop the mark. Keep a single short sentence that reads
    // like a question, and drop anything longer.
    if (text.length > 120 || text.contains('\n')) return null;
    text = '$text?';
  }
  if (text.split(RegExp(r'\s+')).length > 20) return null;

  // Only one question mark: a model that wrote two did not follow the rule.
  if ('?'.allMatches(text).length > 1) return null;

  if (alreadyAsked.any((asked) => asked.toLowerCase() == text.toLowerCase())) {
    return null;
  }
  return text;
}

/// Finds fenced `dot` and `chart` blocks in a reply and parses them.
///
/// A model that ignores the format simply produces no blocks, and the text is
/// shown as written, so this degrades gracefully.
List<RenderedBlock> parseBlocks(String reply) {
  final blocks = <RenderedBlock>[];
  // Any fence, whatever it says it is. Real models write ```dot, ```json,
  // ```graphviz, or even a bare fence with the language on the next line, so
  // the language is detected from the body instead of trusted from the fence.
  final pattern = RegExp(r'```[^\n]*\n([\s\S]*?)```');

  for (final match in pattern.allMatches(reply)) {
    final body = match.group(1)!.trim();
    if (body.isEmpty) continue;

    if (_looksLikeDot(body)) {
      blocks.add(RenderedBlock(kind: RenderedBlockKind.diagram, source: body));
      continue;
    }

    if (body.startsWith('{')) {
      final parsed = _parseChart(body);
      if (parsed != null) blocks.add(parsed);
    }
  }
  return blocks;
}

bool _looksLikeDot(String body) {
  final lower = body.toLowerCase();
  return lower.contains('digraph') || lower.contains('graph ');
}

/// Reads chart JSON, or returns null when the block is not chart data.
///
/// Two shapes are accepted: the documented `labels`/`values` pair, and the
/// equally natural "one list of labels, one list of numbers" shape that models
/// often emit instead (e.g. `{"dates": [...], "hours": [...]}`).
RenderedBlock? _parseChart(String body) {
  Map<String, dynamic> json;
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return null;
    json = decoded;
  } catch (_) {
    return null;
  }

  final typeName = (json['type']?.toString() ?? 'bar').toLowerCase();
  final type = switch (typeName) {
    'line' => ChartType.line,
    'pie' => ChartType.pie,
    _ => ChartType.bar,
  };
  final title = json['title']?.toString() ?? '';

  var rawLabels = json['labels'];
  var rawValues = json['values'];

  if (rawLabels is! List || rawValues is! List) {
    // Fall back to the first string list and the first number list.
    MapEntry<String, List<Object?>>? stringList;
    MapEntry<String, List<Object?>>? numberList;
    for (final entry in json.entries) {
      final value = entry.value;
      if (value is! List || value.isEmpty) continue;
      if (value.every((item) => item is num || num.tryParse('$item') != null)) {
        numberList ??= MapEntry(entry.key, value);
      } else if (value.every((item) => item is String)) {
        stringList ??= MapEntry(entry.key, value);
      }
    }
    if (stringList == null || numberList == null) return null;
    rawLabels = stringList.value;
    rawValues = numberList.value;
  }

  final labels = [for (final label in rawLabels) '$label'];
  final values = <double>[];
  for (final value in rawValues) {
    if (value is num) {
      values.add(value.toDouble());
    } else if (num.tryParse('$value') != null) {
      values.add(num.parse('$value').toDouble());
    } else {
      return RenderedBlock(
        kind: RenderedBlockKind.chart,
        source: body,
        error: 'That chart had a value that is not a number.',
      );
    }
  }

  if (labels.length != values.length || labels.isEmpty) {
    return RenderedBlock(
      kind: RenderedBlockKind.chart,
      source: body,
      error: 'That chart had a different number of labels and values.',
    );
  }

  return RenderedBlock(
    kind: RenderedBlockKind.chart,
    source: body,
    chart: ChartData(type: type, title: title, labels: labels, values: values),
  );
}
