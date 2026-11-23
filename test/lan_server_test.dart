import 'package:flutter_test/flutter_test.dart';

import 'package:verbal_outlet/data/note_repository.dart';
import 'package:verbal_outlet/data/note_store.dart';
import 'package:verbal_outlet/sync/lan_transport.dart';
import 'package:verbal_outlet/sync/sync_controller.dart';
import 'package:verbal_outlet/sync/sync_models.dart';
import 'package:verbal_outlet/sync/sync_settings.dart';

/// Keeps settings in memory for one controller.
///
/// The real store shares a single preferences file, which is right for an app
/// with one install but wrong for a test where two devices run in one process:
/// each would overwrite the other's paired list.
class _DeviceSettings implements SyncSettingsStore {
  _DeviceSettings(this.deviceName);

  final String deviceName;
  SyncSettings? _saved;

  @override
  Future<SyncSettings> load() async =>
      _saved ?? SyncSettings(deviceId: '', deviceName: deviceName, peers: const []);

  @override
  Future<SyncSettings> save(SyncSettings settings) async {
    _saved = settings.deviceId.isEmpty
        // A per-controller id, so the two sides in a test never look alike.
        ? SyncSettings(
            deviceId: 'device-$deviceName',
            deviceName: settings.deviceName,
            peers: settings.peers,
            autoSync: settings.autoSync,
          )
        : settings;
    return _saved!;
  }
}

/// A device: its controller, and the store its notes live in.
typedef _Device = ({SyncController controller, NoteStore store});

Future<_Device> _device({required String name, int? port}) async {
  final store = NoteStore.forTesting(MemoryNoteRepository());
  await store.attachRepository(MemoryNoteRepository());

  final controller = SyncController(
    noteStore: store,
    settingsStore: _DeviceSettings(name),
    // Both devices listen on a free port, like the app: that is what makes a
    // two-way sync possible without a fixed port on the phone.
    listen: true,
    port: port ?? 0,
    addressesOverride: const [LocalAddress('127.0.0.1', 'Loopback')],
  );
  await controller.init();
  return (controller: controller, store: store);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the real server accepts a sync from the real client', () async {
    // Not the app's port, so this never fights a copy of the app running
    // beside the test.
    final laptop = await _device(name: 'Laptop', port: 47899);
    addTearDown(laptop.controller.dispose);
    expect(
      laptop.controller.serverState,
      ServerState.listening,
      reason: laptop.controller.serverError,
    );
    expect(laptop.controller.pairingCodePeer, isNotNull);

    laptop.store.appendToDay(DateTime(2026, 5, 1), 'written on the laptop');
    await laptop.store.flush();

    final phone = await _device(name: 'Phone');
    addTearDown(phone.controller.dispose);

    await phone.controller.beginPairing(
      PairingCode.fromPeer(laptop.controller.pairingCodePeer!),
    );
    expect(
      phone.controller.peers.single.deviceId,
      laptop.controller.settings!.deviceId,
    );

    // Give the introduction the phone sends on pairing a moment to land.
    await Future<void>.delayed(const Duration(milliseconds: 300));

    await phone.controller.syncAll();
    if (phone.controller.statusIsError) {
      // Surface the underlying reason rather than syncAll's friendly wrapper.
      await phone.controller.syncWith(phone.controller.peers.single);
    }
    expect(
      phone.controller.statusIsError,
      isFalse,
      reason: phone.controller.status,
    );
    expect(phone.controller.status!.toLowerCase(), contains('synced'));
    expect(
      phone.store.noteFor(DateTime(2026, 5, 1))!.body,
      'written on the laptop',
    );
    expect(phone.controller.peers.single.lastSyncAt, isNotNull);

    // Pairing was mutual: the computer learned who the phone is.
    expect(
      laptop.controller.peers.map((peer) => peer.deviceId),
      contains(phone.controller.settings!.deviceId),
    );
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a second sync carries changes back the other way', () async {
    final laptop = await _device(name: 'Laptop', port: 47898);
    addTearDown(laptop.controller.dispose);
    final phone = await _device(name: 'Phone');
    addTearDown(phone.controller.dispose);

    expect(
      laptop.controller.serverState,
      ServerState.listening,
      reason: laptop.controller.serverError,
    );
    expect(laptop.controller.pairingCodePeer, isNotNull);

    await phone.controller.beginPairing(
      PairingCode.fromPeer(laptop.controller.pairingCodePeer!),
    );
    await phone.controller.syncWith(phone.controller.peers.single);
    expect(
      phone.controller.statusIsError,
      isFalse,
      reason: phone.controller.status,
    );

    // Something new on the phone, then catch up from the laptop's side.
    phone.store.appendToDay(DateTime(2026, 5, 2), 'added on the phone');
    await phone.store.flush();

    expect(laptop.controller.peers, hasLength(1));
    await laptop.controller.syncWith(laptop.controller.peers.single);

    expect(
      laptop.controller.statusIsError,
      isFalse,
      reason: laptop.controller.status,
    );
    expect(
      laptop.store.noteFor(DateTime(2026, 5, 2))!.body,
      'added on the phone',
    );
  }, timeout: const Timeout(Duration(seconds: 30)));
}
