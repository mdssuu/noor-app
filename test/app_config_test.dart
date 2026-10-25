import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/prayer_readings.dart';
import 'package:noor_masjid_time/services/app_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The owner's control document, from the two directions that matter:
///
///  * parsing — a document nobody typed into may be missing, hand-edited,
///    or left holding something this build no longer offers, and none of
///    that may reach a screen as an unrenderable state;
///  * seeding — the one rule the whole feature turns on: the owner's
///    defaults are given to a profile that has never stored a setting, and
///    to no other profile ever.
///
/// Nothing here touches Firestore. The document's *content* is what these
/// tests are about; how it travels is `AppConfig`'s own business, and the
/// rules' business for who may write it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NewUserDefaults.fromMap', () {
    test('an absent document is the app’s own defaults', () {
      const NewUserDefaults builtin = NewUserDefaults();
      expect(NewUserDefaults.fromMap(null), builtin);
      expect(NewUserDefaults.fromMap(<String, dynamic>{}), builtin);
    });

    test('hand-edited junk falls back field by field', () {
      final NewUserDefaults parsed = NewUserDefaults.fromMap(<String, dynamic>{
        'method': 'made-up-method',
        'madhab': 'shia',
        'timeFormat': '13',
        'hijriAdjustment': 'tomorrow',
        'azanSound': 'not-a-sound',
        'azaanTiming': 'whenever',
        'minutesBefore': 'soon',
        'readingLanguage': 'klingon',
        'notificationsEnabled': 'yes please',
      });
      expect(parsed, const NewUserDefaults());
    });

    test('values this build knows are kept', () {
      final NewUserDefaults parsed = NewUserDefaults.fromMap(<String, dynamic>{
        'method': 'karachi',
        'madhab': 'hanafi',
        'timeFormat': '24',
        'hijriAdjustment': 1,
        'azanSound': 'mishary',
        'azaanTiming': kAzaanTimingJamaatOnly,
        'minutesBefore': 10,
        'readingLanguage': kReadingLanguageEnglish,
        'notificationsEnabled': false,
      });
      expect(parsed.method, 'karachi');
      expect(parsed.madhab, 'hanafi');
      expect(parsed.timeFormat, '24');
      expect(parsed.hijriAdjustment, 1);
      expect(parsed.azanSound, 'mishary');
      expect(parsed.azaanTiming, kAzaanTimingJamaatOnly);
      expect(parsed.minutesBefore, 10);
      expect(parsed.readingLanguage, kReadingLanguageEnglish);
      expect(parsed.notificationsEnabled, isFalse);

      // Azaan ka sirf ek hi option offer hota hai (kAzaanTimingOptions), aur
      // owner ka document purane options (awwal_only / both / none) bhi rakh
      // sakta hai - wo padh kar seedha "Jamaat only" ban jaate hain, warna
      // Settings me dropdown me dikhne wali value hi na bache.
      expect(
        NewUserDefaults.fromMap(<String, dynamic>{'azaanTiming': kAzaanTimingAwwalOnly}).azaanTiming,
        kAzaanTimingJamaatOnly,
      );
      expect(
        NewUserDefaults.fromMap(<String, dynamic>{'azaanTiming': kAzaanTimingBoth}).azaanTiming,
        kAzaanTimingJamaatOnly,
      );
    });

    test('minutes below zero fold onto "at time"; a typo clamps to an hour', () {
      expect(
        NewUserDefaults.fromMap(<String, dynamic>{'minutesBefore': -30}).minutesBefore,
        -1,
      );
      expect(
        NewUserDefaults.fromMap(<String, dynamic>{'minutesBefore': 9999}).minutesBefore,
        120,
      );
    });

    test('a Hijri offset cannot be moved into next month', () {
      expect(
        NewUserDefaults.fromMap(<String, dynamic>{'hijriAdjustment': 40}).hijriAdjustment,
        7,
      );
      expect(
        NewUserDefaults.fromMap(<String, dynamic>{'hijriAdjustment': -40}).hijriAdjustment,
        -7,
      );
    });

    test('round-trips through toMap without losing anything', () {
      const NewUserDefaults original = NewUserDefaults(
        method: 'ummAlQura',
        madhab: 'hanafi',
        timeFormat: '24',
        hijriAdjustment: 2,
        azanSound: 'madina',
        // Is build ka sirf ek hi option hai (kAzaanTimingOptions), isliye
        // round-trip me wahi jaana chahiye - `both` jaisa purana value
        // fromMap me hi "Jamaat only" ban jaata hai aur ye test girta.
        azaanTiming: kAzaanTimingJamaatOnly,
        minutesBefore: 15,
        readingLanguage: kReadingLanguageRoman,
        notificationsEnabled: false,
      );
      expect(NewUserDefaults.fromMap(original.toMap()), original);
    });

    test('describe says in one line what a fresh profile opens on', () {
      const NewUserDefaults defaults = NewUserDefaults();
      final String said = defaults.describe();
      expect(said, contains('Shafi'));
      expect(said, contains('Muslim World League'));
      expect(said, contains('Azaan at time'));
    });
  });

  group('AppConfigData.fromMap', () {
    test('an absent document is an untouched app', () {
      expect(AppConfigData.fromMap(null), const AppConfigData());
      expect(AppConfigData.fromMap(<String, dynamic>{}), const AppConfigData());
    });

    test('branding is read field by field, and only if it is usable', () {
      final AppConfigData good = AppConfigData.fromMap(<String, dynamic>{
        'branding': <String, dynamic>{
          'wallpaperUrl': '  https://example.com/wall.jpg ',
          'logoUrl': 'https://example.com/logo.png',
          'announcement': '  Jumu’ah at 13:30  ',
          'iconVariant': 2,
        },
      });
      expect(good.wallpaperUrl, 'https://example.com/wall.jpg');
      expect(good.logoUrl, 'https://example.com/logo.png');
      expect(good.announcement, 'Jumu’ah at 13:30');
      expect(good.iconVariant, 2);

      final AppConfigData bad = AppConfigData.fromMap(<String, dynamic>{
        'branding': <String, dynamic>{
          'wallpaperUrl': 'ftp://example.com/wall.jpg',
          'logoUrl': 'not a url at all',
          'announcement': 42,
          'iconVariant': 'two',
        },
      });
      expect(bad.wallpaperUrl, '');
      expect(bad.logoUrl, '');
      expect(bad.announcement, '');
      expect(bad.iconVariant, 0);
    });

    test('the launcher icon is clamped into the range this build prepared', () {
      expect(
        AppConfigData.fromMap(<String, dynamic>{
          'branding': <String, dynamic>{'iconVariant': 99},
        }).iconVariant,
        kLauncherIconLabels.length - 1,
      );
      expect(
        AppConfigData.fromMap(<String, dynamic>{
          'branding': <String, dynamic>{'iconVariant': -4},
        }).iconVariant,
        0,
      );
    });

    test('clips keep only the slots this build knows how to play', () {
      final AppConfigData parsed = AppConfigData.fromMap(<String, dynamic>{
        'azanUrls': <String, dynamic>{
          'makkah': 'https://example.com/makkah.mp3',
          'a-sound-from-a-later-build': 'https://example.com/unknown.mp3',
        },
      });
      expect(parsed.azanUrls, <String, String>{
        'makkah': 'https://example.com/makkah.mp3',
      });
    });

    test('an empty URL clears the override — and stays cleared', () {
      final AppConfigData cleared = AppConfigData.fromMap(<String, dynamic>{
        'azanUrls': <String, dynamic>{'makkah': ''},
      });
      expect(cleared.azanUrls, isEmpty);
      expect(AppConfigData.fromMap(cleared.toMap()).azanUrls, isEmpty);
    });

    test('round-trips through toMap without losing anything', () {
      final AppConfigData original = AppConfigData(
        defaults: const NewUserDefaults(madhab: 'hanafi', minutesBefore: 5),
        wallpaperUrl: 'https://example.com/wall.jpg',
        logoUrl: 'https://example.com/logo.png',
        announcement: 'Notice',
        iconVariant: 3,
        azanUrls: const <String, String>{
          'madina': 'https://example.com/madina.mp3',
        },
      );
      expect(AppConfigData.fromMap(original.toMap()), original);
    });

    test('two documents holding the same clips are the same document', () {
      final AppConfigData a = AppConfigData.fromMap(<String, dynamic>{
        'azanUrls': <String, dynamic>{
          'makkah': 'https://example.com/a.mp3',
          'madina': 'https://example.com/b.mp3',
        },
      });
      final AppConfigData b = AppConfigData.fromMap(<String, dynamic>{
        'azanUrls': <String, dynamic>{
          'madina': 'https://example.com/b.mp3',
          'makkah': 'https://example.com/a.mp3',
        },
      });
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('seeding a new profile', () {
    test('a profile that has stored nothing takes the owner’s defaults once', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final AppSettings settings = AppSettings.instance;
      await settings.useProfile('uid-new');

      expect(settings.isVirginProfile, isTrue);

      settings.seedWith(const NewUserDefaults(
        method: 'karachi',
        madhab: 'hanafi',
        minutesBefore: 10,
        azanSound: 'mishary',
        azaanTiming: kAzaanTimingAwwalOnly,
      ));

      // What the profile opens on...
      expect(settings.isHanafi, isTrue);
      expect(settings.methodKey, 'karachi');
      expect(settings.azanSound, 'mishary');
      expect(settings.azaanTiming, kAzaanTimingAwwalOnly);
      expect(settings.notifyOffsetFor('fajr'), 10);
      expect(settings.notifyOffsetFor('isha'), 10);

      // ...and that it is no longer a profile anyone may seed.
      expect(settings.isVirginProfile, isFalse);
      settings.seedWith(const NewUserDefaults(madhab: 'shafi', method: 'egyptian'));
      expect(settings.isHanafi, isTrue);
      expect(settings.methodKey, 'karachi');
    });

    test('a profile that has spoken for itself is never seeded', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'calcMethod::uid-old': 'karachi',
      });
      final AppSettings settings = AppSettings.instance;
      await settings.useProfile('uid-old');

      expect(settings.isVirginProfile, isFalse);

      settings.seedWith(const NewUserDefaults(
        method: 'ummAlQura',
        madhab: 'hanafi',
        minutesBefore: 30,
      ));

      expect(settings.methodKey, 'karachi');
      expect(settings.isHanafi, isFalse);
      expect(settings.notifyOffsetFor('fajr'), -1);
    });

    test('a second account on the same phone is a new user again', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final AppSettings settings = AppSettings.instance;

      await settings.useProfile('uid-a');
      settings.seedWith(const NewUserDefaults(madhab: 'hanafi', minutesBefore: 10));
      expect(settings.isVirginProfile, isFalse);

      // The second account has stored nothing of its own, so it qualifies —
      // and the first account's choices must not have followed it across.
      await settings.useProfile('uid-b');
      expect(settings.isVirginProfile, isTrue);

      settings.seedWith(const NewUserDefaults(madhab: 'shafi', minutesBefore: -1));
      expect(settings.isHanafi, isFalse);
      expect(settings.notifyOffsetFor('fajr'), -1);

      // And the first account still holds what it was given.
      await settings.useProfile('uid-a');
      expect(settings.isHanafi, isTrue);
      expect(settings.notifyOffsetFor('fajr'), 10);
    });

    test('seeded settings survive to the next read', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final AppSettings settings = AppSettings.instance;
      await settings.useProfile('uid-persist');

      settings.seedWith(const NewUserDefaults(
        method: 'dubai',
        minutesBefore: 15,
        timeFormat: '24',
      ));
      // The write is issued, not awaited: setters never block a frame. Let
      // its microtasks run before reading the store back.
      await pumpEventQueue();

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('calcMethod::uid-persist'), 'dubai');
      expect(prefs.getInt('notify_fajr::uid-persist'), 15);
      expect(prefs.getString('timeFormat::uid-persist'), '24');
    });
  });
}
