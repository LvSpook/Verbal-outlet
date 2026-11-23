/// What a spoken sentence meant, as far as the app is concerned.
///
/// The AI classifier returns one line of JSON; this turns it into a value the
/// app can act on, tolerantly. A model that wraps the JSON in prose, uses a
/// different key, or writes `yes` instead of `true` should still work, because
/// the alternative - a command silently doing nothing - is much worse than a
/// slightly loose parser.
library;

import 'dart:convert';

/// One action the person asked for by voice.
sealed class VoiceCommand {
  const VoiceCommand();
}

/// Write the words down as a diary entry.
class AddNoteCommand extends VoiceCommand {
  const AddNoteCommand(this.text);
  final String text;
}

class SearchCommand extends VoiceCommand {
  const SearchCommand(this.query);
  final String query;
}

class OpenDayCommand extends VoiceCommand {
  const OpenDayCommand(this.date);
  final String date;
}

class SummariseCommand extends VoiceCommand {
  const SummariseCommand(this.date);
  final String date;
}

class ChangeMonthCommand extends VoiceCommand {
  const ChangeMonthCommand({required this.forward});
  final bool forward;
}

class ExportCommand extends VoiceCommand {
  const ExportCommand({required this.everything});
  final bool everything;
}

/// A destructive action: the UI must confirm it before it happens.
class DeleteEntryCommand extends VoiceCommand {
  const DeleteEntryCommand({required this.target});

  /// A short quote of the entry, or "last".
  final String target;
}

class EditEntryCommand extends VoiceCommand {
  const EditEntryCommand({required this.target, required this.instruction});
  final String target;
  final String instruction;
}

class OpenSettingsCommand extends VoiceCommand {
  const OpenSettingsCommand(this.section);
  final String section;
}

class ReadQuestionCommand extends VoiceCommand {
  const ReadQuestionCommand();
}

/// Not a command: ordinary diary speech.
class NoCommand extends VoiceCommand {
  const NoCommand();
}

/// Whether carrying this out cannot be undone.
bool isDestructive(VoiceCommand command) =>
    command is DeleteEntryCommand || command is EditEntryCommand;

/// The label shown on a confirmation button.
String confirmLabelFor(VoiceCommand command) => switch (command) {
  DeleteEntryCommand() => 'Delete it',
  EditEntryCommand() => 'Change it',
  _ => 'Do it',
};

/// Reads the classifier's reply into a [VoiceCommand].
///
/// [fallback] is what to do when the reply is missing or unreadable. The default
/// is to treat the words as a note, because losing a thought is worse than
/// missing a command.
VoiceCommand parseVoiceCommand(
  String? reply,
  String originalText, {
  VoiceCommand fallback = const AddNoteCommand(''),
}) {
  final text = originalText.trim();
  if (reply == null || reply.trim().isEmpty) {
    return _withFallback(fallback, text);
  }

  final json = _extractJson(reply);
  if (json == null) return _withFallback(fallback, text);

  final intent = _readString(json['intent'] ?? json['action'] ?? json['type'])
      ?.toLowerCase()
      .trim();
  final value =
      _readString(json['value'] ?? json['text'] ?? json['query'])?.trim() ?? '';

  switch (intent) {
    case 'add_note':
    case 'note':
      return AddNoteCommand(text.isEmpty ? value : text);
    case 'search':
      return value.isEmpty ? NoCommand() : SearchCommand(value);
    case 'open_day':
      return value.isEmpty ? NoCommand() : OpenDayCommand(value);
    case 'summarise':
    case 'summary':
      return SummariseCommand(value.isEmpty ? 'today' : value);
    case 'next_month':
      return const ChangeMonthCommand(forward: true);
    case 'previous_month':
    case 'prev_month':
      return const ChangeMonthCommand(forward: false);
    case 'export':
      return ExportCommand(everything: value.toLowerCase().contains('all'));
    case 'delete_entry':
    case 'delete':
      return DeleteEntryCommand(target: value.isEmpty ? 'last' : value);
    case 'edit_entry':
    case 'edit':
      return EditEntryCommand(
        target: value.isEmpty ? 'last' : value,
        instruction: text.isEmpty ? value : text,
      );
    case 'open_settings':
    case 'settings':
      return OpenSettingsCommand(value.toLowerCase());
    case 'read_question':
      return const ReadQuestionCommand();
    case 'none':
      return AddNoteCommand(text);
  }
  return _withFallback(fallback, text);
}

VoiceCommand _withFallback(VoiceCommand fallback, String text) {
  switch (fallback) {
    case AddNoteCommand():
      return AddNoteCommand(text);
    default:
      return fallback;
  }
}

/// Pulls the first JSON object out of a reply, tolerating code fences or
/// leading prose.
Map<String, dynamic>? _extractJson(String reply) {
  final start = reply.indexOf('{');
  if (start == -1) return null;
  // Scan for the matching close brace rather than the last one, so trailing
  // prose does not spoil the object.
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = start; i < reply.length; i++) {
    final char = reply[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (char == r'\') {
        escaped = true;
      } else if (char == '"') {
        inString = false;
      }
      continue;
    }
    if (char == '"') {
      inString = true;
    } else if (char == '{') {
      depth++;
    } else if (char == '}') {
      depth--;
      if (depth == 0) {
        final candidate = reply.substring(start, i + 1);
        try {
          final decoded = jsonDecode(candidate);
          if (decoded is Map<String, dynamic>) return decoded;
        } catch (_) {
          return null;
        }
      }
    }
  }
  return null;
}

String? _readString(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  return value.toString();
}

