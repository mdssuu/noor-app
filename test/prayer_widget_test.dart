import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/services/prayer_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The picture the home-screen widget is fed — the structure the Kotlin
/// side reads field by field, so a rename on either side has to show up
/// here first.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.instance.load();
  });

  final Map<String, Object?> payload = PrayerWidget.buildPayload(
    latitude: 19.0760,
    longitude: 72.8777,
    areaName: 'Kurla',
    now: DateTime(2026, 10, 12, 10, 30),
    hijriAdjustment: 0,
  );

  group('the prepared picture', () {
    test('carries the place and both calendars', () {
      expect(payload['city'], 'Kurla');
      expect(payload['dateLabel'], 'Mon, 12 Oct');
      expect(payload['hijri'], isNot(isEmpty),
          reason: 'the Hijri line is a headline field, not optional');
    });

    test('lists today’s six times, labelled for a human', () {
      final List<Map<String, Object?>> prayers =
          (payload['prayers']! as List).cast<Map<String, Object?>>();
      expect(prayers, hasLength(6));
      expect(prayers.first['label'], 'Fajr');
      expect(prayers.last['label'], 'Isha');
      // Sunrise is not one of the five — the widget must not present it as
      // a prayer to be offered, only as the light coming up.
      expect(
        prayers.where((Map<String, Object?> p) => p['label'] == 'Sunrise'),
        hasLength(1),
      );
      for (final Map<String, Object?> p in prayers) {
        expect(p['time'], isNot(isEmpty), reason: '${p['label']} needs a clock');
      }
    });

    test('the transition table runs two days, ascending', () {
      final List<Map<String, Object?>> transitions =
          (payload['transitions']! as List).cast<Map<String, Object?>>();
      expect(transitions, hasLength(10), reason: 'five prayers × two days');
      expect(transitions.first['label'], 'Fajr');
      expect(transitions[5]['label'], 'Fajr', reason: 'tomorrow starts over');

      int previous = 0;
      for (final Map<String, Object?> t in transitions) {
        final int at = t['atMs']! as int;
        expect(at, greaterThan(previous), reason: 'instants must ascend');
        previous = at;
        expect(t['time'], isNot(isEmpty));
      }
    });

    test('survives the trip across the channel as JSON', () {
      final String wire = jsonEncode(payload);
      final Map<String, Object?> back =
          (jsonDecode(wire) as Map).cast<String, Object?>();
      expect(back['city'], 'Kurla');
      expect((back['transitions']! as List), hasLength(10));
    });
  });

  test('tomorrow’s Fajr is in the table tonight', () {
    // At 23:30 every of *today's* entries is behind the clock — without
    // tomorrow's copy the widget would have nothing true left to say.
    final Map<String, Object?> late = PrayerWidget.buildPayload(
      latitude: 19.0760,
      longitude: 72.8777,
      areaName: 'Kurla',
      now: DateTime(2026, 10, 12, 23, 30),
    );
    final List<Map<String, Object?>> transitions =
        (late['transitions']! as List).cast<Map<String, Object?>>();
    final int now = DateTime(2026, 10, 12, 23, 30).millisecondsSinceEpoch;
    expect(
      transitions.where((Map<String, Object?> t) => (t['atMs']! as int) > now),
      isNotEmpty,
      reason: 'something must still be ahead of the clock',
    );
  });
}
