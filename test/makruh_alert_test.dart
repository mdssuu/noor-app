import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/main.dart' as app;
import 'package:shared_preferences/shared_preferences.dart';

/// The banner that says salah is prohibited *right now*.
///
/// Two things can go wrong with it and neither shows up on a phone until the
/// half hour is already running: an id some other pass sweeps (the alert is
/// armed and then cancelled a moment later, which is indistinguishable from an
/// alarm that never fired), and words that name a different window from the
/// red line Home prints. Both are pinned here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the zawal banner owns an id no other pass sweeps', () {
    // 0..4 are the five Azaan reminders, retired by hand on every
    // `cancelAzan()` — an id in that block would be cancelled by the very
    // refresh meant to re-arm it.
    expect(
      app.NotificationService.makruhId,
      greaterThanOrEqualTo(kNotifiablePrayers.length),
      reason: 'ids 0..4 belong to the five Azaan reminders',
    );

    // `[1000, 1000000000)` is cleared wholesale on every favourite rebuild —
    // the same trap that swallowed the test reminder when it sat at 791900.
    expect(
      app.NotificationService.makruhId,
      lessThan(1000),
      reason: 'ids from 1000 up are cancelled on every favourite rebuild',
    );

    // `show()` allocates epoch-second ids; the banner must not collide with
    // a one-shot the moment one of those is posted.
    expect(
      app.NotificationService.makruhId,
      lessThan(DateTime.now().millisecondsSinceEpoch ~/ 1000),
      reason: '`show()` hands out epoch-second ids',
    );
  });

  test('the banner names the window the red line on Home prints', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final AppSettings settings = AppSettings.instance;
    await settings.useProfile('makruh-alert');

    final DateTime start = DateTime(2026, 10, 25, 12, 3);
    final DateTime end = DateTime(2026, 10, 25, 12, 33);

    // The twelve-hour clock the app ships with.
    settings.setTimeFormat('12');
    expect(
      app.NotificationService.makruhText(
        start: start,
        end: end,
        settings: settings,
      ),
      (
        title: 'Prohibited time 12:03 PM – 12:33 PM',
        body:
            'Zawal is on — salah is prohibited until Dhuhr begins at 12:33 PM.',
      ),
      reason: 'the reader is told the window, in the clock they chose',
    );

    // …and the twenty-four-hour one Settings offers.
    settings.setTimeFormat('24');
    expect(
      app.NotificationService.makruhText(
        start: start,
        end: end,
        settings: settings,
      ).title,
      'Prohibited time 12:03 – 12:33',
      reason: 'the same window, in the other clock — never a different one',
    );
  });
}
