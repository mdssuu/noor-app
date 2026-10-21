import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hijri/hijri_calendar.dart';
import 'package:intl/intl.dart';

import '../app_settings.dart';
import 'islamic_calendar.dart';

/// What the home-screen widget is fed and when.
///
/// The widget cannot run Dart: an `AppWidgetProvider` is plain Kotlin, and
/// prayer times come out of an engine that only the app process can host.
/// So the app hands the platform side a *prepared* picture — today's times,
/// and a table of the next few prayer instants with their wall-clock
/// labels — and the provider picks whichever entry the phone's own clock
/// says is next whenever it redraws. That is what keeps the widget honest
/// for a day or two of the phone being closed, instead of freezing on
/// whatever "next" meant at the last app open.
class PrayerWidget {
  PrayerWidget._();

  static const MethodChannel _channel =
      MethodChannel('noor_masjid_time/widget');

  /// How many prayer instants the table carries: the rest of today plus all
  /// of tomorrow, which is two days of truth for one small message.
  static const int transitionDays = 2;

  /// The prepared picture, as JSON the Kotlin side reads. Pure — the test
  /// suite drives it with a hand-built day.
  ///
  /// [now] only decides which calendar day to prepare from; the table
  /// itself always starts at today's remaining prayers and runs forward.
  static Map<String, Object?> buildPayload({
    required double latitude,
    required double longitude,
    required String areaName,
    DateTime? now,
    int hijriAdjustment = 0,
  }) {
    final AppSettings settings = AppSettings.instance;
    final DateTime today = now ?? DateTime.now();

    final List<Map<String, Object?>> transitions = <Map<String, Object?>>[];
    final List<Map<String, Object?>> prayers = <Map<String, Object?>>[];

    for (int dayOffset = 0; dayOffset < transitionDays; dayOffset++) {
      final DateTime day = DateTime(today.year, today.month, today.day)
          .add(Duration(days: dayOffset));
      final LocalPrayerTimes times = settings.compute(
        latitude: latitude,
        longitude: longitude,
        day: day,
      );

      if (dayOffset == 0) {
        for (final String key in <String>[
          'fajr', 'sunrise', 'dhuhr', 'asr', 'maghrib', 'isha',
        ]) {
          final DateTime? at = times.times[key];
          if (at == null) continue;
          prayers.add(<String, Object?>{
            'label': _labelFor(key),
            'time': settings.format(at),
          });
        }
      }

      for (final String key in <String>['fajr', 'dhuhr', 'asr', 'maghrib', 'isha']) {
        final DateTime? at = times.times[key];
        if (at == null) continue;
        transitions.add(<String, Object?>{
          'atMs': at.millisecondsSinceEpoch,
          'label': _labelFor(key),
          'time': settings.format(at),
        });
      }
    }

    String hijri = '';
    try {
      final HijriCalendar h =
          NoorHijri.hijriOf(today, adjustment: hijriAdjustment);
      hijri = '${h.hDay} ${h.getLongMonthName()} ${h.hYear}';
    } catch (_) {}

    return <String, Object?>{
      'city': areaName.trim(),
      'hijri': hijri,
      'dateLabel': DateFormat('EEE, d MMM').format(today),
      'prayers': prayers,
      'transitions': transitions,
    };
  }

  static String _labelFor(String key) {
    switch (key) {
      case 'sunrise':
        return 'Sunrise';
      case 'fajr':
        return 'Fajr';
      case 'dhuhr':
        return 'Dhuhr';
      case 'asr':
        return 'Asr';
      case 'maghrib':
        return 'Maghrib';
      case 'isha':
        return 'Isha';
      default:
        return key;
    }
  }

  /// Pushes the picture to every widget on the home screens.
  ///
  /// The payload crosses the channel as one JSON string rather than a
  /// typed map: the platform codec hands Kotlin nested `HashMap`s and
  /// `ArrayList`s that then have to be re-serialised by hand, while a
  /// string round-trips untouched — and the Kotlin side parses it with
  /// `org.json`, which is already in the box.
  ///
  /// Every failure is swallowed: a widget that misses one refresh is a
  /// widget that is a few hours stale, and the alternative — an exception
  /// escaping into the resume path — takes the whole app down over a
  /// decoration.
  static Future<void> push({
    required double latitude,
    required double longitude,
    required String areaName,
  }) async {
    try {
      final Map<String, Object?> payload = buildPayload(
        latitude: latitude,
        longitude: longitude,
        areaName: areaName,
        hijriAdjustment: AppSettings.instance.hijriAdjustment,
      );
      await _channel.invokeMethod<void>('update', jsonEncode(payload));
      debugPrint('Noor ▸ widget picture handed over');
    } on MissingPluginException catch (error) {
      // Not Android — no home-screen widgets to feed. Said out loud anyway:
      // a silently missing channel looks exactly like a hang upstream.
      debugPrint('Noor ▸ widget channel absent: $error');
    } catch (error) {
      debugPrint('Noor ▸ widget push failed: $error');
    }
  }
}
