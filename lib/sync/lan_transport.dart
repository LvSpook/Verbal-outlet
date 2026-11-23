/// Moving one message between two devices on the same Wi-Fi.
///
/// No server, no relay, no cloud: the desktop listens on a port and the phone
/// dials it. A connection carries exactly one request and one reply, then
/// closes, which keeps the code small and means a dropped connection can only
/// ever cost one sync.
///
/// Every frame is sealed with [SyncCrypto], so anything else on the network can
/// connect but cannot read or forge a note.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'sync_crypto.dart';
import 'sync_models.dart';
import 'sync_protocol.dart';

/// Addresses a QR code could advertise.
///
/// More than one when a machine has several network adapters (Wi-Fi plus a
/// virtual one, say); the caller shows the best guess and the rest as options.
class LocalAddress {
  const LocalAddress(this.address, this.interfaceName);

  final String address;
  final String interfaceName;

  /// Real Wi-Fi/Ethernet addresses first: a VPN or a VM adapter will not reach
  /// the phone, so it should not be the one in the QR code.
  static bool _looksRoutable(String address) {
    if (address.startsWith('169.254.')) return false;
    return address.startsWith('192.168.') ||
        address.startsWith('10.') ||
        _isPrivate172(address);
  }

  static bool _isPrivate172(String address) {
    final parts = address.split('.');
    if (parts.length < 2 || parts[0] != '172') return false;
    final second = int.tryParse(parts[1]);
    return second != null && second >= 16 && second <= 31;
  }

  /// Every usable IPv4 address on this machine, best first.
  static Future<List<LocalAddress>> discover() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final found = <LocalAddress>[
        for (final interface in interfaces)
          for (final address in interface.addresses)
            LocalAddress(address.address, interface.name),
      ];
      found.sort((a, b) {
        final rank =
            (_looksRoutable(b.address) ? 1 : 0) -
            (_looksRoutable(a.address) ? 1 : 0);
        return rank;
      });
      return found;
    } catch (error) {
      debugPrint('Listing network interfaces failed: $error');
      return const [];
    }
  }
}

/// The desktop side: accepts one sync at a time from a paired device.
class LanSyncServer {
  LanSyncServer({
    required this.protocol,
    required this.peers,
    required this.port,
    this.pairingPeers,
    this.onPaired,
  });

  /// Handles the merge for this device.
  final SyncProtocol protocol;

  /// The keys we will try each incoming frame against, one per paired device.
  final List<PeerRecord> Function() peers;

  /// Keys currently shown in a QR code, waiting for a device to scan them.
  ///
  /// A device that has just scanned has our key but we do not yet have its
  /// identity, so its first message cannot be matched to a known peer. This is
  /// how that first message is allowed in.
  final List<PeerRecord> Function()? pairingPeers;

  /// Called when a device pairs with us through a scanned code.
  final Future<void> Function(PeerRecord peer)? onPaired;

  /// The port to listen on. Fixed, because it is baked into the pairing code.
  final int port;

  ServerSocket? _socket;
  StreamSubscription<Socket>? _subscription;

  bool get isRunning => _socket != null;

  /// Starts listening, or does nothing if already listening.
  ///
  /// Returns null on success, or a message explaining why it could not start -
  /// usually the port being taken by another copy of the app.
  Future<String?> start() async {
    if (_socket != null) return null;
    try {
      // A zero port asks the OS for any free one, which is what a phone does:
      // it cannot know a fixed port in advance, and should not need to.
      _socket = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        port,
      );
      _subscription = _socket!.listen(_onConnection, onError: _onSocketError);
      return null;
    } on SocketException catch (error) {
      final busy =
          error.osError?.errorCode == 10048 || // Windows
          error.osError?.errorCode == 98; // Linux/macOS
      return busy
          ? 'Sync is already running on port $port, probably from another copy '
                'of the app.'
          : 'Could not listen on port $port: ${error.message}';
    }
  }

  /// The port actually bound, which differs from [port] when that was zero.
  int get boundPort => _socket?.port ?? port;

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    await _socket?.close();
    _socket = null;
  }

  void _onSocketError(Object error) {
    debugPrint('Sync server socket error: $error');
  }

  Future<void> _onConnection(Socket socket) async {
    // A stalled or malicious client must not hold a connection forever.
    socket.setOption(SocketOption.tcpNoDelay, true);
    final timer = Timer(const Duration(seconds: 15), socket.destroy);

    try {
      final frame = await _readLine(socket);
      final opened = await _openWithAnyKey(frame);
      if (opened == null) {
        // Not paired, or the frame was corrupted: close without explaining,
        // since the sender is not someone we trust.
        return;
      }
      final (key, peer, request) = opened;
      final host = socket.remoteAddress.address;

      // A frame that opened under a key from the code on screen came from the
      // device that scanned it, so this is the moment pairing becomes mutual.
      // Done before the reply so the other side sees the pair saved as soon as
      // its sync returns.
      if (peer == null) {
        final introduced = protocol.readIntroduction(
          request,
          host: host,
          secret: key,
        );
        final isCodeOnScreen =
            (pairingPeers?.call() ?? const []).any(
              (candidate) => candidate.secret == key,
            );
        if (introduced != null && isCodeOnScreen) {
          try {
            await onPaired?.call(introduced);
          } catch (error) {
            // The sync below still matters more than the saved pair.
            debugPrint('Recording a paired device failed: $error');
          }
        }
      }

      final reply = protocol.handleRequest(request);
      reply['deviceName'] = protocol.deviceName;
      final sealed = await SyncCrypto(key).seal(reply);
      socket.write('$sealed\n');
      await socket.flush();
    } catch (error) {
      debugPrint('Sync connection failed: $error');
    } finally {
      timer.cancel();
      await socket.close();
    }
  }

  /// Tries each paired key, then any code currently on screen, until one opens
  /// the frame.
  ///
  /// There are only ever a handful of keys, and this avoids putting a device id
  /// in the clear just to pick one. Returns the key that worked, the matching
  /// peer if there was one, and the message.
  Future<(String, PeerRecord?, Map<String, Object?>)?> _openWithAnyKey(
    String frame,
  ) async {
    for (final peer in peers()) {
      if (!peer.isPaired) continue;
      try {
        final opened = await SyncCrypto(peer.secret).open(frame);
        if (opened != null) return (peer.secret, peer, opened);
      } catch (error) {
        // A malformed stored key should skip this peer, not kill the sync.
        debugPrint('Bad key for ${peer.deviceName}: $error');
      }
    }

    for (final candidate in pairingPeers?.call() ?? const <PeerRecord>[]) {
      try {
        final opened = await SyncCrypto(candidate.secret).open(frame);
        if (opened != null) return (candidate.secret, null, opened);
      } catch (error) {
        debugPrint('Bad pairing key: $error');
      }
    }
    return null;
  }
}

/// The client side: one request to one peer, and its reply.
class LanSyncClient {
  const LanSyncClient({this.timeout = const Duration(seconds: 10)});

  final Duration timeout;

  /// Sends [message] to [peer] and returns the decrypted reply.
  ///
  /// Every failure becomes a [SyncTransportException] with wording aimed at a
  /// person: "not on this network" is what they can act on, a stack trace is
  /// not.
  Future<Map<String, Object?>> send(
    PeerRecord peer,
    Map<String, Object?> message,
  ) async {
    if (!peer.isPaired) {
      throw const SyncTransportException('This device is not paired yet.');
    }

    Socket? socket;
    try {
      socket = await Socket.connect(
        peer.host,
        peer.port,
        timeout: timeout,
      ).timeout(timeout);

      final crypto = SyncCrypto(peer.secret);
      socket.write('${await crypto.seal(message)}\n');
      await socket.flush();

      final frame = await _readLine(socket).timeout(timeout);
      final reply = await crypto.open(frame);
      if (reply == null) {
        throw const SyncTransportException(
          'The reply could not be read. Try pairing again.',
        );
      }
      return reply;
    } on SocketException {
      throw SyncTransportException(
        'Could not reach ${peer.deviceName}. Check both devices are on the '
        'same Wi-Fi and the app is open on the other one.',
      );
    } on TimeoutException {
      throw SyncTransportException(
        '${peer.deviceName} did not answer in time. Try again in a moment.',
      );
    } finally {
      socket?.destroy();
    }
  }
}

/// Something a person can act on, rather than a raw socket error.
class SyncTransportException implements Exception {
  const SyncTransportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Reads one newline-terminated line, capped so a huge frame cannot exhaust
/// memory.
Future<String> _readLine(
  Socket socket, {
  int maxBytes = 8 * 1024 * 1024,
}) async {
  final buffer = <int>[];
  await for (final chunk in socket) {
    buffer.addAll(chunk);
    final newline = buffer.indexOf(10);
    if (newline != -1) {
      return utf8.decode(buffer.sublist(0, newline));
    }
    if (buffer.length > maxBytes) {
      throw const SyncTransportException('The message was too large.');
    }
  }
  // The socket closed without a newline: treat what arrived as the line, which
  // is enough for a peer that shuts down immediately after replying.
  if (buffer.isEmpty) {
    throw const SyncTransportException(
      'The other device closed the connection.',
    );
  }
  return utf8.decode(buffer);
}
