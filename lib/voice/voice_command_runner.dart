/// Carrying out a spoken command.
///
/// The classifier says what was meant; this decides what that means for the
/// app's state and reports back in words the person can hear or read. It is
/// separated from the UI so the same actions work from the add-thought sheet,
/// the note pane, or a future hands-free mode.
///
/// Destructive commands ([isDestructive]) are never run here. The caller asks
/// for confirmation first and only then calls [run] again with
/// `confirmed: true`. That keeps the confirmation policy in one place and lets
/// a test prove that a delete cannot happen without it.
library;

import '../ai/compose_queue.dart';
import '../capture/app_request.dart';
import '../data/note_store.dart';
import '../models/day_note.dart';
import '../utils/date_format.dart';
import 'voice_command.dart';

/// What happened, in words worth showing.
class CommandOutcome {
  const CommandOutcome(
    this.message, {
    this.spoken = '',
    this.needsConfirmation = false,
    this.done = false,
  });

  /// Shown in the sheet or a snack bar.
  final String message;

  /// Read aloud if speech is on. Defaults to [message].
  final String spoken;

  /// True when the command must be confirmed before it runs.
  final bool needsConfirmation;

  /// True when the command actually changed something.
  final bool done;
}

/// Runs commands against the app's state.
class VoiceCommandRunner {
  VoiceCommandRunner({
    required this.store,
    required this.mailbox,
    this.composeQueue,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final NoteStore store;
  final AppRequestMailbox mailbox;

  /// Used to re-compose an edited entry, the same way the pane does. Null in a
  /// preview or a test, where editing still changes the words but the AI pass
  /// is skipped.
  final ComposeQueue? composeQueue;

  /// Read once at construction so a test can pin "today".
  final DateTime Function() _clock;

  /// Carries out [command].
  ///
  /// Returns an outcome describing what happened. When [confirmed] is false and
  /// the command is destructive, nothing is changed and the outcome asks for
  /// confirmation instead.
  Future<CommandOutcome> run(
    VoiceCommand command, {
    required DateTime day,
    bool confirmed = false,
  }) async {
    if (isDestructive(command) && !confirmed) {
      return _describeDestructive(command, day);
    }

    return switch (command) {
      AddNoteCommand(:final text) => _addNote(text, day),
      SearchCommand(:final query) => _search(query),
      OpenDayCommand(:final date) => _openDay(date),
      SummariseCommand(:final date) => _summarise(date, day),
      ChangeMonthCommand(:final forward) => _changeMonth(forward),
      ExportCommand(:final everything) => CommandOutcome(
        everything
            ? 'Export everything from Settings.'
            : 'Use the 3-dot menu on the note to export it.',
        spoken: 'You can export from the note menu, or all notes in Settings.',
      ),
      DeleteEntryCommand(:final target) => _delete(target, day),
      EditEntryCommand(:final target, :final instruction) => _edit(
        target,
        instruction,
        day,
      ),
      OpenSettingsCommand(:final section) => _openSettings(section),
      ReadQuestionCommand() => const CommandOutcome(
        'The question is on screen.',
        spoken: 'The question is on screen.',
      ),
      NoCommand() => const CommandOutcome('', done: false),
    };
  }

  /// The confirmation sentence for a destructive command.
  CommandOutcome _describeDestructive(VoiceCommand command, DateTime day) {
    final section = _findSection(day, switch (command) {
      DeleteEntryCommand(:final target) => target,
      EditEntryCommand(:final target) => target,
      _ => '',
    });

    final what = section == null
        ? 'the entry you mentioned'
        : 'the entry from ${formatClock(section.createdAt)} — '
              '"${_short(section.text)}"';

    return switch (command) {
      DeleteEntryCommand() => CommandOutcome(
        'Delete $what?',
        spoken: 'Delete $what? Say yes to confirm.',
        needsConfirmation: true,
      ),
      EditEntryCommand() => CommandOutcome(
        'Change $what?',
        spoken: 'Change $what? Say yes to confirm.',
        needsConfirmation: true,
      ),
      _ => const CommandOutcome('Are you sure?', needsConfirmation: true),
    };
  }

  CommandOutcome _addNote(String text, DateTime day) {
    final words = text.trim();
    if (words.isEmpty) {
      return const CommandOutcome('Nothing was said to write down.');
    }
    // The sheet normally does this itself; routing it here means a command
    // spoken in the middle of a longer thought still becomes an entry.
    if (composeQueue == null) {
      store.appendToDay(day, words);
    } else {
      store.holdForCompose(day, words);
      composeQueue!.kick();
    }
    return const CommandOutcome(
      'Added to your note.',
      spoken: 'Added to your note.',
      done: true,
    );
  }

  CommandOutcome _search(String query) {
    mailbox.search(query);
    return CommandOutcome(
      'Searching every note for "$query".',
      spoken: 'Searching your notes.',
      done: true,
    );
  }

  CommandOutcome _openDay(String when) {
    final target = parseSpokenDate(when, now: _clock());
    if (target == null) {
      return CommandOutcome(
        'I could not work out which day "$when" means.',
        spoken: 'I could not work out which day that is.',
      );
    }
    mailbox.openDay(dateOnly(target));
    return CommandOutcome(
      'Opening ${formatDayTitle(target)}.',
      spoken: 'Opening that day.',
      done: true,
    );
  }

  CommandOutcome _summarise(String when, DateTime day) {
    final target = parseSpokenDate(when, now: _clock());
    if (target == null) {
      return const CommandOutcome(
        'I could not work out what to summarise.',
        spoken: 'I could not work out what to summarise.',
      );
    }
    final note = store.noteFor(dateOnly(target));
    if (note == null || note.isEmpty) {
      return CommandOutcome(
        'There is nothing written for ${formatDayTitle(target)} yet.',
        spoken: 'There is nothing written for that day yet.',
      );
    }
    // Opening the day puts the assistant one tap away, which is where a
    // summary belongs. Reading the month itself is the calendar's insight card.
    mailbox.openDay(dateOnly(target));
    return CommandOutcome(
      '${formatDayTitle(target)} has ${note.sectionCount} '
      '${note.sectionCount == 1 ? 'entry' : 'entries'}. Opening it so you can '
      'ask for a summary.',
      spoken: 'Opening that day. Ask the assistant to summarise it.',
      done: true,
    );
  }

  CommandOutcome _changeMonth(bool forward) {
    mailbox.changeMonth(forward: forward);
    return CommandOutcome(
      forward ? 'Showing the next month.' : 'Showing the previous month.',
      spoken: forward ? 'Next month.' : 'Previous month.',
      done: true,
    );
  }

  CommandOutcome _delete(String target, DateTime day) {
    final section = _findSection(day, target);
    if (section == null) {
      return const CommandOutcome(
        'I could not find that entry to delete.',
        spoken: 'I could not find that entry.',
      );
    }
    store.removeSection(day, section.id);
    return const CommandOutcome(
      'Deleted.',
      spoken: 'Deleted.',
      done: true,
    );
  }

  CommandOutcome _edit(String target, String instruction, DateTime day) {
    final section = _findSection(day, target);
    if (section == null) {
      return const CommandOutcome(
        'I could not find that entry to change.',
        spoken: 'I could not find that entry.',
      );
    }

    // The new words are what the person said after the command ("... change it
    // to say I walked to the river"). If the classifier only returned the
    // target, there is nothing to write, so ask rather than blank the entry.
    final replacement = instruction.trim();
    if (replacement.isEmpty || replacement.toLowerCase() == target.toLowerCase()) {
      return const CommandOutcome(
        'Tell me what it should say instead.',
        spoken: 'What should it say instead?',
      );
    }

    store.updateSection(day, section.id, replacement);
    final updated = store.noteFor(day)?.sections
        .where((entry) => entry.id == section.id)
        .firstOrNull;
    if (composeQueue != null && updated != null && updated.isPending) {
      composeQueue!.compose(day, updated);
    }
    return const CommandOutcome(
      'Changed the entry.',
      spoken: 'Changed.',
      done: true,
    );
  }

  CommandOutcome _openSettings(String section) {
    mailbox.openSettings(section: section);
    return const CommandOutcome(
      'Opening settings.',
      spoken: 'Opening settings.',
      done: true,
    );
  }

  /// Finds the entry a command refers to: "last", or a quote from its words.
  NoteSection? _findSection(DateTime day, String target) {
    final note = store.noteFor(day);
    if (note == null || note.isEmpty) return null;
    final visible = note.visible;
    if (visible.isEmpty) return null;

    final wanted = target.trim().toLowerCase();
    if (wanted.isEmpty || wanted == 'last' || wanted == 'that' || wanted == 'it') {
      return visible.last;
    }

    // A quote: match on a distinctive run of words, ignoring case and
    // punctuation, so a paraphrase still lands on the right entry.
    final needle = _normalise(wanted);
    if (needle.isEmpty) return visible.last;

    NoteSection? best;
    var bestScore = 0;
    for (final section in visible) {
      final haystack = _normalise('${section.text} ${section.body}');
      final score = _overlap(needle, haystack);
      if (score > bestScore) {
        bestScore = score;
        best = section;
      }
    }
    // One shared word is too weak to act destructively on; fall back to "last"
    // only when nothing better was found and the request was vague.
    if (best == null || bestScore < 2) return visible.last;
    return best;
  }

  static String _normalise(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static int _overlap(String needle, String haystack) {
    final hayWords = haystack.split(' ').toSet();
    var matches = 0;
    for (final word in needle.split(' ')) {
      if (word.length < 3) continue;
      if (hayWords.contains(word)) matches++;
    }
    return matches;
  }

  static String _short(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 48 ? flat : '${flat.substring(0, 48)}…';
  }
}

/// Reads a spoken date into a real day.
///
/// Handles the words people actually use - "today", "yesterday", "last friday",
/// "the 3rd" - and ISO dates a model may have normalised to. Returns null when
/// nothing matches, so the caller can say so rather than guess.
DateTime? parseSpokenDate(String when, {DateTime? now}) {
  final today = dateOnly(now ?? DateTime.now());
  final text = when.trim().toLowerCase();
  if (text.isEmpty) return null;

  if (text == 'today' || text == 'this day') return today;
  if (text == 'yesterday') return today.subtract(const Duration(days: 1));
  if (text == 'the day before yesterday') {
    return today.subtract(const Duration(days: 2));
  }
  if (text == 'tomorrow') return today.add(const Duration(days: 1));

  // An ISO date, which is what the prompt asks the model to produce.
  final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(text);
  if (iso != null) {
    return DateTime(
      int.parse(iso.group(1)!),
      int.parse(iso.group(2)!),
      int.parse(iso.group(3)!),
    );
  }

  // "3 april", "april 3", "3rd april 2026".
  final monthNames = [
    'january',
    'february',
    'march',
    'april',
    'may',
    'june',
    'july',
    'august',
    'september',
    'october',
    'november',
    'december',
  ];
  for (var i = 0; i < monthNames.length; i++) {
    final month = monthNames[i];
    if (!text.contains(month)) continue;
    final dayMatch = RegExp(r'(\d{1,2})').firstMatch(text);
    final yearMatch = RegExp(r'(20\d{2})').firstMatch(text);
    if (dayMatch == null) {
      // Just a month: its first day, so "show me April" lands somewhere.
      return DateTime(int.tryParse(yearMatch?.group(1) ?? '${today.year}') ?? today.year, i + 1, 1);
    }
    final year = int.tryParse(yearMatch?.group(1) ?? '') ?? today.year;
    return DateTime(year, i + 1, int.parse(dayMatch.group(1)!));
  }

  // "last friday", "next monday", or just "friday".
  const weekdays = {
    'monday': 1,
    'tuesday': 2,
    'wednesday': 3,
    'thursday': 4,
    'friday': 5,
    'saturday': 6,
    'sunday': 7,
  };
  for (final entry in weekdays.entries) {
    if (!text.contains(entry.key)) continue;
    final back = text.contains('last') || !text.contains('next');
    final delta = (today.weekday - entry.value) % 7;
    if (back) {
      // The most recent one, never today when "last" was said.
      final days = delta == 0 ? 7 : delta;
      return today.subtract(Duration(days: days));
    }
    final ahead = (entry.value - today.weekday) % 7;
    return today.add(Duration(days: ahead == 0 ? 7 : ahead));
  }

  // A bare number: the day of this month, which is how people say "the 3rd".
  final bare = RegExp(
    r'^(?:the\s+)?(\d{1,2})(?:st|nd|rd|th)?$',
  ).firstMatch(text);
  if (bare != null) {
    final day = int.parse(bare.group(1)!);
    if (day >= 1 && day <= 31) {
      return DateTime(today.year, today.month, day);
    }
  }

  return null;
}


