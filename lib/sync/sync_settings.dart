/// What this device remembers about sync: who it is, and who it trusts.
///
/// Identity and paired devices live in normal preferences. The section data
/// itself never does - that is in SQLite - and the shared keys are only useful
/// between two known devices, so the plain preferences file is the right place
/// for them; they are useless without the other device's data too.
library;

import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'sync_models.dart';

/// The saved sync configuration.
class SyncSettings {
  const SyncSettings({
    required this.deviceId,
    required this.deviceName,
    required this.peers,
    this.autoSync = true,
  });

  /// A stable id for this install. Created once and kept, so a peer recognises
  /// a device it has already paired with instead of pairing again.
  final String deviceId;

  /// What the other device shows while pairing, e.g. "Luke's laptop".
  final String deviceName;

  final List<PeerRecord> peers;

  /// Whether to sync whenever a paired device turns up on the same network.
  final bool autoSync;

  bool get hasPeers => peers.isNotEmpty;

  SyncSettings copyWith({
    String? deviceName,
    List<PeerRecord>? peers,
    bool? autoSync,
  }) {
    return SyncSettings(
      deviceId: deviceId,
      deviceName: deviceName ?? this.deviceName,
      peers: peers ?? this.peers,
      autoSync: autoSync ?? this.autoSync,
    );
  }
}

/// Reads and writes [SyncSettings].
class SyncSettingsStore {
  static const String _keyDeviceId = 'sync.deviceId';
  static const String _keyDeviceName = 'sync.deviceName';
  static const String _keyPeers = 'sync.peers';
  static const String _keyAutoSync = 'sync.autoSync';

  SharedPreferences? _preferences;

  Future<SharedPreferences> get _prefs async =>
      _preferences ??= await SharedPreferences.getInstance();

  Future<SyncSettings> load() async {
    final prefs = await _prefs;
    final deviceId = prefs.getString(_keyDeviceId) ?? '';

    return SyncSettings(
      deviceId: deviceId,
      deviceName: prefs.getString(_keyDeviceName) ?? _defaultName(),
      peers: _decodePeers(prefs.getString(_keyPeers)),
      autoSync: prefs.getBool(_keyAutoSync) ?? true,
    );
  }

  /// Saves [settings], generating a device id on the first save.
  Future<SyncSettings> save(SyncSettings settings) async {
    final prefs = await _prefs;
    final deviceId = settings.deviceId.isEmpty
        ? const Uuid().v4()
        : settings.deviceId;

    await prefs.setString(_keyDeviceId, deviceId);
    await prefs.setString(_keyDeviceName, settings.deviceName);
    await prefs.setBool(_keyAutoSync, settings.autoSync);
    await prefs.setString(
      _keyPeers,
      jsonEncode([for (final peer in settings.peers) peer.toJson()]),
    );

    return SyncSettings(
      deviceId: deviceId,
      deviceName: settings.deviceName,
      peers: settings.peers,
      autoSync: settings.autoSync,
    );
  }

  static List<PeerRecord> _decodePeers(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return [
        for (final item in list)
          if (item is Map<String, dynamic>) PeerRecord.fromJson(item),
      ];
    } catch (_) {
      // A corrupt preferences file should mean "no paired devices", not a
      // crash on launch.
      return const [];
    }
  }

  /// A friendly name from the machine, so pairing shows something meaningful.
  static String _defaultName() {
    const adjectives = ['Quiet', 'Blue', 'Drifting', 'Still', 'Tidal'];
    const nouns = ['Laptop', 'Phone', 'Desktop', 'Tablet'];
    final random = Random();
    final adjective = adjectives[random.nextInt(adjectives.length)];
    final noun = nouns[random.nextInt(nouns.length)];
    return '$adjective $noun';
  }
}
