import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/main.dart';
import 'package:noor_masjid_time/today_prayer_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression for: "Today's Prayer Times me favourite masjid ka Jamaat time
/// bhi dikhe, Awwal waqt ke saath — upar Jamaat, niche chhota Awwal."
///
/// The card has always shown the calculated (Awwal) times alone. Now that a
/// starred board is quoted too, two things have to hold: the board's own
/// column takes the big line with the Awwal time small beneath it, and only
/// the prayers a board actually publishes get that second line — Sunrise
/// never does, and an unstarred card must look exactly as it did before.
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

  /// A second starred masjid, so the chooser has something to choose between.
  Masjid otherBoard() => Masjid(
        id: 'masjid-other',
        name: 'Baqiya Masjid',
        fajr: '05:10',
        dhuhr: '13:30',
        asr: '17:50',
        maghrib: '18:40',
        isha: '21:10',
        juma: '13:30',
        latitude: 19.10,
        longitude: 72.85,
        address: 'Andheri East, Mumbai',
        photoProofPath: '',
        photoProofBase64: '',
        lastUpdated: Timestamp.fromMillisecondsSinceEpoch(1700000000000),
        updatedBy: 'Sahil',
        updatedByUid: 'uid-editor-2',
      );

  Future<AppSettings> settingsWith(String format) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final AppSettings settings = AppSettings.instance;
    await settings.useProfile('today-board-$format');
    settings.setTimeFormat(format);
    return settings;
  }

  Future<void> pumpCard(
    WidgetTester tester, {
    Masjid? boardToQuote,
    List<Masjid> boards = const <Masjid>[],
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TodayPrayerCard(
          latitude: lat,
          longitude: lng,
          areaName: 'Mumbai',
          board: boardToQuote,
          boards: boards,
        ),
      ),
    ));
  }

  /// The small second line — every other text on the card has its own size.
  List<Text> smallLines(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .where((Text t) => t.style?.fontSize == 9)
      .toList();

  /// Unmounts the card, which cancels its 30-second ticker; a widget test
  /// fails at teardown if a timer outlives it.
  Future<void> tearDownCard(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
  }

  /// The bell state lives on the AppSettings singleton and survives a
  /// profile that is already active — put every prayer back on before
  /// reading the glyphs, so each test starts from its own state.
  void bellsOn(AppSettings settings) {
    for (final String key in kNotifiablePrayers) {
      if (!settings.notifyOnFor(key)) settings.setNotifyOn(key, true);
    }
  }

  /// The bell dialog answers *in place* — a tap files the choice and leaves
  /// the dialog open, so the reader can still read what the tick moved to
  /// and reach the timing chips beneath it. A glyph count therefore has to
  /// shut it first, or the dialog's own copy of the icon is counted beside
  /// the card's.
  Future<void> closeBellDialog(WidgetTester tester) async {
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
  }

  group('Today card quoting a starred masjid', () {
    testWidgets('the board time takes the big line, the Awwal sits small beneath',
        (WidgetTester tester) async {
      final AppSettings settings = await settingsWith('12');
      await pumpCard(tester, boardToQuote: board());

      // The board's own Fajr, in the reader's clock.
      final Finder jamaat = find.text('5:00am');
      expect(jamaat, findsWidgets);

      final DateTime awwalFajr =
          settings.compute(latitude: lat, longitude: lng).times['fajr']!;
      final Finder awwal = find.text(settings.formatShort(awwalFajr));
      expect(awwal, findsWidgets);

      // Upar Jamaat, niche chhota Awwal.
      expect(
        tester.getTopLeft(jamaat.first).dy,
        lessThan(tester.getTopLeft(awwal.first).dy),
      );

      await tearDownCard(tester);
    });

    testWidgets('only the prayers a board publishes carry the second line',
        (WidgetTester tester) async {
      await settingsWith('12');
      await pumpCard(tester, boardToQuote: board());

      // Fajr, Dhuhr, Asr, Maghrib and Isha — the board answers those five;
      // Sunrise has no Jamaat, so it keeps one clock.
      expect(smallLines(tester), hasLength(5));

      await tearDownCard(tester);
    });

    testWidgets('reads the board as stored when the reader wants 24-hour',
        (WidgetTester tester) async {
      await settingsWith('24');
      await pumpCard(tester, boardToQuote: board());

      expect(find.text('05:00'), findsWidgets);
      expect(find.text('5:00am'), findsNothing);

      await tearDownCard(tester);
    });
  });

  group('Today card with nothing starred', () {
    testWidgets('is the calculated clock alone, exactly as it was before',
        (WidgetTester tester) async {
      final AppSettings settings = await settingsWith('12');
      await pumpCard(tester);

      // The board's stored Fajr never appears …
      expect(find.text('5:00am'), findsNothing);
      // … and no cell grew a second line.
      expect(smallLines(tester), isEmpty);

      final DateTime fajr = settings.compute(latitude: lat, longitude: lng).times['fajr']!;
      expect(find.text(settings.format(fajr)), findsWidgets);

      await tearDownCard(tester);
    });

    testWidgets('a board with no Fajr does not invent one', (WidgetTester tester) async {
      await settingsWith('12');

      final Masjid blank = board();
      await pumpCard(
        tester,
        boardToQuote: Masjid(
          id: blank.id,
          name: blank.name,
          fajr: '--:--',
          dhuhr: '--:--',
          asr: '--:--',
          maghrib: '--:--',
          isha: '--:--',
          juma: '--:--',
          latitude: blank.latitude,
          longitude: blank.longitude,
          address: blank.address,
          photoProofPath: '',
          photoProofBase64: '',
          lastUpdated: blank.lastUpdated,
          updatedBy: blank.updatedBy,
          updatedByUid: blank.updatedByUid,
        ),
      );

      expect(smallLines(tester), isEmpty);

      await tearDownCard(tester);
    });
  });

  group('the card says whose times it is showing', () {
    testWidgets('names the board on the card and offers the chooser',
        (WidgetTester tester) async {
      await settingsWith('12');
      await pumpCard(
        tester,
        boardToQuote: board(),
        boards: <Masjid>[board(), otherBoard()],
      );

      final Finder chip = find.text('Jamaat times from Aqsa Masjid');
      expect(chip, findsOneWidget);

      await tester.tap(chip);
      await tester.pumpAndSettle();

      expect(find.text('Which masjid’s times on this card?'), findsOneWidget);
      // The automatic answer, then both starred boards.
      expect(find.text('Nearest starred masjid'), findsOneWidget);
      expect(find.text('Aqsa Masjid'), findsOneWidget);
      expect(find.text('Baqiya Masjid'), findsOneWidget);

      await tearDownCard(tester);
    });

    testWidgets('choosing the other masjid writes the preference and closes',
        (WidgetTester tester) async {
      final AppSettings settings = await settingsWith('12');
      await pumpCard(
        tester,
        boardToQuote: board(),
        boards: <Masjid>[board(), otherBoard()],
      );

      await tester.tap(find.text('Jamaat times from Aqsa Masjid'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Baqiya Masjid'));
      await tester.pumpAndSettle();

      expect(settings.todayBoardId, 'masjid-other');
      expect(find.text('Which masjid’s times on this card?'), findsNothing);

      await tearDownCard(tester);
    });

    testWidgets('the automatic answer is a choice too, and puts the pick back',
        (WidgetTester tester) async {
      final AppSettings settings = await settingsWith('12');
      settings.setTodayBoard('masjid-other');

      await pumpCard(
        tester,
        boardToQuote: otherBoard(),
        boards: <Masjid>[board(), otherBoard()],
      );
      expect(find.text('Jamaat times from Baqiya Masjid'), findsOneWidget);

      await tester.tap(find.text('Jamaat times from Baqiya Masjid'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nearest starred masjid'));
      await tester.pumpAndSettle();

      expect(settings.todayBoardId, isEmpty);

      await tearDownCard(tester);
    });

    testWidgets('says nothing about a board when nothing is starred',
        (WidgetTester tester) async {
      await settingsWith('12');
      await pumpCard(tester);

      expect(find.textContaining('Jamaat times from'), findsNothing);
      expect(find.byIcon(Icons.arrow_drop_down), findsNothing);

      await tearDownCard(tester);
    });

    testWidgets('the times card itself carries the share button',
        (WidgetTester tester) async {
      await settingsWith('12');
      await pumpCard(tester);

      // One tap from the very card that prints the five times — the
      // forward to the family group used to sit at the bottom of Home,
      // far away from what it shares.
      expect(find.byIcon(Icons.share_outlined), findsOneWidget);
      expect(find.byTooltip('Share times'), findsOneWidget);

      await tearDownCard(tester);
    });
  });

  group('every row carries its own bell', () {
    testWidgets('the bell asks which of the three it wants, and arms that one',
        (WidgetTester tester) async {
      final AppSettings settings = await settingsWith('12');
      bellsOn(settings);
      await pumpCard(tester);

      // Fresh profile, global sound "Azaan 1" — every untouched bell
      // derives the full azan: the active glyph on all five rows.
      expect(find.byIcon(Icons.notifications_active_outlined), findsNWidgets(5));
      expect(find.byIcon(Icons.notifications_outlined), findsNothing);
      expect(find.byIcon(Icons.notifications_off_outlined), findsNothing);

      // Tap 1 — azan → silent: the recitation goes, the banner stays.
      await tester.tap(find.byIcon(Icons.notifications_active_outlined).first);
      await tester.pumpAndSettle();

      expect(find.text('Mute'), findsOneWidget);

      // Mute — the recitation goes, the banner stays. The dialog keeps the
      // tick on Mute and stays open; only leaving puts the card's own glyph
      // back in sole charge of the count.
      await tester.tap(find.text('Mute'));
      await tester.pumpAndSettle();
      await closeBellDialog(tester);

      expect(settings.bellModeFor('fajr'), kBellSilent);
      expect(settings.notifyOnFor('fajr'), isTrue,
          reason: 'silent still shows a banner, so Settings still reads on');
      expect(find.byIcon(Icons.notifications_outlined), findsOneWidget);
      expect(find.byIcon(Icons.notifications_active_outlined), findsNWidgets(4));

      // Tap 2 — silent → off: no banner either, the same switch Settings holds.
      await tester.tap(find.byIcon(Icons.notifications_outlined));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Band'));
      await tester.pumpAndSettle();
      await closeBellDialog(tester);

      expect(settings.bellModeFor('fajr'), kBellOff);
      expect(settings.notifyOnFor('fajr'), isFalse);
      expect(find.byIcon(Icons.notifications_off_outlined), findsOneWidget);
      expect(find.byIcon(Icons.notifications_active_outlined), findsNWidgets(4));

      // Tap 3 — off → azan: the ring closes where it started.
      await tester.tap(find.byIcon(Icons.notifications_off_outlined));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Azaan'));
      await tester.pumpAndSettle();
      await closeBellDialog(tester);

      expect(settings.bellModeFor('fajr'), kBellAzan);
      expect(settings.notifyOnFor('fajr'), isTrue);
      expect(find.byIcon(Icons.notifications_active_outlined), findsNWidgets(5));

      // Every other prayer keeps its own state through all three taps.
      for (final String key in <String>['dhuhr', 'asr', 'maghrib', 'isha']) {
        expect(settings.bellModeFor(key), kBellAzan, reason: '$key untouched');
      }

      await tearDownCard(tester);
    });

    testWidgets('a prayer Settings switched off shows the dead bell, and asking revives it',
        (WidgetTester tester) async {
      final AppSettings settings = await settingsWith('12');
      bellsOn(settings);
      settings.setNotifyOn('asr', false);
      await pumpCard(tester);

      // notifyOn false always reads as `off`, whatever was stored before.
      expect(find.byIcon(Icons.notifications_off_outlined), findsOneWidget);

      await tester.tap(find.byIcon(Icons.notifications_off_outlined));
      await tester.pumpAndSettle();

      // Asking — the same dialog, now choosing Azaan back on.
      await tester.tap(find.text('Azaan'));
      await tester.pumpAndSettle();
      await closeBellDialog(tester);

      // Off walks into azan — both halves back on, on Home and in Settings.
      expect(settings.bellModeFor('asr'), kBellAzan);
      expect(settings.notifyOnFor('asr'), isTrue);
      expect(find.byIcon(Icons.notifications_active_outlined), findsNWidgets(5));

      await tearDownCard(tester);
    });

    testWidgets('Sunrise carries no bell — it has nothing to mute',
        (WidgetTester tester) async {
      final AppSettings settings = await settingsWith('12');
      bellsOn(settings);
      await pumpCard(tester);

      // Six rows, five bells: one per prayer, none for Sunrise.
      expect(find.byIcon(Icons.notifications_active_outlined), findsNWidgets(5));

      await tearDownCard(tester);
    });
  });

  test('the pick is stored under the profile, never device-wide', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final AppSettings settings = AppSettings.instance;
    await settings.useProfile('today-board-pick');
    expect(settings.todayBoardId, isEmpty);

    settings.setTodayBoard('masjid-other');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(
          AppSettings.scopedKeyFor('today_board_pref', 'today-board-pick')),
      'masjid-other',
    );
    expect(prefs.containsKey('today_board_pref'), isFalse);

    // A profile that never picked anything gets the automatic answer.
    await settings.useProfile('today-board-nobody');
    expect(settings.todayBoardId, isEmpty);
  });
}
