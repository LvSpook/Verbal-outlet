/// Pulling two devices' notes together.
///
/// A sync is one round trip:
///
/// 1. We send every section *we* changed after [PeerRecord.localCursor], which
///    is everything they may not have from us.
/// 2. We ask for everything *they* changed after [PeerRecord.remoteCursor],
///    the last time we heard from them.
/// 3. They apply our sections and reply with theirs, plus how many of ours were
///    actually new to them.
///
/// Cursors use each device's own clock, so a little clock drift only causes a
/// few extra sections to be re-sent - never a missed one. Re-sending is safe
/// because applying a section is idempotent: it only lands if it is newer.
library;

import '../data/note_store.dart';
import 'sync_models.dart';

/// What one sync did, for the UI to report.
class SyncOutcome {
  const SyncOutcome({
    required this.received,
    required this.sent,
    required this.deviceName,
    required this.remoteCursor,
    required this.localCursor,
    this.remotePort,
  });

  /// Sections from the other device that were actually new here.
  final int received;

  /// Sections of ours that were actually new to the other device.
  final int sent;

  final String deviceName;

  /// The peer's clock, up to their newest change: ask from here next time.
  final DateTime remoteCursor;

  /// Our clock, up to the moment this sync started: they have it all now.
  final DateTime localCursor;

  /// The port the peer said it listens on, when it does.
  final int? remotePort;

  bool get changedAnything => received > 0 || sent > 0;

  String get summary {
    if (!changedAnything) return 'Already up to date with $deviceName.';
    final parts = <String>[
      if (received > 0) '$received received',
      if (sent > 0) '$sent sent',
    ];
    return '${parts.join(', ')} — synced with $deviceName.';
  }
}

/// The messages two devices exchange, before they go over a socket.
///
/// Kept apart from the transport so the merge can be tested by handing one
/// device's request straight to the other.
class SyncProtocol {
  SyncProtocol({
    required this.store,
    required this.deviceId,
    this.deviceName = 'Device',
    this.listenPort = 0,
  });

  final NoteStore store;
  final String deviceId;

  /// The name this device is shown by, so a peer can report who it synced with.
  final String deviceName;

  /// The port this device listens on, advertised to the peer so the peer can
  /// dial back. Zero until a listener binds, for a device that does not listen.
  int listenPort;

  /// Every section changed strictly after [since], oldest first.
  List<SyncSectionData> changedSince(DateTime since) {
    final found = [
      for (final (day, section) in store.allSections)
        if (section.modifiedAt.isAfter(since))
          SyncSectionData.fromSection(day, section),
    ];
    found.sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    return found;
  }

  /// The newest modified time we hold, or the epoch when we hold nothing.
  DateTime newestChange() {
    var newest = DateTime.fromMillisecondsSinceEpoch(0);
    for (final (_, section) in store.allSections) {
      if (section.modifiedAt.isAfter(newest)) newest = section.modifiedAt;
    }
    return newest;
  }

  /// The single request that both pushes ours and pulls theirs.
  ///
  /// [startedAt] is our newest change at the moment of the call, so the caller
  /// can advance [PeerRecord.localCursor] to exactly what was included here.
  Map<String, Object?> buildRequest(PeerRecord peer, DateTime startedAt) => {
    'type': 'sync',
    'deviceId': deviceId,
    'deviceName': deviceName,
    // So they can dial back here later, when this device listens.
    'port': listenPort,
    // Their clock: send me anything newer than this.
    'cursor': peer.remoteCursor,
    // Ours, unchanged since we last sent them anything.
    'sections': [
      for (final section in changedSince(
        DateTime.fromMillisecondsSinceEpoch(peer.localCursor),
      ))
        section.toJson(),
    ],
    'sentAt': DateTime.now().millisecondsSinceEpoch,
  };

  /// Reads a peer's identity out of a first message.
  ///
  /// No secret travels in the message: the sender is identified by the fact
  /// that the transport opened the frame with a key from the code on screen.
  /// So this accepts a sync or an introduction, whichever the scanner sends
  /// first.
  PeerRecord? readIntroduction(
    Map<String, Object?> request, {
    required String host,
    required String secret,
  }) {
    final peerId = request['deviceId'] as String?;
    if (peerId == null || peerId.isEmpty || peerId == deviceId) return null;

    return PeerRecord(
      deviceId: peerId,
      deviceName: request['deviceName'] as String? ?? 'Device',
      host: host,
      // The port the sender said it listens on, if any. Zero means it does not
      // listen, and we can only reach it while it dials us.
      port: (request['port'] as num?)?.toInt() ?? 0,
      secret: secret,
    );
  }

  /// Handles a peer's request: applies what they sent, replies with ours.
  Map<String, Object?> handleRequest(Map<String, Object?> request) {
    final applied = applySections(request['sections']);
    final cursor = (request['cursor'] as num?)?.toInt() ?? 0;
    final theirs = changedSince(
      DateTime.fromMillisecondsSinceEpoch(cursor),
    );

    return {
      'type': 'sync',
      'deviceId': deviceId,
      'deviceName': deviceName,
      // So the peer can dial this device back later, if it listens at all.
      'port': listenPort,
      'sections': [for (final section in theirs) section.toJson()],
      // How many of their sections were genuinely new here.
      'applied': applied,
      // Their next cursor: our newest change, on our clock.
      'cursor': newestChange().millisecondsSinceEpoch,
      'sentAt': DateTime.now().millisecondsSinceEpoch,
    };
  }

  /// Applies a list of sections, newest-version-wins. Returns how many landed.
  int applySections(Object? raw) {
    if (raw is! List) return 0;

    var applied = 0;
    for (final item in raw) {
      if (item is! Map) continue;
      final data = SyncSectionData.fromJson(
        item.map((key, value) => MapEntry(key.toString(), value)),
      );
      if (store.applyRemoteSection(data.day, data.toSection())) {
        applied++;
      }
    }
    return applied;
  }

  /// Runs the whole exchange against [peer] using [send], which transports one
  /// message and returns the reply.
  ///
  /// [send] is injected so the flow can be exercised without a network, and so
  /// encryption can wrap it in exactly one place.
  Future<SyncOutcome> run(
    PeerRecord peer,
    Future<Map<String, Object?>> Function(Map<String, Object?> message) send,
  ) async {
    // Taken before sending, so anything made mid-sync is picked up next time
    // rather than silently marked as sent.
    final startedAt = newestChange();
    final request = buildRequest(peer, startedAt);
    final reply = await send(request);

    final replyCursor = (reply['cursor'] as num?)?.toInt();
    final received = applySections(reply['sections']);

    return SyncOutcome(
      received: received,
      sent: (reply['applied'] as num?)?.toInt() ?? 0,
      deviceName: peer.deviceName,
      remoteCursor: DateTime.fromMillisecondsSinceEpoch(
        replyCursor ?? peer.remoteCursor,
      ),
      localCursor: startedAt,
      // The peer's own port, so a later sync can start from this side even
      // when only one of the two listens.
      remotePort: (reply['port'] as num?)?.toInt() ?? peer.port,
    );
  }
}
