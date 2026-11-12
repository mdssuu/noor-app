import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/services/azaan_alarm.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Silence after the Azaan: the recitation ends, the phone goes to **vibrate**
/// for the minutes the reader chose in Settings, and rings normally again on
/// its own.
///
/// The feature is one number travelling five hops — the Settings row, the
/// alarm's extras, the ledger that rebuilds tomorrow, the receiver, the
/// service — and a break at any hop reads to the user as "the setting does
/// nothing". Each hop is pinned on the side it lives:
///
///   * the **choice** here in Dart: six durations, fifteen by default, and a
///     value the row cannot show never reaching the phone;
///   * the **wire**: the exact key `MainActivity.kt` reads, because a
///     different spelling is read as 0 and the ringer is simply never
///     touched;
///   * the **native side**: the window opens *after* a recitation that
///     actually sounded (never during one — the Azaan rides the ringer's own
///     stream, so switching it mid-clip would mute the thing the reader
///     asked to hear), and comes back only where this code left it, so a
///     reader who moved the switch themselves is never overwritten.
///
/// The last rule is the one worth most: an automatic silence that can
/// outlive its own reason is worse than no feature at all.
void main() {
  const String kotlin = 'android/app/src/main/kotlin/com/sunesra_app/';
  TestWidgetsFlutterBinding.ensureInitialized();

  final String appSettings = File('lib/app_settings.dart').readAsStringSync();
  final String screen =
      File('lib/screens/settings_screen.dart').readAsStringSync();
  final String mainDart = File('lib/main.dart').readAsStringSync();
  final String silence = File('${kotlin}RingerSilence.kt').readAsStringSync();
  final String receiver =
      File('${kotlin}AzaanAlarmReceiver.kt').readAsStringSync();
  final String service =
      File('${kotlin}AzaanPlaybackService.kt').readAsStringSync();
  final String alarms = File('${kotlin}AzaanAlarms.kt').readAsStringSync();
  final String scheduleReceiver =
      File('${kotlin}AzaanScheduleReceiver.kt').readAsStringSync();
  final String activity = File('${kotlin}MainActivity.kt').readAsStringSync();
  final String manifest =
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

  group('the choice', () {
    test('six durations, fifteen by default, off a real answer', () {
      expect(kAutoSilentOptions, <int>[kAutoSilentOff, 10, 15, 30, 45, 60],
          reason: 'the row shows exactly these and the load accepts only '
              'these — a duration nobody can pick must not be one the '
              'phone obeys');
      expect(kAutoSilentDefault, 15);
      expect(kAutoSilentOff, 0);
      expect(kAutoSilentOptions.contains(kAutoSilentDefault), isTrue);
    });

    test('a duration the row cannot show is filed as the default', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final AppSettings settings = AppSettings.instance;

      await settings.useProfile('silent-uid-a');

      settings.setAutoSilentMinutes(7);
      expect(settings.autoSilentMinutes, kAutoSilentDefault,
          reason: 'seven minutes is not offered, so it is not obeyed');
      settings.setAutoSilentMinutes(-5);
      expect(settings.autoSilentMinutes, kAutoSilentDefault);
      settings.setAutoSilentMinutes(30);
      expect(settings.autoSilentMinutes, 30);
    });

    test('the choice is saved under the profile and read back', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final AppSettings settings = AppSettings.instance;

      await settings.useProfile('silent-uid-b');
      settings.setAutoSilentMinutes(45);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getInt(
            AppSettings.scopedKeyFor('autoSilentMinutes', 'silent-uid-b')),
        45,
      );
      // The bare name never sits device-wide where the next profile could
      // inherit it, exactly like every other setting.
      expect(prefs.containsKey('autoSilentMinutes'), isFalse);

      await settings.useProfile('silent-uid-c');
      expect(settings.autoSilentMinutes, kAutoSilentDefault);

      await settings.useProfile('silent-uid-b');
      expect(settings.autoSilentMinutes, 45);
    });

    test('a stored duration the app cannot offer falls back to fifteen',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        AppSettings.scopedKeyFor('autoSilentMinutes', 'silent-uid-d'): 900,
      });
      final AppSettings settings = AppSettings.instance;

      await settings.useProfile('silent-uid-d');

      expect(settings.autoSilentMinutes, kAutoSilentDefault,
          reason: 'a corrupt or ancient value must not silence a phone for '
              'a day and a half');
    });

    test('the setting is profile-scoped and re-arms what it changes', () {
      final int bases = appSettings.indexOf('_allBases = <String>[');
      expect(bases, greaterThan(-1));
      expect(
        appSettings.substring(bases, appSettings.indexOf('];', bases)),
        contains('_kAutoSilent'),
        reason: 'a key outside _allBases is written device-wide and leaks '
            'into the next profile that signs in',
      );

      final int setter = appSettings.indexOf('void setAutoSilentMinutes');
      expect(setter, greaterThan(-1));
      expect(
        appSettings.substring(setter, setter + 600),
        contains('notifyListeners()'),
        reason: 'armed alarms carry this number in their intent — a setter '
            'that never notified would only reach the next prayer the app '
            'happened to schedule afterwards',
      );
    });
  });

  group('the wire', () {
    const MethodChannel channel = MethodChannel('noor_masjid_time/azaan');
    final List<MethodCall> calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('the alarm carries the quiet window it was asked for', () async {
      await AzaanAlarm.schedule(
        id: 7,
        at: DateTime(2026, 1, 1, 5),
        raw: 'azaan1',
        silentMinutes: 30,
      );

      expect(calls.single.method, 'schedule');
      final Object? sent =
          (calls.single.arguments as Map<Object?, Object?>)['silentMinutes'];
      expect(
        sent,
        30,
        reason: 'MainActivity.kt reads exactly "silentMinutes" — a '
            'different spelling is read as 0 and the phone never goes quiet',
      );
    });

    test('an alarm that says nothing never touches the ringer', () async {
      await AzaanAlarm.schedule(
        id: 8,
        at: DateTime(2026, 1, 1, 5),
        raw: 'azaan1',
      );

      final Object? sent =
          (calls.single.arguments as Map<Object?, Object?>)['silentMinutes'];
      expect(sent, 0,
          reason: '0 is the answer every caller that does not care must '
              'give, or Kotlin defaults cannot be trusted');
    });
  });

  group('the native side', () {
    test('the window opens only after a recitation that sounded', () {
      expect(
        service,
        contains('if (recited && silentMinutes > 0)'),
        reason: 'a service retired before the player took the field — no '
            'card, no clip, a ringer that said no — must leave the ringer '
            'exactly as it found it',
      );
      expect(
        service.indexOf('recited = true'),
        greaterThan(service.indexOf('AzaanAudio.play(this, sound)')),
        reason: 'the flag belongs to a play that returned true, not to a '
            'service that merely started',
      );
      expect(
        service.indexOf('RingerSilence.engage(this, silentMinutes)'),
        greaterThan(service.indexOf('recited = true')),
        reason: 'flipping the ringer mid-clip would mute the very recitation '
            'the reader asked to hear — the window starts at the end',
      );
      // A STOP intent carries no window and must not zero out the one the
      // clip it stopped asked for.
      expect(service, contains('getIntExtra(EXTRA_SILENT, -1)'));
    });

    test('the receiver hands the window to both roads that can end a clip',
        () {
      expect(receiver, contains('intent.getIntExtra(EXTRA_SILENT, 0)'),
          reason: 'the value is frozen into the alarm at arm time — the '
              'receiver has no settings to ask');
      expect(
        receiver,
        contains('.putExtra(AzaanPlaybackService.EXTRA_SILENT, silentMinutes)'),
        reason: 'the service owns the clip end, so it is the service that '
            'starts the window',
      );
      expect(
        receiver,
        contains('RingerSilence.engage(context, silentMinutes)'),
        reason: 'the inline fallback (foreground start refused) ends its '
            'clip without a service — that road needs the window too',
      );
    });

    test('the phone comes back only where this code left it', () {
      expect(
        silence,
        contains('if (audio.ringerMode == AudioManager.RINGER_MODE_VIBRATE)'),
        reason: 'the restore may only touch a ringer that still reads '
            'vibrate — a reader who silenced the phone themselves, or '
            'rang it back early, has answered for themselves',
      );
      expect(
        silence,
        contains('editor.putInt(KEY_PREV_MODE, audio.ringerMode)'),
        reason: 'whatever the mode was when the window opened is what has '
            'to come back — not a hardcoded NORMAL',
      );
      expect(silence, contains('audio.ringerMode = AudioManager.RINGER_MODE_VIBRATE'),
          reason: 'the reader chose vibrate, not Do Not Disturb — no '
              'ACCESS_NOTIFICATION_POLICY, no notifications policy to '
              'restore later');
      expect(silence, contains('setExactAndAllowWhileIdle'),
          reason: 'a "15 minutes" that answers at 17 is a setting that lies; '
                  'and it must fire with the app shut, through Doze');
      expect(silence, contains('fun reconcile'),
          reason: 'a window whose restore alarm died with a reboot would '
              'leave the phone on vibrate for ever');
    });

    test('the quiet window survives tomorrow and every restart', () {
      expect(
        alarms,
        contains('.putExtra(AzaanAlarmReceiver.EXTRA_SILENT, silentMinutes)'),
        reason: 'the value rides the alarm itself, like sound and body',
      );
      expect(
        alarms,
        contains('.put("k", spec.silentMinutes)'),
        reason: "tomorrow's copy is rebuilt from the ledger — an alarm that "
            'forgot its window would ring loud again at the day rollover',
      );
      expect(
        alarms,
        contains('silentMinutes = entry.optInt("k", 0).coerceIn(0, 240)'),
        reason: 'read back clamped: a corrupt ledger must not silence a '
            'phone for days',
      );
      expect(
        'silentMinutes = spec.silentMinutes'.allMatches(alarms).length,
        greaterThanOrEqualTo(2),
          reason: 'both re-arm roads — the one that follows a fired alarm '
              'and the one that follows a boot — must carry it',
      );

      expect(
        scheduleReceiver,
        contains('RingerSilence.reconcile(context)'),
        reason: 'AlarmManager’s list dies with the reboot; the ringer mode '
            'does not, and neither must the way back out of it',
      );
      expect(activity, contains('"silentMinutes"'),
          reason: 'the channel key the Dart side sends');
    });

    test('the manifest declares the switch and its way back', () {
      expect(manifest, contains('android.permission.MODIFY_AUDIO_SETTINGS'),
          reason: 'switching the ringer is the one permission this feature '
              'needs — and VIBRATE is already declared for the clip');
      expect(manifest, contains('android.permission.VIBRATE'));
      expect(manifest, contains('.RingerRestoreReceiver'),
          reason: 'registered in the manifest, not at runtime: it has to be '
              'reachable with the app shut, which is the usual state of a '
              'phone sitting on vibrate');
      expect(
        manifest,
        isNot(contains('android.permission.ACCESS_NOTIFICATION_POLICY')),
        reason: 'the reader chose vibrate, not Do Not Disturb — DND would '
            'need a policy grant and a restore of its own',
      );
    });

    test('the Settings row offers every duration the setting accepts', () {
      expect(screen, contains("'Silence after Azaan'"));
      for (final int minutes in kAutoSilentOptions) {
        // The off chip is spelled with its constant in the source — the
        // literal `0` appears nowhere in the row.
        final String call = minutes == kAutoSilentOff
            ? '_silentOption(kAutoSilentOff)'
            : '_silentOption($minutes)';
        expect(
          screen,
          contains(call),
          reason: 'a duration the setter accepts but the row never offers '
              'is a setting with no way to reach it',
        );
      }
      expect(screen, contains('_silentOption(kAutoSilentOff)'),
          reason: 'off must be a choice — a feature with no way out is a '
              'trap, not a setting');
    });

    test('the closed-app probe never silences the phone it just rang', () {
      final int probe = mainDart.indexOf('recurring: false');
      expect(probe, greaterThan(-1),
          reason: 'the test reminder is the one schedule that passes it');
      expect(
        mainDart.substring(probe, probe + 500),
        contains('silentMinutes: 0'),
        reason: 'a button a reader pressed to *hear* their Azaan must not '
            'leave the phone on vibrate for a quarter of an hour afterwards',
      );
    });
  });
}
