/// Local AI through Ollama.
///
/// Ollama runs models on the user's machine and serves them over HTTP on
/// localhost. Using it instead of bundling a runtime keeps this app small and
/// means the user gets a model that can be swapped, upgraded, or already exists
/// on their disk. Notes never leave the computer.
///
/// Everything here talks to the documented API (`/api/chat`, `/api/pull`,
/// `/api/tags`), so it works against any Ollama version from the last few years.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_provider.dart';

/// The default address Ollama serves on.
const String ollamaDefaultBaseUrl = 'http://127.0.0.1:11434';

/// Progress of a model download, so the UI can show a real bar instead of a
/// spinner that might mean "nothing is happening".
class PullProgress {
  const PullProgress({required this.status, this.fraction});

  /// Ollama's own phase text, e.g. "pulling manifest" or "downloading".
  final String status;

  /// 0..1 when the byte counts are known, else null (manifest, verifying...).
  final double? fraction;
}

/// An [AiProvider] backed by a local Ollama server.
class OllamaProvider implements AiProvider {
  OllamaProvider({
    this.baseUrl = ollamaDefaultBaseUrl,
    this.model = 'qwen3:4b',
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  @override
  final String model;

  final http.Client _client;

  @override
  String get name => 'Ollama';

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  @override
  Future<bool> isAvailable() async {
    try {
      final response = await _client
          .get(_uri('/api/tags'))
          .timeout(const Duration(seconds: 3));
      return response.statusCode == 200;
    } catch (_) {
      // Connection refused simply means Ollama is not running.
      return false;
    }
  }

  /// Models already downloaded on this machine, newest first from Ollama.
  Future<List<String>> installedModels() async {
    try {
      final response = await _client
          .get(_uri('/api/tags'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return const [];
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final models = body['models'] as List<dynamic>? ?? const [];
      return [
        for (final entry in models)
          if (entry is Map<String, dynamic> && entry['name'] is String)
            entry['name'] as String,
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Whether [name] is present locally, tolerating the `:latest` suffix Ollama
  /// adds to untagged names.
  Future<bool> hasModel([String? name]) async {
    final wanted = (name ?? model).toLowerCase();
    for (final installed in await installedModels()) {
      final candidate = installed.toLowerCase();
      if (candidate == wanted) return true;
      if ('$candidate:latest' == wanted || candidate == '$wanted:latest') {
        return true;
      }
    }
    return false;
  }

  /// Downloads [name] (defaults to [model]), reporting progress as it goes.
  ///
  /// Ollama streams newline-delimited JSON: each line is a status update with
  /// `completed`/`total` bytes while downloading.
  Stream<PullProgress> pull([String? name]) async* {
    final request = http.Request('POST', _uri('/api/pull'))
      ..headers['content-type'] = 'application/json'
      ..body = jsonEncode({'model': name ?? model, 'stream': true});

    final response = await _client.send(request);
    if (response.statusCode != 200) {
      throw AiException(
        'Ollama refused the download (HTTP ${response.statusCode}).',
        hint: 'Check that Ollama is up to date, then try again.',
      );
    }

    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      Map<String, dynamic> json;
      try {
        json = jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }

      // Ollama reports failures inside the stream, not as an HTTP error.
      final error = json['error'];
      if (error is String && error.isNotEmpty) {
        throw AiException(
          'Could not download $model: $error',
          hint:
              'Check the model name, and that you have disk space and a '
              'working connection.',
        );
      }

      final status = json['status'] as String? ?? '';
      final total = json['total'];
      final completed = json['completed'];
      double? fraction;
      if (total is int && completed is int && total > 0) {
        fraction = completed / total;
      }
      yield PullProgress(status: status, fraction: fraction);

      if (status == 'success') return;
    }
  }

  @override
  Stream<AiChunk> chat(List<AiMessage> messages) async* {
    final request = http.Request('POST', _uri('/api/chat'))
      ..headers['content-type'] = 'application/json'
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
        'Could not reach the local model.',
        hint: 'Start Ollama, then try again. On Windows it runs in the tray.',
      );
    }

    if (response.statusCode == 404) {
      throw AiException(
        'The model "$model" is not installed yet.',
        hint: 'Download it from AI settings, then try again.',
      );
    }
    if (response.statusCode != 200) {
      throw AiException(
        'The local model failed (HTTP ${response.statusCode}).',
      );
    }

    var emitted = false;
    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      Map<String, dynamic> json;
      try {
        json = jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }

      final error = json['error'];
      if (error is String && error.isNotEmpty) {
        throw AiException('The local model stopped: $error');
      }

      final message = json['message'];
      if (message is Map<String, dynamic>) {
        // `thinking` models emit a reasoning trace before the answer; it is
        // deliberately not shown, so only `content` is surfaced.
        final content = message['content'];
        if (content is String && content.isNotEmpty) {
          if (!emitted) {
            yield const AiChunk.first();
            emitted = true;
          }
          yield AiChunk.token(content);
        }
      }

      if (json['done'] == true) break;
    }

    if (!emitted) {
      throw const AiException(
        'The model returned nothing. Try rephrasing, or a different model.',
      );
    }
    yield const AiChunk.finished();
  }

  @override
  Future<void> dispose() async => _client.close();
}
