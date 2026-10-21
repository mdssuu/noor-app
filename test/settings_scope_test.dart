import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression for: "in one account I set the Azan reminder to 10 min before
/// and the other account had it too."
///
/// Every setting used to be stored under a bare key, so all accounts signed
/// in on one phone read and wrote the same preferences.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('settings key is scoped per account', () {
    test('two signed-in accounts never share a key', () {
      expect(
        AppSettings.scopedKeyFor('azanNotifications', 'uid-a'),
        isNot(AppSettings.scopedKeyFor('azanNotifications', 'uid-b')),
      );
      expect(
        AppSettings.scopedKeyFor('azanNotifications', 'uid-a'),
        isNot(AppSettings.scopedKeyFor('azanNotifications', null)),
      );
      expect(AppSettings.scopedKeyFor('notify_asr', 'uid-a'), 'notify_asr::uid-a');
      expect(AppSettings.scopedKeyFor('notify_asr', null), 'notify_asr::anon');
    });

    test('no profile reuses the old device-wide key', () {
      expect(AppSettings.scopedKeyFor('calcMethod', 'uid-a'), isNot('calcMethod'));
      expect(AppSettings.scopedKeyFor('notify_asr', null), isNot('notify_asr'));
      expect(AppSettings.scopedKeyFor('azanSound', null), isNot('azanSound'));
    });

    test('legacy device-wide settings move to the profile that claims them', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'calcMethod': 'karachi',
        'madhab': 'hanafi',
        'azanSound': 'madina',
        'azanNotifications': true,
        'notify_asr': 10,
        'notifyon_asr': false,
        'hijriAdjustment': 1,
        'customCity': 'Kurla',
        'customLat': 19.076,
        'customLng': 72.8777,
      });
      final SharedPreferences prefs = await SharedPreferences.getInstance();

      await AppSettings.retireLegacyKeys(prefs, 'uid-a');

      expect(prefs.getString(AppSettings.scopedKeyFor('calcMethod', 'uid-a')), 'karachi');
      expect(prefs.getString(AppSettings.scopedKeyFor('madhab', 'uid-a')), 'hanafi');
      expect(prefs.getString(AppSettings.scopedKeyFor('azanSound', 'uid-a')), 'madina');
      expect(prefs.getBool(AppSettings.scopedKeyFor('azanNotifications', 'uid-a')), true);
      expect(prefs.getInt(AppSettings.scopedKeyFor('notify_asr', 'uid-a')), 10);
      expect(prefs.getBool(AppSettings.scopedKeyFor('notifyon_asr', 'uid-a')), false);
      expect(prefs.getInt(AppSettings.scopedKeyFor('hijriAdjustment', 'uid-a')), 1);
      expect(prefs.getString(AppSettings.scopedKeyFor('customCity', 'uid-a')), 'Kurla');
      expect(prefs.getDouble(AppSettings.scopedKeyFor('customLat', 'uid-a')), closeTo(19.076, 1e-9));
      expect(prefs.getDouble(AppSettings.scopedKeyFor('customLng', 'uid-a')), closeTo(72.8777, 1e-9));
    });

    test('every bare key is removed so no later profile can inherit it', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'calcMethod': 'karachi',
        'madhab': 'hanafi',
        'timeFormat': '24',
        'hijriAdjustment': 2,
        'customCity': 'Kurla',
        'azanNotifications': false,
        'azanSound': 'mishary',
        'notify_fajr': 5,
        'notify_dhuhr': 10,
        'notify_asr': 10,
        'notify_maghrib': -1,
        'notify_isha': 5,
        'notifyon_fajr': false,
        'notifyon_dhuhr': true,
        'notifyon_asr': false,
        'notifyon_maghrib': true,
        'notifyon_isha': false,
      });
      final SharedPreferences prefs = await SharedPreferences.getInstance();

      await AppSettings.retireLegacyKeys(prefs, 'uid-a');

      for (final String key in prefs.getKeys()) {
        expect(key, contains('::'), reason: '$key was left device-wide');
      }
      // ...and the other account starts clean rather than inheriting these.
      expect(prefs.getString(AppSettings.scopedKeyFor('calcMethod', 'uid-b')), isNull);
      expect(prefs.getInt(AppSettings.scopedKeyFor('notify_asr', 'uid-b')), isNull);
      expect(prefs.getBool(AppSettings.scopedKeyFor('azanNotifications', 'uid-b')), isNull);
    });

    test('a profile that already owns a setting keeps it', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'calcMethod': 'karachi', // device-wide leftover
        AppSettings.scopedKeyFor('calcMethod', 'uid-a'): 'egyptian',
      });
      final SharedPreferences prefs = await SharedPreferences.getInstance();

      await AppSettings.retireLegacyKeys(prefs, 'uid-a');

      expect(prefs.getString(AppSettings.scopedKeyFor('calcMethod', 'uid-a')), 'egyptian');
      expect(prefs.containsKey('calcMethod'), isFalse);
    });

    test('running it twice changes nothing', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{'notify_fajr': 5});
      final SharedPreferences prefs = await SharedPreferences.getInstance();

      await AppSettings.retireLegacyKeys(prefs, 'uid-a');
      await AppSettings.retireLegacyKeys(prefs, 'uid-a');

      expect(prefs.getInt(AppSettings.scopedKeyFor('notify_fajr', 'uid-a')), 5);
      expect(prefs.containsKey('notify_fajr'), isFalse);
    });

    test('the signed-out profile is a profile too', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{'azanSound': 'mishary'});
      final SharedPreferences prefs = await SharedPreferences.getInstance();

      await AppSettings.retireLegacyKeys(prefs, null);

      expect(prefs.getString(AppSettings.scopedKeyFor('azanSound', null)), 'mishary');
      expect(prefs.containsKey('azanSound'), isFalse);
    });

    test('a clean install has nothing to migrate', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SharedPreferences prefs = await SharedPreferences.getInstance();

      await AppSettings.retireLegacyKeys(prefs, 'uid-a');

      expect(prefs.getKeys(), isEmpty);
    });
  });

  // Regression for: "in one account I set the Azan reminder to 10 min before
  // and the other account had it too" — the whole point of the scoping.
  group('a setting saved in one account never reaches another', () {
    test('read, then write, then read again', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        AppSettings.scopedKeyFor('azanSound', 'uid-a'): 'madina',
        AppSettings.scopedKeyFor('notify_asr', 'uid-a'): 10,
        AppSettings.scopedKeyFor('notifyon_asr', 'uid-a'): true,
      });
      final AppSettings settings = AppSettings.instance;

      await settings.useProfile('uid-a');
      expect(settings.azanSound, 'madina');
      expect(settings.notifyOffsetFor('asr'), 10);

      // Account B has never set anything, so it must land on the defaults
      // rather than inherit A's 10-minute reminder.
      await settings.useProfile('uid-b');
      expect(settings.azanSound, 'makkah');
      expect(settings.notifyOffsetFor('asr'), -1);
      expect(settings.madhabKey, 'shafi');

      // Writing as B must leave A's copy alone.
      settings.setAzanSound('beep');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppSettings.scopedKeyFor('azanSound', 'uid-b')), 'beep');
      expect(prefs.getString(AppSettings.scopedKeyFor('azanSound', 'uid-a')), 'madina');

      // And A still reads its own values back after the round trip.
      await settings.useProfile('uid-a');
      expect(settings.azanSound, 'madina');
      expect(settings.notifyOffsetFor('asr'), 10);
      expect(settings.notifyOnFor('asr'), true);
    });
  });
}
