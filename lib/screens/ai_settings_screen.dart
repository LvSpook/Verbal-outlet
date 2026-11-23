/// Settings for the AI features.
///
/// Two engines, one screen:
///
/// * **On this device** — finds or starts Ollama, then downloads a model with a
///   real progress bar. Everything stays on the machine.
/// * **Cloud** — an API key against an OpenAI-compatible provider, which is the
///   path for phones.
///
/// The screen is deliberately blunt about state: it says what is missing and
/// puts the fix next to it, rather than hiding failures behind a spinner.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';

import '../ai/ai_controller.dart';
import '../ai/ai_scope.dart';
import '../ai/ai_settings.dart';
import '../ai/ollama_launcher.dart';

/// A model worth offering, with a rough size so the download is not a surprise.
class _ModelOption {
  const _ModelOption(this.name, this.sizeLabel, this.note);

  final String name;
  final String sizeLabel;
  final String note;
}

const List<_ModelOption> _localModels = [
  _ModelOption(
    'qwen3:4b',
    '~2.5 GB',
    'Recommended. Quick on a laptop, good at following the diagram format.',
  ),
  _ModelOption(
    'llama3.2:3b',
    '~2.0 GB',
    'Smaller and faster, slightly simpler answers.',
  ),
  _ModelOption(
    'gemma3:4b',
    '~3.3 GB',
    'Warmer writing, a little slower to start.',
  ),
  _ModelOption(
    'qwen3:1.7b',
    '~1.4 GB',
    'Fastest. Fine for summaries, weaker at structure.',
  ),
];

/// An OpenAI-compatible provider preset.
class _CloudPreset {
  const _CloudPreset(this.label, this.baseUrl, this.model);

  final String label;
  final String baseUrl;
  final String model;
}

const List<_CloudPreset> _cloudPresets = [
  _CloudPreset('OpenAI', 'https://api.openai.com/v1', 'gpt-4o-mini'),
  _CloudPreset(
    'OpenRouter',
    'https://openrouter.ai/api/v1',
    'openai/gpt-4o-mini',
  ),
  _CloudPreset(
    'Groq',
    'https://api.groq.com/openai/v1',
    'llama-3.3-70b-versatile',
  ),
  _CloudPreset('Mistral', 'https://api.mistral.ai/v1', 'mistral-small-latest'),
  _CloudPreset('DeepSeek', 'https://api.deepseek.com/v1', 'deepseek-chat'),
];

class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key});

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  AiController? _ai;

  AiSettings _settings = const AiSettings();

  final _apiKeyController = TextEditingController();
  final _cloudModelController = TextEditingController();
  final _cloudBaseUrlController = TextEditingController();

  /// Installed models reported by Ollama, for the picker.
  List<String> _installed = const [];

  bool _loading = true;
  bool _busy = false;
  String? _status;
  bool _statusIsError = false;

  /// Non-null while a model download is running.
  double? _pullFraction;
  String? _pullStatus;

  /// Whether the API key field has been edited, so a typed key is not
  /// overwritten by a reload.
  bool _keyTouched = false;
  bool _showKey = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ai != null) return;
    _ai = AiScope.of(context);
    unawaited(_load());
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _cloudModelController.dispose();
    _cloudBaseUrlController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final ai = _ai!;
    // Show the screen immediately with whatever is already known, then fill in
    // saved choices. Nothing here blocks the first paint: reading secure
    // storage on a cold start can take a moment.
    setState(() => _loading = false);
    await ai.init();
    if (!mounted) return;

    _settings = ai.settings;
    _cloudModelController.text = _settings.cloudModel;
    _cloudBaseUrlController.text = _settings.cloudBaseUrl;
    setState(() {});
    unawaited(_refreshInstalled());
  }

  Future<void> _refreshInstalled() async {
    final models = await _ai!.local.installedModels();
    if (!mounted) return;
    setState(() => _installed = models);
  }

  bool get _isPhone => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  void _setStatus(String? message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _status = message;
      _statusIsError = error;
    });
  }

  /// Saves engine/model choices to the controller without touching the key.
  Future<void> _persist(AiSettings next) async {
    setState(() => _settings = next);
    await _ai!.applySettings(next);
  }

  Future<void> _chooseEngine(AiEngineKind engine) async {
    if (_settings.engine == engine) return;
    _setStatus(null);
    await _persist(_settings.copyWith(engine: engine));
    if (engine == AiEngineKind.local && !_isPhone) {
      await _refreshInstalled();
    }
  }

  /// Starts Ollama, or opens the installer if it is not present at all.
  Future<void> _setUpLocal() async {
    setState(() {
      _busy = true;
      _status = null;
    });

    if (!await isOllamaInstalled()) {
      setState(() => _busy = false);
      final opened = await openOllamaDownloadPage();
      _setStatus(
        opened
            ? 'Install Ollama from the page that just opened, then come back '
                  'and press "Start Ollama".'
            : 'Ollama is not installed. Download it from ollama.com/download.',
      );
      return;
    }

    final started = await startOllamaServer();
    if (!started) {
      setState(() => _busy = false);
      _setStatus(
        'Could not start Ollama. Try launching it yourself.',
        error: true,
      );
      return;
    }

    // Give the server a few seconds to bind the port.
    final up = await _waitForServer();
    if (!mounted) return;
    setState(() => _busy = false);
    if (!up) {
      _setStatus(
        'Ollama is starting but not answering yet. Give it a moment and check '
        'again.',
      );
      return;
    }
    await _refreshInstalled();
    _setStatus('Ollama is running.');
  }

  Future<bool> _waitForServer() async {
    for (var attempt = 0; attempt < 15; attempt++) {
      if (await _ai!.local.isAvailable()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    return false;
  }

  Future<void> _downloadModel(String name) async {
    setState(() {
      _busy = true;
      _pullFraction = null;
      _pullStatus = 'Starting…';
      _status = null;
    });

    try {
      await for (final progress in _ai!.local.pull(name)) {
        if (!mounted) return;
        setState(() {
          _pullStatus = progress.status;
          _pullFraction = progress.fraction;
        });
      }
      if (!mounted) return;
      await _persist(_settings.copyWith(localModel: name));
      await _refreshInstalled();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _pullFraction = null;
        _pullStatus = null;
      });
      _setStatus('$name is ready.');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _pullFraction = null;
        _pullStatus = null;
      });
      _setStatus('$error', error: true);
    }
  }

  Future<void> _saveCloud() async {
    setState(() => _busy = true);
    try {
      if (_keyTouched) {
        await _saveKey(_apiKeyController.text);
      }
      final next = _settings.copyWith(
        cloudBaseUrl: _cloudBaseUrlController.text.trim(),
        cloudModel: _cloudModelController.text.trim(),
        cloudName:
            _presetFor(_cloudBaseUrlController.text.trim())?.label ?? 'Cloud',
        hasApiKey: _keyTouched
            ? _apiKeyController.text.trim().isNotEmpty
            : _settings.hasApiKey,
      );
      await _persist(next);
      if (!mounted) return;
      _setStatus('Cloud settings saved.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveKey(String key) async {
    // The store hides the key; go through a fresh store so this screen never
    // holds it in field state.
    await AiSettingsStore().saveApiKey(key);
  }

  _CloudPreset? _presetFor(String baseUrl) {
    for (final preset in _cloudPresets) {
      if (preset.baseUrl == baseUrl) return preset;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 32),
              children: [
                _header(context),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else ...[
                  _engineSection(theme),
                  const SizedBox(height: 8),
                  if (_settings.engine == AiEngineKind.local)
                    _localSection(theme)
                  else
                    _cloudSection(theme),
                  if (_status != null) ...[
                    const SizedBox(height: 8),
                    _statusBanner(theme),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AI settings',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Choose where the thinking happens.',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _engineSection(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Engine',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<AiEngineKind>(
              segments: [
                ButtonSegment(
                  value: AiEngineKind.local,
                  label: const Text('On this device'),
                  icon: const Icon(Icons.memory, size: 18),
                  enabled: !_isPhone,
                ),
                const ButtonSegment(
                  value: AiEngineKind.cloud,
                  label: Text('API key'),
                  icon: Icon(Icons.cloud_outlined, size: 18),
                ),
              ],
              selected: {_settings.engine},
              onSelectionChanged: _busy
                  ? null
                  : (selection) => _chooseEngine(selection.first),
            ),
            const SizedBox(height: 10),
            Text(
              _isPhone
                  ? 'Phones use a cloud model with your own API key — a phone '
                        'cannot run a capable model locally.'
                  : 'On this device uses Ollama, a free local engine. Nothing '
                        'leaves your computer.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _localSection(ThemeData theme) {
    final scheme = theme.colorScheme;
    final selected = _settings.localModel;
    final installedHere = _isInstalled(selected);
    final ollamaRunning = _installed.isNotEmpty;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  'Local model',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                _statusDot(
                  running: ollamaRunning && installedHere,
                  label: ollamaRunning && installedHere
                      ? 'Ready'
                      : ollamaRunning
                      ? 'Model missing'
                      : 'Not running',
                  theme: theme,
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Step 1: the engine itself.
            _stepRow(
              theme,
              number: 1,
              title: 'Ollama',
              subtitle: ollamaRunning
                  ? 'Running on this computer.'
                  : 'Free, one-time install. Takes a minute.',
              action: ollamaRunning
                  ? TextButton.icon(
                      onPressed: _busy ? null : _refreshInstalled,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Refresh'),
                    )
                  : FilledButton.icon(
                      onPressed: _busy ? null : _setUpLocal,
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('Set up'),
                    ),
            ),

            const SizedBox(height: 6),
            Divider(color: scheme.outlineVariant),

            // Step 2: the model.
            _stepRow(
              theme,
              number: 2,
              title: 'Model',
              subtitle: installedHere
                  ? '$selected is downloaded.'
                  : 'Download once, then it works offline.',
            ),
            const SizedBox(height: 8),

            for (final option in _localModels)
              _modelTile(theme, option, selected: option.name == selected),

            const SizedBox(height: 6),
            if (_installed.isNotEmpty &&
                !_installed.every(
                  (model) => _localModels.any((option) => option.name == model),
                )) ...[
              Text(
                'Already on this computer',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final model in _installed)
                    ChoiceChip(
                      label: Text(model),
                      selected: model == selected,
                      onSelected: _busy
                          ? null
                          : (_) =>
                                _persist(_settings.copyWith(localModel: model)),
                    ),
                ],
              ),
              const SizedBox(height: 8),
            ],

            if (_pullStatus != null) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: _pullFraction),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _pullStatus!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (_pullFraction != null)
                    Text(
                      '${(_pullFraction! * 100).round()}%',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.primary,
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _modelTile(
    ThemeData theme,
    _ModelOption option, {
    required bool selected,
  }) {
    final scheme = theme.colorScheme;
    final installed = _isInstalled(option.name);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: _busy
            ? null
            : () {
                if (installed) {
                  _persist(_settings.copyWith(localModel: option.name));
                } else {
                  _downloadModel(option.name);
                }
              },
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 1.4 : 1,
            ),
            color: selected
                ? scheme.primaryContainer.withValues(alpha: 0.35)
                : null,
          ),
          child: Row(
            children: [
              Icon(
                installed
                    ? (selected ? Icons.check_circle : Icons.download_done)
                    : Icons.download_outlined,
                size: 18,
                color: installed ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          option.name,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          option.sizeLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      option.note,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (!installed)
                _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        'Download',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cloudSection(ThemeData theme) {
    final scheme = theme.colorScheme;
    final preset = _presetFor(_cloudBaseUrlController.text.trim());

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Cloud model',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Works on phones and anywhere without a local engine. Your notes '
              'are sent to the provider you choose.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),

            Text(
              'Provider',
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in _cloudPresets)
                  ChoiceChip(
                    label: Text(option.label),
                    selected: preset?.label == option.label,
                    onSelected: _busy
                        ? null
                        : (_) {
                            setState(() {
                              _cloudBaseUrlController.text = option.baseUrl;
                              _cloudModelController.text = option.model;
                            });
                          },
                  ),
              ],
            ),
            const SizedBox(height: 16),

            TextField(
              controller: _cloudBaseUrlController,
              decoration: const InputDecoration(
                labelText: 'Base URL',
                hintText: 'https://api.openai.com/v1',
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _cloudModelController,
              decoration: const InputDecoration(
                labelText: 'Model',
                hintText: 'gpt-4o-mini',
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _apiKeyController,
              obscureText: !_showKey,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'API key',
                hintText: _settings.hasApiKey
                    ? 'Saved — type to replace'
                    : 'Paste your key',
                isDense: true,
                suffixIcon: IconButton(
                  tooltip: _showKey ? 'Hide key' : 'Show key',
                  onPressed: () => setState(() => _showKey = !_showKey),
                  icon: Icon(
                    _showKey ? Icons.visibility_off : Icons.visibility,
                    size: 18,
                  ),
                ),
              ),
              onChanged: (_) => setState(() => _keyTouched = true),
            ),
            const SizedBox(height: 8),
            Text(
              'Stored in this device\'s secure keychain, not in a plain '
              'settings file.',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _saveCloud,
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  bool _isInstalled(String name) {
    final wanted = name.toLowerCase();
    for (final model in _installed) {
      final candidate = model.toLowerCase();
      if (candidate == wanted) return true;
      if ('$candidate:latest' == wanted || candidate == '$wanted:latest') {
        return true;
      }
    }
    return false;
  }

  Widget _statusBanner(ThemeData theme) {
    final scheme = theme.colorScheme;
    final colour = _statusIsError ? scheme.error : scheme.tertiary;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: colour.withValues(alpha: 0.12),
        border: Border.all(color: colour.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            _statusIsError ? Icons.error_outline : Icons.check_circle_outline,
            size: 18,
            color: colour,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _status!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurface,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusDot({
    required bool running,
    required String label,
    required ThemeData theme,
  }) {
    final scheme = theme.colorScheme;
    final colour = running ? scheme.tertiary : scheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: theme.textTheme.labelSmall?.copyWith(color: colour)),
      ],
    );
  }

  Widget _stepRow(
    ThemeData theme, {
    required int number,
    required String title,
    required String subtitle,
    Widget? action,
  }) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.primaryContainer,
            ),
            child: Text(
              '$number',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  subtitle,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}
