/// Remembers which voice model the app uses, and owns the one engine the UI
/// talks to.
///
/// The model is a user choice rather than a constant because the right size
/// depends on the machine: `base.en` is quick enough on a laptop CPU, while
/// `small.en` is worth the wait on a faster one. That choice is saved in
/// preferences so it survives a restart, and the engine is rebuilt when it
/// changes.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper_ggml_plus/whisper_ggml_plus.dart';

import '../ai/ai_controller.dart';
import 'pause_trace.dart';
import 'voice_engine.dart';
import 'voice_settings.dart';
import 'whisper_voice_engine.dart';

/// Reads and writes the voice preferences.
class VoiceSettingsStore {
  static const String _keyModel = 'voice.model';

  SharedPreferences? _preferences;

  Future<SharedPreferences> get _prefs async =>
      _preferences ??= await SharedPreferences.getInstance();

  /// The saved model name, or null when nothing has been chosen yet.
  Future<String?> readModelName() async {
    try {
      return (await _prefs).getString(_keyModel);
    } catch (_) {
      // Preferences are a nicety here: without them the app falls back to the
      // default model and still works.
      return null;
    }
  }

  Future<void> saveModelName(String name) async {
    try {
      await (await _prefs).setString(_keyModel, name);
    } catch (error) {
      debugPrint('Saving the voice model choice failed: $error');
    }
  }
}

/// Finds the model matching a saved name, falling back to the default.
WhisperModel modelForName(String? name) {
  for (final model in WhisperModel.values) {
    if (model.modelName == name) return model;
  }
  return defaultVoiceModel;
}

/// The app-wide voice state: chosen model, whether it is downloaded, and the
/// engine the add-thought sheet records with.
class VoiceController extends ChangeNotifier {
  VoiceController({
    WhisperModel model = defaultVoiceModel,
    VoiceEngine? engine,
    VoiceSettingsStore? settings,
    VoiceBehaviourStore? behaviour,
    PauseTraceStore? trace,
  }) : _engine = engine,
       // ignore: prefer_initializing_formals
       _model = model,
       _settings = settings ?? VoiceSettingsStore(),
       _behaviour = behaviour ?? VoiceBehaviourStore(),
       _traces = trace ?? PauseTraceStore(),
       // An injected engine is owned by whoever made it (a test), so a model
       // change must not dispose it out from under them.
       _ownsEngine = engine == null;

  final VoiceSettingsStore _settings;

  /// Where the behaviour switches are kept. Separate from the model choice in
  /// name only; both are plain preferences.
  final VoiceBehaviourStore _behaviour;

  /// Where the pause evidence is kept.
  final PauseTraceStore _traces;

  final bool _ownsEngine;

  VoiceEngine? _engine;
  WhisperModel _model;

  bool _ready = false;
  bool _checking = false;
  double? _progress;
  bool _downloading = false;
  bool _disposed = false;

  VoiceSettings _voiceSettings = const VoiceSettings();

  /// What live capture has shown about how long this person's pauses are.
  PauseTrace _pauseTrace = const PauseTrace();

  /// True while an AI is judging whether the recorded joins broke a thought.
  bool _analysingPauses = false;

  /// How talking should behave: voice commands, follow-up questions, and
  /// whether those questions are spoken. Defaults are used until [load] runs.
  VoiceSettings get voiceSettings => _voiceSettings;

  /// What the app has seen of this person's pauses, so far.
  PauseTrace get pauseTrace => _pauseTrace;

  /// A suggested pause length worth offering, or null when there is nothing to
  /// say.
  Duration? get pauseSuggestion =>
      _pauseTrace.dismissed ? null : _pauseTrace.suggested;

  /// True while a suggestion is being worked out, for a quiet spinner.
  bool get analysingPauses => _analysingPauses;

  /// The model in use. Changing it swaps the engine underneath.
  WhisperModel get model => _model;

  /// Whether the model file is on disk and recording can work.
  bool get ready => _ready;

  /// True while the readiness of a freshly chosen model is being checked.
  bool get checking => _checking;

  /// Download progress from 0 to 1, or null when not downloading.
  double? get progress => _progress;

  bool get downloading => _downloading;

  /// The engine the add-thought sheet records with.
  ///
  /// Created lazily so opening the app does not construct a recorder nobody
  /// asked for.
  VoiceEngine get engine => _engine ??= WhisperVoiceEngine(model: _model);

  /// The concrete engine, when this controller made one. Download and delete
  /// live there; a test's fake engine need not implement them.
  WhisperVoiceEngine? get _manager =>
      _engine is WhisperVoiceEngine ? _engine as WhisperVoiceEngine : null;

  /// Loads the saved choice, then checks whether its model is present.
  Future<void> load() async {
    final saved = await _settings.readModelName();
    if (saved != null) _model = modelForName(saved);
    _voiceSettings = await _behaviour.load();
    _pauseTrace = await _traces.load();
    if (!_disposed) notifyListeners();
    await refresh();
  }

  /// Changes one or more of the behaviour switches and saves them.
  Future<void> updateVoiceSettings(VoiceSettings settings) async {
    _voiceSettings = settings;
    if (!_disposed) notifyListeners();
    await _behaviour.save(settings);
  }

  /// Notes one place where a pause ended a sentence during live capture.
  ///
  /// Called for every cut, so this has to stay cheap: it only counts, and keeps
  /// the few joins worth judging later. Nothing is sent anywhere from here.
  Future<void> recordCut(ChunkCut cut) async {
    _pauseTrace = noteBoundary(
      _pauseTrace,
      PauseBoundary(
        pause: cut.pause,
        before: cut.before,
        after: cut.after,
      ),
    );
    if (!_disposed) notifyListeners();
    await _traces.save(_pauseTrace);
  }

  /// Asks the AI whether the recorded joins broke a thought, and turns its
  /// answer into a suggestion.
  ///
  /// Runs only when the app has seen enough cuts and there is something to
  /// judge, and only when the person asks for it (the button beside the
  /// slider), so a diary is never quietly sent to a model for tuning.
  Future<void> analysePauses(AiController ai) async {
    if (_analysingPauses) return;
    final trace = _pauseTrace;
    if (!trace.hasEnough || trace.evidence.isEmpty) return;

    _analysingPauses = true;
    if (!_disposed) notifyListeners();
    try {
      final joins = [
        for (final item in trace.evidence)
          '"${item.before}" then "${item.after}"',
      ];
      final broken = await ai.countBrokenJoins(joins);
      if (_disposed) return;
      final suggestion = suggestPause(trace, brokenJoins: broken);
      _pauseTrace = _pauseTrace.copyWith(
        suggested: suggestion,
        dismissed: false,
        clearSuggestion: suggestion == null,
      );
      await _traces.save(_pauseTrace);
    } finally {
      _analysingPauses = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Says no to the current suggestion for good.
  Future<void> dismissPauseSuggestion() async {
    _pauseTrace = _pauseTrace.copyWith(dismissed: true);
    if (!_disposed) notifyListeners();
    await _traces.save(_pauseTrace);
  }

  /// Takes the suggested pause length.
  Future<void> applyPauseSuggestion() async {
    final suggested = _pauseTrace.suggested;
    if (suggested == null) return;
    await updateVoiceSettings(
      _voiceSettings.copyWith(pauseAfterSpeech: suggested),
    );
    // The advice has been taken, so the evidence behind it has done its job.
    _pauseTrace = const PauseTrace(dismissed: true);
    if (!_disposed) notifyListeners();
    await _traces.save(_pauseTrace);
  }

  /// Re-checks whether the model file exists.
  Future<void> refresh() async {
    if (_checking) return;
    _checking = true;
    if (!_disposed) notifyListeners();
    try {
      final ready = await engine.isReady();
      if (_disposed) return;
      _ready = ready;
    } catch (error) {
      // A missing platform implementation is "not ready", not a crash.
      debugPrint('Checking the voice model failed: $error');
      if (_disposed) return;
      _ready = false;
    } finally {
      _checking = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Switches to [model], rebuilding the engine so it points at the new file.
  ///
  /// The old engine is disposed rather than left holding a recorder.
  Future<void> chooseModel(WhisperModel model) async {
    if (model == _model) return;
    _model = model;
    await _settings.saveModelName(model.modelName);

    final old = _engine;
    if (_ownsEngine && old != null) {
      _engine = null;
      await old.dispose();
    }
    _ready = false;
    if (!_disposed) notifyListeners();
    await refresh();
  }

  /// Downloads the current model, reporting real progress.
  ///
  /// Throws [VoiceException] with a readable reason when it cannot.
  Future<void> download() async {
    if (_downloading) return;
    final manager = _manager;
    if (manager == null) return;

    _downloading = true;
    _progress = 0;
    if (!_disposed) notifyListeners();
    try {
      await for (final value in manager.downloadModel()) {
        if (_disposed) return;
        _progress = value;
        notifyListeners();
      }
      _ready = true;
    } finally {
      _downloading = false;
      _progress = null;
      if (!_disposed) notifyListeners();
    }
  }

  /// Removes the downloaded model to free the space.
  Future<void> deleteModel() async {
    final manager = _manager;
    if (manager == null) return;
    await manager.deleteModel();
    _ready = false;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    final engine = _engine;
    _engine = null;
    if (_ownsEngine && engine != null) engine.dispose();
    super.dispose();
  }
}
