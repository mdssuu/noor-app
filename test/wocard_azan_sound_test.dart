import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/main.dart' show buildNoorTheme;
import 'package:noor_masjid_time/screens/settings_screen.dart';
import 'package:noor_masjid_time/services/azan_player.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The clip row's own answer: selected *and* sounding.
///
/// A row that lights up and stays quiet is the broken-button complaint all
/// over again, so the pick is pinned end to end — the choice lands, the
/// channel is rebuilt around it (Android freezes a channel's sound at
/// creation), the preview starts, and leaving the screen takes the preview
/// with it.
///
/// It lives in a file of its own, and it has to: `AzanPlayer` is a singleton
/// whose fallback player waits on a `Completer` made when it is first
/// constructed, and a `Completer` from one `testWidgets` never reaches a
/// later one — each test runs in a fake clock zone of its own. Whichever test
/// constructs the player therefore owns it forever, and in a file where the
/// dialog had already been opened the preview would wait on a future that no
/// test will ever flush. Alone here, these tests are the ones that construct
/// it.
///
/// The rows used to sit behind the Home card's tune button. That button
/// asked a question about one prayer and could not say which, so it is gone
/// and these rows are back in Settings — the one screen that owns every
/// global answer.
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

  /// Settings is a long screen and the sound card is well down it, so the
  /// window is given a phone's worth of height *and* each row is brought up
  /// before it is tapped — a tap fired blind at an off-screen row fails the
  /// test rather than the reader.
  Future<AppSettings> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: buildNoorTheme(),
      home: const SettingsScreen(),
    ));
    await tester.pump();
    return AppSettings.instance;
  }

  Future<void> tapRow(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('picking a clip makes it the one, and rehearses it',
      (WidgetTester tester) async {
    final AppSettings settings = await pumpSettings(tester);

    await tapRow(tester, find.text('Simple Beep'));

    expect(settings.azanSound, 'beep');
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget,
        reason: 'exactly one clip claims to be in force');
    expect(find.byIcon(Icons.stop_circle_outlined), findsWidgets,
        reason: 'and the clip that just sounded says so on its own row — a '
            'row that selected and stayed silent would be the broken button '
            'all over again. "Test Azaan" mirrors the same state, which is '
            'why this is not a count of one.');
    expect(
      find.byType(SnackBar),
      findsNothing,
      reason: 'nothing declined, so nothing needed explaining: the row that '
          'cannot be heard is the one that says why, and this one was heard',
    );

    // Leaving takes the preview with it — the stop button is no longer
    // reachable once this screen is gone.
    await tester.pumpWidget(const SizedBox());
    expect(AzanPlayer.instance.playingKey, isNull);
  });

  testWidgets('“None (silent)” files the choice and rehearses nothing',
      (WidgetTester tester) async {
    final AppSettings settings = await pumpSettings(tester);
    settings.setAzanSound('makkah');
    await tester.pump();

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
    await pumpSettings(tester);

    // The door that used to sit in the Home card's sheet is back in the one
    // screen that owns every global answer — the clip is the same for every
    // prayer, so a per-prayer door for it would promise a choice no
    // per-prayer alarm can keep.
    final Finder door = find.text('Choose a file… (your own Azaan)');
    expect(door, findsOneWidget);
    await tester.ensureVisible(door);
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox());
  });
}
