import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression for: "do baar azaan bajti hai (Awwal + Jamaat)".
///
/// One prayer has two announcements armed by two different passes — the
/// calculated Awwal time and a favourite masjid's own Jamaat column — and
/// "When will the Azaan play?" is the single switch that decides how many of them may
/// ring. These check the two things that decide that: the value on disk, and
/// the two booleans the scheduler consults.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('When will the Azaan play?', () {
    test('a fresh install rings once, at Jamaat', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final AppSettings settings = AppSettings.instance;

      await settings.useProfile('timing-default');

      expect(settings.azaanTiming, kAzaanTimingDefault);
      expect(settings.azaanTiming, kAzaanTimingJamaatOnly);
      expect(settings.schedulesJamaat, isTrue);
      expect(settings.schedulesAwwal, isFalse);
    });

    test('every option reaches the scheduler as exactly one pass', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final AppSettings settings = AppSettings.instance;

      await settings.useProfile('timing-options');

      settings.setAzaanTiming(kAzaanTimingAwwalOnly);
      expect(settings.schedulesAwwal, isTrue);
      expect(settings.schedulesJamaat, isFalse);

      settings.setAzaanTiming(kAzaanTimingBoth);
      expect(settings.schedulesAwwal, isTrue);
      expect(settings.schedulesJamaat, isTrue);

      settings.setAzaanTiming(kAzaanTimingNone);
      expect(settings.schedulesAwwal, isFalse);
      expect(settings.schedulesJamaat, isFalse);

      settings.setAzaanTiming(kAzaanTimingJamaatOnly);
      expect(settings.schedulesAwwal, isFalse);
      expect(settings.schedulesJamaat, isTrue);
    });

    test('the choice is stored and read back from the profile', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final AppSettings settings = AppSettings.instance;

      await settings.useProfile('timing-uid-a');
      settings.setAzaanTiming(kAzaanTimingAwwalOnly);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(AppSettings.scopedKeyFor('azaan_timing_pref', 'timing-uid-a')),
        kAzaanTimingAwwalOnly,
      );
      // The bare name never sits device-wide where the next profile could
      // inherit it, exactly like every other setting.
      expect(prefs.containsKey('azaan_timing_pref'), isFalse);

      await settings.useProfile('timing-uid-b');
      expect(settings.azaanTiming, kAzaanTimingDefault);

      await settings.useProfile('timing-uid-a');
      expect(settings.azaanTiming, kAzaanTimingAwwalOnly);
    });

    test('an unknown value is rejected rather than stored', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final AppSettings settings = AppSettings.instance;

      await settings.useProfile('timing-uid-c');
      settings.setAzaanTiming('sometimes');
      expect(settings.azaanTiming, kAzaanTimingDefault);
    });

    test('a stored value the app cannot read falls back to one ring', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        AppSettings.scopedKeyFor('azaan_timing_pref', 'timing-uid-d'): 'garbage',
      });
      final AppSettings settings = AppSettings.instance;

      await settings.useProfile('timing-uid-d');

      expect(settings.azaanTiming, kAzaanTimingDefault);
      expect(settings.schedulesJamaat, isTrue);
      expect(settings.schedulesAwwal, isFalse);
    });

    test('the wording on every dropdown row is distinct', () {
      final List<String> labels = [
        for (final String key in kAzaanTimingOptions) azaanTimingLabel(key),
      ];
      expect(labels.toSet(), hasLength(kAzaanTimingOptions.length));
      expect(azaanTimingLabel(kAzaanTimingJamaatOnly), 'Only at Jamaat time');
      expect(azaanTimingLabel(kAzaanTimingAwwalOnly), 'Only at Awwal time');
      expect(azaanTimingLabel(kAzaanTimingNone), 'Off');
    });
  });
}
