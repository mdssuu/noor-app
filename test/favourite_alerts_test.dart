import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression for: "I want to also receive notification of prayer time [for]
/// which mosque I added to my favourite list, with an on/off option."
///
/// Two things had to hold for that to work: a board's clock had to be read
/// into a real time of day (a hand-entered `5:30 PM` must not become 05:30),
/// and the on/off switch had to belong to one account the way every other
/// notification setting already did.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a masjid board clock becomes a time of day', () {
    test('reads the 24-hour form written by the scanner', () {
      expect(NotificationService.parseClockTime('05:50'), 5 * 60 + 50);
      expect(NotificationService.parseClockTime('00:00'), 0);
      expect(NotificationService.parseClockTime('07:39'), 7 * 60 + 39);
      expect(NotificationService.parseClockTime('23:59'), 23 * 60 + 59);
      expect(NotificationService.parseClockTime('9:05'), 9 * 60 + 5);
      expect(NotificationService.parseClockTime('  13:15  '), 13 * 60 + 15);
    });

    test('reads a hand-entered clock with a meridiem, not as 24-hour', () {
      expect(NotificationService.parseClockTime('5:30 PM'), 17 * 60 + 30);
      expect(NotificationService.parseClockTime('5:30 AM'), 5 * 60 + 30);
      expect(NotificationService.parseClockTime('12:15 PM'), 12 * 60 + 15);
      expect(NotificationService.parseClockTime('12:05 am'), 5);
      expect(NotificationService.parseClockTime('11:59 pm'), 23 * 60 + 59);
    });

    test('a board with no time for that prayer schedules nothing', () {
      expect(NotificationService.parseClockTime('--:--'), isNull);
      expect(NotificationService.parseClockTime(''), isNull);
      expect(NotificationService.parseClockTime('   '), isNull);
      expect(NotificationService.parseClockTime('noon'), isNull);
      expect(NotificationService.parseClockTime('24:00'), isNull);
      expect(NotificationService.parseClockTime('13:60'), isNull);
      expect(NotificationService.parseClockTime('13:5'), isNull);
      expect(NotificationService.parseClockTime('-1:00'), isNull);
    });
  });

  group('the on/off switch belongs to one account', () {
    test('switching a masjid off in one account never reaches another', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final AppSettings settings = AppSettings.instance;

      await settings.useProfile('alert-uid-a');
      // A starred masjid is one you asked to hear from, so it starts on and
      // only the switch can turn it off.
      expect(settings.favAlertFor('masjid-x'), isTrue);
      expect(settings.favAlertMasjidIds(), isEmpty);

      settings.setFavAlert('masjid-x', false);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await settings.useProfile('alert-uid-b');
      expect(settings.favAlertFor('masjid-x'), isTrue);
      expect(settings.favAlertMasjidIds(), isEmpty);

      await settings.useProfile('alert-uid-a');
      expect(settings.favAlertFor('masjid-x'), isFalse);
      expect(settings.favAlertMasjidIds(), contains('masjid-x'));

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(AppSettings.scopedKeyFor('favalert::masjid-x', 'alert-uid-a')), false);
      // ...and the key itself never sits device-wide where anyone could pick
      // it up, which is exactly how the original leak happened.
      expect(prefs.containsKey('favalert::masjid-x'), isFalse);
    });

    test('the timing choice is per account too', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final AppSettings settings = AppSettings.instance;

      await settings.useProfile('mode-uid-a');
      expect(settings.favModeFor('fajr'), kFavModeAt);
      settings.setFavMode('fajr', kFavModeOffset);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await settings.useProfile('mode-uid-b');
      expect(settings.favModeFor('fajr'), kFavModeAt);

      await settings.useProfile('mode-uid-a');
      expect(settings.favModeFor('fajr'), kFavModeOffset);

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(AppSettings.scopedKeyFor('favmode_fajr', 'mode-uid-a')),
        kFavModeOffset,
      );
      expect(prefs.containsKey('favmode_fajr'), isFalse);
    });

    test('an unknown mode is rejected rather than stored', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final AppSettings settings = AppSettings.instance;

      await settings.useProfile('mode-uid-c');
      settings.setFavMode('asr', 'whenever');
      expect(settings.favModeFor('asr'), kFavModeAt);
    });

    test('the new timing keys migrate off the device-wide name', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'favmode_asr': kFavModeOffset,
        'favmode_isha': kFavModeAt,
      });
      final SharedPreferences prefs = await SharedPreferences.getInstance();

      await AppSettings.retireLegacyKeys(prefs, 'migrate-uid');

      expect(prefs.getString(AppSettings.scopedKeyFor('favmode_asr', 'migrate-uid')),
          kFavModeOffset);
      expect(prefs.getString(AppSettings.scopedKeyFor('favmode_isha', 'migrate-uid')), kFavModeAt);
      expect(prefs.containsKey('favmode_asr'), isFalse);
      expect(prefs.containsKey('favmode_isha'), isFalse);
    });
  });
}
