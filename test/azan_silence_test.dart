import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A phone its reader put on silent stays silent.
///
/// The app used to promise the opposite, out loud, in four separate places —
/// and it was not a stray sentence: the recitation rides `USAGE_ALARM`,
/// the one stream a ringer key does not mute, so *nothing downstream* could
/// be relied on to keep quiet. The stream choice is a real feature (it is
/// what lets the volume rocker reach the clip, and what keeps an app-closed
/// alarm audible), but it silently turned into a policy nobody had agreed to,
/// and by the time it was pointed out the alarm stream had already been
/// proven working on a phone set to vibrate.
///
/// So the policy is now said where it can be read: silence is checked first,
/// on every path into a sound, and the answer is never left to the stream.
///
/// The paths are three, and they cannot be allowed to disagree:
///
///   * the exact-alarm receiver, which has no Dart side to ask and is
///     therefore where a prayer time is actually declined;
///   * `AzaanAudio.play`, the one choke point both the receiver and the
///     service fall through;
///   * `AzanPlayer.preview`, which must decline *before* falling back to the
///     remote clip, or "Test Azaan" lights a stop button over a phone that
///     will never let anyone hear it — the original "button does nothing",
///     wearing a different hat.
///
/// The last path is the reason the decline is also reported: a silent answer
/// with no sentence is the bug that started all of this.
void main() {
  const String kotlin = 'android/app/src/main/kotlin/com/sunesra_app/';
  final String audio = File('${kotlin}AzaanAudio.kt').readAsStringSync();
  final String receiver =
      File('${kotlin}AzaanAlarmReceiver.kt').readAsStringSync();
  final String activity = File('${kotlin}MainActivity.kt').readAsStringSync();
  final String player = File('lib/services/azan_player.dart').readAsStringSync();
  final String alarm = File('lib/services/azaan_alarm.dart').readAsStringSync();
  final String settings =
      File('lib/screens/settings_screen.dart').readAsStringSync();
  final String onboarding =
      File('lib/screens/onboarding_screen.dart').readAsStringSync();

  test('the player refuses before it plays anything', () {
    expect(audio, contains('fun ringerAllowsRecitation'),
        reason: 'one function, asked by every path, or the paths disagree.');
    expect(audio, contains('AudioManager.RINGER_MODE_NORMAL'),
        reason: 'only NORMAL recites; silent and vibrate are both answers a '
            'person gave on purpose, not two halves of one.');
    expect(
        audio.indexOf('ringerAllowsRecitation(app)'),
        lessThan(audio.indexOf('stopLocked()')),
        reason: 'the check must come first — after it the player is already '
            'built, a wake lock is held and the service has announced itself.');
    expect(audio, contains('recitation declined'),
        reason: 'a refusal nobody logs is indistinguishable from a clip that '
            'failed to start.');
  });

  test('the receiver asks before the service starts', () {
    expect(receiver, contains('ringerAllowsRecitation'),
        reason: 'this is the path a prayer time actually takes; a gate only '
            'in Dart would be a gate on the wrong side of the alarm.');
    expect(
        receiver.indexOf('ringerAllowsRecitation(context)'),
        lessThan(receiver.indexOf('startForegroundService(')),
        reason: 'start the service and the playback notification is already '
            'up — visible over a clip nobody will hear.');
    expect(
        receiver.indexOf('ringerAllowsRecitation(context)'),
        greaterThan(receiver.indexOf('rearmNext')),
        reason: "tomorrow's alarm is armed before today's is declined, or a "
            'week of silent mornings would stop being scheduled.');
  });

  test('the preview gets a reason it can show', () {
    expect(activity, contains('"ringerMode"'),
        reason: 'the channel carries the switch, so Dart can ask instead of '
            'guessing from a `false` that could mean anything.');
    expect(activity, contains('RINGER_MODE_VIBRATE'),
        reason: 'vibrate has to be distinguishable from silent — both refuse, '
            'and the reader is told which.');
    expect(alarm, contains('Future<String> ringerMode()'),
        reason: 'and it must answer "normal" with no Android side to ask, so '
            'the guard cannot block desktop or web.');
    expect(player, contains('AzaanAlarm.ringerMode()'),
        reason: 'before step 1, or the false from the native player falls '
            'through to step 2 and fetches the remote clip anyway.');
    expect(settings, contains('_explainSilenced'),
        reason: 'declining silently is the complaint this app was fixed for, '
            'one row over: a button that answers nothing.');
  });

  test('Settings no longer promises to ring through silence', () {
    expect(settings,
        isNot(contains('at alarm volume when the phone is on silent')),
        reason: 'the sentence existed to be read; it is now a sentence about '
            'something the device is told not to do.');
    expect(onboarding, isNot(contains('on a silent phone')),
        reason: 'the same promise on the first screen anyone sees is the one '
            'most likely to be believed.');
    expect(settings, contains('Silence is still yours'),
        reason: 'the promise is replaced, not deleted — a reader has to be '
            'told what happens instead.');
    expect(audio, contains('AudioAttributes.USAGE_NOTIFICATION_RINGTONE'),
        reason: 'the stream is the reader\u2019s own ringer, so one slider '
            'sets how loud a prayer may be and the volume keys are already '
            'pointing at it — which is the whole of why the rocker used to be '
            'powerless: it moved the ring volume while the clip played '
            'somewhere else.');
  });
}
