/// The things that travel between two devices.
///
/// Everything is plain JSON so the protocol can be read while debugging with a
/// socket dump, and so a future version can add fields without breaking an
/// older app: unknown keys are ignored on read.
library;

import 'dart:convert';

import '../data/note_repository.dart' show dateOnly;
import '../models/day_note.dart';

/// The protocol version. Bump only when an old app could not cope.
const int syncProtocolVersion = 1;

/// One section, flattened with its day, ready to be sent.
///
/// [day] is separate from [createdAt] because a thought added today can belong
/// to a note for last week.
class SyncSectionData {
  const SyncSectionData({
    required this.id,
    required this.day,
    required this.createdAt,
    required this.updatedAt,
    required this.text,
    this.body = '',
    this.state = ComposeState.ready,
    this.instruction = '',
    this.composeError,
    this.durationMs,
    this.deleted = false,
  });

  factory SyncSectionData.fromSection(DateTime day, NoteSection section) {
    return SyncSectionData(
      id: section.id,
      day: dateOnly(day),
      createdAt: section.createdAt,
      updatedAt: section.modifiedAt,
      text: section.text,
      body: section.body,
      state: section.state,
      instruction: section.instruction,
      composeError: section.composeError,
      durationMs: section.duration?.inMilliseconds,
      deleted: section.deleted,
    );
  }

  factory SyncSectionData.fromJson(Map<String, dynamic> json) {
    return SyncSectionData(
      id: json['id'] as String,
      day: DateTime.fromMillisecondsSinceEpoch((json['day'] as num).toInt()),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAt'] as num).toInt(),
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['updatedAt'] as num).toInt(),
      ),
      text: json['text'] as String? ?? '',
      body: json['body'] as String? ?? '',
      state: NoteSection.stateFromName(json['state']),
      instruction: json['instruction'] as String? ?? '',
      composeError: json['composeError'] as String?,
      durationMs: (json['durationMs'] as num?)?.toInt(),
      deleted: json['deleted'] as bool? ?? false,
    );
  }

  final String id;
  final DateTime day;
  final DateTime createdAt;

  /// The version time: the newest edit (or delete) of this section.
  final DateTime updatedAt;
  final String text;
  final String body;
  final ComposeState state;
  final String instruction;
  final String? composeError;
  final int? durationMs;
  final bool deleted;

  Map<String, Object?> toJson() => {
    'id': id,
    'day': day.millisecondsSinceEpoch,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    'text': text,
    'body': body,
    'state': state.name,
    if (instruction.isNotEmpty) 'instruction': instruction,
    if (composeError != null) 'composeError': composeError,
    if (durationMs != null) 'durationMs': durationMs,
    'deleted': deleted,
  };

  /// This section as the app uses it.
  NoteSection toSection() {
    return NoteSection(
      id: id,
      createdAt: createdAt,
      text: text,
      body: body,
      state: state,
      instruction: instruction,
      composeError: composeError,
      duration: durationMs == null
          ? null
          : Duration(milliseconds: durationMs!),
      updatedAt: updatedAt,
      deleted: deleted,
    );
  }
}

/// A device's stored knowledge of one partner.
class PeerRecord {
  const PeerRecord({
    required this.deviceId,
    required this.deviceName,
    required this.host,
    required this.port,
    required this.secret,
    this.remoteCursor = 0,
    this.localCursor = 0,
    this.lastSyncAt,
  });

  factory PeerRecord.fromJson(Map<String, dynamic> json) {
    final synced = json['lastSyncAt'] as num?;
    return PeerRecord(
      deviceId: json['deviceId'] as String,
      deviceName: json['deviceName'] as String? ?? 'Device',
      host: json['host'] as String? ?? '',
      port: (json['port'] as num?)?.toInt() ?? 0,
      secret: json['secret'] as String? ?? '',
      remoteCursor: (json['remoteCursor'] as num?)?.toInt() ?? 0,
      localCursor: (json['localCursor'] as num?)?.toInt() ?? 0,
      lastSyncAt: synced == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(synced.toInt()),
    );
  }

  final String deviceId;
  final String deviceName;

  /// The last address the peer was reachable at. A router may change it, in
  /// which case discovery finds it again.
  final String host;
  final int port;

  /// Base64 of the 32-byte shared key, agreed when pairing.
  final String secret;

  /// A time in the *peer's* clock: everything they made before this has
  /// already arrived here. Sent back to them to ask only for new work.
  final int remoteCursor;

  /// A time in *our* clock: everything we made before this has already been
  /// sent to them.
  final int localCursor;

  final DateTime? lastSyncAt;

  bool get isPaired => secret.isNotEmpty && deviceId.isNotEmpty;

  PeerRecord copyWith({
    String? deviceName,
    String? host,
    int? port,
    String? secret,
    int? remoteCursor,
    int? localCursor,
    DateTime? lastSyncAt,
  }) {
    return PeerRecord(
      deviceId: deviceId,
      deviceName: deviceName ?? this.deviceName,
      host: host ?? this.host,
      port: port ?? this.port,
      secret: secret ?? this.secret,
      remoteCursor: remoteCursor ?? this.remoteCursor,
      localCursor: localCursor ?? this.localCursor,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    );
  }

  Map<String, Object?> toJson() => {
    'deviceId': deviceId,
    'deviceName': deviceName,
    'host': host,
    'port': port,
    'secret': secret,
    'remoteCursor': remoteCursor,
    'localCursor': localCursor,
    if (lastSyncAt != null) 'lastSyncAt': lastSyncAt!.millisecondsSinceEpoch,
  };
}

/// What a QR code carries when one device pairs with another.
///
/// It is the peer's address plus the shared key, so scanning once is enough
/// for every later sync.
class PairingCode {
  const PairingCode({
    required this.deviceId,
    required this.deviceName,
    required this.host,
    required this.port,
    required this.secret,
  });

  factory PairingCode.fromPeer(PeerRecord peer) => PairingCode(
    deviceId: peer.deviceId,
    deviceName: peer.deviceName,
    host: peer.host,
    port: peer.port,
    secret: peer.secret,
  );

  final String deviceId;
  final String deviceName;
  final String host;
  final int port;
  final String secret;

  String encode() => base64Url.encode(
    utf8.encode(
      jsonEncode({
        'v': syncProtocolVersion,
        'app': 'verbal-outlet',
        'deviceId': deviceId,
        'deviceName': deviceName,
        'host': host,
        'port': port,
        'secret': secret,
      }),
    ),
  );

  /// Reads a scanned code, or null if it is not one of ours.
  static PairingCode? tryDecode(String raw) {
    try {
      final text = utf8.decode(base64Url.decode(base64Url.normalize(raw.trim())));
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) return null;
      if (json['app'] != 'verbal-outlet') return null;
      final deviceId = json['deviceId'] as String?;
      final host = json['host'] as String?;
      final secret = json['secret'] as String?;
      final port = (json['port'] as num?)?.toInt();
      if (deviceId == null || deviceId.isEmpty) return null;
      if (host == null || host.isEmpty) return null;
      if (secret == null || secret.isEmpty) return null;
      if (port == null || port <= 0) return null;
      return PairingCode(
        deviceId: deviceId,
        deviceName: json['deviceName'] as String? ?? 'Device',
        host: host,
        port: port,
        secret: secret,
      );
    } catch (_) {
      return null;
    }
  }
}
