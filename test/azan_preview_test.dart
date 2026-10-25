import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/services/azan_player.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Test Azaan" is the one control whose whole job is to answer.
///
/// With the owner's old default — "None (silent)" — it answered nothing at
/// all: `_start` returned before it had called anything, so neither the row's
/// play icon nor the button moved, and a reader was left poking a control
/// that was wired correctly and simply *declined*. A preview owes an answer,
/// so the built-in clip stands in; a reminder tapped on a silent profile owes
/// silence, which is exactly what that profile asked for. Both halves are
/// pinned here, because either one drifting is the same bug wearing the other
/// one's clothes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel native = MethodChannel('noor_masjid_time/azaan');

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.instance.load();
    // The preview goes down the native alarm-stream path first; answering
    // `true` keeps the test on that path instead of falling through to the
    // remote clip, which is the order production runs in.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, (MethodCall call) async =>
            call.method == 'playNow' ? true : null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, null);
  });

  test('a silent profile still previews — the Test button is never dead',
      () async {
    AppSettings.instance.setAzanSound('silent');

    await AzanPlayer.instance.preview('silent');

    expect(AzanPlayer.instance.playingKey, 'silent',
        reason: 'the row and the button both read this to show a stop state');
    await AzanPlayer.instance.stop();
  });

  test('a chosen clip previews through the native player', () async {
    AppSettings.instance.setAzanSound('makkah');

    await AzanPlayer.instance.preview('makkah');

    expect(AzanPlayer.instance.playingKey, 'makkah');
    await AzanPlayer.instance.stop();
  });

  test('a reminder tapped on a silent profile stays silent', () async {
    AppSettings.instance.setAzanSound('silent');

    await AzanPlayer.instance.playSelected();

    expect(AzanPlayer.instance.playingKey, isNull,
        reason: 'the built-in stand-in belongs to previews, not to reminders');
  });
}
