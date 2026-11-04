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

  group('the star itself chooses the one Azaan masjid', () {
    test('the last star wins, and un-starring it hands the choice back',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final AppSettings settings = AppSettings.instance;
      await settings.useProfile('star-selects-uid');
      expect(settings.todayBoardId, isEmpty);

      // Star A — A now owns both the Today card and the Azaan.
      settings.setStarredSelection('masjid-a', true);
      expect(settings.todayBoardId, 'masjid-a');

      // Star B — exactly one masjid rings, and it is the one just starred.
      settings.setStarredSelection('masjid-b', true);
      expect(settings.todayBoardId, 'masjid-b');

      // Un-starring a masjid that is not chosen leaves the choice alone.
      settings.setStarredSelection('masjid-a', false);
      expect(settings.todayBoardId, 'masjid-b');

      // Un-starring the chosen one clears it; the automatic answer (nearest
      // starred) takes over rather than leaving a dead id behind.
      settings.setStarredSelection('masjid-b', false);
      expect(settings.todayBoardId, isEmpty);
    });

    test('the one-masjid choice still belongs to the account', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final AppSettings settings = AppSettings.instance;

      await settings.useProfile('star-choice-a');
      settings.setStarredSelection('masjid-a', true);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await settings.useProfile('star-choice-b');
      expect(settings.todayBoardId, isEmpty);

      await settings.useProfile('star-choice-a');
      expect(settings.todayBoardId, 'masjid-a');
    });
  });

  group('the on/off switch belongs to one account', () {
    test('switching a masjid off in one account never reaches another', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final AppSettings settings = AppSettings.instance;

      await settings.useProfile('alert-uid-a');
      // The chosen masjid starts on without any stored answer, and only the
      // switch can turn it off.
      settings.setStarredSelection('masjid-x', true);
      expect(settings.favAlertFor('masjid-x'), isTrue);
      expect(settings.favAlertMasjidIds(), isEmpty);

      settings.setFavAlert('masjid-x', false);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await settings.useProfile('alert-uid-b');
      // The other account chose nothing, so nothing of A's rings there.
      settings.setStarredSelection('masjid-x', true);
      expect(settings.favAlertFor('masjid-x'), isTrue);
      expect(settings.favAlertMasjidIds(), isEmpty);

      await settings.useProfile('alert-uid-a');
      expect(settings.todayBoardId, 'masjid-x');
      expect(settings.favAlertFor('masjid-x'), isFalse);
      expect(settings.favAlertMasjidIds(), contains('masjid-x'));

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(AppSettings.scopedKeyFor('favalert::masjid-x', 'alert-uid-a')), false);
      expect(prefs.getString(AppSettings.scopedKeyFor('today_board_pref', 'alert-uid-a')),
          'masjid-x');
      // ...and the key itself never sits device-wide where anyone could pick
      // it up, which is exactly how the original leak happened.
      expect(prefs.containsKey('favalert::masjid-x'), isFalse);
    });

    test('only the masjid chosen on Home may ring', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final AppSettings settings = AppSettings.instance;

      await settings.useProfile('one-masjid-uid');
      // Three stars, one alert: the star alone arms nothing — the Home pick
      // is the one masjid whose azan, notification and Jamaat alert fire.
      settings.setStarredSelection('masjid-a', true);
      settings.setStarredSelection('masjid-b', true);
      settings.setTodayBoard('masjid-a');
      expect(settings.favAlertFor('masjid-a'), isTrue);
      expect(settings.favAlertFor('masjid-b'), isFalse);

      // Turning it on for a second starred masjid moves the alert there,
      // and the first one goes quiet without a second tap.
      settings.setTodayBoard('masjid-b');
      expect(settings.favAlertFor('masjid-a'), isFalse);
      expect(settings.favAlertFor('masjid-b'), isTrue);

      // Switching the chosen masjid off leaves nothing ringing at all.
      settings.setFavAlert('masjid-b', false);
      expect(settings.favAlertFor('masjid-b'), isFalse);

      // Switching a masjid on picks it, even from the automatic answer.
      settings.setTodayBoard('');
      expect(settings.favAlertFor('masjid-a'), isFalse);
      settings.setFavAlert('masjid-a', true);
      expect(settings.todayBoardId, 'masjid-a');
      expect(settings.favAlertFor('masjid-a'), isTrue);
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
