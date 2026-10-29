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
/// Android freezes a channel's sound at creation) and the offset, filed
/// against every prayer the moment a chip is picked.
///
/// What is pinned here is the wiring a reader cannot see: that one chip
/// answers for *all five* prayers rather than the row it was tapped near,
/// and that the selected chip is the one lit. The clip's own rehearsal —
/// what the row shows while it sounds — lives in `wocard_azan_sound_test.dart`,
/// because a player first created in one test can never answer a later one.
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
    // row — laid out, but below the fold where a tap cannot reach it. A phone
    // gives the sheet more; a window shorter than that still scrolls, which
    // is what the sheet's own scroll view is there for.
    tester.view.physicalSize = const Size(800, 1000);
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
    expect(find.text('When it rings'), findsOneWidget);
    for (final int minutes in kNotifyOffsets) {
      expect(find.text(minutes < 0 ? 'At time' : '$minutes min'),
          findsOneWidget,
          reason: 'every offered offset is one chip');
    }
    // The caption has to name the clock the offset is measured against —
    // this build's mode is "only at my masjid's Jamaat time".
    expect(
      find.textContaining('before your favourite masjid’s Jamaat time'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('one chip files the offset against every prayer',
      (WidgetTester tester) async {
    final AppSettings settings = await pumpCard(tester);
    await openSheet(tester);

    await tester.tap(find.text('15 min'));
    await tester.pumpAndSettle();

    for (final String key in kNotifiablePrayers) {
      expect(settings.notifyOffsetFor(key), 15, reason: '$key too');
      expect(settings.favModeFor(key), kFavModeOffset,
          reason: '$key’s Jamaat source reads its own switch, so the pair '
              'moves together');
    }

    // And the chip that says it is the one in force is the one lit — five
    // prayers can be parted by Settings, and no chip lit until a tap unites
    // them is exactly what that should look like.
    final Finder chip = find.widgetWithText(InkWell, '15 min');
    final Container box = tester.widget<Container>(
      find.descendant(of: chip, matching: find.byType(Container)).first,
    );
    expect((box.decoration! as BoxDecoration).color, NoorColors.emerald,
        reason: 'the chosen chip is visibly chosen');

    // "At time" is the other half of the same answer.
    await tester.tap(find.text('At time'));
    await tester.pumpAndSettle();
    for (final String key in kNotifiablePrayers) {
      expect(settings.notifyOffsetFor(key), -1, reason: '$key too');
      expect(settings.favModeFor(key), kFavModeAt, reason: '$key too');
    }

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
}
