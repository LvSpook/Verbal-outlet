# Verbal Outlet

A voice-first diary for Windows and Android, built with Flutter.

Talk instead of typing. Entries get transcribed, titled, and organised afterwards,
with AI features layered on top.

## Current state

The app opens straight into a month calendar.

**One note per day.** Each day has exactly one note, and adding to it appends a
new timestamped section rather than making another note. Selecting any date
opens that day's note immediately — there is no in-between list.

On a wide window the note opens **beside** the calendar: the calendar slides
left and narrows into a sidebar, and the note appears on the right. The
calendar stays usable, so switching days is a single click. Press Escape or the
close button to return to the empty pane. On a narrow window the note opens as
a full page instead, since there is no room for two panes.

- Month grid with previous/next navigation and a "jump to this month" button
- Tap the month heading to open a picker: step through years, pick any month,
  and jump straight to today or to your very first note. Months with notes
  show a small dot, and a year strip appears once you have notes in more than
  one year.
- Days with a note get a soft circle behind the number; the open day is filled
- Today gets a small underline under the number (and a ring if it has a note)
- **Your notes are saved.** They live in a SQLite database in the app's support
  folder and come back after a restart.
- **Sync between your own phone and computer** with no account: the computer
  shows a QR code, the phone scans it once, and the two keep in step over your
  Wi-Fi. See [Sync](#sync).
- In the note editor, type what happened and press **Write it up** (or
  Ctrl+Enter). The AI turns it into the entry; your exact words stay available
  under **Your words**. Tap any entry to edit it, and it is written up again. An
  optional instruction field steers the shape — "checklist", "one line",
  "chart it". See [How an entry is written](#how-an-entry-is-written).
- Notes are written by the AI, so the assistant is not just a panel: it is the
  thing that produces what you read back. If it is unavailable, entries are held
  rather than lost, and written as soon as it returns.
- **Search a day's note** with the magnifier in the note header (or Ctrl+F).
  It is not plain text matching: it also understands
  - other forms of a word — "walk" finds "walked" and "walking"
  - typos — "exausted" still finds "exhausted"
  - related wording — "tired" finds "knackered", "money" finds "rent"
  Results are ranked, with the closest hit first, the matching words
  highlighted, and a note explaining when related wording was used. Clicking a
  result opens that section in the editor.
- **Search every note**, not just the open day, with the magnifier in the
  calendar header or **Ctrl+K**. Results are ranked across all days, each one
  labelled with its date, and choosing one opens that day with the matched
  section ready to edit. See [How search is put together](#how-search-is-put-together).
- **Quick capture** from anywhere: Ctrl+Shift+Space on Windows, a long-press
  shortcut on Android, or the New thought button. All three open today's note
  with the cursor already in the composer. See [Quick capture](#quick-capture).
- **Export and import** in Settings: write any note or every note to Markdown or
  JSON, and read a JSON export back in. See [Export](#export).
- **Storage usage** in Settings: how much room the notes take, and a safe way to
  reclaim what deleted entries and the database leave behind. See
  [Storage](#storage).
- **Updates itself** from this repository's GitHub Releases: a quiet check at
  launch, and one button in Settings when a new version is ready. See
  [Updates](#updates).
- **Speak a thought** with the microphone pinned over the note: the transcript
  grows while you talk, stays editable, and becomes an AI-written entry like a
  typed one. Transcription runs on the device. See [Voice](#voice).
- **Talk to the app**: say "search my notes for the trip", "open yesterday", "next
  month", "delete the last one". Destructive actions wait for a spoken-style
  confirmation. See [Voice](#voice).
- **A month in review** under the calendar: a summary, the main threads and a
  diagram, written once per month and refreshed when the month's notes change.
  See [A month, looked back on](#a-month-looked-back-on).

Everything works without an account or a cloud service, apart from the AI model
itself, which can be local (Ollama) or a cloud key you supply — see [AI](#ai).

## AI

The AI is not a side panel bolted on: **it writes the notes.** Adding to a day
hands the words to the model, which turns them into the entry you read back —
summary, bullets, a checklist, a chart, a diagram, or a mix, whichever shows the
content best. You can also ask for a shape with the optional instruction field
("make this a checklist", "keep it to one line", "chart the costs").

Your original words are always kept. Under every entry is a small **Your words**
link that reveals exactly what you typed, so nothing the model rewrote is ever
lost — and edits go back through the model too.

The sparkle button in the note header still opens an assistant beside the note
(or in place of it on a narrow window). It can reflect on the day, pull out
to-dos, summarise, diagram, chart, or answer a typed question about what you
have written.

**Two engines, chosen in AI settings.**

| Engine | Where it runs | Notes |
|---|---|---|
| On this device | Ollama on your computer | Free, private, works offline. Nothing leaves the machine. |
| API key | Any OpenAI-compatible provider | The path for phones, which cannot run a capable model locally. |

Local uses [Ollama](https://ollama.com/download). If it is not installed, **Set
up** opens the official download page; once installed, the same button starts it
and the app waits for it to answer. Then pick a model and press Download — a real
progress bar, then it is ready. The default is `qwen3:4b`: 4B-class is the sweet
spot for a laptop, quick enough to feel instant and strong enough to follow the
diagram format. Smaller (`llama3.2:3b`, `qwen3:1.7b`) and larger (`gemma3:4b`)
options are listed, and any model already on the machine is offered too.

Cloud takes a base URL, model name, and API key, with presets for OpenAI,
OpenRouter, Groq, Mistral, and DeepSeek. The key is stored in the platform's
secure store (Keychain, Keystore, or the desktop equivalent), not in a
preferences file.

### How an entry is written

Adding never blocks on the model, and never loses anything:

1. Pressing **Write it up** stores the words immediately as *pending*. The note
   shows a quiet "waiting" line rather than raw text, so a half-written day
   never appears as if it were finished.
2. `ComposeQueue` (`lib/ai/compose_queue.dart`) checks the model once, then
   writes each waiting entry in turn and stores the result.
3. **If the AI is not there**, the entry keeps waiting and the composer says
   "AI offline — saved until it is back". It is not marked failed, and the next
   launch, new entry, or retry starts the pass again.
4. **If the model answers badly**, that one entry is marked failed with the
   reason and a **Try again** button. The rest of the pass carries on.
5. Editing an entry's words clears the stale AI version and writes it up again,
   so the entry always matches what you actually meant.

Holding rather than dropping is the key decision: the note is the AI's, but the
words are yours, and a diary that silently loses a thought because Ollama was
closed would be worse than useless.

The reply is rendered by `lib/widgets/ai/entry_view.dart`, a deliberately small
Markdown reader: paragraphs, headings, bullets, `- [ ]` checklists, quotes, and
the real diagram and chart widgets. Anything it does not recognise falls back to
readable text, so a model being clever cannot break the note.

### How diagrams and charts work

A small local model cannot draw pictures, but it can describe them, and the app
does the drawing. The prompt asks for a fenced block, either Graphviz DOT or a
small JSON chart, and `parseBlocks` lifts it out of the reply:

- **Diagrams** — `lib/widgets/ai/diagram_view.dart` parses the DOT subset the
  prompt asks for (nodes with quoted labels, labelled edges, `rankdir`) and lays
  it out in columns from the roots. No graph package.
- **Charts** — `lib/widgets/ai/chart_view.dart` paints bar, line, and pie from
  the numbers, matching the app palette.

Both degrade gracefully: an unreadable block is dropped rather than shown as
code, and plain prose is shown as written. The parser also accepts what models
actually emit — ```` ```dot ````, ```` ```json ````, a bare fence with the
language on the next line, and two parallel lists like
`{"dates":[…],"hours":[…]}` instead of `labels`/`values`.

| File | Does |
|---|---|
| `ai/ai_provider.dart` | The interface both engines implement |
| `ai/ollama_provider.dart` | Local engine: chat, model list, download with progress |
| `ai/cloud_provider.dart` | OpenAI-compatible streaming engine |
| `ai/ai_settings.dart` | Saved choices; API key in secure storage |
| `ai/ollama_launcher.dart` | Finds, starts, or installs Ollama on desktop |
| `ai/prompts.dart` | Task list, the entry-writing prompt, block formats |
| `ai/ai_controller.dart` | Provider selection, streaming, parsing blocks, composing |
| `ai/compose_queue.dart` | Holds entries, writes them up, retries failures |
| `ai/compose_scope.dart` | Makes the one queue available app-wide |
| `widgets/ai/` | The panel, the entry reader, chart and diagram painters |

Tests: `test/ai_test.dart` (parsing, settings, fence variants),
`test/ai_panel_test.dart` (streaming, charts, diagrams, typed questions with a
fake provider), `test/ai_integration_test.dart` (the header button, narrow vs
wide layout, settings screen), `test/compose_test.dart` (holding, composing,
offline handling, retries, the entry reader), `test/compose_ui_test.dart` (the
composer through to the note, the instruction field, folding away your words),
and `test/migration_test.dart` (an old database opening safely after the
upgrade).

### How search is put together

Search lives in `lib/search/` and runs entirely on your machine — nothing is
sent anywhere:

| File | Does |
|---|---|
| `search_text.dart` | Cuts text into words and folds them to a root form |
| `concepts.dart` | The synonym groups ("tired" ↔ "knackered", …) |
| `note_search.dart` | Scoring, ranking, excerpts, and the `NoteSearcher` interface |

The UI talks only to `NoteSearcher`. `LexicalSearcher` is the current on-device
implementation; a future embedding-based or cloud-backed ranker can implement
the same interface without touching the widgets.

The same engine searches **every note**, not just the open day: `searchAll`
scores sections from all days with identical rules, so one ranked list is
meaningful and the best answer anywhere comes first. Each hit carries its day,
which is what lets the result open the right note.

That is reachable three ways — the magnifier in the calendar header, **Ctrl+K**,
or the search action inside a note on a phone — and it is a dialog, so it closes
as soon as you pick something. On desktop the chosen day opens in the pane with
the matched section already in its editor; on a phone it opens as a full page.

The engine is covered by `test/search_test.dart`, which asserts the behaviour
above (word forms, typos, concepts, ranking, and that every highlight lands
exactly on the word it belongs to). `test/global_search_test.dart` covers
cross-day ranking, date labels, and the empty and no-match states;
`test/global_search_integration_test.dart` drives the real app from Ctrl+K to a
section from another day opening for editing. `test/search_layout_test.dart`
opens search at three window sizes to catch any layout overflow.

## Sync

Notes move **directly between your own devices**, over the Wi-Fi you are already
on. There is no account and no server: your computer listens, your phone talks
to it, and the two remember each other after a single pairing.

To set it up:

1. Open the gear in the calendar header on your computer. It shows a QR code.
2. On the phone, open the same screen and tap **Scan a code instead**.
3. Point the camera at the code. That is the whole setup — the code carries the
   address and a shared key.

After that, **Sync now** merges both ways. With **Sync automatically** on, the
app also catches up quietly at launch, whenever the other device is around.
Both devices listen, so either one can start a sync: you do not have to
remember which side to press.

**The one limitation:** both devices must be on the same Wi-Fi at the same time.
That is the trade for having no cloud. If one is on mobile data, nothing happens
until it is back on the network.

### How it decides what wins

- There is a real database now (`lib/data/note_repository.dart`), one row per
  section, so notes survive restarts.
- Each section carries a `modifiedAt`, and merging is **last write wins per
  section** — not per note. Since a note is a list of independent sections,
  writing one on the computer while editing another on the phone cannot lose
  either.
- A delete is not a disappearance but a **tombstone**: the section stays,
  flagged `deleted`, long enough to reach the other device so the delete is not
  undone by a stale copy. Tombstones older than 90 days are pruned.
- Section ids are random UUIDs, not timestamps, so two devices cannot accidentally
  create the same id at the same moment.
- Sync compares **cursors** — a time per device — rather than whole databases, so
  a run only moves sections that changed since the last one. Each direction
  remembers its own cursor, and re-sending a section is harmless because
  applying one only ever overwrites something older.

| File | Does |
|---|---|
| `sync/sync_models.dart` | Wire format, paired-device record, QR pairing code |
| `sync/sync_crypto.dart` | AES-256-GCM sealing of every message |
| `sync/sync_protocol.dart` | Diff-since-cursor, merge, and the sync outcome |
| `sync/lan_transport.dart` | The listening socket and the one-shot client |
| `sync/sync_controller.dart` | Identity, pairing, auto-sync, status messages |
| `sync/sync_settings.dart` | Device name and the list of paired devices |
| `screens/sync_screen.dart` | The QR code, scanner, device list, sync button |

Everything is encrypted in transit with a key generated at pairing; the key is
only ever shared inside the QR code, so it is worth treating a screenshot of
that code as private.

Tests: `test/sync_test.dart` covers the merge in both directions, a delete
travelling as a tombstone, idempotent repeat syncs, tampered frames, and a real
encrypted round trip over a socket. `test/lan_server_test.dart` runs two real
devices against each other, pairing included. `test/sync_screen_test.dart`
covers the screen's states.

## Export

Notes are yours, so getting them out is two taps, not a feature hunt.

- **One day:** the three-dot menu in the note header offers **Copy note**,
  **Export as Markdown**, and **Export as JSON**.
- **Everything:** Settings → **Export** writes every day that has a note to a
  single file.

Markdown is the default. It reads in any text editor, keeps each timestamp, and
quotes the text, so a day still feels like a diary:

```markdown
# Wednesday 4 March 2026

**09:12**

> A thought on the way to work.

**21:40**

> One more, before bed.
```

JSON keeps the exact structure the app uses — ids, timestamps, and tombstones —
so nothing is lost and it can be read back in.

Files go to your **Downloads** folder (falling back to Documents, then the
app's own folder) rather than opening a save dialog, and a snack bar shows the
name with a **Show folder** button. Exporting the same day twice replaces the
file instead of piling up copies.

### Importing

Settings → **Import from a JSON file** reads an export back in. It is a merge,
not a replace, and uses the same rule as sync: per section, the newer edit wins.
So an old export cannot overwrite newer writing, and importing the same file
twice changes nothing the second time.

The parser is deliberately forgiving. It accepts the all-notes export and a
single-day export, ISO or epoch timestamps, and sections with no `id` (assigning
a stable one so a repeat import does not duplicate them). A file that is not a
note export is refused with a sentence rather than half-imported.

| File | Does |
|---|---|
| `data/note_export.dart` | Markdown and JSON rendering, where files go, reveal |
| `data/note_import.dart` | Reading a file back, merging it, reporting what changed |
| `widgets/export_feedback.dart` | The "saved, here it is" snack bar |
| `widgets/import_feedback.dart` | The "1 entry added" snack bar |
| `widgets/note_editor_pane.dart` | The note's three-dot menu |

Tests: `test/export_test.dart` covers the rendered Markdown, the JSON shape,
empty-note refusals, and the files actually written; `test/import_test.dart`
covers merging, repeat imports, tombstones, odd timestamps, and a full
export-then-import round trip; `test/note_menu_test.dart` covers the menu,
clipboard, and disabled states.

## Storage

Settings → **Storage** shows what the notes are using, and offers one safe way
to shrink it. There are two numbers, and it is worth knowing why they differ:

- **On disk** is the size of the SQLite file — what a backup or a
  "disk full" message will quote.
- **Text** is the characters of your actual writing. This is the part that
  grows as you write.

Almost all of the difference is overhead that the app can reclaim. Deleted
entries are kept as *tombstones* for 90 days so the deletion can reach another
device that was offline; and SQLite marks pages free on delete but keeps the
file the same size until it is compacted.

**Clean up old deleted entries** does both: it drops tombstones older than 90
days and vacuums the file. Nothing you can see is ever deleted, and running it
again is harmless. The 90-day window is deliberately long — the only way a
cleanup can lose a deletion is if a device has been offline for more than three
months, and the app also prunes on startup for exactly the same reason.

| File | Does |
|---|---|
| `data/storage_tools.dart` | Measures usage, formats sizes, runs the cleanup |
| `data/note_repository.dart` | Exposes the file location, adds `compact()` |
| `data/note_store.dart` | `purgeTombstonesBefore`, `storageLocation` |

Tests: `test/storage_test.dart` covers size formatting, UTF-8 counts with
emoji, tombstone separation, cleanup removing only old entries, a repeat
cleanup, and the in-memory store reporting no file; `test/sync_screen_test.dart`
covers the Settings card and its cleanup button.

## Quick capture

Getting into the app should not cost more than the thought is worth, so there
are three ways in:

- **Windows:** press **Ctrl+Shift+Space** anywhere. The window comes forward,
  today's note opens, and the cursor is in the composer.
- **Android:** long-press the app icon and choose **New thought**.
- **Either:** the **New thought** button in the empty note pane, or the
  speech-bubble button in a note's header.

All three do the same thing: today's note, cursor ready, typable immediately. A
press that arrives before the window exists — the cold-start case on Android — is
held until the UI is ready rather than dropped.

The hotkey is registered quietly. If another app already owns the combination,
the feature is simply absent and nothing interrupts you; the button still works.

| File | Does |
|---|---|
| `capture/capture_request.dart` | The pending request and how it is consumed |
| `capture/capture_scope.dart` | Makes the one request available app-wide |
| `capture/quick_capture.dart` | The Windows hotkey and the Android shortcut tile |
| `screens/home_screen.dart` | Opens today and focuses the composer |

Tests: `test/capture_test.dart` covers the request, a pending capture arriving
at startup, a capture while a note is already open, the narrow-window page, and
typing straight into the focused composer.

# Voice

Speaking a thought is the primary way into a note. A microphone button floats
over the note — pinned above the list, so it stays reachable however far down you
scroll — with a smaller text button beside it for when typing is easier.

Pressing the microphone opens a small sheet: a big record button, a live level
meter while you speak, then the transcript. The transcript is editable before it
is sent, because a recogniser will always mishear a name or two. A per-entry
instruction can be added, exactly as with a typed thought. Sending it goes
through the same path as typing: the words are held, and the `ComposeQueue`
turns them into the note. Nothing raw is ever written, and an entry spoken while
the AI is down simply waits.

## Words appear while you talk

Transcription is chunked rather than streamed: whisper.cpp cannot emit words
incrementally, so the app keeps the raw 16 kHz PCM it captures and re-transcribes
the current sentence from its start as it goes.

What decides when a chunk goes off is now the voice, not a stopwatch:

- **A pause ends it.** After speech, a short silence closes the sentence and
  sends it. That is the moment you stop talking, so that is when your words
  appear — instead of up to four seconds later. The length is adjustable (below).
- **Long speech is still read as it goes.** If you keep talking without pausing,
  the open sentence is re-read about every 2.5 s of audio, and force-ended at
  15 s so no single transcription grows unbounded.
- **Silence is skipped.** A stretch with no speech above a low RMS threshold is
  never sent to Whisper at all, which is most of the CPU the old version spent.

The threshold is a cheap gate, not a classifier: a knock or a keyboard tap can
clear it and start a pass, and Whisper then returns nothing. That is a little
wasted work, never a wrong word. It is set low on purpose — the failure that
actually hurts is cutting somebody off mid-sentence.

Words are only ever added, never withdrawn. A pass that hears one word fewer
than the one before keeps the longer reading, so the last word does not blink out
and reappear. Sentences a pause has closed are committed; the one you are speaking
now is drawn in a softer ink and settles to full contrast when you stop. It reads
as typing, not as a paragraph refreshing.

Stopping the recording does one final pass over everything captured, so the text
you send is the complete transcript, not the last chunk.

## Talking to the app, not just into it

Everything the app can do can be asked for out loud. The transcript is sent to
the AI as one short question — "is this a note, or an instruction?" — which
answers with a single line of JSON:

```json
{"intent": "search", "value": "the trip"}
```

The classifier sees the note that is open, so "delete the last bit" means
something. Recognised commands open a day, change month, search all notes, open
settings, add an entry, and delete or rewrite one. Anything unreadable falls back
to a note, so a misheard sentence is never lost — it just needs editing.

Destructive commands stop and ask first. Delete and edit show a confirmation in
the same sheet and do nothing until it is confirmed; the runner refuses to act
without that flag, not just the UI.

**Settings → Voice** has three switches: voice commands on or off, whether the
AI may ask a follow-up while you talk, and whether that question is read aloud
(off by default).

## Tuning how long a pause is

How long a silence should count as a full stop depends on the person. Brisk
speech with short breaths gets chopped off at 0.7 s; someone thinking aloud
wants longer. So the length is a slider in **Settings → Voice**, from 0.35 s to
2 s in 50 ms steps, and it is saved.

Rather than leaving people to guess a millisecond value, the app keeps count of
where pauses actually cut the transcript. Only joins that look suspicious are
kept — no full stop before, no capital after — and only three of them, never the
whole transcript. When there are enough (12 boundaries), an **"Check whether
this suits my speech"** button appears beside the slider. It sends those few
joins to the AI with one yes-or-no question: did the pause break a thought? If
at least two did, the app offers a longer pause — the longest cut plus a little
headroom, rounded to a friendly step. Take it or say no; a no is remembered.

Nothing is judged in the background. The button is the only thing that sends
anything, and if the AI is unsure the answer is "no suggestion", which matters
more than a clever guess.

## Undo, and a note that waits on its own

Deleting an entry from its three-dot menu now says "Entry deleted." with an
**Undo** for six seconds. The deletion is only a tombstone, so undo clears it and
stamps the entry as newer — which also makes the restore win on another device.

Entries held for the AI used to be retried only at launch, when another entry
was added, or by pressing Try again. Now the queue also retries by itself: a
quiet attempt after 20 s, doubling to a two-minute ceiling while something is
waiting, and resetting on success. It stops as soon as there is nothing held, and
the timer is cancelled with the app. Returning to the window tries immediately,
since starting Ollama and coming back is the common case.

## A question, now and then

While you are talking, the AI may ask one short question about what it heard —
"who was that?" — if an answer would make the entry better. It is shown on the
recording sheet with a Skip button, and never blocks sending. It is rate-limited
(no more than one every nine seconds, one at a time), rejects anything that is
not a single short question, and never fails the recording if the model is
unreachable. Off entirely with the follow-up switch.

Speaking questions uses the platform's own voice — SAPI on Windows, the system
`TextToSpeech` on Android — through a small method channel rather than a plugin,
so there is no extra build-time toolchain and no downloaded voice. If the
channel is missing, the question is still on screen.

## A month, looked back on

Under the calendar, the app shows an overview of the visible month: a short
summary, the main threads, and any diagram or chart the model thinks fits, drawn
by the same renderer as an entry. It is written once per month and cached under
a fingerprint of that month's notes; editing the month marks it out of date and
rewrites it, and switching months is a cache read. A month with no notes shows
nothing at all. If the AI is unreachable, any previous overview stays on screen
and the card offers a retry.

## Speech never leaves the machine

Transcription is local. `record` captures 16 kHz mono WAV; `whisper_ggml_plus`
runs a bundled whisper.cpp model over it through FFI. No audio is uploaded — for
a diary, the most personal input should not need a cloud account.

The model is not bundled with the installer, so the app stays small for people
who never speak into it. **Settings → Voice** offers three English models, with
real download progress and a delete button:

| Model | Size | Why |
|---|---|---|
| `tiny.en` | ~75 MB | Fastest; mishears more, fine on a slow machine |
| `base.en` | ~140 MB | The default; a good balance on a laptop CPU |
| `small.en` | ~480 MB | Most accurate; several times slower without a GPU |

The download streams to a temporary `.part` file and is renamed only when
complete, so a cancelled or interrupted download is never mistaken for a usable
model. Once downloaded it works offline.

The audio file is deleted immediately after transcription: the words are what
matter, and keeping recordings is a privacy cost with no benefit.

Language follows the device locale rather than being forced to English, so an
entry is not silently translated.

## On Android

`RECORD_AUDIO` is declared in the manifest and requested by `record` on first
use. Transcription uses the same on-device Whisper engine, so no
`android.speech` service or Google account is involved.

| File | Does |
|---|---|
| `voice/voice_engine.dart` | The narrow `VoiceEngine` interface the sheet drives |
| `voice/whisper_voice_engine.dart` | Recording, the model download, Whisper itself |
| `voice/live_session.dart` | Live chunking: speech detection, pauses, committed text |
| `voice/audio_chunks.dart` | WAV header, levels, duration maths, transcript merge |
| `voice/voice_controller.dart` | Chosen model, readiness, download state, app-wide |
| `voice/pause_trace.dart` | Where pauses cut a sentence, and the suggested length |
| `voice/voice_settings.dart` | The behaviour switches and the pause length |
| `voice/voice_scope.dart` | Makes the one controller available |
| `voice/voice_command.dart` | The command types and tolerant JSON parsing |
| `voice/voice_command_runner.dart` | Running a command, and the confirmation gate |
| `voice/speech_service.dart` | Speaking a question through the platform |
| `voice/voice_settings.dart` | The three behaviour switches and their storage |
| `capture/app_request.dart` | "Open this day", "search", "change month", "settings" |
| `widgets/voice/add_thought_sheet.dart` | Record → live transcript → question → send |
| `widgets/note_editor_pane.dart` | The pinned microphone and text buttons |
| `widgets/ai/monthly_insight_card.dart` | The month's overview under the calendar |
| `ai/monthly_insight*.dart` | The overview model, cache and controller |

Tests: `test/voice_ui_test.dart` drives the whole flow with a fake engine — the
buttons staying put during scroll, a spoken entry becoming an AI-written one, a
corrected transcript, cancelling, a missing model offering setup, and an entry
held while the AI is offline. `test/voice_live_test.dart` covers the growing
transcript, a follow-up question, spoken confirmation, and the command paths;
`test/live_session_test.dart` covers the chunker itself — a pause closing a
sentence, silence never reaching Whisper, a shorter reading never removing a
word, and the cut it reports for tuning; `test/pause_trace_test.dart` covers the
evidence, its cap, and when a suggestion is made; `test/hardening_test.dart`
covers undo, the retry backoff, and the slider's suggestion;
`test/voice_command_test.dart` and `test/voice_command_runner_test.dart`
cover classification, spoken dates and the destructive-action gate;
`test/monthly_insight_test.dart` and `test/monthly_insight_card_test.dart` cover
the cache, staleness, failures and the card's states.

## Updates

The app updates itself from this repository's GitHub Releases, with no store and
no account.

**Where it looks:** `lib/update/update_config.dart` holds the repository —
currently `LvSpook/verbal-outlet`. If you fork this project, change
`updateRepoOwner` there to the account that owns your releases. A build pointed
at a repository that does not exist fails quietly, and checks behave as "could
not reach GitHub".

## Publishing a version

```powershell
# keep pubspec.yaml's `version:` in step with the tag
git tag v1.1.0
git push --tags
```

`.github/workflows/release.yml` then builds both platforms on GitHub's runners
and publishes a release with two files:

| File | For | The app does |
|---|---|---|
| `verbal-outlet-windows.zip` | Windows | Downloads, unpacks, replaces its own folder, restarts |
| `verbal-outlet-android.apk` | Android | Downloads, opens the system installer for one tap |

The workflow refuses to publish if the tag and `pubspec.yaml` disagree, because
the app compares against the tag: a mismatch would offer the same update forever.

## How the app knows

At launch it waits a few seconds, then asks the releases API once for the newest
version. Behind, it says nothing (being offline at startup is not the person's
problem). Newer, it puts a "New" badge on **Settings → Updates**, where the
release notes appear beside an **Update now** button. That card can also check
by hand, which is the only place a failure is explained.

Versions compare by number, so `v1.3.0` beats `1.2.0` and `1.2.0+7` equals
`1.2.0`. Anything unreadable is treated as "not newer", so a bad tag can never
nag anyone.

## What installing does

- **Windows**: the running exe cannot overwrite itself, so a short command
  script waits for the app to exit, copies the new folder over the old one, and
  starts the new build. Your notes live outside the install folder, so they are
  untouched.
- **Android**: the OS will not let an app replace itself silently. The APK is
  downloaded and the system installer opens; if installs from this app have not
  been allowed yet, Android shows that screen first, and the next attempt
  finishes. The manifest declares `REQUEST_INSTALL_PACKAGES` and a FileProvider
  so the installer can read the downloaded file.

Only the two release assets above are trusted, and only from the repository
named in `update_config.dart`: the address is compiled in, not a setting, so the
app cannot be pointed at someone else's builds.

# Branding

The logo is two filled seas in two blues — deep ocean behind, bright cyan in
front, with a pale glint along the front waterline — on a dark navy rounded
tile. Generated by code so it can be tweaked and regenerated exactly:

```
python tool/make_logo.py
```

That writes the master `assets/branding/icon_1024.png`, the background-free
`assets/branding/mark_transparent.png` for use inside the app, the multi-size
Windows `app_icon.ico`, and the Android launcher icons. Palette constants at the
top of the script match `lib/theme.dart`.

## Running it on Windows

There are two double-clickable files in the project folder.

### `Run Verbal Outlet.bat`

The one to use while building the app. Double-click it and it compiles and
launches in debug mode, with a console window attached.

Keep that console open. While the app runs:

| Key | Does |
|---|---|
| `r` | Hot reload — applies code edits without losing state |
| `R` | Hot restart — reloads from scratch |
| `q` | Quit |

Press `r` after saving a file to see the change almost instantly. If a change
doesn't show up, `R` is the fallback.

### `Build Windows App.bat`

Double-click to produce a fast release build, then it opens the folder
containing `verbal_outlet.exe`. That folder is self-contained, so you can copy
it anywhere, including to another PC. This is the version to show someone.

It takes a minute or two, and you only need to re-run it when you want a fresh
standalone copy.

### From a terminal

Flutter is on your `PATH`, so from this folder:

```powershell
flutter run -d windows
```

Checks:

```powershell
flutter analyze
flutter test
```

### If `flutter` is not recognised

The `.bat` files find Flutter themselves, so they work regardless. In a terminal,
open a new window first — the PATH change only applies to new sessions. If it
still fails, add this for the current session:

```powershell
$env:Path = "$env:LOCALAPPDATA\flutter_sdk\flutter\bin;$env:Path"
```

## Checks

```powershell
flutter analyze
flutter test
```

## Project layout

```
lib/
  main.dart                     app entry point, opens the database, starts sync
  theme.dart                    colour scheme and shared component styling
  models/day_note.dart          a day's note, sections, and compose state
  data/note_store.dart          synchronous cache in front of the repository
  data/note_repository.dart     SQLite storage and the in-memory test double
  data/note_export.dart         Markdown and JSON writing, reveal in a folder
  data/note_import.dart         reading an export back in, merging it
  data/storage_tools.dart       storage usage and safe clean-up
  capture/capture_request.dart  a pending "new thought", consumed by the UI
  capture/capture_scope.dart    makes the one request available app-wide
  capture/app_request.dart      "open a day", "search", "change month" requests
  capture/app_request_scope.dart  makes the one mailbox available app-wide
  capture/quick_capture.dart    Windows hotkey and Android shortcut tile
  utils/date_format.dart        date, time and duration formatting
  screens/home_screen.dart      split layout: calendar + note pane
  screens/note_page.dart        full-screen note, used on narrow windows
  screens/ai_settings_screen.dart  engine picker, Ollama setup, model download
  screens/sync_screen.dart      pairing, devices, voice, export and import
  widgets/calendar_view.dart    month calendar, compact-capable
  widgets/note_editor_pane.dart the editor for one day's note
  widgets/global_search_dialog.dart  search across every note
  widgets/highlighted_text.dart highlighting shared by both searches
  widgets/export_feedback.dart  "saved, here it is" snack bar
  widgets/import_feedback.dart  "1 entry added" snack bar
  widgets/month_picker.dart     the jump-to-any-month dialog
  widgets/ocean_background.dart subtle depth gradient behind every screen
  widgets/ai/ai_panel.dart      the assistant panel
  widgets/ai/entry_view.dart    reads the AI's entry back as a note
  widgets/ai/chart_view.dart    paints bar / line / pie charts
  widgets/ai/diagram_view.dart  parses DOT and draws the diagram
  widgets/ai/monthly_insight_card.dart  the month under the calendar
  widgets/update_card.dart      check for and install a new version
  update/                       release check, download, install, per platform
  voice/                        recording, transcription, commands, speech
  ai/                           providers, settings, prompts, controller
  sync/                         models, crypto, protocol, transport, controller
test/
  widget_test.dart              split layout, note editing and picker tests
  search_test.dart              search matching and ranking
  search_layout_test.dart       no overflow at several window sizes
  global_search_test.dart       cross-day ranking and the all-notes dialog
  global_search_integration_test.dart  Ctrl+K through to a section opening
  ai_test.dart                  block parsing, DOT, settings
  ai_panel_test.dart            streaming, charts, diagrams, questions
  ai_integration_test.dart      header button, layouts, settings screen
  note_repository_test.dart     storage round trip, tombstones, merging
  sync_test.dart                protocol, crypto and a socket round trip
  lan_server_test.dart          two real devices syncing both directions
  sync_screen_test.dart         the settings screen's states, export and import
  export_test.dart              Markdown and JSON output, files written
  import_test.dart              merging, repeats, round trip from an export
  note_menu_test.dart           the three-dot menu, copy, disabled states
  capture_test.dart             the request, startup capture, composer focus
  storage_test.dart             usage measurement and safe clean-up
  compose_test.dart             holding, composing, retries, the entry reader
  compose_ui_test.dart          composer through to the note, folded-away words
  migration_test.dart           an old database opening safely after the upgrade
  voice_ui_test.dart            the sheet, with a fake microphone
  voice_live_test.dart          live transcript, questions, commands, confirm
  live_session_test.dart        chunking: pauses, silence, words never withdrawn
  voice_command_test.dart       command parsing and the destructive rules
  voice_command_runner_test.dart  spoken dates, running commands, the gate
  audio_chunks_test.dart        WAV header, levels, duration, transcript merge
  monthly_insight_test.dart     overview caching, staleness, failures
  monthly_insight_card_test.dart  the card's states
  ai_one_shot_test.dart         follow-up questions and command classification
  updates_test.dart             version comparison, release parsing, unzipping
  update_controller_test.dart   checking, installing, the Android hand-off
  update_card_test.dart         the Settings card's states
```

## Platform focus

Development is Windows-first. Android is set up and builds, but it is
intentionally parked until the desktop app is feature-complete; porting and
performance tuning come after.

## Theme

The app uses a hand-tuned deep ocean palette defined in `lib/theme.dart`.
Colours are picked by hand rather than generated from a seed, because Material's
tonal generator washes very dark blues out towards grey.

- Near-black blue depths for surfaces (`_abyss` through `_shoal`)
- Cyan accent for actions (`_current`)
- Mint tertiary for secondary highlights (`_seagrass`)

A very subtle vertical gradient (`lib/widgets/ocean_background.dart`) sits behind
every screen so the dark areas read as water rather than flat black. The app
defaults to dark mode; a light theme exists only as a fallback.

## Android status

The Android toolchain is installed and working on this machine:

- Android SDK at `%LOCALAPPDATA%\Android\Sdk` (platform 36, build-tools 36.0.0)
- JDK 25 at `C:\Program Files\Java\jdk-25.0.2`, configured via
  `flutter config --jdk-dir`
- `flutter build apk --debug` has been verified

There is no Android emulator installed, so to run on a phone enable USB
debugging and plug it in, then use `flutter run -d android`.

## Next steps

1. Undo for a deleted section
2. AI over more than one day in the assistant chat, not just the month card
3. Streaming the notes into the assistant automatically as a day changes
4. Re-sync as soon as a device rejoins the network, without reopening the app
5. Encryption at rest for notes
6. A real-device pass over live transcription and the system voice

