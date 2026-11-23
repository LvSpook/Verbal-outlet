/// Cloud AI through an OpenAI-compatible API.
///
/// This is the path for phones: they cannot run a capable model locally, so the
/// app talks to a hosted model with the user's own API key. OpenAI-compatible
/// is the right target because the major providers expose that shape, so one
/// implementation covers several of them by changing the base URL.
///
/// The key is read from secure storage and never logged or written to a plain
/// settings file.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_provider.dart';

/// A hosted model reachable through the OpenAI chat-completions API.
class CloudProvider implements AiProvider {
  CloudProvider({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.displayName = 'Cloud',
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// Base URL including the version path, e.g.
  /// `https://api.openai.com/v1`.
  final String baseUrl;
  final String apiKey;
  @override
  final String model;

  final String displayName;
  final http.Client _client;

  @override
  String get name => displayName;

  Uri get _chatUri =>
      Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions');

  @override
  Future<bool> isAvailable() async => apiKey.trim().isNotEmpty;

  @override
  Stream<AiChunk> chat(List<AiMessage> messages) async* {
    if (apiKey.trim().isEmpty) {
      throw const AiException(
        'No API key saved.',
        hint: 'Add a key in AI settings.',
      );
    }

    final request = http.Request('POST', _chatUri)
      ..headers['content-type'] = 'application/json'
      ..headers['authorization'] = 'Bearer $apiKey'
      ..body = jsonEncode({
        'model': model,
        'messages': [for (final message in messages) message.toJson()],
        'stream': true,
      });

    http.StreamedResponse response;
    try {
      response = await _client.send(request);
    } catch (_) {
      throw const AiException(
        'Could not reach the AI provider.',
        hint: 'Check your internet connection.',
      );
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const AiException(
        'The API key was rejected.',
        hint:
            'Check the key in AI settings — it may have been revoked or '
            'copied incompletely.',
      );
    }
    if (response.statusCode == 429) {
      throw const AiException(
        'Rate limited or out of credit.',
        hint: 'Wait a moment, or check your provider account.',
      );
    }
    if (response.statusCode != 200) {
      // Read the body: providers put the real reason in an error object.
      final body = await response.stream.bytesToString();
      throw AiException(_describeError(response.statusCode, body));
    }

    var emitted = false;
    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || !trimmed.startsWith('data:')) continue;
      final payload = trimmed.substring(5).trim();
      if (payload == '[DONE]') break;

      Map<String, dynamic> json;
      try {
        json = jsonDecode(payload) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }

      final choices = json['choices'];
      if (choices is! List || choices.isEmpty) continue;
      final delta = (choices.first as Map<String, dynamic>)['delta'];
      if (delta is! Map<String, dynamic>) continue;
      final content = delta['content'];
      if (content is String && content.isNotEmpty) {
        if (!emitted) {
          yield const AiChunk.first();
          emitted = true;
        }
        yield AiChunk.token(content);
      }
    }

    if (!emitted) {
      throw const AiException('The model returned nothing. Try rephrasing.');
    }
    yield const AiChunk.finished();
  }

  /// Turns a provider error body into something a person can act on.
  String _describeError(int status, String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map<String, dynamic>) {
        final error = json['error'];
        if (error is Map<String, dynamic> && error['message'] is String) {
          return 'The provider refused the request: ${error['message']}';
        }
        if (error is String) return 'The provider refused the request: $error';
      }
    } catch (_) {
      // Fall through to the generic message.
    }
    return 'The provider failed (HTTP $status).';
  }

  @override
  Future<void> dispose() async => _client.close();
}
