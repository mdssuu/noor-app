import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/main.dart';
import 'package:noor_masjid_time/today_prayer_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What a prayer's own bell asks, now that it asks the whole question.
///
/// The bell used to answer only *whether* this prayer rings. The button that
/// sat beside Share carried the other half — how long before the prayer the
/// knock arrives — and it has moved in here, one prayer at a time, because
/// that is the only scope the offset has ever had: a reader who wants Fajr
/// five minutes early and Isha on the dot has always been able to store
/// exactly that, prayer by prayer. What did *not* move in is the clip: it is
/// one global answer (the bells gate *whether* a prayer recites, never what
/// it recites), so its door stays in Settings and a pin below keeps it there.
///
/// The other half of the move — that the dialog now answers in place instead
/// of closing on the first tap — is what lets one open serve both questions.
///
/// The clip's own rehearsal lives in `wocard_azan_sound_test.dart`, because
/// a player first created in one test can never answer a later one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel native = MethodChannel('noor_masjid_time/azaan');

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final AppSettings settings = AppSettings.instance;
    await settings.useProfile('wocard-bell-dialog');
    // Nothing here starts a preview, but leaving the card stops whatever the
    // shared player is holding, and a platform message nobody answers never
    // comes back once the clock is faked.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, (MethodCall call) async =>
            call.method == 'playNow' ? true : null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, null);
  });

  /// The dialog is a fixed-width panel, so the card behind it is all the
  /// window it needs — but a window shorter than the panel would push the
  /// chips under the ceiling where a tap cannot reach them.
  Future<AppSettings> pumpCard(WidgetTester tester) async {
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

  /// Opens the first prayer's own dialog — a fresh profile leaves every bell
  /// on Band, and the rows are drawn in prayer order, so the first crossed
  /// bell is Fajr's.
  Future<void> openBell(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.notifications_off_outlined).first);
    await tester.pumpAndSettle();
  }

  testWidgets('the bell opens one dialog with the three answers and the '
      'timing chips',
      (WidgetTester tester) async {
    final AppSettings settings = await pumpCard(tester);

    // Share is still where the family group expects it. The tune button that
    // used to sit beside it is gone: its whole answer now belongs to the
    // prayer it was being asked about.
    expect(find.byTooltip('Share times'), findsOneWidget);
    expect(find.byTooltip('Azaan sound & timing'), findsNothing,
        reason: 'the tune button carried a question about *this* prayer from '
            'a button that never knew which one it was about');

    await openBell(tester);

    expect(find.text('${prayerByKey('fajr').label} bell'), findsOneWidget,
        reason: 'the dialog is named for the prayer whose bell was tapped');
    // The three answers, in the reader's own words.
    for (final String name in <String>['Azaan', 'Mute', 'Band']) {
      expect(find.text(name), findsOneWidget, reason: name);
    }

    // …and the half that moved in: this prayer's own timing.
    expect(find.text('When it rings'), findsOneWidget);
    for (final int minutes in kNotifyOffsets) {
      expect(
        find.text(notifyOffsetChipLabel(minutes)),
        findsOneWidget,
        reason: 'every offered offset is one chip, in this prayer\'s dialog '
            'alone — a second copy would be a second prayer\'s',
      );
    }
    expect(find.text('Custom…'), findsOneWidget,
        reason: 'the door to a number no chip carries');
    // The caption names the clock the offset is measured against — this
    // build's mode is "only at my masjid's Jamaat time".
    expect(
      find.textContaining('before your favourite masjid’s Jamaat time'),
      findsOneWidget,
    );

    // The clip does not belong here: it is one answer for every prayer, so
    // the dialog that only one prayer can open must not offer it.
    for (final AzanSound sound in kAzanSounds) {
      expect(find.text(sound.label), findsNothing, reason: sound.label);
    }
    expect(find.text('Choose a file… (your own Azaan)'), findsNothing);

    // Closing leaves the bell exactly as it was — dismissing the question is
    // not an answer.
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(settings.bellModeFor('fajr'), kBellOff);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a chip files the offset against that prayer alone, and the '
      'dialog stays open to say so',
      (WidgetTester tester) async {
    final AppSettings settings = await pumpCard(tester);
    for (final String key in kNotifiablePrayers) {
      settings.setNotifyOffset(key, 5);
      settings.setFavMode(key, kFavModeOffset);
    }
    await openBell(tester);

    // Fajr's own "15 min". Nothing the reader taps here may move a sibling,
    // and nothing may close the question over their head.
    await tester.tap(find.text('15 min'));
    await tester.pumpAndSettle();

    expect(settings.notifyOffsetFor('fajr'), 15,
        reason: 'the prayer whose dialog was open is the prayer that changed');
    expect(settings.favModeFor('fajr'), kFavModeOffset,
        reason: 'that prayer’s Jamaat source reads its own switch, so the '
            'pair moves together');
    for (final String key in kNotifiablePrayers.skip(1)) {
      expect(settings.notifyOffsetFor(key), 5, reason: '$key was not asked');
      expect(settings.favModeFor(key), kFavModeOffset,
          reason: '$key’s switch stays where it was put');
    }

    expect(find.byType(AlertDialog), findsOneWidget,
        reason: 'the dialog answers in place — a reader comparing chips must '
            'not have to reopen it for each one');
    // The chosen chip is visibly chosen, and it is the only one lit.
    final Container lit = tester.widget<Container>(
      find.descendant(
        of: find.widgetWithText(InkWell, '15 min'),
        matching: find.byType(Container),
      ),
    );
    expect((lit.decoration! as BoxDecoration).color, NoorColors.emerald);
    final Container atTime = tester.widget<Container>(
      find.descendant(
        of: find.widgetWithText(InkWell, 'At time'),
        matching: find.byType(Container),
      ),
    );
    expect((atTime.decoration! as BoxDecoration).color, NoorColors.white,
        reason: 'a chip the reader did not ask for wears no light');

    // "At time" is the other half of the same answer, still this prayer's.
    await tester.tap(find.text('At time'));
    await tester.pumpAndSettle();
    expect(settings.notifyOffsetFor('fajr'), -1);
    expect(settings.notifyOffsetFor(kNotifiablePrayers.last), 5,
        reason: 'the last prayer never moved');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Custom… asks for a number and files it on this prayer',
      (WidgetTester tester) async {
    final AppSettings settings = await pumpCard(tester);
    for (final String key in kNotifiablePrayers) {
      settings.setNotifyOffset(key, 5);
      settings.setFavMode(key, kFavModeOffset);
    }
    await openBell(tester);

    await tester.tap(find.text('Custom…'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNWidgets(2),
        reason: 'the door asks rather than guessing a number, on top of the '
            'bell dialog that is still holding the question');
    await tester.enterText(find.byType(TextField), '7');
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();

    expect(settings.notifyOffsetFor('fajr'), 7,
        reason: 'the typed number lands on the prayer whose dialog asked');
    for (final String key in kNotifiablePrayers.skip(1)) {
      expect(settings.notifyOffsetFor(key), 5, reason: '$key was not asked');
    }
    // A custom number is a *kept* answer, and exactly one chip says it: the
    // Custom… door wears the number itself rather than a plain "Custom…"
    // that hides a seven already filed.
    expect(find.text('7 min'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNWidgets(1),
        reason: 'only the bell dialog is left, still open on the answer');

    // Two hours is a typo, not a reminder — the door keeps asking. The chip
    // now wears "7 min" rather than "Custom…", because a kept custom number
    // is an answer worth showing rather than a door worth hiding.
    await tester.tap(find.text('7 min'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '500');
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNWidgets(2),
        reason: 'an impossible number is refused, not stored');
    expect(settings.notifyOffsetFor('fajr'), 7,
        reason: 'the refused pick kept its own answer');

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox());
  });

  test('the dialog is wired to the card’s re-arm and keeps its doors shut',
      () {
    final String card = File('lib/today_prayer_card.dart').readAsStringSync();

    // A pick that is never re-armed keeps ringing the old way — the reader
    // would move the chip and still hear the old clock. Every pick here goes
    // through the card's own debounce.
    expect(card, contains('settings.setNotifyOffset(key, minutes)'),
        reason: 'the chip files against the prayer whose dialog it is in');
    expect(card, contains('settings.setFavMode(key, minutes < 0'),
        reason: 'the offset and the Jamaat source\'s own switch move as a '
            'pair, whichever mode happens to be in force');
    expect(card, contains('_askCustomOffset(key, setDialog)'),
        reason: 'the Custom… chip has to ask *the prayer whose dialog it is*, '
            'or the typed number lands on somebody else’s reminder.');
    expect(card, contains('_armReschedule();'),
        reason: 'every pick rides the same debounced re-arm the card has '
            'always used, so five chips cost one schedule pass');

    // The old door is bolted shut: no sheet, no button to open it.
    expect(card, isNot(contains('_AzaanAlertSheet')),
        reason: 'the sheet carried a clip question that was never this '
            'prayer\'s to answer, and a button beside Share that nobody '
            'could find again');
    expect(card, isNot(contains('Azaan sound & timing')),
        reason: 'the tune button\'s own words, and the last place they may '
            'live is nowhere');
    expect(card, isNot(contains('pickAudioFile')),
        reason: 'the clip door moved to Settings, where the global answer '
            'actually lives');
  });

  test('the own-file door now lives where the other clips do', () {
    final String settings = File('lib/screens/settings_screen.dart').readAsStringSync();
    expect(settings, contains('AzaanAlarm.pickAudioFile()'),
        reason: 'the own-file row opens the picker on the Kotlin side, '
            'which is what copies the bytes where the alarm can reopen them.');
    expect(settings, contains('previewFile(path)'),
        reason: 'the rehearsal must play the *copied* file — that is exactly '
            'what tomorrow’s alarm plays.');
    expect(settings, contains('Choose a file… (your own Azaan)'),
        reason: 'the row reads as the door until there is a file to name, '
            'and as the file\'s name once there is — a second pick has to be '
            'visibly a replacement.');

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
