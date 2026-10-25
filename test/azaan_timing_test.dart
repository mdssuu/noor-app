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

    test('the only option is jamaat_only and reaches the scheduler as one pass', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final AppSettings settings = AppSettings.instance;

      await settings.useProfile('timing-options');

      settings.setAzaanTiming(kAzaanTimingJamaatOnly);
      expect(settings.schedulesAwwal, isFalse);
      expect(settings.schedulesJamaat, isTrue);
    });

    test('the choice is always saved as jamaat_only and read back', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final AppSettings settings = AppSettings.instance;

      await settings.useProfile('timing-uid-a');
      settings.setAzaanTiming(kAzaanTimingAwwalOnly);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      // Only one option is offered, so the value is always jamaat_only.
      expect(
        prefs.getString(AppSettings.scopedKeyFor('azaan_timing_pref', 'timing-uid-a')),
        kAzaanTimingJamaatOnly,
      );
      // The bare name never sits device-wide where the next profile could
      // inherit it, exactly like every other setting.
      expect(prefs.containsKey('azaan_timing_pref'), isFalse);

      await settings.useProfile('timing-uid-b');
      expect(settings.azaanTiming, kAzaanTimingDefault);

      await settings.useProfile('timing-uid-a');
      expect(settings.azaanTiming, kAzaanTimingJamaatOnly);
    });

    test('an unknown value is stored as jamaat_only', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final AppSettings settings = AppSettings.instance;

      await settings.useProfile('timing-uid-c');
      settings.setAzaanTiming('sometimes');
      expect(settings.azaanTiming, kAzaanTimingJamaatOnly);
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

    test('the wording on the single dropdown row is correct', () {
      final List<String> labels = [
        for (final String key in kAzaanTimingOptions) azaanTimingLabel(key),
      ];
      expect(labels, hasLength(1));
      expect(azaanTimingLabel(kAzaanTimingJamaatOnly), 'Only at Jamaat time');
    });
  });
}
