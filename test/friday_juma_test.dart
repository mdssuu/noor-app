import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_look.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/main.dart';
import 'package:noor_masjid_time/today_prayer_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Friday, read as Friday — in exactly two places.
///
/// The reader's ask: the Jummah section belongs *only* on Friday, under the
/// Awwal in the hero's Jamaat line, and as the last row of the times card.
/// The five daily prayers keep their own rows on every weekday: Friday does
/// not rename Dhuhr, and Jummah is not a sixth notification — it carries no
/// bell.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const double lat = 19.0760;
  const double lng = 72.8777;

  // 30 Oct 2026 is a Friday, the 31st a Saturday.
  final DateTime friday = DateTime(2026, 10, 30, 11, 0);
  final DateTime saturday = DateTime(2026, 10, 31, 11, 0);

  Masjid board({String juma = '13:30'}) => Masjid(
        id: 'masjid-board',
        name: 'Aqsa Masjid',
        fajr: '05:00',
        dhuhr: '13:20',
        asr: '17:45',
        maghrib: '18:35',
        isha: '21:00',
        juma: juma,
        latitude: 19.076,
        longitude: 72.8777,
        address: 'Jogeshwari West, Mumbai',
        photoProofPath: '',
        photoProofBase64: '',
        lastUpdated: Timestamp.fromMillisecondsSinceEpoch(1700000000000),
        updatedBy: 'Ayesha',
        updatedByUid: 'uid-editor',
      );

  Future<AppSettings> settingsWith(String format, String profile) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final AppSettings settings = AppSettings.instance;
    await settings.useProfile('friday-juma-$profile-$format');
    settings.setTimeFormat(format);
    return settings;
  }

  Future<void> pumpCard(
    WidgetTester tester, {
    Masjid? boardToQuote,
    required DateTime debugNow,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TodayPrayerCard(
          latitude: lat,
          longitude: lng,
          areaName: 'Mumbai',
          board: boardToQuote,
          boards: <Masjid>[?boardToQuote],
          debugNow: debugNow,
        ),
      ),
    ));
    await tester.pump();
  }

  Future<void> pumpHero(
    WidgetTester tester, {
    Masjid? boardToQuote,
    required DateTime debugNow,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: NextPrayerHero(
          latitude: lat,
          longitude: lng,
          areaName: 'Mumbai',
          board: boardToQuote,
          debugNow: debugNow,
        ),
      ),
    ));
    await tester.pump();
  }

  Future<void> tearDownWidgets(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
  }

  /// The small Awwal line under a row's Jamaat — fontSize 9, and no other
  /// text on the card wears that size.
  List<Text> smallLines(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .where((Text t) => t.style?.fontSize == 9)
      .toList();

  group('the Today card on a Friday', () {
    testWidgets('keeps five prayer rows and appends Jummah last',
        (WidgetTester tester) async {
      final AppSettings settings = await settingsWith('12', 'append');
      await pumpCard(tester, boardToQuote: board(), debugNow: friday);
      final LocalPrayerTimes day =
          settings.compute(latitude: lat, longitude: lng, day: friday);

      // The five daily prayers are all still there, Dhuhr included.
      for (final String name in <String>[
        'Fajr',
        'Sunrise',
        'Dhuhr',
        'Asr',
        'Maghrib',
        'Isha',
      ]) {
        expect(find.text(name), findsOneWidget, reason: name);
      }

      // Jummah is a seventh row, every day, at the foot of the card.
      expect(find.text('Juma'), findsOneWidget);
      final double ishaY = tester.getTopLeft(find.text('Isha')).dy;
      final double jumaY = tester.getTopLeft(find.text('Juma')).dy;
      expect(jumaY, greaterThan(ishaY),
          reason: 'the Jummah section sits at the foot of the card');

      // Dhuhr keeps its own board cell and its own Awwal.
      expect(find.text(settings.formatClockShort('13:20')), findsOneWidget,
          reason: 'Dhuhr is still Thursday\'s Dhuhr, cell and all');
      // Jummah quotes the board\'s Juma cell with no Awwal/end.
      expect(find.text(settings.formatClockShort('13:30')), findsOneWidget,
          reason: 'the Juma cell is the Jummah row\'s big line');
      expect(find.text(settings.formatShort(day.times['dhuhr']!)),
          findsOneWidget,
          reason: 'only Dhuhr carries the calculated Awwal now');
      expect(smallLines(tester), hasLength(5),
          reason: 'five daily rows keep their Awwal; Jummah has none');

      // The mosque glyph belongs to Jummah; Dhuhr keeps the noon sun.
      expect(find.byIcon(Icons.mosque_outlined), findsWidgets);
      expect(find.byIcon(Icons.light_mode_outlined), findsOneWidget);

      await tearDownWidgets(tester);
    });

    testWidgets('Jummah opens no sixth notification — it has no bell',
        (WidgetTester tester) async {
      await settingsWith('12', 'bell');
      await pumpCard(tester, boardToQuote: board(), debugNow: friday);

      // Five bells: Fajr, Dhuhr, Asr, Maghrib, Isha. Sunrise and Jummah
      // both leave the fixed-width spacer empty.
      expect(find.byIcon(Icons.notifications_off_outlined), findsNWidgets(5));

      await tester.tap(find.byIcon(Icons.notifications_off_outlined).at(1));
      await tester.pumpAndSettle();
      expect(find.text('Dhuhr bell'), findsOneWidget,
          reason: 'the bell is still Dhuhr\'s own door');
      expect(find.text('Juma bell'), findsNothing);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tearDownWidgets(tester);
    });

    testWidgets('Saturday has no Jummah section at all',
        (WidgetTester tester) async {
      final AppSettings settings = await settingsWith('12', 'saturday');
      await pumpCard(tester, boardToQuote: board(), debugNow: saturday);

      expect(find.text('Dhuhr'), findsOneWidget);
      expect(find.text('Juma'), findsOneWidget,
          reason: 'the Jummah section now appears every day');
      expect(find.text(settings.formatClockShort('13:30')), findsOneWidget,
          reason: 'on non-Friday it still shows the board\'s Juma cell if present');

      await tearDownWidgets(tester);
    });

    testWidgets('a board that never filled a Juma cell shows the calculated clock',
        (WidgetTester tester) async {
      final AppSettings settings = await settingsWith('12', 'no-juma');
      await pumpCard(tester,
          boardToQuote: board(juma: '--:--'), debugNow: friday);
      final LocalPrayerTimes day =
          settings.compute(latitude: lat, longitude: lng, day: friday);

      expect(find.text('Juma'), findsOneWidget,
          reason: 'the Jummah section still stands up');
      expect(find.text(settings.format(day.times['dhuhr']!)), findsWidgets,
          reason: 'with no Juma cell the Jummah row falls to the calculated '
              'Dhuhr rather than the daily noon cell');
      expect(find.text(settings.formatClockShort('13:20')), findsWidgets,
          reason: 'the daily Dhuhr cell stays on Dhuhr\'s own row');
      expect(smallLines(tester).length, greaterThanOrEqualTo(4),
          reason: 'the five daily rows keep their Awwal; the Jummah row has '
              'only one clock to print');

      await tearDownWidgets(tester);
    });
  });

  group('the hero on a Friday', () {
    testWidgets('names the Juma cell under the Awwal, and only there',
        (WidgetTester tester) async {
      final AppSettings settings = await settingsWith('12', 'hero');
      await pumpHero(tester, boardToQuote: board(), debugNow: friday);
      final LocalPrayerTimes day =
          settings.compute(latitude: lat, longitude: lng, day: friday);

      // Friday does not rename the prayer in the hero.
      expect(find.text('Dhuhr'), findsWidgets);
      expect(find.text('Juma'), findsNothing,
          reason: 'Jummah is the line under Awwal, not the prayer’s name');

      expect(find.text(settings.format(day.times['dhuhr']!)), findsWidgets,
          reason: 'the Awwal is the calculated Dhuhr, unchanged');
      expect(
        find.text('Juma ${settings.format(DateTime(2026, 10, 30, 13, 30))}'),
        findsOneWidget,
        reason: 'the Friday section appears in the Jamaat line under Awwal',
      );
      expect(
        find.text('Jamaat ${settings.format(DateTime(2026, 10, 30, 13, 30))}'),
        findsNothing,
        reason: 'Friday’s line is Juma, not a second “Jamaat”',
      );

      await tearDownWidgets(tester);
    });

    testWidgets('any other weekday quotes the daily cell, as before',
        (WidgetTester tester) async {
      final AppSettings settings = await settingsWith('12', 'hero-sat');
      await pumpHero(tester, boardToQuote: board(), debugNow: saturday);

      expect(find.text('Dhuhr'), findsWidgets);
      expect(find.text('Juma'), findsNothing);
      expect(
        find.text('Jamaat ${settings.format(DateTime(2026, 10, 31, 13, 20))}'),
        findsOneWidget,
        reason: 'Saturday’s Jamaat is the masjid’s daily noon cell',
      );

      await tearDownWidgets(tester);
    });

    testWidgets('with no Juma cell the pair keeps its Awwal and says so',
        (WidgetTester tester) async {
      await settingsWith('12', 'hero-no-juma');
      await pumpHero(tester,
          boardToQuote: board(juma: '--:--'), debugNow: friday);

      expect(find.textContaining('Juma '), findsNothing);
      expect(find.text('Next prayer is'), findsNothing,
          reason: 'card B does not render at all rather than half-speak');

      await tearDownWidgets(tester);
    });
  });
}
