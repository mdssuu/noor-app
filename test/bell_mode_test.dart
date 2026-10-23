import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Home bell's three states, in the reader's own words: the default is
/// "mute notification on", one tap is "azaan aur notification dono band",
/// the next is "dono on" — and the two switches Settings and Home hold
/// never disagree about which of the three is meant.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.instance.load();
  });

  group('a bell nobody has tapped derives its state', () {
    test('global "Azaan 1" → the full azan, exactly as the bell read before',
        () {
      expect(AppSettings.instance.bellModeFor('fajr'), kBellAzan);
    });

    test('global "None (silent)" → notification-only, the quiet default', () {
      final AppSettings settings = AppSettings.instance;
      settings.setAzanSound('silent');
      expect(settings.bellModeFor('fajr'), kBellSilent);
    });

    test('switched off in Settings → off, whatever the sound says', () {
      final AppSettings settings = AppSettings.instance;
      settings.setAzanSound('makkah');
      settings.setNotifyOn('fajr', false);
      expect(settings.bellModeFor('fajr'), kBellOff);
    });
  });

  group('the ring', () {
    test('walks azan → silent → off → azan', () {
      final AppSettings settings = AppSettings.instance;
      expect(settings.cycleBellMode('fajr'), kBellSilent);
      expect(settings.cycleBellMode('fajr'), kBellOff);
      expect(settings.cycleBellMode('fajr'), kBellAzan);
    });

    test('keeps the master switch agreeing at every step', () {
      final AppSettings settings = AppSettings.instance;

      settings.cycleBellMode('dhuhr'); // azan → silent
      expect(settings.notifyOnFor('dhuhr'), isTrue,
          reason: 'silent still shows a banner');

      settings.cycleBellMode('dhuhr'); // silent → off
      expect(settings.notifyOnFor('dhuhr'), isFalse);

      settings.cycleBellMode('dhuhr'); // off → azan
      expect(settings.notifyOnFor('dhuhr'), isTrue);
    });

    test('touches only the prayer it was tapped on', () {
      final AppSettings settings = AppSettings.instance;
      settings.setBellMode('isha', kBellOff);
      expect(settings.bellModeFor('maghrib'), kBellAzan);
      expect(settings.notifyOnFor('maghrib'), isTrue);
    });
  });

  group('the Settings switch and the bell', () {
    test('a stored azan comes back when Settings switches the prayer on again',
        () {
      final AppSettings settings = AppSettings.instance;
      settings.setBellMode('asr', kBellAzan);

      settings.setNotifyOn('asr', false);
      expect(settings.bellModeFor('asr'), kBellOff,
          reason: 'notifyOn false always wins');

      settings.setNotifyOn('asr', true);
      expect(settings.bellModeFor('asr'), kBellAzan,
          reason: 'the reader’s own choice survives the round trip');
    });

    test('an off bell switched on in Settings lands on the quiet default', () {
      final AppSettings settings = AppSettings.instance;
      settings.setAzanSound('silent');
      settings.setBellMode('maghrib', kBellOff); // stored off, notifyOn false

      settings.setNotifyOn('maghrib', true);
      expect(settings.bellModeFor('maghrib'), kBellSilent,
          reason: 'a quiet profile keeps its plain bells quiet');
    });

    test('rejects a mode that is not one of the three', () {
      final AppSettings settings = AppSettings.instance;
      settings.setBellMode('fajr', 'loud');
      expect(settings.bellModeFor('fajr'), kBellAzan,
          reason: 'nothing stored, so the derivation stands');
      expect(settings.notifyOnFor('fajr'), isTrue);
    });
  });

  test('the choice is written under the profile, not device-wide', () async {
    final AppSettings settings = AppSettings.instance;
    settings.setBellMode('isha', kBellSilent);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(AppSettings.scopedKeyFor('bellmode_isha', 'anon')),
      kBellSilent,
    );
    expect(prefs.containsKey('bellmode_isha'), isFalse);
  });
}
