import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression for: "masjid ke time 24h me dikh rahe hain, 12h chahiye".
///
/// The Settings option ("Time format", in *Prayer calculation*) has always
/// existed and always reached `AppSettings`; what it never touched was a
/// masjid's own Jamaat column, which is stored as strict `HH:MM` and was
/// printed straight onto the cards. These pin the two formatters that turn
/// that stored text into the reader's clock — and, just as importantly, the
/// text they must leave alone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppSettings settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    settings = AppSettings.instance;
    await settings.useProfile('clock-format');
  });

  group('formatClock (the masjid detail row)', () {
    test('stays as stored when the reader wants 24-hour', () {
      settings.setTimeFormat('24');

      expect(settings.formatClock('13:20'), '13:20');
      expect(settings.formatClock('05:15'), '05:15');
    });

    test('carries a meridiem when the reader wants 12-hour', () {
      settings.setTimeFormat('12');

      expect(settings.formatClock('13:20'), '01:20 PM');
      expect(settings.formatClock('05:15'), '05:15 AM');
      expect(settings.formatClock('23:59'), '11:59 PM');
    });

    test('midnight and noon are named, not zeroed or pushed to 13', () {
      settings.setTimeFormat('12');

      expect(settings.formatClock('00:05'), '12:05 AM');
      expect(settings.formatClock('12:30'), '12:30 PM');
    });

    test('an unanswered or impossible time is printed exactly as stored', () {
      settings.setTimeFormat('12');

      expect(settings.formatClock('--:--'), '--:--');
      expect(settings.formatClock(''), '');
      expect(settings.formatClock('asr'), 'asr');
      expect(settings.formatClock('13:60'), '13:60');
      expect(settings.formatClock('25:00'), '25:00');
    });
  });

  group('formatClockShort (the five card chips)', () {
    test('drops the space and lowercases the suffix, nothing else', () {
      settings.setTimeFormat('12');

      expect(settings.formatClockShort('17:45'), '5:45pm');
      expect(settings.formatClockShort('09:05'), '9:05am');
      expect(settings.formatClockShort('12:00'), '12:00pm');
      expect(settings.formatClockShort('00:30'), '12:30am');
    });

    test('reads as stored when the reader wants 24-hour', () {
      settings.setTimeFormat('24');

      expect(settings.formatClockShort('17:45'), '17:45');
    });

    test('an unanswered time is printed exactly as stored', () {
      settings.setTimeFormat('12');

      expect(settings.formatClockShort('--:--'), '--:--');
      expect(settings.formatClockShort('19:70'), '19:70');
    });
  });

  group('the choice itself', () {
    test('is stored and read back from the profile', () async {
      settings.setTimeFormat('24');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(AppSettings.scopedKeyFor('timeFormat', 'clock-format')),
        '24',
      );
      // Scoped like every other setting: the bare name never sits
      // device-wide where the next profile could inherit it.
      expect(prefs.containsKey('timeFormat'), isFalse);

      await settings.useProfile('clock-format-other');
      expect(settings.timeFormat, '12');
      expect(settings.formatClock('17:00'), '05:00 PM');

      await settings.useProfile('clock-format');
      expect(settings.timeFormat, '24');
      expect(settings.formatClock('17:00'), '17:00');
    });

    test('a fresh install opens on the 12-hour clock', () async {
      final AppSettings fresh = AppSettings.instance;

      await fresh.useProfile('clock-fresh');

      expect(fresh.timeFormat, '12');
      expect(fresh.use12Hour, isTrue);
    });
  });
}
