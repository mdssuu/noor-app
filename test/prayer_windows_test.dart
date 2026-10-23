import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_look.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/main.dart';
import 'package:noor_masjid_time/today_prayer_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Two figures a reader acts on, so both belong to the *official* clock:
/// a prayer's end time is the calculated start of whatever follows it —
/// a board's Jamaat cell never moves it — and the makruh (Zawal) window is
/// the half hour before Dhuhr, the way the masjid's printed table says it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const double lat = 19.0760;
  const double lng = 72.8777;

  Masjid board() => Masjid(
        id: 'masjid-board',
        name: 'Aqsa Masjid',
        fajr: '05:00',
        dhuhr: '13:20',
        asr: '17:45',
        maghrib: '18:35',
        isha: '21:00',
        juma: '13:30',
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
    await settings.useProfile('windows-$format');
    settings.setTimeFormat(format);
    return settings;
  }

  /// Unmounts a ticking widget — the card ticks every 30s, the hero every
  /// second, and a widget test fails at teardown if a timer outlives it.
  Future<void> tearDownWidgets(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
  }

  /// The `hh:mm:ss` a card prints for [d] — the same shape `_clock` builds.
  String tick(Duration d) {
    if (d.isNegative) d = Duration.zero;
    return '${d.inHours.toString().padLeft(2, '0')}'
        ':${d.inMinutes.remainder(60).toString().padLeft(2, '0')}'
        ':${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';
  }

  group('the official end of a prayer', () {
    test('is the calculated start of whatever follows it', () {
      final DateTime fajr = DateTime(2026, 10, 12, 5, 19);
      final DateTime sunrise = DateTime(2026, 10, 12, 6, 31);
      final DateTime dhuhr = DateTime(2026, 10, 12, 12, 31);
      final DateTime asr = DateTime(2026, 10, 12, 15, 57);
      final DateTime maghrib = DateTime(2026, 10, 12, 18, 20);
      final DateTime isha = DateTime(2026, 10, 12, 20, 10);
      final DateTime tomorrow = DateTime(2026, 10, 13, 5, 18);

      final LocalPrayerTimes day = LocalPrayerTimes(
        times: <String, DateTime>{
          'fajr': fajr,
          'sunrise': sunrise,
          'dhuhr': dhuhr,
          'asr': asr,
          'maghrib': maghrib,
          'isha': isha,
        },
        fajrTomorrow: tomorrow,
      );

      expect(day.officialEnd('fajr'), sunrise);
      expect(day.officialEnd('dhuhr'), asr);
      expect(day.officialEnd('asr'), maghrib);
      expect(day.officialEnd('maghrib'), isha);
      expect(day.officialEnd('isha'), tomorrow);
      expect(day.officialEnd('sunrise'), isNull,
          reason: 'sunrise is not a prayer and ends nothing');
      expect(day.officialEnd('nonsense'), isNull);
    });

    test('the makruh window is the half hour before Dhuhr', () {
      final DateTime dhuhr = DateTime(2026, 10, 12, 12, 31);
      final LocalPrayerTimes day = LocalPrayerTimes(
        times: <String, DateTime>{'dhuhr': dhuhr},
        fajrTomorrow: DateTime(2026, 10, 13, 5, 18),
      );

      final ({DateTime start, DateTime end}) window = day.makruhWindow!;
      expect(window.end, dhuhr, reason: 'Zawal ends the moment Dhuhr begins');
      expect(window.start, dhuhr.subtract(const Duration(minutes: 30)));

      final LocalPrayerTimes empty =
          LocalPrayerTimes(times: const <String, DateTime>{},
              fajrTomorrow: DateTime(2026, 10, 13, 5, 18));
      expect(empty.makruhWindow, isNull);
    });
  });

  group('the Today card', () {
    testWidgets('shows every prayer’s official end, the board never moving it',
        (WidgetTester tester) async {
      final AppSettings settings = await settingsWith('12');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TodayPrayerCard(
            latitude: lat,
            longitude: lng,
            areaName: 'Mumbai',
            board: board(),
            boards: <Masjid>[board()],
          ),
        ),
      ));

      final LocalPrayerTimes day = settings.compute(latitude: lat, longitude: lng);

      // The board quotes Fajr 05:00 — Fajr still ends at calculated sunrise.
      expect(find.text('Ends ${settings.format(day.times['sunrise']!)}'),
          findsOneWidget);
      expect(find.text('Ends ${settings.format(day.times['asr']!)}'),
          findsOneWidget);
      expect(find.text('Ends ${settings.format(day.times['maghrib']!)}'),
          findsOneWidget);
      expect(find.text('Ends ${settings.format(day.times['isha']!)}'),
          findsOneWidget);
      expect(find.text('Ends ${settings.format(day.fajrTomorrow)}'),
          findsOneWidget);

      // Five prayers end; Sunrise ends nothing.
      expect(find.textContaining('Ends '), findsNWidgets(5));

      await tearDownWidgets(tester);
    });

    testWidgets('says nothing about makruh — the hero’s top line owns it',
        (WidgetTester tester) async {
      await settingsWith('12');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TodayPrayerCard(
            latitude: lat,
            longitude: lng,
            areaName: 'Mumbai',
          ),
        ),
      ));

      expect(find.textContaining('Makruh'), findsNothing,
          reason: 'the half hour stands once — big at the top of the hero, '
              'for exactly the minutes it covers — never a standing note '
              'in the list all day');

      await tearDownWidgets(tester);
    });
  });

  group('the hero’s card A', () {
    testWidgets('ends the current prayer on the calculated clock, even under a board',
        (WidgetTester tester) async {
      final AppSettings settings = await settingsWith('12');
      final Masjid quoted = board();

      final LocalPrayerTimes day = settings.compute(latitude: lat, longitude: lng);

      // Whatever the card picks as "next", its End line must quote one of
      // the *calculated* figures — the board's Jamaat cells (05:00, 13:20 …)
      // live on today's calendar at their own values and must not appear.
      final List<String> official = <String>[
        for (final DateTime t in day.times.values) settings.format(t),
        settings.format(day.fajrTomorrow),
      ];

      // Pinned into the afternoon: run the suite between local sunrise and
      // Dhuhr and the card would rightly speak in its morning voice —
      // "Begins" — and this End-line contract would find no "End time -".
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: NextPrayerHero(
            latitude: lat,
            longitude: lng,
            areaName: 'Mumbai',
            board: quoted,
            debugNow: day.times['dhuhr']!.add(const Duration(hours: 1)),
          ),
        ),
      ));

      final Finder endLine = find.textContaining('End time - ');
      expect(endLine, findsOneWidget);
      final String shown = tester.widget<Text>(endLine).data!;
      expect(
        official.map((String s) => 'End time - $s'),
        contains(shown),
        reason: 'the end of a prayer is official, not the masjid’s Jamaat',
      );

      await tearDownWidgets(tester);
    });

    testWidgets('carries the makruh window only while zawal is running',
        (WidgetTester tester) async {
      final AppSettings settings = await settingsWith('12');
      final ({DateTime start, DateTime end}) window =
          settings.compute(latitude: lat, longitude: lng).makruhWindow!;
      final String line =
          'Makruh ${settings.format(window.start)} – ${settings.format(window.end)}';

      Future<void> showAt(DateTime now) async {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: NextPrayerHero(
              latitude: lat,
              longitude: lng,
              areaName: 'Mumbai',
              debugNow: now,
            ),
          ),
        ));
      }

      // A minute before the window opens — nothing to warn about yet.
      await showAt(window.start.subtract(const Duration(minutes: 1)));
      expect(find.textContaining('Makruh'), findsNothing,
          reason: 'the hero stays quiet until zawal actually begins');
      await tearDownWidgets(tester);

      // Five minutes in — the window stands up top, big, of its own accord.
      await showAt(window.start.add(const Duration(minutes: 5)));
      expect(find.text(line), findsOneWidget,
          reason: 'during zawal the top line must say the window');
      expect(
        find.ancestor(
            of: find.text(line), matching: find.byType(IntrinsicHeight)),
        findsNothing,
        reason: '…as a line of its own above the cards, not tucked in one',
      );
      // And the rail underneath is near its end — the morning is almost over.
      final LocalPrayerTimes day = settings.compute(latitude: lat, longitude: lng);
      final double expectedRail = window.start
              .add(const Duration(minutes: 5))
              .difference(day.times['sunrise']!)
              .inMilliseconds /
          day.times['dhuhr']!.difference(day.times['sunrise']!).inMilliseconds;
      expect(
        tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value,
        closeTo(expectedRail, 0.005),
        reason: 'zawal is the last quarter of the run to Dhuhr',
      );
      await tearDownWidgets(tester);

      // Dhuhr has just opened; the window is behind the reader — the line
      // goes rather than lingering for the rest of the day.
      await showAt(window.end);
      expect(find.textContaining('Makruh'), findsNothing);
      await tearDownWidgets(tester);
    });

    testWidgets('through the morning the card counts the next prayer, not Sunrise',
        (WidgetTester tester) async {
      final AppSettings settings = await settingsWith('12');
      final LocalPrayerTimes day = settings.compute(latitude: lat, longitude: lng);

      // An hour past sunrise, long before Dhuhr: sunrise is not a prayer,
      // so nothing is "left" in it — the card switches voice and runs the
      // next prayer's timer instead.
      final DateTime during =
          day.times['sunrise']!.add(const Duration(hours: 1));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: NextPrayerHero(
            latitude: lat,
            longitude: lng,
            areaName: 'Mumbai',
            debugNow: during,
          ),
        ),
      ));

      expect(find.text('Now time is'), findsNothing,
          reason: 'no one has a namaz to finish at sunrise');
      expect(find.text('Next prayer in'), findsOneWidget);
      expect(find.text('Dhuhr'), findsOneWidget,
          reason: 'the morning timer belongs to the prayer actually due');
      expect(find.byIcon(Icons.wb_sunny_outlined), findsWidgets,
          reason: 'wearing Dhuhr’s own glyph');
      expect(find.text(tick(day.times['dhuhr']!.difference(during))),
          findsOneWidget,
          reason: 'and it counts down to the calculated Dhuhr');
      expect(find.text('Begins - ${settings.format(day.times['dhuhr']!)}'),
          findsOneWidget,
          reason: 'the line under it says when that Dhuhr begins');

      // The rail measures the morning as distance: sunrise at the left
      // edge, Dhuhr at the right, filled to where the clock stands.
      final double expectedRail = during
              .difference(day.times['sunrise']!)
              .inMilliseconds /
          day.times['dhuhr']!.difference(day.times['sunrise']!).inMilliseconds;
      expect(
        tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value,
        closeTo(expectedRail, 0.005),
        reason: 'the window’s rail runs sunrise → Dhuhr, not sunrise → sunrise',
      );

      await tearDownWidgets(tester);
    });
  });

  group('the hero, kept minimal', () {
    testWidgets('card A counts the running prayer down to its End line',
        (WidgetTester tester) async {
      final AppSettings settings = await settingsWith('12');
      final LocalPrayerTimes day = settings.compute(latitude: lat, longitude: lng);

      // Half an hour into Dhuhr: the big type must be what is left of
      // Dhuhr, ticking to the very instant the End line below prints.
      final DateTime during =
          day.times['dhuhr']!.add(const Duration(minutes: 30));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: NextPrayerHero(
            latitude: lat,
            longitude: lng,
            areaName: 'Mumbai',
            debugNow: during,
          ),
        ),
      ));

      final DateTime end = day.times['asr']!;
      expect(find.text('Now time is'), findsOneWidget);
      expect(find.text('Dhuhr'), findsOneWidget);
      expect(find.byIcon(Icons.wb_sunny_outlined), findsWidgets,
          reason: 'the running prayer wears its own day glyph');
      expect(find.text(tick(end.difference(during))), findsOneWidget,
          reason: 'the remaining time of the prayer whose time is on');
      expect(find.text('End time - ${settings.format(end)}'), findsOneWidget,
          reason: 'and the countdown runs down to that official End');
      expect(find.byType(LinearProgressIndicator), findsOneWidget,
          reason: 'the window’s rail draws how much of it has passed');

      await tearDownWidgets(tester);
    });

    testWidgets('card B prints the pair — Awwal and Jamaat — and no second countdown',
        (WidgetTester tester) async {
      final AppSettings settings = await settingsWith('12');
      final LocalPrayerTimes day = settings.compute(latitude: lat, longitude: lng);

      // Between the board's Dhuhr Jamaat (13:20) and its Asr (17:45): card
      // B carries both clocks the reader plans by — when Asr opens on the
      // official clock and when the board will actually pray — and never
      // a second ticking number or a repeated "Jamaat:" line.
      final DateTime onDay = day.times['dhuhr']!;
      final DateTime during =
          DateTime(onDay.year, onDay.month, onDay.day, 14, 0);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: NextPrayerHero(
            latitude: lat,
            longitude: lng,
            areaName: 'Mumbai',
            board: board(),
            debugNow: during,
          ),
        ),
      ));

      expect(find.textContaining('Jamaat:'), findsNothing,
          reason: 'the big time *is* the Jamaat');

      // What it carries: the pair — Awwal and Jamaat — side by side…
      final DateTime jamaatAt =
          DateTime(onDay.year, onDay.month, onDay.day, 17, 45);
      expect(find.text('Jamaat'), findsOneWidget,
          reason: 'the big clock names itself');
      expect(find.text(settings.format(jamaatAt)), findsOneWidget);
      expect(find.text('Awwal ${settings.format(day.times['asr']!)}'),
          findsOneWidget,
          reason: 'and the Awwal beneath it — both of the prayer’s times');

      // …and no second ticking number: card A's countdown stands alone.
      expect(find.text('in ${tick(jamaatAt.difference(during))}'),
          findsNothing,
          reason: 'the seconds chip is gone — the clock already says when');

      await tearDownWidgets(tester);
    });

    testWidgets('with no board, card B does not render at all', (WidgetTester tester) async {
      final AppSettings settings = await settingsWith('12');
      final LocalPrayerTimes day = settings.compute(latitude: lat, longitude: lng);

      // No board: card B's clock would be card A's End line printed a
      // second time, right beside it — so the white card does not exist
      // and card A alone runs the width.
      final DateTime during =
          day.times['dhuhr']!.add(const Duration(minutes: 30));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: NextPrayerHero(
            latitude: lat,
            longitude: lng,
            areaName: 'Mumbai',
            debugNow: during,
          ),
        ),
      ));

      final DateTime asr = day.times['asr']!;
      expect(find.text('Next prayer is'), findsNothing,
          reason: 'there is nothing new for the second card to say');
      expect(find.text(settings.format(asr)), findsNothing,
          reason: 'the End clock may exist exactly once — on card A');
      expect(find.text('Awwal ${settings.format(asr)}'), findsNothing,
          reason: 'the pair has nowhere to stand without card B');
      expect(find.text('in ${tick(asr.difference(during))}'), findsNothing,
          reason: 'a second ticking number identical to card A’s');
      expect(find.text(tick(asr.difference(during))), findsOneWidget,
          reason: 'card A’s countdown stands alone');
      expect(find.text('End time - ${settings.format(asr)}'), findsOneWidget);

      await tearDownWidgets(tester);
    });

    testWidgets('a board praying on the calculated clock adds no second card',
        (WidgetTester tester) async {
      final AppSettings settings = await settingsWith('12');
      final LocalPrayerTimes day = settings.compute(latitude: lat, longitude: lng);

      // The masjid's Asr *is* the calculated Asr: its Jamaat cell carries
      // no instant card A's End line lacks, so the pair must not become
      // two cards saying one thing.
      final DateTime calcAsr = day.times['asr']!;
      final String clock =
          '${calcAsr.hour.toString().padLeft(2, '0')}:${calcAsr.minute.toString().padLeft(2, '0')}';
      final Masjid sameClock = Masjid(
        id: 'masjid-same-clock',
        name: 'Aqsa Masjid',
        fajr: '05:00',
        dhuhr: '13:20',
        asr: clock,
        maghrib: '18:35',
        isha: '21:00',
        juma: '13:30',
        latitude: 19.076,
        longitude: 72.8777,
        address: 'Jogeshwari West, Mumbai',
        photoProofPath: '',
        photoProofBase64: '',
        lastUpdated: Timestamp.fromMillisecondsSinceEpoch(1700000000000),
        updatedBy: 'Ayesha',
        updatedByUid: 'uid-editor',
      );

      final DateTime during =
          day.times['dhuhr']!.add(const Duration(minutes: 30));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: NextPrayerHero(
            latitude: lat,
            longitude: lng,
            areaName: 'Mumbai',
            board: sameClock,
            debugNow: during,
          ),
        ),
      ));

      expect(find.text('Next prayer is'), findsNothing,
          reason: 'a Jamaat on the calculated clock says nothing new');
      expect(find.text(settings.format(calcAsr)), findsNothing,
          reason: 'not the End clock a second time either');
      expect(find.text('End time - ${settings.format(calcAsr)}'), findsOneWidget,
          reason: 'card A alone carries the one clock that matters');

      await tearDownWidgets(tester);
    });

    testWidgets('the hero moves on the Awwal, never on a board’s Jamaat',
        (WidgetTester tester) async {
      final AppSettings settings = await settingsWith('12');
      final LocalPrayerTimes day = settings.compute(latitude: lat, longitude: lng);

      // Five minutes after Isha's *calculated* start, with the board's
      // Isha Jamaat (21:00) still three quarters of an hour away: the
      // hero must already be on Isha, counting down to tomorrow's Fajr.
      // A masjid's later Jamaat may not hold the card on Maghrib.
      final DateTime during =
          day.times['isha']!.add(const Duration(minutes: 5));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: NextPrayerHero(
            latitude: lat,
            longitude: lng,
            areaName: 'Mumbai',
            board: board(),
            debugNow: during,
          ),
        ),
      ));

      expect(find.text('Now time is'), findsOneWidget);
      expect(find.text('Isha'), findsOneWidget,
          reason: 'Isha’s Awwal moves the hero, not the Jamaat an hour later');
      expect(find.text('Maghrib'), findsNothing,
          reason: 'the old behaviour — stuck on the prayer before — is the bug');
      expect(find.text('End time - ${settings.format(day.fajrTomorrow)}'),
          findsOneWidget);
      expect(find.text(tick(day.fajrTomorrow.difference(during))),
          findsOneWidget,
          reason: 'and the countdown runs to that official End');

      // Card B keeps its own promise: it quotes the masjid's own Fajr
      // Jamaat on the board — 05:00, an hour before the calc — beside the
      // Awwal tomorrow's Fajr actually opens at, and counts nothing.
      final DateTime fajrJamaat = DateTime(day.fajrTomorrow.year,
          day.fajrTomorrow.month, day.fajrTomorrow.day, 5, 0);
      expect(find.text('Fajr (tomorrow)'), findsOneWidget);
      expect(find.text(settings.format(fajrJamaat)), findsOneWidget,
          reason: 'the big clock is the board’s own Jamaat');
      expect(find.text('Awwal ${settings.format(day.fajrTomorrow)}'),
          findsOneWidget,
          reason: 'and the pair’s other clock is the official Awwal');
      expect(find.text('in ${tick(fajrJamaat.difference(during))}'),
          findsNothing,
          reason: 'no second countdown — the chip is gone by request');

      await tearDownWidgets(tester);
    });
  });
}
