import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/services/azan_player.dart';
import 'package:noor_masjid_time/today_prayer_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The clip row's own answer: selected *and* sounding.
///
/// A row that lights up and stays quiet is the broken-button complaint all
/// over again, so the pick is pinned end to end — the choice lands, the
/// channel is rebuilt around it (Android freezes a channel's sound at
/// creation), the preview starts, and leaving the sheet takes the preview
/// with it.
///
/// It lives in a file of its own, and it has to: `AzanPlayer` is a singleton
/// whose fallback player waits on a `Completer` made when it is first
/// constructed, and a `Completer` from one `testWidgets` never reaches a
/// later one — each test runs in a fake clock zone of its own. Whichever test
/// constructs the player therefore owns it forever, and in a file where the
/// sheet had already been opened the preview would wait on a future that no
/// test will ever flush. Alone here, this test is the one that constructs it.
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

  testWidgets('picking a clip makes it the one, and rehearses it',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final AppSettings settings = AppSettings.instance;
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

    await tester.tap(find.byTooltip('Azaan sound & timing'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Simple Beep'));
    await tester.pumpAndSettle();

    expect(settings.azanSound, 'beep');
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget,
        reason: 'exactly one clip claims to be in force');
    expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget,
        reason: 'and the clip that just sounded says so — a row that selected '
            'and stayed silent would be the broken button all over again');
    expect(
      find.textContaining('silent or vibrate'),
      findsNothing,
      reason: 'nothing declined: the ringer answered normally',
    );

    // Leaving takes the preview with it — the stop button lives in the sheet.
    await tester.pumpWidget(const SizedBox());
    expect(AzanPlayer.instance.playingKey, isNull);
  });
}
