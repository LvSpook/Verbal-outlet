/// Where AI choices are remembered between launches.
///
/// Preferences (which engine, which model, which base URL) live in normal
/// shared preferences. The API key does not: it goes to the platform's secure
/// store, which is Keychain on iOS/macOS, the Keystore on Android, and the
/// equivalent protected store on desktop.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which kind of AI the app should use.
enum AiEngineKind {
  /// A model on this machine, reached through Ollama.
  local,

  /// A hosted model with the user's API key.
  cloud,
}

/// The saved configuration for the AI features.
class AiSettings {
  const AiSettings({
    this.engine = AiEngineKind.local,
    this.localModel = defaultLocalModel,
    this.localBaseUrl = 'http://127.0.0.1:11434',
    this.cloudBaseUrl = 'https://api.openai.com/v1',
    this.cloudModel = 'gpt-4o-mini',
    this.cloudName = 'OpenAI',
    this.hasApiKey = false,
  });

  /// A 4B-class model: the sweet spot for a laptop. Small enough to stay quick
  /// and light, capable enough to answer questions about a diary entry and to
  /// describe a chart. Users can switch it in settings.
  static const String defaultLocalModel = 'qwen3:4b';

  final AiEngineKind engine;
  final String localModel;
  final String localBaseUrl;
  final String cloudBaseUrl;
  final String cloudModel;

  /// Provider label shown in the UI, e.g. "OpenAI".
  final String cloudName;

  /// Whether a key exists in secure storage. The key itself is never held in
  /// this object.
  final bool hasApiKey;

  AiSettings copyWith({
    AiEngineKind? engine,
    String? localModel,
    String? localBaseUrl,
    String? cloudBaseUrl,
    String? cloudModel,
    String? cloudName,
    bool? hasApiKey,
  }) {
    return AiSettings(
      engine: engine ?? this.engine,
      localModel: localModel ?? this.localModel,
      localBaseUrl: localBaseUrl ?? this.localBaseUrl,
      cloudBaseUrl: cloudBaseUrl ?? this.cloudBaseUrl,
      cloudModel: cloudModel ?? this.cloudModel,
      cloudName: cloudName ?? this.cloudName,
      hasApiKey: hasApiKey ?? this.hasApiKey,
    );
  }
}

/// Reads and writes [AiSettings], keeping the key out of shared preferences.
class AiSettingsStore {
  // `preferences` is a test seam: production code lets the store open its own.
  // ignore: prefer_initializing_formals
  AiSettingsStore({FlutterSecureStorage? secureStorage})
    : _secureStorage =
          secureStorage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
          );

  static const String _keyEngine = 'ai.engine';
  static const String _keyLocalModel = 'ai.localModel';
  static const String _keyLocalBaseUrl = 'ai.localBaseUrl';
  static const String _keyCloudBaseUrl = 'ai.cloudBaseUrl';
  static const String _keyCloudModel = 'ai.cloudModel';
  static const String _keyCloudName = 'ai.cloudName';
  static const String _keyApiKey = 'ai.apiKey';

  SharedPreferences? _preferences;
  final FlutterSecureStorage _secureStorage;

  Future<SharedPreferences> get _prefs async =>
      _preferences ??= await SharedPreferences.getInstance();

  Future<AiSettings> load() async {
    final prefs = await _prefs;
    final engine = prefs.getString(_keyEngine) == 'cloud'
        ? AiEngineKind.cloud
        : AiEngineKind.local;

    String? apiKey;
    try {
      // Bounded: a locked key store, or a platform channel that never answers,
      // must not block the rest of the app. Worst case the user is asked for
      // the key again.
      apiKey = await _secureStorage
          .read(key: _keyApiKey)
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // A locked or unavailable key store should not break the app; the user
      // just sees "no key" and can re-enter it.
      apiKey = null;
    }

    return AiSettings(
      engine: engine,
      localModel:
          prefs.getString(_keyLocalModel) ?? AiSettings.defaultLocalModel,
      localBaseUrl:
          prefs.getString(_keyLocalBaseUrl) ?? 'http://127.0.0.1:11434',
      cloudBaseUrl:
          prefs.getString(_keyCloudBaseUrl) ?? 'https://api.openai.com/v1',
      cloudModel: prefs.getString(_keyCloudModel) ?? 'gpt-4o-mini',
      cloudName: prefs.getString(_keyCloudName) ?? 'OpenAI',
      hasApiKey: apiKey != null && apiKey.trim().isNotEmpty,
    );
  }

  Future<void> save(AiSettings settings) async {
    final prefs = await _prefs;
    await prefs.setString(
      _keyEngine,
      settings.engine == AiEngineKind.cloud ? 'cloud' : 'local',
    );
    await prefs.setString(_keyLocalModel, settings.localModel);
    await prefs.setString(_keyLocalBaseUrl, settings.localBaseUrl);
    await prefs.setString(_keyCloudBaseUrl, settings.cloudBaseUrl);
    await prefs.setString(_keyCloudModel, settings.cloudModel);
    await prefs.setString(_keyCloudName, settings.cloudName);
  }

  Future<String?> readApiKey() async {
    try {
      return await _secureStorage.read(key: _keyApiKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveApiKey(String key) async {
    if (key.trim().isEmpty) {
      await _secureStorage.delete(key: _keyApiKey);
    } else {
      await _secureStorage.write(key: _keyApiKey, value: key.trim());
    }
  }

  Future<void> clearApiKey() => _secureStorage.delete(key: _keyApiKey);
}
