import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The switch that decides how many times a prayer may speak.
///
/// One prayer has two announcements available to it — the calculated Awwal
/// time and a favourite masjid's own Jamaat column — and "When will the
/// Azaan play?" is the single control that says which of them may ring. The
/// dropdown was once reduced to one row (a fix for the "do baar azaan" bug,
/// where both were armed because neither could be chosen); it offers all four
/// modes again, so these check the three things that decide behaviour: the
/// value on disk, the labels a reader picks from, and the two booleans the
/// scheduler consults.
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

    test('each mode reaches the scheduler as the passes it names', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final AppSettings settings = AppSettings.instance;

      await settings.useProfile('timing-options');

      // At the masjid: the favourite pass only, so a reader who follows a
      // printed board hears one Azaan at the time the board prints.
      settings.setAzaanTiming(kAzaanTimingJamaatOnly);
      expect(settings.schedulesAwwal, isFalse);
      expect(settings.schedulesJamaat, isTrue);

      // At Awwal: the calculated pass only, so the masjid's own column never
      // adds a second ring beside it.
      settings.setAzaanTiming(kAzaanTimingAwwalOnly);
      expect(settings.schedulesAwwal, isTrue);
      expect(settings.schedulesJamaat, isFalse);

      // Both — the one mode where two rings are the answer rather than the
      // bug, and only because the reader asked for it.
      settings.setAzaanTiming(kAzaanTimingBoth);
      expect(settings.schedulesAwwal, isTrue);
      expect(settings.schedulesJamaat, isTrue);

      // Off: neither pass arms, which is the same as no Azaan at all.
      settings.setAzaanTiming(kAzaanTimingNone);
      expect(settings.schedulesAwwal, isFalse);
      expect(settings.schedulesJamaat, isFalse);
    });

    test('the choice is saved under the profile and read back', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final AppSettings settings = AppSettings.instance;

      await settings.useProfile('timing-uid-a');
      settings.setAzaanTiming(kAzaanTimingAwwalOnly);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      // A mode that is offered must survive the write — collapsing every
      // choice onto the default is what made this row a formality.
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

    test('a mode that is not offered is stored as the default', () async {
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

    test('every mode on the dropdown row is worded, in order', () {
      final List<String> labels = <String>[
        for (final String key in kAzaanTimingOptions) azaanTimingLabel(key),
      ];
      expect(labels, <String>[
        'Only at my masjid’s Jamaat time',
        'Only at Awwal time (my calculated time)',
        'At both Awwal and Jamaat time',
        'Off — no Azaan',
      ]);
      // The two sources have to be tellable apart without knowing the words
      // first: the default row names the masjid, the row under it names
      // "Awwal", and neither leans on the reader inferring which clock.
      expect(azaanTimingLabel(kAzaanTimingJamaatOnly), contains('masjid'));
      expect(azaanTimingLabel(kAzaanTimingAwwalOnly), contains('Awwal'));
    });
  });
}
