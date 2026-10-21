import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_settings.dart';

/// The salah log: which of the five prayers a day has been offered, and how
/// long the chain of complete days has run.
///
/// The record is personal and local — it never leaves the phone, needs no
/// account, and is scoped per profile so a second account on the same
/// handset starts its own chain. One key holds the whole log as JSON rather
/// than one preference per day: a year of entries is a few kilobytes, and a
/// single read at load beats 365 `getString` calls on every cold start.
class PrayerTracker extends ChangeNotifier {
  PrayerTracker._();

  static final PrayerTracker instance = PrayerTracker._();

  /// A fresh log for tests — see the note on `Tasbeeh.test`.
  @visibleForTesting
  PrayerTracker.test();

  static const String _kLog = 'prayer_log_v1';
  static const int _kRetainDays = 730;

  SharedPreferences? _prefs;
  bool _loaded = false;

  bool get isLoaded => _loaded;

  /// `'yyyy-MM-dd'` → the prayer keys offered that day.
  final Map<String, Set<String>> _log = <String, Set<String>>{};

  // ------------------------------------------------------------- reading

  static String stamp(DateTime day) =>
      '${day.year}-${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  static DateTime dayOf(String stamp) {
    final List<String> parts = stamp.split('-');
    if (parts.length != 3) return DateTime.now();
    return DateTime(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
  }

  /// The prayers offered on [day]; empty for a day nothing was logged.
  Set<String> day(DateTime day) =>
      Set<String>.of(_log[stamp(day)] ?? const <String>{});

  bool isPrayed(DateTime day, String prayer) =>
      _log[stamp(day)]?.contains(prayer) ?? false;

  /// A "complete" day is one where all five were offered — the definition
  /// every streak in this file counts by, and the one the UI spells out
  /// under the number so nobody has to guess.
  static bool isComplete(Set<String> prayed) => prayed.length >= 5;

  /// Consecutive complete days ending today — or ending *yesterday* when
  /// today's prayers have not all been offered yet, so the chain does not
  /// read as broken at 6 a.m. before Fajr has even come in.
  int get streak => streakOf(_log, today: DateTime.now());

  /// Pure streak arithmetic, lifted out of the class so the rule can be
  /// tested against logs that would take a year to build by hand.
  static int streakOf(Map<String, Set<String>> log, {DateTime? today}) {
    final DateTime now = today ?? DateTime.now();
    DateTime cursor = DateTime(now.year, now.month, now.day);

    // Today only counts once it is complete; otherwise the chain is measured
    // from yesterday and today is still a chance to extend it.
    if (!isComplete(log[stamp(cursor)] ?? const <String>{})) {
      cursor = cursor.subtract(const Duration(days: 1));
    }

    int run = 0;
    while (isComplete(log[stamp(cursor)] ?? const <String>{})) {
      run++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return run;
  }

  /// What one month of logging adds up to — the numbers under the grid.
  MonthSummary monthOf(DateTime anchor) =>
      monthSummary(_log, year: anchor.year, month: anchor.month, today: anchor);

  static MonthSummary monthSummary(
    Map<String, Set<String>> log, {
    required int year,
    required int month,
    DateTime? today,
  }) {
    final DateTime first = DateTime(year, month, 1);
    final DateTime nextMonth = DateTime(year, month + 1, 1);
    final DateTime cutoff = today ?? DateTime.now();

    int days = 0;
    int complete = 0;
    final Map<String, int> perPrayer = <String, int>{};
    for (DateTime day = first;
        day.isBefore(nextMonth);
        day = day.add(const Duration(days: 1))) {
      if (day.isAfter(cutoff)) break;
      final Set<String> prayed = log[stamp(day)] ?? const <String>{};
      if (prayed.isEmpty) continue;
      days++;
      if (isComplete(prayed)) complete++;
      for (final String key in prayed) {
        perPrayer[key] = (perPrayer[key] ?? 0) + 1;
      }
    }
    return MonthSummary(
      year: year,
      month: month,
      daysLogged: days,
      daysComplete: complete,
      perPrayer: Map<String, int>.unmodifiable(perPrayer),
    );
  }

  // ------------------------------------------------------------- writing

  /// Offers or takes back one prayer on one day.
  void toggle(DateTime day, String prayer) {
    final String key = stamp(day);
    final Set<String> prayed = _log[key] ?? <String>{};
    if (!prayed.add(prayer)) {
      prayed.remove(prayer);
    }
    if (prayed.isEmpty) {
      _log.remove(key);
    } else {
      _log[key] = prayed;
    }
    notifyListeners();
    unawaited(_persist());
  }

  /// Fills today's row in one tap — "I prayed all five", for the majority
  /// of days that are simply *done* and deserve a checkmark without five.
  void markTodayComplete() {
    final DateTime now = DateTime.now();
    for (final String prayer in kNotifiablePrayers) {
      _log.putIfAbsent(stamp(now), () => <String>{}).add(prayer);
    }
    notifyListeners();
    unawaited(_persist());
  }

  Future<void> load() async {
    try {
      final SharedPreferences prefs =
          _prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_scopedKey());
      if (raw != null && raw.isNotEmpty) {
        final Object? decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          for (final MapEntry<String, dynamic> e in decoded.entries) {
            if (e.value is List) {
              _log[e.key] = Set<String>.of((e.value as List).cast<String>());
            }
          }
        }
      }
      _loaded = true;
    } catch (error) {
      debugPrint('Noor ▸ prayer log load failed: $error');
      _loaded = true;
    }
    notifyListeners();
  }

  String _scopedKey() => '$_kLog::${AppSettings.instance.activeProfileScope}';

  Future<void> _persist() async {
    final SharedPreferences? prefs = _prefs;
    if (prefs == null || !_loaded) return;
    try {
      await prefs.setString(_scopedKey(), _encode());
    } catch (error) {
      debugPrint('Noor ▸ prayer log save failed: $error');
    }
  }

  @visibleForTesting
  String encodeForTest() => _encode();

  /// The whole log as JSON, oldest days first and past [_kRetainDays]
  /// dropped: two years is a generous memory, and an unbounded map is how a
  /// local-only preference grows into something a cold start notices.
  String _encode() {
    final List<String> keys = _log.keys.toList()..sort();
    final DateTime cutoff = DateTime.now().subtract(const Duration(days: _kRetainDays));
    final Map<String, List<String>> out = <String, List<String>>{};
    for (final String key in keys) {
      if (dayOf(key).isBefore(cutoff)) continue;
      out[key] = _log[key]!.toList()..sort();
    }
    return jsonEncode(out);
  }
}

/// One month's totals, ready for the header of the calendar grid.
class MonthSummary {
  const MonthSummary({
    required this.year,
    required this.month,
    required this.daysLogged,
    required this.daysComplete,
    required this.perPrayer,
  });

  final int year;
  final int month;

  /// Days with at least one prayer offered.
  final int daysLogged;

  /// Days where all five were offered.
  final int daysComplete;

  /// prayer key → how many times it was offered this month.
  final Map<String, int> perPrayer;
}
