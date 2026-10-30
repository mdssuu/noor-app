import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_look.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/main.dart';
import 'package:noor_masjid_time/today_prayer_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Friday, read as Friday.
///
/// The reader's complaint was plain: "home prayer card me jummah nahi dikh
/// raha". The card has always had exactly six rows and noon has always been
/// one of them — but on the one day the prayer is Jummah it still said
/// Dhuhr, quoted the board's *daily* noon cell as its Jamaat, and wore the
/// noon sun where the prayer's own glyph belonged. The hero above it, whose
/// whole second card exists to print a board's Jamaat under the Awwal, did
/// the same: on a Friday it quoted the cell the masjid does not pray by.
///
/// So the noon row keeps every clock it has always had and changes only its
/// answer to "which prayer, whose Jamaat": Jummah's name, the board's Juma
/// cell, and the calculated Dhuhr untouched beneath as the Awwal — a board
/// that filled no Juma time stays on the calculated clock rather than
/// quoting its everyday noon as the Jummah.
///
/// The other five rows, the bell (still `dhuhr`'s door — Jummah opens no
/// sixth notification) and every other day of the week are pinned here too,
/// because a Friday-only feature that leaks into Saturday is half a feature.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const double lat = 19.0760;
  const double lng = 72.8777;

  // Known weekdays: 30 Oct 2026 is a Friday, the 31st a Saturday. The card
  // reads the weekday off this clock, so pinning it is what makes both days
  // reachable on any day the suite runs.
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

  Future<AppSettings> settingsWith(String format) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final AppSettings settings = AppSettings.instance;
    await settings.useProfile('friday-juma-$format');
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

  /// Unmounts a ticking widget — the card ticks every 30s, the hero every
  /// second, and a widget test fails at teardown if a timer outlives it.
  Future<void> tearDownWidgets(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
  }

  /// The small second line the board's Jamaat carries — fontSize 9, and no
  /// other text on the card wears that size.
  List<Text> smallLines(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .where((Text t) => t.style?.fontSize == 9)
      .toList();

  group('the Today card on a Friday', () {
    testWidgets('the noon row is Jummah — named, quoted and robed as such',
        (WidgetTester tester) async {
      final AppSettings settings = await settingsWith('12');
      await pumpCard(tester, boardToQuote: board(), debugNow: friday);
      final LocalPrayerTimes day =
          settings.compute(latitude: lat, longitude: lng, day: friday);

      // The complaint itself, answered: the word is on the card.
      expect(find.text('Juma'), findsOneWidget,
          reason: 'the noon prayer wears its Friday name');
      expect(find.text('Dhuhr'), findsNothing,
          reason: 'Friday has no Dhuhr row to print it on');

      // The big line is the board's *Juma* clock — not the daily noon cell
      // the masjid does not pray by today.
      expect(find.text(settings.formatClockShort('13:30')), findsOneWidget,
          reason: 'the Juma cell takes the Jamaat line');
      expect(find.text(settings.formatClockShort('13:20')), findsNothing,
          reason: 'a guess dressed as a fact — Friday’s answer is the other '
              'cell');

      // And the Awwal beneath it is the calculated Dhuhr, unmoved: the two
      // clocks the reader plans by, exactly as every other row carries them.
      expect(find.text(settings.formatShort(day.times['dhuhr']!)),
          findsOneWidget,
          reason: 'the Awwal is Friday’s Dhuhr too — it never moved');
      expect(
        find.text('Ends ${settings.format(day.times['asr']!)}'),
        findsOneWidget,
        reason: 'and Jummah still ends when Asr opens, on the official clock',
      );

      // The mosque glyph, not the noon sun.
      expect(find.byIcon(Icons.mosque_outlined), findsWidgets);
      expect(find.byIcon(Icons.light_mode_outlined), findsNothing);

      await tearDownWidgets(tester);
    });

    testWidgets('the bell is still dhuhr’s door — no sixth notification',
        (WidgetTester tester) async {
      await settingsWith('12');
      await pumpCard(tester, boardToQuote: board(), debugNow: friday);

      // A fresh profile leaves every bell off: five glyphs, sunrise without
      // one, whatever the weekday says.
      expect(find.byIcon(Icons.notifications_off_outlined), findsNWidgets(5));

      // And the dialog opened from the Jummah row answers in the same name —
      // two names for the prayer just tapped would be its own confusion.
      await tester.tap(find.byIcon(Icons.notifications_off_outlined).at(1));
      await tester.pumpAndSettle();
      expect(find.text('Juma bell'), findsOneWidget);
      expect(find.text('Dhuhr bell'), findsNothing);
      // The three answers ride along unchanged — Friday moves no mode.
      for (final String name in <String>['Azaan', 'Mute', 'Band']) {
        expect(find.text(name), findsOneWidget, reason: name);
      }

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tearDownWidgets(tester);
    });

    testWidgets('Saturday reads exactly as it always did', (WidgetTester tester) async {
      final AppSettings settings = await settingsWith('12');
      await pumpCard(tester, boardToQuote: board(), debugNow: saturday);

      expect(find.text('Dhuhr'), findsOneWidget);
      expect(find.text('Juma'), findsNothing,
          reason: 'the rename lives on one weekday, not all seven');
      expect(find.text(settings.formatClockShort('13:20')), findsOneWidget,
          reason: 'and Saturday’s Jamaat is the daily cell again');
      expect(find.text(settings.formatClockShort('13:30')), findsNothing,
          reason: 'the Juma clock is not quoted on a non-Friday');
      expect(find.byIcon(Icons.light_mode_outlined), findsWidgets);

      await tearDownWidgets(tester);
    });

    testWidgets('a board that never filled a Juma cell stays calculated',
        (WidgetTester tester) async {
      final AppSettings settings = await settingsWith('12');
      await pumpCard(tester,
          boardToQuote: board(juma: '--:--'), debugNow: friday);
      final LocalPrayerTimes day =
          settings.compute(latitude: lat, longitude: lng, day: friday);

      // The name still changes — the weekday decides that, not the board —
      // but the clock falls to the calculated time rather than reaching for
      // the daily noon cell: an unanswered question stays unanswered.
      expect(find.text('Juma'), findsOneWidget);
      expect(find.text(settings.format(day.times['dhuhr']!)), findsWidgets,
          reason: 'the big line is the reader’s own calculated Dhuhr');
      expect(find.text(settings.formatClockShort('13:20')), findsNothing,
          reason: 'the daily cell is not Friday’s answer either');
      expect(smallLines(tester), hasLength(4),
          reason: 'and the row carries one clock — no Awwal under a Jamaat '
              'the board never gave');

      await tearDownWidgets(tester);
    });
  });

  group('the hero on a Friday', () {
    testWidgets('card B quotes the Juma cell under the same Awwal',
        (WidgetTester tester) async {
      final AppSettings settings = await settingsWith('12');
      await pumpHero(tester, boardToQuote: board(), debugNow: friday);
      final LocalPrayerTimes day =
          settings.compute(latitude: lat, longitude: lng, day: friday);

      // The name reaches both cards — the peach one counting down to the
      // prayer and the white one planning it.
      expect(find.text('Juma'), findsWidgets,
          reason: 'the hero names Friday’s prayer as Jummah');
      expect(find.text('Dhuhr'), findsNothing);

      // The pair card B exists for: the Awwal big (the reader's clock,
      // Friday's Dhuhr to the minute) and the board's Juma Jamaat small.
      expect(find.text(settings.format(day.times['dhuhr']!)), findsWidgets,
          reason: 'the Awwal is the calculated Dhuhr, unchanged');
      expect(
        find.text('Jamaat ${settings.format(DateTime(2026, 10, 30, 13, 30))}'),
        findsOneWidget,
        reason: 'and the Jamaat beneath it is the Juma cell — the whole '
            'complaint was that this line quoted 13:20 on a Friday',
      );

      await tearDownWidgets(tester);
    });

    testWidgets('any other weekday quotes the daily cell, as before',
        (WidgetTester tester) async {
      final AppSettings settings = await settingsWith('12');
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
      final AppSettings settings = await settingsWith('12');
      await pumpHero(tester,
          boardToQuote: board(juma: '--:--'), debugNow: friday);

      // `_boardQuotesAnotherTime` needs two *different* clocks: with no
      // Juma cell the board quotes nothing for Friday's prayer, so card B
      // does not stand up quoting the daily cell it was never asked for —
      // the prayer and the countdown remain, on the calculated clock.
      expect(
        find.text('Jamaat ${settings.format(DateTime(2026, 10, 30, 13, 30))}'),
        findsNothing,
      );
      expect(
        find.text('Jamaat ${settings.format(DateTime(2026, 10, 30, 13, 20))}'),
        findsNothing,
        reason: 'nor the daily noon cell — Friday was never answered by it',
      );
      expect(find.text('Next prayer is'), findsNothing,
          reason: 'card B does not render at all rather than half-speak');

      await tearDownWidgets(tester);
    });
  });
}
