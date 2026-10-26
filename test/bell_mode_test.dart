import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Home bell's three states, in the reader's own words: the default is
/// off — silence is the app's opening answer, and it is the bell's dialog
/// (Azaan / Mute / Band) that hands a reader a state — while the Settings
/// switch holds the same "off", so the two never disagree about which of the
/// three is meant.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.instance.load();
  });

  group('a bell nobody has chosen starts off', () {
    test('a fresh profile rings for nobody, not even the azaan', () {
      final AppSettings settings = AppSettings.instance;
      expect(settings.bellModeFor('fajr'), kBellOff);
      expect(settings.notifyOnFor('fajr'), isFalse);
    });

    test('a quiet global sound does not wake an untouched bell', () {
      final AppSettings settings = AppSettings.instance;
      settings.setAzanSound('silent');
      expect(settings.bellModeFor('fajr'), kBellOff);
    });
  });

  group('the three answers', () {
    test('Azaan rings the full way — card and recitation', () {
      final AppSettings settings = AppSettings.instance;
      settings.setBellMode('fajr', kBellAzan);
      expect(settings.bellModeFor('fajr'), kBellAzan);
      expect(settings.notifyOnFor('fajr'), isTrue);
    });

    test('Mute keeps the card and drops the recitation', () {
      final AppSettings settings = AppSettings.instance;
      settings.setBellMode('fajr', kBellSilent);
      expect(settings.bellModeFor('fajr'), kBellSilent);
      expect(settings.notifyOnFor('fajr'), isTrue,
          reason: 'silent still shows a banner, so Settings still reads on');
    });

    test('Band does neither — not even a card', () {
      final AppSettings settings = AppSettings.instance;
      settings.setBellMode('fajr', kBellOff);
      expect(settings.bellModeFor('fajr'), kBellOff);
      expect(settings.notifyOnFor('fajr'), isFalse);
    });

    test('touches only the prayer it was chosen for', () {
      final AppSettings settings = AppSettings.instance;
      settings.setBellMode('isha', kBellOff);
      expect(settings.bellModeFor('maghrib'), kBellOff,
          reason: 'untouched prayers keep the default off too');
      expect(settings.notifyOnFor('maghrib'), isFalse);
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
      expect(settings.bellModeFor('fajr'), kBellOff,
          reason: 'nothing stored, so the default stays off');
      expect(settings.notifyOnFor('fajr'), isFalse);
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
