import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:verbal_outlet/data/note_repository.dart';
import 'package:verbal_outlet/data/note_store.dart';
import 'package:verbal_outlet/models/day_note.dart';
import 'package:verbal_outlet/sync/lan_transport.dart';
import 'package:verbal_outlet/sync/sync_crypto.dart';
import 'package:verbal_outlet/sync/sync_models.dart';
import 'package:verbal_outlet/sync/sync_protocol.dart';

Future<NoteStore> _store() async {
  final store = NoteStore.forTesting(MemoryNoteRepository());
  await store.attachRepository(MemoryNoteRepository());
  return store;
}

PeerRecord _peer({
  String id = 'phone',
  String name = 'Phone',
  required String secret,
  int remoteCursor = 0,
  int localCursor = 0,
}) {
  return PeerRecord(
    deviceId: id,
    deviceName: name,
    host: '127.0.0.1',
    port: 47821,
    secret: secret,
    remoteCursor: remoteCursor,
    localCursor: localCursor,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pairing code', () {
    test('round-trips the address and key', () {
      final peer = _peer(secret: SyncCrypto.newKey());
      final code = PairingCode.fromPeer(peer);
      final decoded = PairingCode.tryDecode(code.encode());

      expect(decoded, isNotNull);
      expect(decoded!.deviceId, peer.deviceId);
      expect(decoded.host, peer.host);
      expect(decoded.port, peer.port);
      expect(decoded.secret, peer.secret);
    });

    test('rejects text that is not one of ours', () {
      expect(PairingCode.tryDecode('https://example.com'), isNull);
      expect(PairingCode.tryDecode('hello'), isNull);
      expect(
        PairingCode.tryDecode(
          base64Url.encode(utf8.encode(jsonEncode({'app': 'something'}))),
        ),
        isNull,
      );
    });
  });

  group('crypto', () {
    test('a sealed message opens with the same key only', () async {
      final key = SyncCrypto.newKey();
      final sealed = await SyncCrypto(key).seal({'type': 'sync', 'n': 2});

      expect(await SyncCrypto(key).open(sealed), {'type': 'sync', 'n': 2});
      expect(await SyncCrypto(SyncCrypto.newKey()).open(sealed), isNull);
    });

    test('a tampered frame does not open', () async {
      final key = SyncCrypto.newKey();
      final sealed = await SyncCrypto(key).seal({'text': 'private'});
      final bytes = base64.decode(sealed);
      bytes[bytes.length - 1] ^= 0xff;

      expect(await SyncCrypto(key).open(base64.encode(bytes)), isNull);
    });

    test('keys are 32 bytes of base64', () {
      final bytes = base64Url.decode(SyncCrypto.newKey());
      expect(bytes, hasLength(32));
    });
  });

  group('protocol', () {
    test('new notes travel one way', () async {
      final laptop = await _store();
      final phone = await _store();
      final secret = SyncCrypto.newKey();

      laptop.appendToDay(DateTime(2026, 4, 1), 'written on the laptop');
      await laptop.flush();

      final laptopProtocol = SyncProtocol(store: laptop, deviceId: 'laptop');
      final phoneProtocol = SyncProtocol(store: phone, deviceId: 'phone');

      final phonePeer = _peer(secret: secret);
      final outcome = await phoneProtocol.run(phonePeer, (message) async {
        return laptopProtocol.handleRequest(message);
      });

      expect(outcome.received, 1);
      expect(phone.noteFor(DateTime(2026, 4, 1))!.body, 'written on the laptop');
      expect(outcome.remoteCursor.isAfter(DateTime(2020)), isTrue);
    });

    test('an old copy does not overwrite a newer edit', () async {
      final laptop = await _store();
      final phone = await _store();
      final secret = SyncCrypto.newKey();

      // Both have the same section id, but the laptop's is newer.
      final id = 'shared-section';
      final base = DateTime(2026, 4, 2, 10);
      phone.applyRemoteSection(
        DateTime(2026, 4, 2),
        NoteSection(
          id: id,
          createdAt: base,
          text: 'older',
          updatedAt: base,
        ),
      );
      laptop.applyRemoteSection(
        DateTime(2026, 4, 2),
        NoteSection(
          id: id,
          createdAt: base,
          text: 'newer',
          updatedAt: base.add(const Duration(minutes: 30)),
        ),
      );

      final laptopProtocol = SyncProtocol(store: laptop, deviceId: 'laptop');
      final phoneProtocol = SyncProtocol(store: phone, deviceId: 'phone');

      await phoneProtocol.run(_peer(secret: secret), (message) async {
        return laptopProtocol.handleRequest(message);
      });

      expect(phone.noteFor(DateTime(2026, 4, 2))!.body, 'newer');
    });

    test('a delete travels as a tombstone', () async {
      final laptop = await _store();
      final phone = await _store();
      final secret = SyncCrypto.newKey();

      laptop.appendToDay(DateTime(2026, 4, 3), 'to remove');
      await laptop.flush();
      final id = laptop.noteFor(DateTime(2026, 4, 3))!.sections.single.id;

      final laptopProtocol = SyncProtocol(store: laptop, deviceId: 'laptop');
      final phoneProtocol = SyncProtocol(store: phone, deviceId: 'phone');

      // First sync so the phone has it.
      await phoneProtocol.run(_peer(secret: secret), (message) async {
        return laptopProtocol.handleRequest(message);
      });
      expect(phone.hasNote(DateTime(2026, 4, 3)), isTrue);

      // Delete on the laptop, then sync again with a cursor from the last run.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      laptop.updateSection(DateTime(2026, 4, 3), id, '');
      await laptop.flush();

      await phoneProtocol.run(_peer(secret: secret), (message) async {
        return laptopProtocol.handleRequest(message);
      });

      expect(phone.hasNote(DateTime(2026, 4, 3)), isFalse);
    });

    test('a second sync with nothing new reports nothing changed', () async {
      final laptop = await _store();
      final phone = await _store();
      final secret = SyncCrypto.newKey();
      laptop.appendToDay(DateTime(2026, 4, 4), 'once');

      final laptopProtocol = SyncProtocol(store: laptop, deviceId: 'laptop');
      final phoneProtocol = SyncProtocol(store: phone, deviceId: 'phone');

      var peer = _peer(secret: secret);
      final first = await phoneProtocol.run(peer, (m) async {
        return laptopProtocol.handleRequest(m);
      });
      peer = peer.copyWith(
        remoteCursor: first.remoteCursor.millisecondsSinceEpoch,
        localCursor: first.localCursor.millisecondsSinceEpoch,
      );

      final second = await phoneProtocol.run(peer, (m) async {
        return laptopProtocol.handleRequest(m);
      });

      expect(second.received, 0);
      expect(second.sent, 0);
      expect(second.summary, contains('Already up to date'));
    });

    test('both devices can add without losing either note', () async {
      final laptop = await _store();
      final phone = await _store();
      final secret = SyncCrypto.newKey();

      laptop.appendToDay(DateTime(2026, 4, 5), 'laptop thought');
      phone.appendToDay(DateTime(2026, 4, 5), 'phone thought');

      final laptopProtocol = SyncProtocol(store: laptop, deviceId: 'laptop');
      final phoneProtocol = SyncProtocol(store: phone, deviceId: 'phone');

      await phoneProtocol.run(_peer(secret: secret), (m) async {
        return laptopProtocol.handleRequest(m);
      });
      // And the other direction, as the laptop syncing to the phone would do.
      await laptopProtocol.run(_peer(id: 'phone', secret: secret), (m) async {
        return phoneProtocol.handleRequest(m);
      });

      for (final store in [laptop, phone]) {
        final body = store.noteFor(DateTime(2026, 4, 5))!.body;
        expect(body, contains('laptop thought'));
        expect(body, contains('phone thought'));
      }
    });
  });

  group('transport', () {
    test('a sealed request crosses a real socket', () async {
      final laptop = await _store();
      final phone = await _store();
      final secret = SyncCrypto.newKey();

      laptop.appendToDay(DateTime(2026, 4, 6), 'over the wire');

      final peer = _peer(secret: secret);
      final laptopProtocol = SyncProtocol(store: laptop, deviceId: 'laptop');
      final phoneProtocol = SyncProtocol(store: phone, deviceId: 'phone');

      // Bind on an ephemeral port so the test never collides with the app.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      final subscription = server.listen((socket) async {
        final crypto = SyncCrypto(secret);
        // Read until the newline the client writes; the socket stays open for
        // the reply, so it cannot be read to completion.
        final buffer = <int>[];
        String? frame;
        await for (final chunk in socket) {
          buffer.addAll(chunk);
          final newline = buffer.indexOf(10);
          if (newline != -1) {
            frame = utf8.decode(buffer.sublist(0, newline));
            break;
          }
        }
        final request = await crypto.open(frame!);
        final reply = laptopProtocol.handleRequest(request!);
        socket.write('${await crypto.seal(reply)}\n');
        await socket.flush();
        await socket.close();
      });
      addTearDown(() async {
        await subscription.cancel();
        await server.close();
      });

      final reachable = peer.copyWith(port: port);
      final outcome = await phoneProtocol.run(reachable, (message) {
        return const LanSyncClient().send(reachable, message);
      });

      expect(outcome.received, 1);
      expect(phone.noteFor(DateTime(2026, 4, 6))!.body, 'over the wire');
    });

    test('an unreachable peer gives an actionable message', () async {
      // A valid local address with nothing listening: refusal, not a hang.
      final reserved = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = reserved.port;
      await reserved.close();

      final peer = _peer(secret: SyncCrypto.newKey()).copyWith(port: port);
      // Windows may refuse or silently drop, so either wording is acceptable;
      // what matters is that it becomes a message for a person, not a raw
      // SocketException.
      await expectLater(
        const LanSyncClient(timeout: Duration(seconds: 2))
            .send(peer, {'type': 'sync'}),
        throwsA(
          isA<SyncTransportException>().having(
            (e) => e.message,
            'message',
            isNotEmpty,
          ),
        ),
      );
    });
  });
}
