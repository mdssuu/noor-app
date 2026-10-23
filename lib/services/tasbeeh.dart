import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_settings.dart';

/// One dhikr the counter remembers.
class Dhikr {
  const Dhikr(this.key, this.arabic, this.label, {this.roundOf = 33});

  final String key;

  /// The phrase itself, shown on the bead.
  final String arabic;

  /// The name the picker uses.
  final String label;

  /// How many beads make one complete round of this dhikr — 33 for the
  /// SubhanAllah/Alhamdulillah/Allahu Akbar set as the Prophet ﷺ taught
  /// counting on the fingers, and 0 for a dhikr counted without a fixed
  /// round (La ilaha illallah, Istighfar), where the ring shows progress
  /// toward a plain hundred instead.
  final int roundOf;
}

/// The set offered on the bead screen — the counting of the masjid, in the
/// order the tasbeeh itself usually carries them.
const List<Dhikr> kDhikr = <Dhikr>[
  Dhikr('subhanallah', 'سُبْحَانَ ٱللَّٰه', 'SubhanAllah', roundOf: 33),
  Dhikr('alhamdulillah', 'ٱلْحَمْدُ لِلَّٰه', 'Alhamdulillah', roundOf: 33),
  Dhikr('allahuakbar', 'ٱللَّٰهُ أَكْبَر', 'Allahu Akbar', roundOf: 33),
  Dhikr('tahlil', 'لَا إِلَٰهَ إِلَّا ٱللَّٰه', 'La ilaha illallah', roundOf: 99),
  Dhikr('istighfar', 'أَسْتَغْفِرُ ٱللَّٰه', 'Astaghfirullah', roundOf: 99),
];

Dhikr dhikrByKey(String key) => kDhikr.firstWhere(
      (Dhikr d) => d.key == key,
      orElse: () => kDhikr.first,
    );

/// The tasbeeh: a bead counter that remembers where it was.
///
/// Totals are kept per profile — two accounts sharing a phone do not share
/// each other's beads — and per dhikr, because a SubhanAllah count and an
/// Istighfar count are different numbers to the person keeping them. The
/// *today* count resets itself at midnight without losing the lifetime
/// total: the reset is derived from the stored date, never scheduled, so a
/// phone that was off overnight catches up on its next open.
class Tasbeeh extends ChangeNotifier {
  Tasbeeh._();

  static final Tasbeeh instance = Tasbeeh._();

  /// A fresh counter for tests: the singleton would carry its beads from
  /// one test into the next, which is exactly the bug the tests are for.
  @visibleForTesting
  Tasbeeh.test();

  static const String _kPrefix = 'tasbeeh::';
  static const String _kSelected = 'selected';

  SharedPreferences? _prefs;
  bool _loaded = false;

  bool get isLoaded => _loaded;

  /// Which dhikr is on the bead right now.
  String _selected = kDhikr.first.key;
  String get selectedKey => _selected;
  Dhikr get selected => dhikrByKey(_selected);

  /// dhikr key → lifetime beads counted.
  final Map<String, int> _totals = <String, int>{};

  /// dhikr key → beads counted since [today] began.
  final Map<String, int> _today = <String, int>{};

  /// The calendar day [today] counts belong to; `''` until loaded.
  String _todayStamp = '';

  /// Which round the next bead completes: 1…[Dhikr.roundOf].
  int get roundOf => selected.roundOf == 0 ? 100 : selected.roundOf;

  int totalOf(String key) => _totals[key] ?? 0;
  int todayOf(String key) => _today[key] ?? 0;

  /// Beads into the current round, 0…roundOf−1 — the ring's progress.
  int get inRound => roundOf == 0 ? 0 : todayOf(_selected) % roundOf;

  /// Rounds completed today for the selected dhikr.
  int get roundsToday => roundOf == 0 ? 0 : todayOf(_selected) ~/ roundOf;

  /// Adds one bead, rolling midnight over if the day has changed while the
  /// screen was closed. Returns true when this bead *completed a round* —
  /// the caller's cue to buzz the phone.
  bool tap() {
    final String key = _selected;
    _rollDay();
    final int before = _today[key] ?? 0;
    _today[key] = before + 1;
    _totals[key] = (_totals[key] ?? 0) + 1;
    notifyListeners();
    unawaited(_persist(key));
    final int round = roundOf;
    return round > 0 && (before + 1) % round == 0;
  }

  /// Puts the bead count back to zero for this dhikr — today's only; the
  /// lifetime total keeps every bead ever counted.
  void reset() {
    _rollDay();
    _today[_selected] = 0;
    notifyListeners();
    unawaited(_persist(_selected));
  }

  void select(String key) {
    if (!kDhikr.any((Dhikr d) => d.key == key)) return;
    _selected = key;
    notifyListeners();
    unawaited(_prefs?.setString(_scopeKey(_kSelected), key));
  }

  /// Midnight, derived rather than scheduled: a phone that was off between
  /// two days starts the new day's count at zero the moment it is opened,
  /// without a timer having had to run at midnight on a dead battery.
  void _rollDay() {
    final String stamp = _stamp(DateTime.now());
    if (stamp == _todayStamp) return;
    _todayStamp = stamp;
    _today.clear();
    unawaited(_persistAll());
  }

  static String _stamp(DateTime day) =>
      '${day.year}-${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  String _scopeKey(String base) =>
      '$base::${AppSettings.instance.activeProfileScope}';

  Future<void> load() async {
    try {
      final SharedPreferences prefs = _prefs = await SharedPreferences.getInstance();
      _rollDay();
      _selected = prefs.getString(_scopeKey(_kSelected)) ?? kDhikr.first.key;
      for (final Dhikr d in kDhikr) {
        _totals[d.key] = prefs.getInt(_scopeKey('$_kPrefix${d.key}')) ?? 0;
        _today[d.key] = prefs.getInt(_scopeKey('$_kPrefix${d.key}::$_todayStamp')) ?? 0;
      }
      _loaded = true;
    } catch (error) {
      debugPrint('Noor ▸ tasbeeh load failed: $error');
      _loaded = true;
    }
    notifyListeners();
  }

  Future<void> _persist(String key) async {
    final SharedPreferences? prefs = _prefs;
    if (prefs == null || !_loaded) return;
    try {
      await prefs.setInt(_scopeKey('$_kPrefix$key'), _totals[key] ?? 0);
      await prefs.setInt(
          _scopeKey('$_kPrefix$key::$_todayStamp'), _today[key] ?? 0);
    } catch (error) {
      debugPrint('Noor ▸ tasbeeh save failed: $error');
    }
  }

  Future<void> _persistAll() async {
    for (final Dhikr d in kDhikr) {
      await _persist(d.key);
    }
  }
}
