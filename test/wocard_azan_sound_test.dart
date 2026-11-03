import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/main.dart' show buildNoorTheme;
import 'package:noor_masjid_time/today_prayer_card.dart';
import 'package:noor_masjid_time/services/azan_player.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The clip row's own answer: selected *and* sounding — now inside the Home
/// bell dialog, where a masjid's voice is chosen.
///
/// A row that lights up and stays quiet is the broken-button complaint all
/// over again, so the pick is pinned end to end — the choice lands, the
/// channel is rebuilt around it, the preview starts, and the row says so.
///
/// It lives in a file of its own, and it has to: `AzanPlayer` is a singleton
/// whose fallback player waits on a `Completer` made when it is first
/// constructed, and a `Completer` from one `testWidgets` never reaches a
/// later one — each test runs in a fake clock zone of its own. Whichever test
/// constructs the player therefore owns it forever, and in a file where the
/// dialog had already been opened the preview would wait on a future that no
/// test will ever flush. Alone here, these tests are the ones that construct
/// it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel native = MethodChannel('noor_masjid_time/azaan');
  const MethodChannel fallbackGlobal =
      MethodChannel('xyz.luan/audioplayers.global');
  const MethodChannel fallback = MethodChannel('xyz.luan/audioplayers');

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final AppSettings settings = AppSettings.instance;
    await settings.useProfile('wocard-azan-sound');
    // The preview goes down the native alarm-stream path first; answering
    // `true` keeps the test on it, which is the order production runs in.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, (MethodCall call) async =>
            call.method == 'playNow' ? true : null);

    // The *fallback* player's own platform side does not exist under test —
    // and a platform message with nobody to answer it never comes back once
    // the clock is faked, so `AzanPlayer.stop()` would wait on it forever and
    // the preview would never start. Answering both of its channels is that
    // platform side in one line; the preview takes the native path above and
    // never asks these for a sound.
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        fallbackGlobal, (MethodCall call) async => null);
    messenger.setMockMethodCallHandler(
        fallback, (MethodCall call) async => null);
  });

  tearDown(() {
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(native, null);
    messenger.setMockMethodCallHandler(fallbackGlobal, null);
    messenger.setMockMethodCallHandler(fallback, null);
  });

  Future<AppSettings> pumpCard(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: buildNoorTheme(),
      home: const Scaffold(
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

  Future<void> openBell(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.notifications_off_outlined).first);
    await tester.pumpAndSettle();
  }

  Future<void> tapRow(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('picking a clip makes it the one, and rehearses it',
      (WidgetTester tester) async {
    final AppSettings settings = await pumpCard(tester);
    await openBell(tester);

    await tapRow(tester, find.text('Simple Beep'));

    expect(settings.azanSound, 'beep');
    expect(find.byIcon(Icons.radio_button_checked), findsWidgets,
        reason: 'the chosen clip claims to be in force');
    expect(find.byIcon(Icons.stop_circle_outlined), findsWidgets,
        reason: 'and the clip that just sounded says so on its own row — a '
            'row that selected and stayed silent would be the broken button '
            'all over again.');
    expect(
      find.byType(SnackBar),
      findsNothing,
      reason: 'nothing declined, so nothing needed explaining: the row that '
          'cannot be heard is the one that says why, and this one was heard',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('“None (silent)” files the choice and rehearses nothing',
      (WidgetTester tester) async {
    final AppSettings settings = await pumpCard(tester);
    settings.setAzanSound('makkah');
    await tester.pump();
    await openBell(tester);

    await tapRow(tester, find.text('None (silent)'));

    expect(settings.azanSound, 'silent',
        reason: 'the choice itself still lands — only the rehearsal is gone');
    expect(
      AzanPlayer.instance.playingKey,
      isNull,
      reason: 'choosing “None (silent)” used to answer with a full Makkah '
          'recitation, which is the one sound the reader had just asked the '
          'app not to make',
    );
    expect(
      find.textContaining('nothing is playing now'),
      findsOneWidget,
      reason: 'and the row says what it did instead of staying wordless — a '
          'tap that answers nothing is the broken-button bug in new clothes',
    );
    expect(
      find.byIcon(Icons.volume_off_outlined),
      findsOneWidget,
      reason: 'the row wears the mute sign, not a play button promising a '
          'sound it is built not to make',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the reader’s own clip is a row here, and only here',
      (WidgetTester tester) async {
    await pumpCard(tester);
    await openBell(tester);

    final Finder door = find.text('Choose a file… (your own Azaan)');
    expect(door, findsOneWidget,
        reason: 'the own-file door lives in the bell dialog, beside the '
            'masjid’s other clips');
    await tester.ensureVisible(door);
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox());
  });
}
