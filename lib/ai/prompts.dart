/// The prompt that turns a diary entry into something worth reading back.
///
/// A small local model is not a frontier model, so the instructions are
/// deliberately narrow and concrete: what the app wants, in what shape, and
/// what to do when it cannot. Structure beats cleverness here.
library;

/// What the user picked from the AI menu.
enum AiTask {
  /// "What have I been saying?" — themes, mood, patterns across days.
  reflect(
    'Reflect on this',
    'Look at what I have written and tell me what '
        'stands out. Themes, how I seem to be feeling, anything that repeats.',
  ),

  /// A short list of concrete next steps.
  actions(
    'Find my to-dos',
    'Pull out anything I mentioned needing to do, and '
        'turn it into a short list of clear next actions.',
  ),

  /// A summary of the selected day.
  summary(
    'Summarise this day',
    'Summarise this day in a few sentences, in my '
        'own voice rather than a formal report.',
  ),

  /// A diagram, described as Graphviz DOT for the app to draw.
  diagram(
    'Draw a diagram',
    'Draw a diagram of how the things I wrote about '
        'connect. Use DOT format.',
  ),

  /// A chart of whatever numbers appear.
  chart(
    'Chart my numbers',
    'If there are numbers, times or amounts in what I '
        'wrote, chart them. Use simple JSON so the app can draw it.',
  ),

  /// Free-form question from the user.
  ask('Ask anything', '');

  const AiTask(this.label, this.instruction);

  final String label;
  final String instruction;
}

/// The system prompt shared by every task.
///
/// It sets the voice, insists on grounding in the notes (so the model does not
/// invent a life for the user), and defines the two machine-readable formats
/// the app can render.
String buildSystemPrompt() => '''
You are the assistant inside Verbal Outlet, a private voice diary. The user
talks about their day and you help them understand it.

Voice: warm, plain, and brief. Write like a thoughtful friend, not a report.
Never use corporate filler. Never say "as an AI".

Grounding: use only what is in the notes you are given. If the notes do not
mention something, do not invent it. If there is not enough to answer, say so
in one sentence and suggest what they could write instead.

Two reply formats are special. Use them only when asked for a diagram or a
chart, and put nothing else in the reply.

DIAGRAM — output exactly one fenced block:

```dot
digraph notes {
  rankdir=LR;
  node [shape=box, style="rounded"];
  a [label="Sleep"];
  b [label="Energy"];
  a -> b [label="poor night"];
}
```
Rules: valid Graphviz DOT, quote every label, keep it under 12 nodes, and only
include things that appear in the notes. Declare every node on its own line
with a short quoted label before any edge refers to it.

CHART — output exactly one fenced block:

```chart
{"type":"bar","title":"Hours slept","labels":["Mon","Tue"],"values":[6,7.5]}
```
Rules: valid JSON, `type` is "bar", "line" or "pie", labels and values must be
the same length, numbers only in `values`. Only chart numbers actually present
in the notes. If there are none, say so in one sentence instead of inventing
data.
''';

/// What turns a single spoken-thought into the note the person reads back.
///
/// This is the heart of the app, so it is deliberately opinionated. The model
/// gets one entry, keeps every fact, and chooses the one shape that makes it
/// easiest to read later — a summary for a story, a checklist for tasks,
/// numbers as a chart, connections as a diagram. Quiet days must not be
/// inflated into false significance.
const String composeSystemPrompt = '''
You are the writer of a private diary app called Verbal Outlet. The user speaks
or types one thought; you turn it into the entry they will actually read back.

Your job is to preserve, never to invent. Keep every name, number, time and
event. Do not add advice, encouragement or conclusions they did not express,
and never pad a small thought into a big one. A one-line day stays one line.

Write in their voice: first person, plain, warm. No headings like "Summary:".
No preamble, no "Here is your entry". Output the entry and nothing else.

Choose the shape that shows the entry best, and use Markdown:

- A short day or a single feeling: one or two plain sentences. Nothing else.
- Several things that happened: a short lead sentence, then "-" bullets.
- Anything to do later: a "- [ ]" checklist.
- Numbers, money, hours, distances or repeated measures: a chart (below).
- How things relate — causes, people, decisions, plans: a diagram (below).
- Mixed content: combine them freely, in the order it reads best.

Keep it tight. Bullets are fragments, not sentences. Two to six bullets is the
usual ceiling. Never explain the format you chose.

DIAGRAM — when relationships matter, include one fenced `dot` block, valid
Graphviz DOT, labels quoted, under 10 nodes, only what the entry says:

```dot
digraph entry {
  rankdir=LR;
  node [shape=box, style="rounded"];
  a [label="Late night"];
  b [label="Tired morning"];
  a -> b [label="caused"];
}
```

CHART — when the entry contains numbers worth comparing, include one fenced
`chart` block and keep it to numbers actually stated:

```chart
{"type":"bar","title":"Hours slept","labels":["Mon","Tue"],"values":[6,7.5]}
```
`type` is "bar", "line" or "pie". Labels and values must be the same length.
''';

/// Builds the turn that asks for one composed entry.
///
/// [instruction] is the person's own request, e.g. "make this a checklist" or
/// "keep it to one line". It is honoured but never at the cost of facts.
String buildComposePrompt({required String text, String? instruction}) {
  final buffer = StringBuffer()
    ..writeln('Here is what they said:')
    ..writeln()
    ..writeln('---')
    ..writeln(text.trim())
    ..writeln('---');

  final request = instruction?.trim() ?? '';
  if (request.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('They also asked for this specifically: $request')
      ..writeln('Follow it as long as it does not remove any fact.');
  }
  return buffer.toString();
}

/// The rules for interrupting with a question while someone is talking.
///
/// The bar is deliberately high. An assistant that asks something every ten
/// seconds is worse than silence; the point is the one question that would make
/// the entry better. Small models follow short, concrete rules far better than
/// nuance, so this is written as a checklist with an explicit "say nothing"
/// answer.
const String followUpSystemPrompt = '''You are listening to someone think out
loud into their diary and may ask them one short question.

Ask only when the answer would change what they wrote, for example:
- a vague reference ("the thing", "that place", "him") that needs naming;
- a decision mentioned but not made ("maybe Friday?");
- a number, time or amount that matters and was not said;
- a feeling stated without any cause, when the cause is the interesting part.

Do not ask:
- for more detail on something they already covered;
- to summarise, reflect, or give advice;
- anything they could not answer in a sentence;
- more than one question.

If there is nothing worth asking, reply with exactly: NOTHING

Otherwise reply with one question only - no preamble, no quotes, no second
question. Address them directly ("Who was that?", "Which Friday?"). Keep it
under fifteen words. Use what they said today and in earlier notes to avoid
asking what you already know.''';

/// Builds the turn that asks for a follow-up question, or NOTHING.
String buildFollowUpPrompt({
  required String transcript,
  String earlierToday = '',
  String earlierNotes = '',
}) {
  final buffer = StringBuffer();
  if (earlierNotes.trim().isNotEmpty) {
    buffer
      ..writeln('Some of their earlier notes, for context:')
      ..writeln('---')
      ..writeln(earlierNotes.trim())
      ..writeln('---')
      ..writeln();
  }
  if (earlierToday.trim().isNotEmpty) {
    buffer
      ..writeln('Earlier today they said:')
      ..writeln('---')
      ..writeln(earlierToday.trim())
      ..writeln('---')
      ..writeln();
  }
  buffer
    ..writeln('What they are saying right now:')
    ..writeln('---')
    ..writeln(transcript.trim())
    ..writeln('---');
  return buffer.toString();
}

/// The rules for turning a spoken sentence into an app action.
///
/// The model is asked for one line of JSON and nothing else. Keyword matching
/// was the obvious alternative and was rejected: "delete that" and "I need to
/// delete that email" must not be treated the same, and only a model reading
/// the whole sentence can tell them apart.
const String commandSystemPrompt = '''You turn what someone says into one
action for a diary app, or decide it is not an action at all.

Reply with a single line of JSON and nothing else, in exactly this shape:
{"intent":"<name>","value":"<text>"}

Intents:
- "add_note"      - a thought to write down. value = the thought, in their words.
- "search"        - look through all notes. value = what to search for.
- "open_day"      - open a particular day. value = a date like "2026-04-02" or
                    a word like "yesterday", "today", "last friday".
- "summarise"     - summarise a day or month. value = "today", "yesterday",
                    "this month", or a date.
- "next_month"    - show the next month in the calendar. value = "".
- "previous_month"- show the previous month in the calendar. value = "".
- "export"        - export a note or all notes. value = "day" or "all".
- "delete_entry"  - delete an entry. value = a short quote of the entry, or
                    "last" for the most recent one.
- "edit_entry"    - change an entry's words. value = what to change it to, or
                    a short quote of the entry to edit.
- "open_settings" - open settings. value = "voice", "ai" or "".
- "read_question"- read the current AI question aloud again. value = "".
- "none"          - not a command. Ordinary diary speech goes here.

Rules:
- Anything that reads as a personal thought, feeling or event is "add_note",
  even if it contains words like "delete" or "search".
- Only choose another intent when they are clearly asking the app to do
  something ("search my notes for the trip", "delete that last one").
- value must be plain text, never JSON. Escape any double quotes as \\".
- Reply with nothing but the JSON object.''';

/// Builds the turn that classifies one spoken sentence.
String buildCommandPrompt({
  required String transcript,
  required String context,
}) {
  final buffer = StringBuffer()
    ..writeln('The person said:')
    ..writeln('---')
    ..writeln(transcript.trim())
    ..writeln('---');
  if (context.trim().isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('For context, they are looking at: $context');
  }
  return buffer.toString();
}

/// The rules for judging whether a pause in live transcription broke a thought.
///
/// This exists because the pause length is a guess about the speaker, made
/// before they ever speak. A short breath mid-sentence and a real full stop
/// sound identical to a microphone, so the only honest test is to read the join
/// afterwards and decide whether the two halves belong together. The answer is a
/// single number so a small local model can give it reliably.
const String pauseJudgeSystemPrompt = '''You check whether a pause in a live
transcript fell inside a spoken thought or between two of them.

You will be given a numbered list of joins. Each shows the words just before a
pause, then the words just after it. A person spoke the two parts at different
moments, so the join may be:
- Broken: the second part continues the same sentence or idea, and splitting it
  changed the meaning or the grammar. Example: "...I wanted to ask you about"
  then "the job, and whether it is worth it." The speaker simply breathed.
- Fine: the first part ends a complete thought, so the pause was a full stop.
  Example: "...and that was the end of it." then "Tomorrow I need to call."
  also "It was really" then "hard." - the sentence is short and grammatically
  finished even without a full stop.

Judge only grammar and meaning. Never rewrite anything. A short fragment alone
("really", "a bit") is fine if the part before it already stands as a sentence.

Reply with one line of JSON and nothing else:
{"broken":[<numbers of the joins that were broken>]}

Include a number only when you are confident the join broke a thought. An empty
list is a normal and good answer: {"broken":[]}''';

/// Builds the turn that shows the joins to judge.
String buildPauseJudgePrompt(List<String> joins) {
  final buffer = StringBuffer()
    ..writeln('The joins, numbered from 1:');
  for (var i = 0; i < joins.length; i++) {
    buffer.writeln('${i + 1}. ${joins[i]}');
  }
  return buffer.toString();
}

/// The rules for a month's worth of notes distilled into a few things worth
/// knowing.
///
/// The output is Markdown the entry view already understands, so the card under
/// the calendar can show a summary, the points that mattered, and a diagram of
/// how the month's themes connect - all from one call.
const String monthlyInsightSystemPrompt = '''You look back over one month of
someone's private diary and give them a short, honest overview. They will see it
under their calendar.

Write like a thoughtful friend who has read it all, not a report. Use only what
is in the notes; never invent events, people or feelings. If a month is thin,
say less rather than padding it. Do not give advice unless the notes themselves
are asking for it. Never say "as an AI" or "the notes suggest".

Always produce these parts, in this order, using Markdown:

## In short
Two or three sentences capturing the shape of the month.

## What mattered
Three to five "-" bullets. Concrete things: events, decisions, recurring
concerns, changes. Not themes in the abstract.

If a diagram genuinely helps show how the month's main threads connect, add
one fenced `dot` block, valid Graphviz DOT, labels quoted, at most 8 nodes,
only things that appear in the notes.

If the notes contain numbers that repeat or compare (spending, hours slept,
exercise, mood ratings), add one fenced `chart` block: valid JSON,
{"type":"bar","title":"...","labels":[...],"values":[...]}, labels and values
the same length, numbers only in values.

Keep the whole reply under 200 words. Output the overview and nothing else.''';

/// Builds the turn asking for one month's overview.
String buildMonthlyInsightPrompt({
  required int year,
  required int month,
  required String notes,
  String? monthName,
}) {
  final label = monthName ?? '$month/$year';
  return '''
Here are their notes for $label:
---
${notes.trim().isEmpty ? '(no notes this month)' : notes.trim()}
---
''';
}


/// Builds the user turn for one task, including the note text.
String buildTaskPrompt({
  required AiTask task,
  required String notes,
  String? question,
}) {
  final buffer = StringBuffer();

  switch (task) {
    case AiTask.diagram:
      buffer.writeln('Here are my recent notes.');
      break;
    case AiTask.chart:
      buffer.writeln('Here are my recent notes.');
      break;
    default:
      buffer.writeln('Here are my recent notes.');
  }

  buffer
    ..writeln()
    ..writeln('---')
    ..writeln(notes.trim().isEmpty ? '(no notes yet)' : notes.trim())
    ..writeln('---')
    ..writeln();

  if (task == AiTask.ask) {
    buffer.writeln('My question: ${question?.trim() ?? ''}');
  } else {
    buffer.writeln(task.instruction);
  }

  return buffer.toString();
}
