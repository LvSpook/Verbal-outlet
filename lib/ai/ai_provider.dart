/// The AI side of Verbal Outlet: one small interface, two kinds of provider.
///
/// * **Local** — a model running on the user's own machine, reached over
///   Ollama's HTTP API at `127.0.0.1:11434`. Nothing leaves the computer.
/// * **Cloud** — an API key against an OpenAI-compatible endpoint, which is what
///   phones use because they cannot run a capable model locally.
///
/// Both speak the same [AiProvider] interface, so the chat UI never knows which
/// one is answering. That also keeps the door open for a bundled on-device model
/// later: it would be one more implementation of the same interface.
library;

/// A message in a conversation.
class AiMessage {
  const AiMessage({required this.role, required this.text});

  const AiMessage.user(this.text) : role = AiRole.user;
  const AiMessage.assistant(this.text) : role = AiRole.assistant;

  final AiRole role;
  final String text;

  Map<String, dynamic> toJson() => {'role': role.wire, 'content': text};
}

enum AiRole {
  system('system'),
  user('user'),
  assistant('assistant');

  const AiRole(this.wire);

  /// The name both Ollama and OpenAI-compatible APIs expect on the wire.
  final String wire;
}

/// One piece of a reply as it arrives.
///
/// The first chunk carries no text for some providers, just a signal that
/// generation started; that is reported as [AiChunk.first].
class AiChunk {
  const AiChunk.token(this.text) : done = false;
  const AiChunk.first() : text = '', done = false;
  const AiChunk.finished() : text = '', done = true;

  final String text;
  final bool done;
}

/// Something that can answer a conversation.
abstract interface class AiProvider {
  /// Short name for the UI, e.g. "Ollama" or "OpenAI".
  String get name;

  /// The model identifier in use, e.g. "qwen3:4b".
  String get model;

  /// Whether this provider is reachable and usable right now.
  Future<bool> isAvailable();

  /// Streams a reply to [messages].
  ///
  /// Emits partial text as it is generated so the UI can render it live, then
  /// a final [AiChunk.finished]. Throws [AiException] on failure.
  Stream<AiChunk> chat(List<AiMessage> messages);

  /// Releases any resources. Safe to call more than once.
  Future<void> dispose();
}

/// A failure the UI can show to the user as-is.
class AiException implements Exception {
  const AiException(this.message, {this.hint});

  /// What went wrong, in plain language.
  final String message;

  /// What the user can do about it, when there is something.
  final String? hint;

  @override
  String toString() => message;
}
