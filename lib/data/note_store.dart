import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/day_note.dart';
import 'note_repository.dart';

export 'note_repository.dart' show dateOnly, dateOnlyKey;

/// In-memory home for every day's note.
///
/// There is at most one note per calendar day. Writing to a day either creates
/// its note or appends a new section to the existing one.
///
/// Reads stay synchronous: the UI asks for a day's note and gets it back
/// immediately. This class is a cache in front of a [NoteRepository], which is
/// written to in the background and read once at startup, so the app never
/// waits on a database read to paint.
class NoteStore extends ChangeNotifier {
  NoteStore._(this._repository, Iterable<DayNote> seed) {
    for (final note in seed) {
      _notes[dateOnly(note.day)] = note;
    }
  }

  /// The app-wide store.
  ///
  /// It starts with the sample notes in memory so the very first frame has
  /// something to show, including in widget tests which never open a database.
  /// [attachRepository] swaps in durable storage and replaces the samples with
  /// real data, or writes the samples through on a truly fresh install.
  static final NoteStore instance = NoteStore._(
    MemoryNoteRepository(),
    _seedNotes().values,
  );

  static const Uuid _uuid = Uuid();

  /// An empty store for tests, with no sample notes and no shared state.
  ///
  /// The app always uses [instance]; this exists so a test can start from a
  /// blank slate and control the repository.
  factory NoteStore.forTesting(NoteRepository repository) =>
      NoteStore._(repository, const []);

  /// Keyed by `dateOnly(day)`, which is a stable identity for a calendar day.
  final Map<DateTime, DayNote> _notes = {};

  NoteRepository _repository;

  /// Writes are chained so they reach the repository in the order they were
  /// made, without making every caller await them.
  Future<void> _pending = Future<void>.value();

  /// Whether [attachRepository] has run, i.e. real data has been loaded.
  bool _loaded = false;

  bool get isLoaded => _loaded;

  /// Points the store at [repository] and loads what it holds.
  ///
  /// If the repository is empty (a fresh install) the sample notes currently in
  /// memory are written to it, so the first launch still opens onto a populated
  /// calendar. Pass [seedSamples] as false to start genuinely empty, which is
  /// what tests and a future "erase everything" want.
  Future<void> attachRepository(
    NoteRepository repository, {
    bool seedSamples = true,
  }) async {
    // A new repository gets a new queue. Anything still pending belonged to the
    // old one, and waiting on it here would mean waiting on a future that was
    // created in a different context (a previous test's fake clock, say).
    _pending = Future<void>.value();
    _repository = repository;
    final stored = await repository.loadAll();
    // Captured before clearing: these are the sample notes a first launch
    // starts with, and the empty set a test store starts with.
    final inMemory = _notes.values.toList();
    _notes.clear();

    if (stored.isEmpty && seedSamples) {
      for (final note in inMemory) {
        for (final section in note.sections) {
          await repository.saveSection(note.day, section);
        }
        _notes[dateOnly(note.day)] = note;
      }
    } else {
      _notes.addEntries(
        stored.map((note) => MapEntry(dateOnly(note.day), note)),
      );
    }

    // Tombstones only need to live long enough for another device to hear about
    // the deletion. Old ones are wasted space.
    await repository.pruneDeletedBefore(
      DateTime.now().subtract(const Duration(days: 90)),
    );

    _loaded = true;
    notifyListeners();
  }

  /// Resolves once every queued write has reached the repository.
  Future<void> flush() => _pending;

  /// Where the notes are kept on disk, or null for the in-memory store.
  String? get storageLocation => _repository.location;

  /// Drops tombstones older than [cutoff] from memory and from storage.
  ///
  /// The repository prunes on its own at startup; this is the same operation
  /// on demand, for the storage section in Settings. Unlike a plain repository
  /// prune, it also forgets the sections in memory, so the measurement after a
  /// cleanup reflects it without a restart.
  Future<void> purgeTombstonesBefore(DateTime cutoff) async {
    var changed = false;
    for (final entry in _notes.entries.toList()) {
      final kept = entry.value.sections
          .where(
            (section) => !section.deleted || section.modifiedAt.isAfter(cutoff),
          )
          .toList();
      if (kept.length == entry.value.sections.length) continue;
      changed = true;
      if (kept.isEmpty) {
        _notes.remove(entry.key);
      } else {
        _notes[entry.key] = DayNote(day: entry.value.day, sections: kept);
      }
    }

    // Storage first, then compaction, so the freed pages have something to
    // reclaim. Both are queued so they cannot overtake writes still in flight.
    _pending = _pending.then((_) async {
      try {
        await _repository.pruneDeletedBefore(cutoff);
        await _repository.compact();
      } catch (error, stack) {
        debugPrint('Cleaning up the notes database failed: $error\n$stack');
      }
    });
    await _pending;

    if (changed) notifyListeners();
  }

  /// The note for [day], or null if nothing has been written yet.
  DayNote? noteFor(DateTime day) => _notes[dateOnly(day)];

  /// The note for [day], creating an empty one if it does not exist.
  ///
  /// Useful for opening the editor on a fresh day.
  DayNote noteOrEmpty(DateTime day) =>
      noteFor(day) ?? DayNote(day: dateOnly(day), sections: const []);

  bool hasNote(DateTime day) => _notes[dateOnly(day)]?.isNotEmpty ?? false;

  /// How many sections the day has. Zero when there is no note.
  int sectionCount(DateTime day) => _notes[dateOnly(day)]?.sectionCount ?? 0;

  /// Appends [text] to [day]'s note, creating the note if needed.
  ///
  /// Returns the updated note.
  DayNote appendToDay(DateTime day, String text) {
    final key = dateOnly(day);
    final trimmed = text.trim();
    if (trimmed.isEmpty) return noteOrEmpty(day);

    final now = DateTime.now();
    final section = NoteSection(
      // A random id rather than a timestamp: two devices adding a thought at
      // the same moment must not end up sharing an identity.
      id: _uuid.v4(),
      createdAt: now,
      text: trimmed,
      updatedAt: now,
    );

    final existing = _notes[key];
    final updated = existing == null
        ? DayNote(day: key, sections: [section])
        : existing.copyWith(sections: [...existing.sections, section]);

    _notes[key] = updated;
    _write(key, section);
    notifyListeners();
    return updated;
  }

  /// Adds an entry that has not been written yet.
  ///
  /// The person's words go in as-is, with no body and a [ComposeState.pending]
  /// state, so the note shows a quiet "waiting" line rather than the raw text.
  /// [ComposeQueue] fills the body in when the AI answers.
  DayNote holdForCompose(
    DateTime day,
    String text, {
    String instruction = '',
    String? id,
  }) {
    final key = dateOnly(day);
    final trimmed = text.trim();
    if (trimmed.isEmpty) return noteOrEmpty(day);

    final now = DateTime.now();
    final section = NoteSection(
      id: id ?? _uuid.v4(),
      createdAt: now,
      text: trimmed,
      state: ComposeState.pending,
      instruction: instruction.trim(),
      updatedAt: now,
    );

    final existing = _notes[key];
    final updated = existing == null
        ? DayNote(day: key, sections: [section])
        : existing.copyWith(sections: [...existing.sections, section]);

    _notes[key] = updated;
    _write(key, section);
    notifyListeners();
    return updated;
  }

  /// Replaces a section with a new version of itself.
  ///
  /// Used by [ComposeQueue] to attach the AI's body, or to mark a failure. The
  /// section is matched by id, so a stale write cannot land on the wrong entry.
  void replaceSection(DateTime day, NoteSection section) {
    final key = dateOnly(day);
    final note = _notes[key];
    if (note == null) return;

    final index = note.sections.indexWhere((entry) => entry.id == section.id);
    if (index == -1) return;

    final sections = [...note.sections];
    sections[index] = section;
    _notes[key] = note.copyWith(sections: sections);
    _write(key, section);
    notifyListeners();
  }

  /// Every section still waiting for the AI, oldest day first.
  List<(DateTime day, NoteSection section)> get pendingCompositions {
    final result = <(DateTime, NoteSection)>[];
    for (final note in allNotes) {
      for (final section in note.sections) {
        if (!section.deleted && section.isPending) {
          result.add((note.day, section));
        }
      }
    }
    return result;
  }

  /// Replaces the whole text of a section.
  void updateSection(DateTime day, String sectionId, String text) {
    final key = dateOnly(day);
    final note = _notes[key];
    if (note == null) return;

    final trimmed = text.trim();
    final index = note.sections.indexWhere((s) => s.id == sectionId);
    if (index == -1) return;

    // Emptying a section deletes it. The words are kept inside the tombstone so
    // an accidental empty edit can still be undone.
    if (trimmed.isEmpty) {
      removeSection(day, sectionId);
      return;
    }

    final updated = note.sections[index].copyWith(
      text: trimmed,
      // The AI version described the old words, so it is no longer true.
      // Clearing it puts the section back in the queue rather than
      // leaving a stale entry that ignores the edit.
      body: '',
      state: note.sections[index].body.trim().isEmpty
          ? note.sections[index].state
          : ComposeState.pending,
      updatedAt: DateTime.now(),
    );

    final sections = [...note.sections];
    sections[index] = updated;
    _notes[key] = note.copyWith(sections: sections);
    _write(key, updated);
    notifyListeners();
  }

  /// Removes one section, and the note itself if nothing is left.
  ///
  /// The section is kept as a tombstone so the deletion can reach another
  /// device, and the words stay inside it so [restoreSection] can bring the
  /// entry back exactly as it was. Nothing shows it: [DayNote.visible] filters
  /// deleted sections out.
  void removeSection(DateTime day, String sectionId) {
    final key = dateOnly(day);
    final note = _notes[key];
    if (note == null) return;

    final index = note.sections.indexWhere((s) => s.id == sectionId);
    if (index == -1) return;

    final tombstone = note.sections[index].copyWith(
      deleted: true,
      updatedAt: DateTime.now(),
    );

    final sections = [...note.sections];
    sections[index] = tombstone;
    _notes[key] = note.copyWith(sections: sections);
    _write(key, tombstone);
    notifyListeners();
  }

  /// Brings back a section that [removeSection] deleted.
  ///
  /// The deletion is only a tombstone, so undoing it is a matter of clearing
  /// the flag and giving it a new timestamp — which also makes the restore win
  /// against the tombstone on another device, the same way any edit does.
  ///
  /// Returns false when the section is gone for good (another device dropped it
  /// before this tombstone arrived), in which case there is nothing to restore.
  bool restoreSection(DateTime day, String sectionId) {
    final key = dateOnly(day);
    final note = _notes[key];
    if (note == null) return false;

    final index = note.sections.indexWhere((s) => s.id == sectionId);
    if (index == -1) return false;

    final previous = note.sections[index];
    final now = DateTime.now();
    // Strictly later than the tombstone, so a restore always wins the sync
    // comparison even when both happened within the same millisecond - which
    // they do when undo follows a delete as fast as a tap allows.
    final stamp = now.isAfter(previous.modifiedAt)
        ? now
        : previous.modifiedAt.add(const Duration(milliseconds: 1));

    final restored = previous.copyWith(deleted: false, updatedAt: stamp);

    final sections = [...note.sections];
    sections[index] = restored;
    _notes[key] = note.copyWith(sections: sections);
    _write(key, restored);
    notifyListeners();
    return true;
  }

  /// Takes a section from another device, keeping the newest version.
  ///
  /// Used by sync. A section arrives either new, as a newer edit, or as a
  /// tombstone; in every case the version with the later [NoteSection.modifiedAt]
  /// wins, which makes repeated syncs harmless. Returns whether it was applied.
  bool applyRemoteSection(DateTime day, NoteSection section) {
    final key = dateOnly(day);
    final existing = _notes[key];
    final sections = [...?existing?.sections];
    final index = sections.indexWhere((entry) => entry.id == section.id);

    if (index == -1) {
      sections.add(section);
    } else {
      if (!section.modifiedAt.isAfter(sections[index].modifiedAt)) return false;
      sections[index] = section;
    }

    sections.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    _notes[key] = DayNote(day: key, sections: sections);
    _write(key, section);
    notifyListeners();
    return true;
  }

  /// Days in the given month that have a non-empty note.
  Set<DateTime> daysWithNotesIn(int year, int month) {
    return _notes.values
        .where(
          (note) =>
              note.isNotEmpty &&
              note.day.year == year &&
              note.day.month == month,
        )
        .map((note) => note.day)
        .toSet();
  }

  /// How many notes fall in each month of [year], keyed 1-12.
  ///
  /// Months without notes are omitted, so callers can just use `isEmpty`.
  Map<int, int> noteCountsByMonth(int year) {
    final counts = <int, int>{};
    for (final note in _notes.values) {
      if (!note.isNotEmpty || note.day.year != year) continue;
      counts[note.day.month] = (counts[note.day.month] ?? 0) + 1;
    }
    return counts;
  }

  /// Years that contain at least one note, newest first.
  List<int> get yearsWithNotes {
    final years =
        _notes.values
            .where((note) => note.isNotEmpty)
            .map((note) => note.day.year)
            .toSet()
            .toList()
          ..sort((a, b) => b.compareTo(a));
    return years;
  }

  /// The earliest day with a note, if there is one.
  DateTime? get earliestNoteDay {
    final days = _notes.values
        .where((note) => note.isNotEmpty)
        .map((note) => note.day)
        .toList();
    if (days.isEmpty) return null;
    days.sort();
    return days.first;
  }

  /// Every note, oldest day first. Includes days whose sections are all
  /// tombstones; callers that display them use [DayNote.isNotEmpty].
  List<DayNote> get allNotes {
    final days = _notes.keys.toList()..sort();
    return [for (final day in days) _notes[day]!];
  }

  /// Every section the store holds, paired with its day, oldest day first.
  ///
  /// Includes tombstones: they have to reach the other device so a delete is
  /// not undone by a stale copy there.
  Iterable<(DateTime day, NoteSection section)> get allSections sync* {
    final days = _notes.keys.toList()..sort();
    for (final day in days) {
      for (final section in _notes[day]!.sections) {
        yield (day, section);
      }
    }
  }

  /// Queues one section for durable storage.
  void _write(DateTime day, NoteSection section) {
    _pending = _pending.then((_) async {
      try {
        await _repository.saveSection(day, section);
      } catch (error, stack) {
        // A failed write must not poison the queue for later writes, and the
        // user's text is still in memory, so log rather than surface an error.
        debugPrint('Saving a note section failed: $error\n$stack');
      }
    });
  }
}

bool isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Sample notes for a first launch, before anything has been written.
Map<DateTime, DayNote> _seedNotes() {
  final now = DateTime.now();
  final today = dateOnly(now);

  DayNote noteOn(
    DateTime day,
    List<(int hour, int minute, String text)> parts,
  ) {
    return DayNote(
      day: day,
      sections: [
        for (var i = 0; i < parts.length; i++)
          NoteSection(
            id: 'seed-${day.toIso8601String()}-$i',
            createdAt: day.add(
              Duration(hours: parts[i].$1, minutes: parts[i].$2),
            ),
            text: parts[i].$3,
          ),
      ],
    );
  }

  final notes = [
    noteOn(today, [
      (
        9,
        12,
        'The main thing I want is to be able to just talk without worrying '
            'about structuring anything. The app should figure out the '
            'structure afterwards.',
      ),
      (
        21,
        40,
        'Quiet day. Went for a walk after dinner and it helped clear my head.',
      ),
    ]),
    noteOn(today.subtract(const Duration(days: 1)), [
      (
        18,
        5,
        'Pretty tired today but I got through the list. Need to remember to '
            'book the thing on Friday.',
      ),
    ]),
    noteOn(today.subtract(const Duration(days: 3)), [
      (
        7,
        30,
        'Walk the long route along the river instead of the main road. Bring '
            'the camera this time.',
      ),
    ]),
    noteOn(today.subtract(const Duration(days: 6)), [
      (
        22,
        10,
        'Need to sort out the trip. Maybe leave Friday evening instead and stay '
            'the extra night.',
      ),
    ]),
  ];

  return {for (final note in notes) note.day: note};
}
