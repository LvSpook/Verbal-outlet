/// A month, looked back on.
///
/// One of these is stored per month that has notes, and shown under the
/// calendar. It is regenerated only when the month's notes change, so opening
/// the calendar does not quietly spend a model call every time.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One AI-written overview of a month's notes.
class MonthlyInsight {
  const MonthlyInsight({
    required this.year,
    required this.month,
    required this.body,
    required this.generatedAt,
    required this.revision,
  });

  final int year;
  final int month;

  /// Markdown, parsed by the entry view: a heading, a short summary, bullets,
  /// and optionally a diagram or chart.
  final String body;

  final DateTime generatedAt;

  /// A fingerprint of the notes this was written from. When the notes change,
  /// the fingerprint changes and the overview is stale.
  final String revision;

  String get key => monthKey(year, month);

  bool isStaleFor(String currentRevision) => revision != currentRevision;

  Map<String, dynamic> toJson() => {
    'year': year,
    'month': month,
    'body': body,
    'generatedAt': generatedAt.millisecondsSinceEpoch,
    'revision': revision,
  };

  static MonthlyInsight? fromJson(Map<String, dynamic> json) {
    final body = json['body'];
    if (body is! String || body.trim().isEmpty) return null;
    return MonthlyInsight(
      year: (json['year'] as num).toInt(),
      month: (json['month'] as num).toInt(),
      body: body,
      generatedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['generatedAt'] as num?)?.toInt() ?? 0,
      ),
      revision: json['revision'] as String? ?? '',
    );
  }
}

/// The stable identifier for a month, e.g. `2026-04`.
String monthKey(int year, int month) =>
    '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}';

/// Where monthly overviews are cached.
///
/// Shared preferences rather than the notes database: these are small strings,
/// derived data that can always be regenerated, and losing them costs a model
/// call rather than a note. Keeping them out of the note tables also means the
/// export and sync formats are untouched.
class MonthlyInsightStore {
  static const String _prefix = 'insights.month.';

  SharedPreferences? _preferences;

  Future<SharedPreferences> get _prefs async =>
      _preferences ??= await SharedPreferences.getInstance();

  /// The saved overview for a month, or null if there is none.
  Future<MonthlyInsight?> read(int year, int month) async {
    try {
      final raw = (await _prefs).getString('$_prefix${monthKey(year, month)}');
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return MonthlyInsight.fromJson(decoded);
    } catch (error) {
      debugPrint('Reading a monthly overview failed: $error');
      return null;
    }
  }

  Future<void> write(MonthlyInsight insight) async {
    try {
      await (await _prefs).setString(
        '$_prefix${insight.key}',
        jsonEncode(insight.toJson()),
      );
    } catch (error) {
      debugPrint('Saving a monthly overview failed: $error');
    }
  }

  Future<void> delete(int year, int month) async {
    try {
      await (await _prefs).remove('$_prefix${monthKey(year, month)}');
    } catch (_) {
      // There is nothing to recover: the next read just finds nothing.
    }
  }
}
