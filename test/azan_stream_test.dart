import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The app promises, in four separate places, that a reminder rings "at alarm
/// volume when the phone is on silent". Only one of them is code.
///
/// The Kotlin player had drifted to `USAGE_NOTIFICATION_RINGTONE`, which is
/// the stream Android mutes the moment the ringer leaves NORMAL — so the
/// promise, the Dart bridge's own header, and the receiver's reasoning all
/// described an alarm stream that the device was not being given. On a
/// silenced phone, which is where a prayer reminder earns its keep, the Azaan
/// stayed silent while every screen in the app claimed otherwise.
///
/// The drift went unnoticed because the symptom is absence: no crash, no
/// error log, just a phone that does not ring — the same shape as the
/// shrinker bug that had just eaten the clips, one layer further down.
///
/// The other half is the rocker. Ending the recitation on a volume press is
/// only possible if the watcher reads the stream that is actually sounding,
/// which is why `STREAM_ALARM` is pinned next to the usage.
void main() {
  final String audio = File(
    'android/app/src/main/kotlin/com/sunesra_app/AzaanAudio.kt',
  ).readAsStringSync();
  final String settings = File(
    'lib/screens/settings_screen.dart',
  ).readAsStringSync();

  test('the clip is played on the alarm stream', () {
    expect(audio, contains('AudioAttributes.USAGE_ALARM'),
        reason: 'the alarm stream is the one volume position Android refuses '
            'to silence; anything else goes quiet exactly when it matters.');
    expect(audio, isNot(contains('USAGE_NOTIFICATION_RINGTONE')),
        reason: 'the ringtone stream is muted by ringer mode, so a silenced '
            'phone would never hear the Azaan.');
  });

  test('the watcher reads the stream that is sounding', () {
    expect(audio, contains('AudioManager.STREAM_ALARM'),
        reason: 'a stop on the volume key is read as a fall in the stream the '
            'clip is on; watching any other one would never see the press.');
    expect(audio, isNot(contains('AudioManager.STREAM_RING')),
        reason: 'watching a stream that is not playing means a rocker press '
            'ends nothing, and the key is swallowed.');
  });

  test('the promise Settings makes is the promise the code keeps', () {
    expect(settings, contains('at alarm volume when the phone is on silent'),
        reason: 'the sentence exists to be read; if it stops being true the '
            'reader is being told something the device will not do.');
    expect(audio, contains('AudioAttributes.USAGE_ALARM'),
        reason: 'Settings promises the alarm stream. The player has to be on '
            'it or the sentence is decoration.');
  });
}
