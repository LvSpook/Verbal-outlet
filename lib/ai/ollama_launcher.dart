/// Finds, starts, and installs Ollama on the desktop.
///
/// This is the "one click" part of local AI. The app never bundles a model
/// runtime; instead it looks for an Ollama the user already has, starts it if it
/// is installed but not running, and otherwise sends them to the official
/// installer. Once it is running, the model download is a single button in
/// settings.
///
/// Everything here is desktop-only and degrades to `false` on phones, where the
/// cloud path is used instead.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

const String _downloadPage = 'https://ollama.com/download';

/// Where Ollama usually installs, per platform.
List<String> _candidatePaths() {
  if (kIsWeb) return const [];
  if (Platform.isWindows) {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    return [
      if (localAppData != null) '$localAppData\\Programs\\Ollama\\ollama.exe',
      'C:\\Program Files\\Ollama\\ollama.exe',
    ];
  }
  if (Platform.isMacOS) {
    return [
      '/Applications/Ollama.app/Contents/Resources/ollama',
      '/usr/local/bin/ollama',
      '/opt/homebrew/bin/ollama',
    ];
  }
  if (Platform.isLinux) {
    return ['/usr/local/bin/ollama', '/usr/bin/ollama', '/bin/ollama'];
  }
  return const [];
}

/// The path to an installed Ollama, or null if there isn't one.
Future<String?> findOllama() async {
  if (kIsWeb) return null;

  for (final path in _candidatePaths()) {
    if (await File(path).exists()) return path;
  }

  // Fall back to PATH, which covers manual installs and package managers.
  try {
    final result = await Process.run(Platform.isWindows ? 'where' : 'which', [
      'ollama',
    ]);
    if (result.exitCode == 0) {
      final first = result.stdout
          .toString()
          .split(RegExp(r'\r?\n'))
          .map((line) => line.trim())
          .firstWhere((line) => line.isNotEmpty, orElse: () => '');
      if (first.isNotEmpty) return first;
    }
  } catch (_) {
    // `where`/`which` missing is not interesting; treat as "not installed".
  }

  return null;
}

/// Whether Ollama is installed on this machine.
Future<bool> isOllamaInstalled() async => await findOllama() != null;

/// Starts `ollama serve` in the background.
///
/// Returns true if a process was launched. It does not wait for the server to
/// answer — the caller polls `/api/tags` for that, because startup takes a
/// moment and blocking the UI on it would feel broken.
Future<bool> startOllamaServer() async {
  final path = await findOllama();
  if (path == null) return false;

  try {
    if (Platform.isWindows) {
      // `-WindowStyle Hidden` keeps the tray-less helper out of the way.
      await Process.start('powershell', [
        '-NoProfile',
        '-WindowStyle',
        'Hidden',
        '-Command',
        'Start-Process -FilePath "$path" -ArgumentList "serve" '
            '-WindowStyle Hidden',
      ], mode: ProcessStartMode.detached);
    } else {
      await Process.start(path, ['serve'], mode: ProcessStartMode.detached);
    }
    return true;
  } catch (_) {
    return false;
  }
}

/// Opens the official download page in the user's browser.
Future<bool> openOllamaDownloadPage() async {
  final uri = Uri.parse(_downloadPage);
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// Opens a URL for an arbitrary provider, e.g. an API key page.
Future<bool> openExternal(String url) async {
  try {
    return await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    return false;
  }
}
