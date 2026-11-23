/// The one object the sync screen talks to.
///
/// It owns the device identity, the paired devices, the listening socket and
/// the merge, so the UI only has to say "pair", "sync now" or "forget this
/// device" and render the state it reports.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/note_store.dart';
import 'lan_transport.dart';
import 'sync_crypto.dart';
import 'sync_models.dart';
import 'sync_protocol.dart';
import 'sync_settings.dart';

/// What the screen should show for the listening side.
enum ServerState { off, starting, listening, failed }

class SyncController extends ChangeNotifier {
  // The parameters are deliberately named differently from the private fields:
  // they are constructor seams, not part of the public surface.
  SyncController({
    required NoteStore noteStore,
    SyncSettingsStore? settingsStore,
    LanSyncClient syncClient = const LanSyncClient(),
    this.port = defaultPort,
    this.listen = true,
    List<LocalAddress>? addressesOverride,
  }) : _fixedAddresses = addressesOverride,
       _store = noteStore,
       _settingsStore = settingsStore ?? SyncSettingsStore(),
       _client = syncClient;

  /// A fixed port, because it is written into the pairing code. Uncommon enough
  /// to avoid a clash, easy to remember when troubleshooting a firewall.
  static const int defaultPort = 47821;

  final NoteStore _store;
  final SyncSettingsStore _settingsStore;
  final LanSyncClient _client;

  /// Addresses supplied by a test, so it does not depend on the machine's real
  /// network adapters.
  final List<LocalAddress>? _fixedAddresses;

  /// The port to listen on. Zero asks the OS for a free one, which is what a
  /// phone does: it cannot know a fixed port in advance.
  final int port;

  /// Whether this device accepts incoming syncs.
  ///
  /// Both devices listen, so either one can start a sync. Tests turn it off so
  /// they do not open sockets.
  final bool listen;

  SyncSettings? _settings;
  bool _loading = true;
  ServerState _serverState = ServerState.off;
  String? _serverError;

  bool _syncing = false;
  String? _status;
  bool _statusIsError = false;

  /// The addresses this machine can be reached at, for the QR code.
  List<LocalAddress> _addresses = const [];
  int _addressIndex = 0;

  LanSyncServer? _server;
  SyncProtocol? _protocol;

  bool get loading => _loading;
  bool get syncing => _syncing;
  ServerState get serverState => _serverState;
  String? get serverError => _serverError;
  String? get status => _status;
  bool get statusIsError => _statusIsError;

  SyncSettings? get settings => _settings;
  List<PeerRecord> get peers => _settings?.peers ?? const [];
  bool get hasPeers => peers.isNotEmpty;
  String get deviceName => _settings?.deviceName ?? 'This device';
  bool get autoSync => _settings?.autoSync ?? true;

  List<LocalAddress> get addresses => _addresses;
  LocalAddress? get address =>
      _addresses.isEmpty ? null : _addresses[_addressIndex.clamp(0, _addresses.length - 1)];

  /// A card to show, only valid once [address] is known.
  PairingCode? get pairingCode {
    final peer = _pairingPeer;
    return peer == null ? null : PairingCode.fromPeer(peer);
  }

  /// The record behind [pairingCode], for tests and for the introduction we
  /// send when the other device scans us.
  PeerRecord? get pairingCodePeer => _pairingPeer;

  /// This device as a peer record, with a key for a device about to pair.
  ///
  /// Regenerated whenever the code is rebuilt, so a code left on screen for
  /// hours is not a single long-lived secret. The key is remembered on first
  /// use in [beginPairing].
  PeerRecord? _pairingPeer;

  /// Starts listening and generating a code. Safe to call more than once.
  Future<void> init() async {
    if (!_loading) return;
    _settings = await _settingsStore.load();
    // A fresh install has no id until the first save.
    _settings = await _settingsStore.save(_settings!);

    _addresses = _fixedAddresses ?? await LocalAddress.discover();
    _loading = false;
    notifyListeners();

    // Port 0 means "do not listen": tests and previews want the screen and the
    // merge without a socket.
    if (listen) await _startServer();
    _regeneratePairingCode();
  }

  /// Starts the listener, or reports why it could not.
  Future<void> _startServer() async {
    final settings = _settings;
    if (settings == null) return;

    // Zero is bound to a free port below; this is what the peer will be told.
    _protocol = SyncProtocol(
      store: _store,
      deviceId: settings.deviceId,
      deviceName: settings.deviceName,
    );

    _server = LanSyncServer(
      protocol: _protocol!,
      peers: () => _settings?.peers ?? const [],
      port: port,
      pairingPeers: () => [?_pairingPeer],
      onPaired: rememberIncoming,
    );

    _serverState = ServerState.starting;
    notifyListeners();

    final error = await _server!.start();
    _serverError = error;
    _serverState = error == null ? ServerState.listening : ServerState.failed;

    // A phone asks the OS for a free port, so only now is the real one known.
    // Peers are told it in every reply, so they can dial back here later.
    _protocol!.listenPort = _server!.boundPort;
    notifyListeners();
  }

  /// A new address for the QR code, when a machine has several and the first
  /// guess was the wrong adapter.
  void useAddress(int index) {
    if (index < 0 || index >= _addresses.length) return;
    _addressIndex = index;
    _regeneratePairingCode();
  }

  void _regeneratePairingCode() {
    final settings = _settings;
    final address = this.address;
    if (settings == null || address == null || _addressIndex >= _addresses.length) {
      _pairingPeer = null;
      return;
    }
    _pairingPeer = PeerRecord(
      deviceId: settings.deviceId,
      deviceName: settings.deviceName,
      host: address.address,
      port: _server?.boundPort ?? port,
      secret: SyncCrypto.newKey(),
    );
  }

  /// Saves a device that scanned our code.
  ///
  /// The scanner already has our key; this is the other half, so both sides
  /// know each other and either one can sync regardless of who dials whom.
  Future<void> beginPairing(PairingCode code) async {
    final settings = _settings;
    if (settings == null) return;

    final existing = settings.peers.indexWhere(
      (peer) => peer.deviceId == code.deviceId,
    );
    final peer = PeerRecord(
      deviceId: code.deviceId,
      deviceName: code.deviceName,
      host: code.host,
      port: code.port,
      secret: code.secret,
    );

    final peers = [...settings.peers];
    if (existing == -1) {
      peers.add(peer);
    } else {
      peers[existing] = peer;
    }

    _settings = await _settingsStore.save(settings.copyWith(peers: peers));
    _setStatus('Paired with ${code.deviceName}.', isError: false);
    notifyListeners();
  }

  /// Registers a paired device that dialled *us* and told us who it is.
  ///
  /// Without this a one-sided pairing would leave the dialling device as a
  /// stranger here: it can send, but would not be recognised as a peer whose
  /// changes we should keep. The reply carries the key, so the pair is now
  /// mutual.
  Future<void> rememberIncoming(PeerRecord peer) async {
    final settings = _settings;
    if (settings == null) return;
    if (settings.peers.any((entry) => entry.deviceId == peer.deviceId)) return;

    _settings = await _settingsStore.save(
      settings.copyWith(peers: [...settings.peers, peer]),
    );
    notifyListeners();
  }

  /// Dials [peer] and merges both ways.
  Future<void> syncWith(PeerRecord peer) async {
    if (_syncing) return;
    _syncing = true;
    _setStatus('Syncing with ${peer.deviceName}…', isError: false);
    notifyListeners();

    try {
      final protocol = _protocol ??
          SyncProtocol(store: _store, deviceId: _settings!.deviceId);
      final outcome = await protocol.run(peer, (message) {
        return _client.send(peer, message);
      });

      await _store.flush();
      await _updatePeer(
        peer.copyWith(
          remoteCursor: outcome.remoteCursor.millisecondsSinceEpoch,
          localCursor: outcome.localCursor.millisecondsSinceEpoch,
          port: outcome.remotePort,
          lastSyncAt: DateTime.now(),
        ),
      );
      _setStatus(outcome.summary, isError: false);
    } on SyncTransportException catch (error) {
      _setStatus(error.message, isError: true);
    } catch (error) {
      _setStatus('Sync failed: $error', isError: true);
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  /// Syncs every paired device in turn, skipping any that are out of reach.
  ///
  /// Used by the automatic retry on the same network: one unreachable phone
  /// should not stop the others, and the user did not ask for a report, so
  /// failures stay quiet unless everything failed.
  Future<void> syncAll() async {
    if (_syncing || peers.isEmpty) return;
    _syncing = true;
    _setStatus('Looking for your other devices…', isError: false);
    notifyListeners();

    var succeeded = 0;
    Object? lastError;
    for (final peer in [...peers]) {
      try {
        final protocol = _protocol!;
        final outcome = await protocol.run(peer, (message) {
          return _client.send(peer, message);
        });
        await _store.flush();
        await _updatePeer(
          peer.copyWith(
            remoteCursor: outcome.remoteCursor.millisecondsSinceEpoch,
            localCursor: outcome.localCursor.millisecondsSinceEpoch,
            port: outcome.remotePort,
            lastSyncAt: DateTime.now(),
          ),
        );
        succeeded++;
      } catch (error) {
        lastError = error;
      }
    }

    if (succeeded > 0) {
      _setStatus(
        succeeded == 1
            ? 'Synced with 1 device.'
            : 'Synced with $succeeded devices.',
        isError: false,
      );
    } else {
      _setStatus(
        lastError is SyncTransportException
            ? lastError.message
            : 'No paired device was reachable. Check they are on the same Wi-Fi.',
        isError: true,
      );
    }

    _syncing = false;
    notifyListeners();
  }

  Future<void> forget(PeerRecord peer) async {
    final settings = _settings;
    if (settings == null) return;
    _settings = await _settingsStore.save(
      settings.copyWith(
        peers: settings.peers
            .where((entry) => entry.deviceId != peer.deviceId)
            .toList(),
      ),
    );
    _setStatus('Forgot ${peer.deviceName}.', isError: false);
    notifyListeners();
  }

  Future<void> setAutoSync(bool value) async {
    final settings = _settings;
    if (settings == null) return;
    _settings = await _settingsStore.save(settings.copyWith(autoSync: value));
    notifyListeners();
  }

  Future<void> setDeviceName(String name) async {
    final settings = _settings;
    if (settings == null) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _settings = await _settingsStore.save(
      settings.copyWith(deviceName: trimmed),
    );
    _regeneratePairingCode();
    notifyListeners();
  }

  Future<void> _updatePeer(PeerRecord peer) async {
    final settings = _settings;
    if (settings == null) return;
    _settings = await _settingsStore.save(
      settings.copyWith(
        peers: [
          for (final entry in settings.peers)
            if (entry.deviceId == peer.deviceId) peer else entry,
        ],
      ),
    );
  }

  void _setStatus(String message, {required bool isError}) {
    _status = message;
    _statusIsError = isError;
  }

  void dismissStatus() {
    _status = null;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_server?.stop());
    super.dispose();
  }
}

/// Whether this build can host the listening side.
bool get canHostSync =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;
