/// Settings for the app: keeping two devices in step, and getting notes out.
///
/// The shape of the screen follows what the user has to do, in order:
///
/// 1. **Pair** — show a code here, or scan one on the other screen. Once done,
///    it is done: the devices remember each other.
/// 2. **Sync** — a button for now, and a switch so it happens by itself while
///    both are on the same Wi-Fi.
/// 3. **Export** — write every note to a Markdown or JSON file you own.
///
/// The sync limitation is stated plainly rather than buried: it works when both
/// devices are on the same network at the same time. That is the price of
/// having no account and no server.
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:whisper_ggml_plus/whisper_ggml_plus.dart' show WhisperModel;

import '../ai/ai_scope.dart';
import '../data/note_export.dart';
import '../data/note_import.dart';
import '../data/note_store.dart';
import '../data/storage_tools.dart';
import '../sync/sync_controller.dart';
import '../sync/sync_models.dart';
import '../sync/sync_scope.dart';
import '../widgets/update_card.dart';
import '../voice/voice_controller.dart';
import '../voice/voice_engine.dart';
import '../voice/voice_scope.dart';
import '../voice/voice_settings.dart';
import '../widgets/export_feedback.dart';
import '../widgets/import_feedback.dart';
import 'ai_settings_screen.dart';

class SyncScreen extends StatefulWidget {
  const SyncScreen({
    super.key,
    this.controller,
    this.exporter,
    this.pickFile,
    this.importer,
    this.storage,
  });

  /// Lets tests (and previews) supply a controller. Production takes the
  /// app-wide one from [SyncScope], so there is only ever one listener.
  final SyncController? controller;

  /// Lets a test write exports to a temporary folder instead of Downloads.
  final NoteExporter? exporter;

  /// Lets a test choose the import file without opening a file dialog.
  final Future<XFile?> Function()? pickFile;

  /// Lets a test supply an importer that does not touch the disk.
  final NoteImporter? importer;

  /// Lets a test supply storage tools, or one that reports fixed numbers.
  final StorageTools? storage;

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  late final SyncController _sync =
      widget.controller ?? SyncScope.of(context);

  bool _ownController = false;
  bool _exporting = false;
  bool _importing = false;
  bool _measuring = true;
  bool _cleaning = false;
  late final NoteExporter _exporter = widget.exporter ?? NoteExporter();
  late final NoteImporter _importer = widget.importer ?? const NoteImporter();
  late final StorageTools _storage = widget.storage ?? const StorageTools();

  /// Latest storage numbers, or null while the first measurement is in flight.
  StorageReport? _report;

  /// Opens the platform's file dialog, filtered to JSON.
  late final Future<XFile?> Function() _picker =
      widget.pickFile ??
      () async {
        const typeGroup = XTypeGroup(label: 'JSON notes', extensions: ['json']);
        return openFile(
          acceptedTypeGroups: const [typeGroup],
          confirmButtonText: 'Import',
        );
      };

  @override
  void initState() {
    super.initState();
    _ownController = widget.controller == null;
    _sync.addListener(_onChanged);
    if (!_sync.loading) return;
    _sync.init();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Measurement touches the disk, so it waits until this screen is actually
    // built rather than running in initState where a test's fake clock could
    // hang on real I/O.
    if (_report == null && _measuring) _measureStorage();
  }

  /// Reads the current storage numbers.
  Future<void> _measureStorage() async {
    try {
      final report = await _storage.measure(NoteStore.instance);
      if (mounted) setState(() => _report = report);
    } catch (error) {
      // Usage is informational: if it cannot be read, say so and carry on.
      debugPrint('Measuring storage failed: $error');
      if (mounted) setState(() => _report = null);
    } finally {
      if (mounted) setState(() => _measuring = false);
    }
  }

  /// Removes tombstones old enough to be safe and compacts the file.
  Future<void> _cleanUpStorage() async {
    if (_cleaning) return;
    setState(() => _cleaning = true);
    try {
      final result = await _storage.cleanUp(NoteStore.instance);
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(result.summary)));
      }
      await _measureStorage();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text('Could not clean up storage: $error')),
          );
      }
    } finally {
      if (mounted) setState(() => _cleaning = false);
    }
  }

  @override
  void dispose() {
    _sync.removeListener(_onChanged);
    if (_ownController) _sync.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
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
                if (_sync.loading)
                  const Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else ...[
                  _pairSection(theme),
                  const SizedBox(height: 8),
                  _devicesSection(theme),
                  if (_sync.status != null) ...[
                    const SizedBox(height: 8),
                    _statusBanner(theme),
                  ],
                  const SizedBox(height: 8),
                  _exportSection(theme),
                  const SizedBox(height: 8),
                  _voiceSection(theme),
                  const SizedBox(height: 8),
                  const UpdateCard(),
                  const SizedBox(height: 8),
                  _storageSection(theme),
                  const SizedBox(height: 8),
                  _aiLink(context, theme),
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
                  'Settings',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Sync between your devices, and take your notes with you.',
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

  Widget _pairSection(ThemeData theme) {
    final scheme = theme.colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Pair a device',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Show this code on your computer and scan it once with your '
              'phone. After that the two remember each other — no account, '
              'nothing to install.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 18),
            if (_sync.address == null)
              _noAddress(theme)
            else
              _codeBlock(theme),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: _openScanner,
              icon: const Icon(Icons.qr_code_scanner, size: 18),
              label: const Text('Scan a code instead'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _noAddress(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(Icons.wifi_off, color: scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'No Wi-Fi address found. Connect this computer to the same '
              'network as your phone, then reopen this screen.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _codeBlock(ThemeData theme) {
    final scheme = theme.colorScheme;
    final code = _sync.pairingCode;

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
          ),
          child: code == null
              ? const SizedBox(
                  width: 220,
                  height: 220,
                  child: Center(child: CircularProgressIndicator()),
                )
              : QrImageView(
                  data: code.encode(),
                  size: 220,
                  backgroundColor: Colors.white,
                  // Medium correction: scannable from a phone at arm's length
                  // on a laptop screen without the code looking dense.
                  errorCorrectionLevel: QrErrorCorrectLevel.M,
                ),
        ),
        const SizedBox(height: 12),
        Text(
          '${_sync.deviceName} · ${_sync.address!.address}',
          textAlign: TextAlign.center,
          style: theme.textTheme.labelMedium?.copyWith(
            color: scheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (_sync.addresses.length > 1) ...[
          const SizedBox(height: 6),
          Text(
            'Wrong network? If scanning fails, try another address:',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            children: [
              for (var i = 0; i < _sync.addresses.length; i++)
                ChoiceChip(
                  label: Text(_sync.addresses[i].address),
                  selected:
                      _sync.addresses[i].address == _sync.address!.address,
                  onSelected: (_) => _sync.useAddress(i),
                ),
            ],
          ),
        ],
        const SizedBox(height: 10),
        if (_sync.serverState == ServerState.failed)
          Text(
            _sync.serverError ?? 'The sync listener could not start.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
          )
        else
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.sensors,
                size: 14,
                color: scheme.tertiary,
              ),
              const SizedBox(width: 6),
              Text(
                'Waiting for a scan',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _devicesSection(ThemeData theme) {
    final scheme = theme.colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Your devices',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            if (!_sync.hasPeers)
              Text(
                'Nothing paired yet. Once you scan the code above, the other '
                'device appears here.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.4,
                ),
              )
            else ...[
              for (final peer in _sync.peers) _peerTile(theme, peer),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _sync.autoSync,
                onChanged: _sync.syncing ? null : _sync.setAutoSync,
                title: Text(
                  'Sync automatically',
                  style: theme.textTheme.bodyMedium,
                ),
                subtitle: Text(
                  'Whenever a paired device is on the same Wi-Fi.',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              FilledButton.icon(
                onPressed: _sync.syncing || !_sync.hasPeers
                    ? null
                    : () => _sync.syncWith(_sync.peers.first),
                icon: _sync.syncing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync, size: 18),
                label: Text(_sync.syncing ? 'Syncing…' : 'Sync now'),
              ),
            ],
            const SizedBox(height: 12),
            _wifiNote(theme),
          ],
        ),
      ),
    );
  }

  Widget _peerTile(ThemeData theme, PeerRecord peer) {
    final scheme = theme.colorScheme;
    final last = peer.lastSyncAt;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        child: Icon(Icons.smartphone, color: scheme.onPrimaryContainer, size: 20),
      ),
      title: Text(peer.deviceName, style: theme.textTheme.bodyMedium),
      subtitle: Text(
        last == null ? 'Paired, not synced yet' : 'Last synced ${_formatWhen(last)}',
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      trailing: IconButton(
        tooltip: 'Forget this device',
        onPressed: _sync.syncing ? null : () => _sync.forget(peer),
        icon: const Icon(Icons.link_off, size: 18),
      ),
    );
  }

  Widget _wifiNote(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: scheme.secondary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Sync happens directly between the two devices, so both need to '
              'be on the same Wi-Fi at the same time. Notes are encrypted in '
              'transit and never go through a server.',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusBanner(ThemeData theme) {
    final scheme = theme.colorScheme;
    final isError = _sync.statusIsError;
    final color = isError ? scheme.error : scheme.tertiary;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: BoxDecoration(
        color: isError ? scheme.errorContainer : scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _sync.status!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: isError ? scheme.onErrorContainer : scheme.onTertiaryContainer,
                height: 1.4,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Dismiss',
            visualDensity: VisualDensity.compact,
            onPressed: _sync.dismissStatus,
            icon: Icon(
              Icons.close,
              size: 16,
              color: isError ? scheme.onErrorContainer : scheme.onTertiaryContainer,
            ),
          ),
        ],
      ),
    );
  }

  Widget _exportSection(ThemeData theme) {
    final scheme = theme.colorScheme;
    final count = NoteStore.instance.allNotes
        .where((note) => note.isNotEmpty)
        .length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Export',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  count == 1 ? '1 note' : '$count notes',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Write everything to a file you own. Markdown reads well in any '
              'editor; JSON keeps the exact structure.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _exporting || count == 0
                  ? null
                  : () => _exportAll(ExportFormat.markdown),
              icon: _exportButtonIcon(Icons.description_outlined),
              label: Text(_exporting ? 'Exporting…' : 'Export all as Markdown'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _exporting || count == 0
                  ? null
                  : () => _exportAll(ExportFormat.json),
              icon: _exportButtonIcon(Icons.data_object),
              label: const Text('Export all as JSON'),
            ),
            const Divider(height: 30),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Import',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Read a JSON export back in, for example after moving to a new '
              'computer. Importing the same file twice changes nothing.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: _importing ? null : _importFile,
              icon: _importing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.upload_file_outlined, size: 18),
              label: Text(_importing ? 'Importing…' : 'Import from a JSON file'),
            ),
          ],
        ),
      ),
    );
  }

  /// Voice: which local model transcribes speech, and whether it is installed.
  ///
  /// The download is offered here rather than bundled with the installer so the
  /// app stays small for people who never speak into it. Once downloaded, all
  /// transcription happens on this machine.
  Widget _voiceSection(ThemeData theme) {
    final scheme = theme.colorScheme;
    final voice = VoiceScope.maybeOf(context);
    final hintStyle = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
      height: 1.45,
    );

    if (voice == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Voice',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text('Voice is not set up in this build.', style: hintStyle),
            ],
          ),
        ),
      );
    }

    final model = voice.model;
    final downloading = voice.downloading;
    final progress = voice.progress;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Voice',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _statusDot(theme, running: voice.ready, label: voice.ready ? 'Ready' : 'Not set up'),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Speak a thought and it becomes a note. Speech is transcribed on '
              'this device — the audio never leaves it.',
              style: hintStyle,
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<WhisperModel>(
              initialValue: model,
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'Model',
              ),
              items: [
                for (final option in _voiceModelOptions)
                  DropdownMenuItem(
                    value: option.model,
                    child: Text(option.label),
                  ),
              ],
              onChanged: downloading
                  ? null
                  : (choice) {
                      if (choice != null) _chooseVoiceModel(voice, choice);
                    },
            ),
            const SizedBox(height: 6),
            Text(_voiceModelHint(model), style: hintStyle),
            const SizedBox(height: 14),
            if (downloading) ...[
              LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                borderRadius: BorderRadius.circular(99),
              ),
              const SizedBox(height: 8),
              Text(
                progress == null
                    ? 'Downloading…'
                    : 'Downloading… ${(progress * 100).round()}%',
                style: hintStyle,
              ),
            ] else if (!voice.ready) ...[
              FilledButton.icon(
                onPressed: () => _downloadVoiceModel(voice),
                icon: const Icon(Icons.download, size: 18),
                label: const Text('Download voice model'),
              ),
              const SizedBox(height: 6),
              Text(
                'One download, about ${_voiceModelSize(model)}. After that it '
                'works offline.',
                style: hintStyle,
              ),
                ] else ...[
              Row(
                children: [
                  Icon(Icons.check_circle_outline, size: 16, color: scheme.tertiary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'The ${model.modelName} model is downloaded.',
                      style: hintStyle,
                    ),
                  ),
                  TextButton(
                    onPressed: voice.checking
                        ? null
                        : () => _deleteVoiceModel(voice),
                    child: const Text('Delete'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 6),
            const Divider(height: 20),
            ..._voiceBehaviourSwitches(voice, hintStyle),
          ],
        ),
      ),
    );
  }

  /// How talking behaves, as opposed to whether it works at all.
  ///
  /// Three switches, each a real difference in feel: whether asking for things
  /// is allowed, whether the AI may interrupt with a question, and whether that
  /// question is also read out loud. Above them sits the one number that
  /// depends on how a person speaks.
  List<Widget> _voiceBehaviourSwitches(
    VoiceController voice,
    TextStyle? hintStyle,
  ) {
    final settings = voice.voiceSettings;

    return [
      _pauseSlider(voice, settings, hintStyle),
      const Divider(height: 20),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        value: settings.commandsEnabled,
        onChanged: (value) => voice.updateVoiceSettings(
          settings.copyWith(commandsEnabled: value),
        ),
        title: const Text('Voice commands'),
        subtitle: Text(
          'Say "search my notes" or "delete that one" to control the app.',
          style: hintStyle,
        ),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        value: settings.followUpsEnabled,
        onChanged: (value) => voice.updateVoiceSettings(
          settings.copyWith(followUpsEnabled: value),
        ),
        title: const Text('Ask a question mid-thought'),
        subtitle: Text(
          'The AI may ask one short question while you talk, if it would help.',
          style: hintStyle,
        ),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        value: settings.speakQuestions,
        onChanged: settings.followUpsEnabled
            ? (value) => voice.updateVoiceSettings(
                settings.copyWith(speakQuestions: value),
              )
            : null,
        title: const Text('Read questions out loud'),
        subtitle: Text(
          'Uses the system voice. Off unless you ask for it.',
          style: hintStyle,
        ),
      ),
    ];
  }

  /// How long a silence ends a sentence.
  ///
  /// The one number that decides whether live capture feels right, because it
  /// depends entirely on the speaker: brisk speech with short breaths gets cut
  /// at the default, while thinking aloud wants longer. The suggestion beside it
  /// comes from pauses that were actually cut mid-thought, judged by the AI, so
  /// it is evidence rather than a guess.
  Widget _pauseSlider(
    VoiceController voice,
    VoiceSettings settings,
    TextStyle? hintStyle,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ms = settings.pauseAfterSpeech.inMilliseconds;
    final min = VoiceSettings.minPauseAfterSpeech.inMilliseconds.toDouble();
    final max = VoiceSettings.maxPauseAfterSpeech.inMilliseconds.toDouble();
    final suggestion = voice.pauseSuggestion;
    final trace = voice.pauseTrace;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: Text('Pause before a sentence ends')),
            Text(
              '${(ms / 1000).toStringAsFixed(2)} s',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
          ],
        ),
        Text(
          'How much silence finishes a sentence while you speak. Shorter feels '
          'quicker; longer waits out a think.',
          style: hintStyle,
        ),
        Slider(
          value: ms.toDouble().clamp(min, max),
          min: min,
          max: max,
          divisions: ((max - min) / 50).round(),
          label: '${(ms / 1000).toStringAsFixed(2)} s',
          onChanged: (value) => voice.updateVoiceSettings(
            settings.copyWith(
              pauseAfterSpeech: clampPause(
                Duration(milliseconds: (value / 50).round() * 50),
              ),
            ),
          ),
        ),
        if (suggestion != null)
          Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Some of your sentences were split mid-thought at the '
                  'current ${(ms / 1000).toStringAsFixed(2)} s. '
                  'A pause of ${(suggestion.inMilliseconds / 1000).toStringAsFixed(2)} s '
                  'would have let them finish.',
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: voice.dismissPauseSuggestion,
                      child: const Text('No thanks'),
                    ),
                    TextButton(
                      onPressed: voice.applyPauseSuggestion,
                      child: const Text('Use it'),
                    ),
                  ],
                ),
              ],
            ),
          )
        else if (trace.hasEnough && !trace.dismissed)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: voice.analysingPauses
                  ? null
                  : () => _analysePauses(voice),
              icon: voice.analysingPauses
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome_outlined, size: 16),
              label: Text(
                voice.analysingPauses
                    ? 'Checking your pauses…'
                    : 'Check whether this suits my speech',
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _analysePauses(VoiceController voice) async {
    final ai = AiScope.maybeOf(context);
    if (ai == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Set up the AI first, in AI settings.')),
      );
      return;
    }
    await voice.analysePauses(ai);
    if (!mounted) return;
    if (voice.pauseSuggestion == null) {
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Your pause length looks right already.'),
          ),
        );
    }
  }

  static const List<({WhisperModel model, String label})> _voiceModelOptions = [
    (model: WhisperModel.baseEn, label: 'Base (English) — balanced'),
    (model: WhisperModel.tinyEn, label: 'Tiny (English) — fastest, less accurate'),
    (model: WhisperModel.smallEn, label: 'Small (English) — most accurate, slower'),
  ];

  String _voiceModelHint(WhisperModel model) => switch (model) {
    WhisperModel.tinyEn => 'Good for quick notes on a slow machine, but it '
        'mishears more words.',
    WhisperModel.smallEn => 'The best accuracy, at a few times the wait of '
        'Base without a fast GPU.',
    _ => 'A good balance for everyday speech on a laptop.',
  };

  String _voiceModelSize(WhisperModel model) => switch (model) {
    WhisperModel.tinyEn => '75 MB',
    WhisperModel.smallEn => '480 MB',
    _ => '140 MB',
  };

  Future<void> _chooseVoiceModel(VoiceController voice, WhisperModel model) async {
    await voice.chooseModel(model);
  }

  Future<void> _downloadVoiceModel(VoiceController voice) async {
    try {
      await voice.download();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Voice is ready. Tap the microphone to speak.')),
        );
    } on VoiceException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              error.hint == null ? error.message : '${error.message} ${error.hint}',
            ),
          ),
        );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('Could not download the voice model: $error')),
        );
    }
  }

  Future<void> _deleteVoiceModel(VoiceController voice) async {
    try {
      await voice.deleteModel();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('Could not delete the voice model: $error')),
        );
    }
  }

  Widget _statusDot(
    ThemeData theme, {
    required bool running,
    required String label,
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
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(color: colour),
        ),
      ],
    );
  }

  Widget _storageSection(ThemeData theme) {
    final scheme = theme.colorScheme;
    final report = _report;
    final hintStyle = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
      height: 1.45,
    );
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final valueStyle = theme.textTheme.bodySmall?.copyWith(
      fontWeight: FontWeight.w600,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Storage',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (report != null)
                  Text(report.fileSizeLabel, style: labelStyle),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Your notes live in one small file on this device. Nothing here '
              'is ever deleted for you.',
              style: hintStyle,
            ),
            const SizedBox(height: 14),
            if (_measuring && report == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 10),
                    Text('Measuring…'),
                  ],
                ),
              )
            else if (report == null)
              Text('Could not read storage usage right now.', style: hintStyle)
            else ...[
              _storageRow(labelStyle, valueStyle, 'On disk', report.fileSizeLabel),
              if (report.location != null) ...[
                const SizedBox(height: 4),
                Text(
                  report.location!,
                  style: labelStyle?.copyWith(height: 1.3),
                ),
              ],
              const SizedBox(height: 12),
              _storageRow(
                labelStyle,
                valueStyle,
                'Notes',
                report.days == 1
                    ? '1 day · ${report.sections} entries'
                    : '${report.days} days · ${report.sections} entries',
              ),
              const SizedBox(height: 4),
              _storageRow(
                labelStyle,
                valueStyle,
                'Text',
                report.textSizeLabel,
              ),
              if (report.tombstones > 0) ...[
                const SizedBox(height: 12),
                Text(
                  report.tombstones == 1
                      ? '1 deleted entry is being kept for 90 days so the '
                            'deletion can reach your other devices.'
                      : '${report.tombstones} deleted entries are being kept '
                            'for 90 days so the deletions can reach your other '
                            'devices.',
                  style: hintStyle,
                ),
              ],
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: _cleaning || !report.hasAnythingToReclaim
                    ? null
                    : _cleanUpStorage,
                icon: _cleaning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cleaning_services_outlined, size: 18),
                label: Text(
                  _cleaning ? 'Cleaning up…' : 'Clean up old deleted entries',
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Only entries deleted more than 90 days ago are removed, and '
                'the file is compacted. Your visible notes are never touched.',
                style: hintStyle,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _storageRow(
    TextStyle? labelStyle,
    TextStyle? valueStyle,
    String label,
    String value,
  ) {
    return Row(
      children: [
        Expanded(child: Text(label, style: labelStyle)),
        Flexible(
          child: Text(
            value,
            style: valueStyle,
            textAlign: TextAlign.end,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _exportButtonIcon(IconData icon) => _exporting
      ? const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        )
      : Icon(icon, size: 18);

  Future<void> _exportAll(ExportFormat format) async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final file = await _exporter.exportAll(
        NoteStore.instance.allNotes,
        format: format,
      );
      if (mounted) showExportResult(context, file);
    } catch (error) {
      if (mounted) showExportError(context, error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// Asks for a JSON file, then merges it into the notes.
  ///
  /// A cancelled picker is not an error and says nothing.
  Future<void> _importFile() async {
    if (_importing) return;
    final File? file;
    try {
      final picked = await _picker();
      if (picked == null) return;
      file = File(picked.path);
    } catch (error) {
      if (mounted) showImportError(context, error);
      return;
    }


    setState(() => _importing = true);
    try {
      final report = await _importer.importFile(file);
      if (mounted) showImportResult(context, report);
    } catch (error) {
      if (mounted) showImportError(context, error);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Widget _aiLink(BuildContext context, ThemeData theme) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => const AiSettingsScreen(),
          ),
        ),
        icon: const Icon(Icons.auto_awesome_outlined, size: 16),
        label: const Text('AI settings'),
      ),
    );
  }

  Future<void> _openScanner() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _ScanScreen(onCode: _sync.beginPairing),
      ),
    );
  }

  static String _formatWhen(DateTime when) {
    final now = DateTime.now();
    final difference = now.difference(when);
    if (difference.inMinutes < 1) return 'just now';
    if (difference.inMinutes < 60) return '${difference.inMinutes} min ago';
    if (difference.inHours < 24) return '${difference.inHours} h ago';
    return '${when.day}/${when.month}';
  }
}

/// The camera view that reads a pairing code.
///
/// A phone points its camera at the other screen. The code is the secret, so
/// this deliberately does not save or share the image: it is decoded and the
/// frame is gone.
class _ScanScreen extends StatefulWidget {
  const _ScanScreen({required this.onCode});

  final Future<void> Function(PairingCode code) onCode;

  @override
  State<_ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<_ScanScreen> {
  final MobileScannerController _camera = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );

  bool _handled = false;
  String? _error;

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled) return;
    final raw = capture.barcodes
        .map((barcode) => barcode.rawValue)
        .whereType<String>()
        .firstOrNull;
    if (raw == null) return;

    final code = PairingCode.tryDecode(raw);
    if (code == null) {
      // Not one of our codes: keep scanning rather than close on a QR code for
      // a menu or a website.
      return;
    }

    _handled = true;
    await _camera.stop();
    await widget.onCode(code);
    if (mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Paired with ${code.deviceName}.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan the code'),
        leading: IconButton(
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.close),
        ),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _camera,
            onDetect: _onDetect,
            errorBuilder: (context, error) => _errorView(theme, error),
          ),
          // A frame to aim with, so it is obvious where the code should go.
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.primary, width: 2),
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 40,
            child: Text(
              _error ?? 'Point the camera at the code on your other screen.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorView(ThemeData theme, MobileScannerException error) {
    final noPermission = error.errorCode == MobileScannerErrorCode.permissionDenied;
    final message = noPermission
        ? "Camera access is needed to scan the code. Allow it in your "
              "phone's settings, then reopen this screen."
        : 'The camera could not start. You can still pair by scanning on the '
              'other device instead.';

    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _error != message) setState(() => _error = message);
      });
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Icon(
          noPermission ? Icons.no_photography_outlined : Icons.videocam_off,
          size: 48,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

