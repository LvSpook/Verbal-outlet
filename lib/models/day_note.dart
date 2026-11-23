import 'package:flutter/foundation.dart';

/// Where a section is in its journey through the AI.
///
/// Every entry is written by the AI rather than stored as typed. That means a
/// section can exist before its polished version does.
enum ComposeState {
  /// Has a polished body, or predates the AI writer. Safe to show.
  ready,

  /// Waiting for the AI. Held rather than shown, so a note never contains
  /// unprocessed text by accident.
  pending,

  /// The AI was tried and could not answer. Kept so nothing is lost, and can be
  /// retried.
  failed,
}

/// A single addition to a day's note.
///
/// Every time you add something, a new section is appended with its own
/// timestamp. Keeping them separate (rather than one merged blob) lets the UI
/// show when each thought arrived, and leaves room for per-section audio later.
///
/// Two texts live here. [text] is what the person actually said, kept forever
/// and folded away in the UI. [body] is what the AI made of it — a summary,
/// bullets, a diagram, whatever suits — and that is what the note shows.
@immutable
class NoteSection {
  const NoteSection({
    required this.id,
    required this.createdAt,
    required this.text,
    this.body = '',
    this.state = ComposeState.ready,
    this.instruction = '',
    this.composeError,
    this.duration,
    this.updatedAt,
    this.deleted = false,
  });

  final String id;

  /// When this section was added. This can be later than the note's day, if
  /// you added a thought to a past day's note.
  final DateTime createdAt;

  /// The words as they were written or said. Never replaced by the AI version.
  final String text;

  /// What the AI wrote from [text]: plain text with optional Markdown, charts
  /// and diagrams. Empty for sections written before the AI existed, in which
  /// case the note shows [text] instead.
  final String body;

  /// Whether [body] is ready to show.
  final ComposeState state;

  /// An optional request from the person, e.g. "make this a checklist". Sent to
  /// the AI along with the text.
  final String instruction;

  /// Why the last attempt failed, in plain language. Null when there is no
  /// problem.
  final String? composeError;

  /// Length of the recording this came from, once audio exists.
  final Duration? duration;

  /// When the text last changed. Null for sections created before syncing
  /// existed, in which case [modifiedAt] falls back to [createdAt].
  final DateTime? updatedAt;

  /// A tombstone. Deleted sections are kept, briefly, so that the deletion can
  /// travel to another device. They are hidden from the UI.
  final bool deleted;

  /// The time to compare when merging two copies of the same section: the
  /// newest edit wins, and a delete counts as an edit.
  DateTime get modifiedAt => updatedAt ?? createdAt;

  /// What the note shows. Falls back to the original words for older sections
  /// that never went through the AI.
  String get content => body.trim().isEmpty ? text : body;

  /// Whether this section has something worth displaying.
  bool get isReady => state == ComposeState.ready && !deleted;

  /// Whether this section is still waiting for the AI.
  bool get isPending =>
      state == ComposeState.pending || state == ComposeState.failed;

  /// Everything a search should look at: both the original words and the
  /// polished version.
  String get searchableText =>
      body.trim().isEmpty ? text : '$text\n$body';

  /// The AI result, ready to store.
  NoteSection withBody(String body, {DateTime? at}) => NoteSection(
    id: id,
    createdAt: createdAt,
    text: text,
    body: body,
    state: ComposeState.ready,
    instruction: instruction,
    duration: duration,
    updatedAt: at ?? DateTime.now(),
    deleted: deleted,
  );

  /// Marked as failed, keeping the reason so the UI can explain itself.
  NoteSection withFailure(String message, {DateTime? at}) => NoteSection(
    id: id,
    createdAt: createdAt,
    text: text,
    body: body,
    state: ComposeState.failed,
    instruction: instruction,
    composeError: message,
    duration: duration,
    updatedAt: at ?? DateTime.now(),
    deleted: deleted,
  );

  NoteSection copyWith({
    String? text,
    String? body,
    ComposeState? state,
    String? instruction,
    String? composeError,
    DateTime? updatedAt,
    bool? deleted,
    Duration? duration,
  }) {
    return NoteSection(
      id: id,
      createdAt: createdAt,
      text: text ?? this.text,
      body: body ?? this.body,
      state: state ?? this.state,
      instruction: instruction ?? this.instruction,
      composeError: composeError ?? this.composeError,
      duration: duration ?? this.duration,
      updatedAt: updatedAt ?? this.updatedAt,
      deleted: deleted ?? this.deleted,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'text': text,
    'durationMs': duration?.inMilliseconds,
    'updatedAt': modifiedAt.millisecondsSinceEpoch,
    'deleted': deleted,
    'body': body,
    'state': state.name,
    if (instruction.isNotEmpty) 'instruction': instruction,
    if (composeError != null) 'composeError': composeError,
  };

  static NoteSection fromJson(Map<String, dynamic> json) {
    final created = DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt'] as num).toInt(),
    );
    final durationMs = json['durationMs'];
    return NoteSection(
      id: json['id'] as String,
      createdAt: created,
      text: json['text'] as String? ?? '',
      body: json['body'] as String? ?? '',
      state: NoteSection.stateFromName(json['state']),
      instruction: json['instruction'] as String? ?? '',
      composeError: json['composeError'] as String?,
      duration: durationMs == null
          ? null
          : Duration(milliseconds: (durationMs as num).toInt()),
      updatedAt: json['updatedAt'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (json['updatedAt'] as num).toInt(),
            ),
      deleted: json['deleted'] as bool? ?? false,
    );
  }

  /// Unknown or missing states mean "ready": that is what every section was
  /// before the AI writer existed, and showing the original words is the safe
  /// way to be wrong.
  static ComposeState stateFromName(Object? raw) {
    for (final candidate in ComposeState.values) {
      if (candidate.name == raw) return candidate;
    }
    return ComposeState.ready;
  }
}

/// The one note belonging to a single calendar day.
///
/// A day has at most one note. Adding to it appends a [NoteSection] rather than
/// creating another note.
@immutable
class DayNote {
  const DayNote({required this.day, required this.sections});

  /// The day this note belongs to, with the time stripped.
  final DateTime day;

  /// Oldest first. May include tombstones for sync; use [visible] for display.
  final List<NoteSection> sections;

  /// Only the sections a person should see: deleted ones are filtered out, and
  /// sections still waiting for the AI are held back rather than shown as raw
  /// text.
  List<NoteSection> get visible => [
    for (final section in sections)
      if (section.isReady) section,
  ];

  /// Sections that exist but are not displayable yet: waiting for the AI, or
  /// failed. Shown as a quiet notice rather than as note content.
  List<NoteSection> get held => [
    for (final section in sections)
      if (!section.deleted && section.isPending) section,
  ];

  bool get isEmpty => visible.isEmpty;
  bool get isNotEmpty => visible.isNotEmpty;

  int get sectionCount => visible.length;

  /// The whole note as readable text, using what the AI wrote.
  String get body => visible.map((section) => section.content).join('\n\n');

  /// When the note was last added to, or null if it is empty.
  DateTime? get updatedAt => visible.isEmpty ? null : visible.last.createdAt;

  /// Short single-line preview for compact surfaces.
  String get preview {
    if (isEmpty) return 'Empty';
    final text = body.replaceAll('\n', ' ').trim();
    return text.length <= 120 ? text : '${text.substring(0, 120)}…';
  }

  DayNote copyWith({List<NoteSection>? sections}) =>
      DayNote(day: day, sections: sections ?? this.sections);
}
