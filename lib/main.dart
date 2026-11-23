import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'ai/ai_controller.dart';
import 'ai/ai_scope.dart';
import 'ai/compose_queue.dart';
import 'ai/compose_scope.dart';
import 'ai/monthly_insight_controller.dart';
import 'ai/monthly_insight_scope.dart';
import 'capture/app_request.dart';
import 'capture/app_request_scope.dart';
import 'capture/capture_request.dart';
import 'capture/capture_scope.dart';
import 'capture/quick_capture.dart';
import 'data/note_repository.dart';
import 'data/note_store.dart';
import 'screens/home_screen.dart';
import 'sync/sync_controller.dart';
import 'sync/sync_scope.dart';
import 'theme.dart';
import 'update/update_config.dart';
import 'update/update_controller.dart';
import 'update/update_scope.dart';
import 'voice/voice_controller.dart';
import 'voice/voice_scope.dart';
import 'widgets/ocean_background.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _openNotes();

  // Sync starts before the first frame so a paired phone can reach this
  // computer without anyone opening the sync screen first; the code it needs
  // was shown once, when the two were paired.
  final sync = SyncController(noteStore: NoteStore.instance);
  unawaited(sync.init().then((_) => _autoSync(sync)));

  // The hotkey and the home-screen shortcut are the ways in; registering them
  // before the first frame means a press during startup is still recorded.
  final capture = CaptureRequest();
  unawaited(
    QuickCapture(onError: debugPrint).start(capture),
  );

  runApp(VerbalOutletApp(sync: sync, capture: capture));
}

/// Swaps the store's in-memory samples for the real database.
///
/// A failure here must not stop the app opening: without a repository the store
/// keeps working in memory, so notes are still usable, just not kept between
/// launches.
Future<void> _openNotes() async {
  try {
    final repository = await SqliteNoteRepository.open();
    await NoteStore.instance.attachRepository(repository);
  } catch (error, stack) {
    debugPrint('Opening the notes database failed: $error\n$stack');
  }
}

/// One quiet attempt to catch up with any paired device that is around.
///
/// Delayed a little so it does not compete with startup, and wrapped so a
/// failure never surfaces: the user did not ask for this sync.
Future<void> _autoSync(SyncController sync) async {
  if (!sync.autoSync || !sync.hasPeers) return;
  await Future<void>.delayed(const Duration(seconds: 3));
  await sync.syncAll();
}

class VerbalOutletApp extends StatefulWidget {
  const VerbalOutletApp({
    super.key,
    this.sync,
    this.capture,
    this.ai,
    this.compose,
    this.voice,
    this.request,
    this.insights,
    this.updates,
  });

  /// The app-wide sync controller. Null in widget tests, which do not want a
  /// listening socket, and on any build where sync is not set up.
  final SyncController? sync;

  /// Where quick-capture requests arrive. Null in widget tests.
  final CaptureRequest? capture;

  /// The AI controller. Null in production, which builds its own; supplied by
  /// tests that need a fake model rather than a real one on localhost.
  final AiController? ai;

  /// Overrides the compose queue. Rarely needed: passing [ai] is enough,
  /// because the queue is built around it.
  final ComposeQueue? compose;

  /// Overrides voice. Tests pass one with a fake engine, so no microphone or
  /// model is touched.
  final VoiceController? voice;

  /// Where voice commands post "show me this" requests. Built by default.
  final AppRequestMailbox? request;

  /// Overrides monthly insights. Tests pass one so no model call is made.
  final MonthlyInsightController? insights;

  /// Overrides update checking. Tests pass one so no network call is made.
  final UpdateController? updates;


  @override
  State<VerbalOutletApp> createState() => _VerbalOutletAppState();
}

class _VerbalOutletAppState extends State<VerbalOutletApp>
    with WidgetsBindingObserver {
  /// One controller for the whole app: one conversation, one provider.
  late final AiController _ai = widget.ai ?? (AiController()..init());

  /// Turns held entries into notes. It reads the same controller, so a model
  /// switch in settings applies to composing too.
  late final ComposeQueue _compose =
      widget.compose ?? ComposeQueue(store: NoteStore.instance, ai: _ai);

  /// The one voice controller. Reads its saved model choice, then checks
  /// readiness in the background so the microphone knows what to offer.
  late final VoiceController _voice = widget.voice ?? (VoiceController()..load());

  /// Where voice commands ask the app to show things.
  late final AppRequestMailbox _request =
      widget.request ?? AppRequestMailbox();

  /// Writes and caches the overview under the calendar.
  late final MonthlyInsightController _insights =
      widget.insights ??
      MonthlyInsightController(store: NoteStore.instance, ai: _ai);

  /// Knows whether a newer build has been published.
  late final UpdateController _updates =
      widget.updates ?? buildUpdateController();

  /// The one delayed launch check, so it can be cancelled if the app closes
  /// first (as every widget test does).
  Timer? _launchCheck;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Anything left waiting from last time - the app closed mid-pass, or the
    // AI was down - gets another go as soon as the app opens.
    WidgetsBinding.instance.addPostFrameCallback((_) => _compose.kick());

    // One quiet check per launch, delayed so it does not compete with startup
    // and never shown as an error: being offline is normal. Skipped when a
    // controller was injected, since its owner decides when to check.
    if (widget.updates == null) {
      _launchCheck = Timer(const Duration(seconds: 4), () {
        if (mounted) _updates.check();
      });
    }
  }

  /// Returning to the app is the best moment to try held entries again.
  ///
  /// Someone who has just started Ollama, or reconnected, comes back to the
  /// window expecting their note to fill in. Waiting for the slow background
  /// poll would make them press a button for no reason.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _compose.kick();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _launchCheck?.cancel();
    _compose.dispose();
    _ai.dispose();
    _insights.dispose();
    // Only dispose a controller this widget made; an injected one belongs to
    // whoever passed it in.
    if (widget.voice == null) _voice.dispose();
    if (widget.updates == null) _updates.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sync = widget.sync;
    final capture = widget.capture;
    Widget app = MaterialApp(
      title: 'Verbal Outlet',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      // The ocean palette is a dark theme, so default to it regardless of the
      // system setting. Light mode exists only as a fallback.
      themeMode: ThemeMode.dark,
      // Painted behind every route, so all screens share the same depth.
      builder: (context, child) =>
          OceanBackground(child: child ?? const SizedBox.shrink()),
      home: const HomeScreen(),
    );

    final scoped = AiScope(
      controller: _ai,
      child: sync == null ? app : SyncScope(controller: sync, child: app),
    );
    final composing = ComposeScope(queue: _compose, child: scoped);
    final voiced = VoiceScope(controller: _voice, child: composing);
    final insighted = MonthlyInsightScope(
      controller: _insights,
      child: voiced,
    );
    final requested = AppRequestScope(mailbox: _request, child: insighted);
    final updatable = UpdateScope(controller: _updates, child: requested);
    return capture == null
        ? updatable
        : CaptureScope(request: capture, child: updatable);
  }
}

