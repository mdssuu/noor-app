import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/main.dart';
import 'package:noor_masjid_time/today_prayer_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The wocard's own answers to "what should play, and when".
///
/// Both choices used to be reachable only from Settings — a screen the reader
/// opens to *configure*, not the one they are standing on when the thought
/// arrives. The card that prints the times is where that thought happens, so
/// it now carries a button beside Share that opens the two answers directly:
/// the clip (previewed, with the channel rebuilt around it first, since
/// Android freezes a channel's sound at creation) and the offset.
///
/// The offset is filed **prayer by prayer**: a reader who wants Fajr five
/// minutes early and Isha on the dot has always been able to store that from
/// the owner's config, and this sheet is where they can now say it. Every row
/// carries its own chips plus a "Custom…" door to a number no chip offers —
/// so what is pinned here is the *isolation*: one row's tap never moves a
/// sibling, and the custom number lands on the prayer whose row asked for it.
///
/// The clip's own rehearsal — what the row shows while it sounds — lives in
/// `wocard_azan_sound_test.dart`, because a player first created in one test
/// can never answer a later one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel native = MethodChannel('noor_masjid_time/azaan');

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final AppSettings settings = AppSettings.instance;
    await settings.useProfile('wocard-azan-sheet');
    // Opening the sheet starts the shared player's stop on the way out, and a
    // platform message nobody answers never comes back once the clock is
    // faked. Answering the alarm channel keeps that tidy; nothing here starts
    // a preview.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, (MethodCall call) async =>
            call.method == 'playNow' ? true : null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, null);
  });

  Future<AppSettings> pumpCard(WidgetTester tester) async {
    // Flutter caps a sheet that is not scroll-controlled at 9/16 of the
    // window, and on an 800×600 test window that cap lands *under* the chip
    // rows — laid out, but below the fold where a tap cannot reach it. A phone
    // gives the sheet more; a window shorter than that still scrolls, which
    // is what the sheet's own scroll view is there for — and with five rows
    // now stacked instead of one, it is what *every* later row needs.
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: TodayPrayerCard(
          latitude: 19.0760,
          longitude: 72.8777,
          areaName: 'Mumbai',
        ),
      ),
    ));
    await tester.pump();
    return AppSettings.instance;
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Azaan sound & timing'));
    await tester.pumpAndSettle();
  }

  /// Brings [finder] up from under the sheet's ceiling, then taps it — the
  /// rows below the first are laid out off-screen until the scroll view
  /// brings them up, and a tap that misses the hit test fails the test rather
  /// than the reader.
  Future<void> scrollAndTap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('the button sits beside Share and opens both answers',
      (WidgetTester tester) async {
    await pumpCard(tester);

    // Share stays where the family group expects it — this is a second
    // option beside it, not a move.
    expect(find.byTooltip('Share times'), findsOneWidget);

    await openSheet(tester);

    expect(find.text('What should play'), findsOneWidget);
    for (final AzanSound sound in kAzanSounds) {
      expect(find.text(sound.label), findsOneWidget, reason: sound.label);
    }
    // The reader's own file, last in the list and one row rather than a
    // screen: the built-in answers stay where a returning reader left them.
    expect(find.text('Choose a file… (your own Azaan)'), findsOneWidget);

    expect(find.text('When it rings'), findsOneWidget);
    // Every prayer gets the whole set — the point of the rows is that they
    // are *separate*, so each offered chip is drawn once per prayer.
    for (final int minutes in kNotifyOffsets) {
      expect(
        find.text(minutes < 0 ? 'At time' : '$minutes min'),
        findsNWidgets(kNotifiablePrayers.length),
        reason: 'every offered offset is one chip in every prayer row',
      );
    }
    // …and the door to a number no chip carries, once per row too.
    expect(find.text('Custom…'), findsNWidgets(kNotifiablePrayers.length));
    for (final String prayer in kNotifiablePrayers) {
      expect(find.text(prayerByKey(prayer).label),
          findsWidgets,
          reason: '${prayerByKey(prayer).label} names its own row');
    }
    // The caption has to name the clock the offset is measured against —
    // this build's mode is "only at my masjid's Jamaat time".
    expect(
      find.textContaining('before your favourite masjid’s Jamaat time'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('one row’s chip files the offset against that prayer alone',
      (WidgetTester tester) async {
    final AppSettings settings = await pumpCard(tester);
    // One shared answer across the five is the *old* sheet; a split profile
    // is what this sheet exists to show, so the test starts from one.
    for (final String key in kNotifiablePrayers) {
      settings.setNotifyOffset(key, 5);
    }
    await openSheet(tester);

    // Fajr's own "15 min" — the first row's, since the rows are drawn in
    // prayer order. Nothing the reader taps here may move a sibling.
    await scrollAndTap(tester, find.text('15 min').first);

    expect(settings.notifyOffsetFor(kNotifiablePrayers.first), 15,
        reason: 'the row that was tapped is the prayer that changed');
    expect(settings.favModeFor(kNotifiablePrayers.first), kFavModeOffset,
        reason: 'that prayer’s Jamaat source reads its own switch, so the '
            'pair moves together');
    for (final String key in kNotifiablePrayers.skip(1)) {
      expect(settings.notifyOffsetFor(key), 5, reason: '$key was not asked');
      expect(settings.favModeFor(key), kFavModeAt,
          reason: '$key’s switch stays where it was put');
    }

    // And the chip that says it is the one in force is the one lit — in
    // *that* row. The other four still wear their own 5-min chip.
    final Finder chip = find.widgetWithText(InkWell, '15 min');
    expect(chip, findsNWidgets(kNotifiablePrayers.length));
    final Container lit = tester.widget<Container>(
      find.descendant(of: chip.first, matching: find.byType(Container)).first,
    );
    expect((lit.decoration! as BoxDecoration).color, NoorColors.emerald,
        reason: 'the chosen chip is visibly chosen');
    final Container stillFive = tester.widget<Container>(
      find.descendant(of: chip.at(1), matching: find.byType(Container)).first,
    );
    expect((stillFive.decoration! as BoxDecoration).color, NoorColors.white,
        reason: 'a sibling’s row shows no light it did not ask for');

    // "At time" is the other half of the same answer, still one prayer's.
    await scrollAndTap(tester, find.text('At time').first);
    expect(settings.notifyOffsetFor(kNotifiablePrayers.first), -1);
    expect(settings.notifyOffsetFor(kNotifiablePrayers.last), 5,
        reason: 'the last prayer never moved');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Custom… asks for a number and files it on its own row',
      (WidgetTester tester) async {
    final AppSettings settings = await pumpCard(tester);
    for (final String key in kNotifiablePrayers) {
      settings.setNotifyOffset(key, 5);
    }
    await openSheet(tester);

    // Dhuhr's row is the second one — a reader who knows they want seven
    // minutes has a door in every row, and it answers for that row only.
    final String prayer = kNotifiablePrayers[1];
    await scrollAndTap(tester, find.text('Custom…').at(1));

    expect(find.byType(AlertDialog), findsOneWidget,
        reason: 'the door asks rather than guessing a number');
    await tester.enterText(find.byType(TextField), '7');
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();

    expect(settings.notifyOffsetFor(prayer), 7,
        reason: 'the typed number lands on the prayer whose row asked');
    expect(settings.notifyOffsetFor(kNotifiablePrayers.first), 5,
        reason: 'the row above it was not asked');
    // A custom number is a *kept* answer, and exactly one chip says it: the
    // Custom… door wears the number it is holding, rather than a duplicate
    // chip the reader never picked standing in for it.
    expect(find.text('7 min'), findsOneWidget);

    // Two hours is a typo, not a reminder — the door keeps asking. Dhuhr's
    // chip now wears "7 min" rather than "Custom…", so the second door in
    // line is Asr's row and only Asr's.
    await scrollAndTap(tester, find.text('Custom…').at(1));
    await tester.enterText(find.byType(TextField), '500');
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget,
        reason: 'an impossible number is refused, not stored');
    expect(settings.notifyOffsetFor(kNotifiablePrayers[2]), 5,
        reason: 'the refused row kept its own answer');

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox());
  });

  test('the sheet is wired to the card’s re-arm', () {
    final String source =
        File('lib/today_prayer_card.dart').readAsStringSync();
    expect(source, contains('_AzaanAlertSheet(onChanged: _armReschedule)'),
        reason: 'a pick that is never re-armed keeps ringing the old way — '
            'the reader would change the clip and hear the old one.');
    expect(source, contains('tooltip: \'Azaan sound & timing\''),
        reason: 'the button’s own words, which is also how a reader finds '
            'it again.');
  });

  test('the per-prayer and own-file doors are wired where they cannot be seen',
      () {
    final String card = File('lib/today_prayer_card.dart').readAsStringSync();
    expect(card, contains('_offsetRow(prayer)'),
        reason: 'a row per prayer is the whole of "each prayer sets its '
            'own minutes" — one shared row would put them back together.');
    expect(card, contains('_askCustomOffset(prayer)'),
        reason: 'the Custom… chip has to ask *the prayer whose row it is*, '
            'or the typed number lands on somebody else’s reminder.');
    expect(card, contains('AzaanAlarm.pickAudioFile()'),
        reason: 'the own-file row opens the picker on the Kotlin side, '
            'which is what copies the bytes where the alarm can reopen them.');
    expect(card, contains('previewFile(path)'),
        reason: 'the rehearsal must play the *copied* file — that is exactly '
            'what tomorrow’s alarm plays.');

    final String player =
        File('lib/services/azan_player.dart').readAsStringSync();
    expect(player, contains('if (key == kCustomAzanKey)'),
        reason: 'a reminder replayed from its banner goes through _start, '
            'which would otherwise look the key up in the built-in list and '
            'find nothing to play.');

    final String main = File('lib/main.dart').readAsStringSync();
    expect(main, contains('static String _bellRaw(String prayer)'),
        reason: 'the alarm carries a file name, and a custom clip names the '
            'file copied when it was picked — not a bundled raw resource.');
    expect(main, contains('raw: _bellRaw(key)'),
        reason: 'every scheduling site has to carry that name, or the alarm '
            'fires with the old clip.');
    expect(main,
        contains('if (sound.key == kCustomAzanKey) return kCustomAzanKey;'),
        reason: 'the branch that turns the key into that file name is only '
            'live once azanSoundByKey answers "custom" for a stored '
            '"custom" — while it answered the first catalogue entry instead, '
            'this line was unreachable and every alarm recited Makkah in '
            'place of the clip the reader had chosen.');

    final String activity =
        File('android/app/src/main/kotlin/com/sunesra_app/MainActivity.kt')
            .readAsStringSync();
    expect(activity, contains('azaan_custom.clip'),
        reason: 'the copy lands where AzaanAudio.cachedClip("custom") reads: '
            'filesDir/azaan_custom.clip — that match is the alarm path.');
  });
}
