import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The stream, and only the stream.
///
/// This file was written when the app promised, in four separate places, that
/// a reminder rang "at alarm volume when the phone is on silent" and only one
/// of them was code: the Kotlin player had drifted to
/// `USAGE_NOTIFICATION_RINGTONE`, the stream Android mutes the moment the
/// ringer leaves NORMAL, so the promise, the Dart bridge's own header and the
/// receiver's reasoning all described an alarm stream the device was never
/// given. The drift went unnoticed because the symptom is absence: no crash,
/// no error log, just a phone that does not ring — the same shape as the
/// shrinker bug that had eaten the clips one layer further down.
///
/// Whether the app rings at all on a silenced phone is a *different* question
/// and is no longer answered here: the reader's ringer mode is asked first, on
/// every path, and pinned in `azan_silence_test.dart`. What stays pinned is
/// the stream itself — it is what an app-closed alarm rides, and it is the
/// one position that survives a ringer key.
///
/// The other half is the rocker. Ending the recitation on a volume press is
/// only possible if the watcher reads the stream that is actually sounding,
/// which is why `STREAM_ALARM` is pinned next to the usage.
void main() {
  final String audio = File(
    'android/app/src/main/kotlin/com/sunesra_app/AzaanAudio.kt',
  ).readAsStringSync();

  test('the clip is played on the alarm stream', () {
    expect(audio, contains('AudioAttributes.USAGE_ALARM'),
        reason: 'the alarm stream is the position a ringer key does not move: '
            'it is what an app-closed alarm rides, and what makes a volume '
            'press land on the clip that is actually sounding.');
    expect(audio, isNot(contains('USAGE_NOTIFICATION_RINGTONE')),
        reason: 'the ringtone stream is muted by ringer mode and is not the '
            'stream the rocker adjusts mid-clip, so the recitation would end '
            'up somewhere no key can reach it.');
  });

  test('the watcher reads the stream that is sounding', () {
    expect(audio, contains('AudioManager.STREAM_ALARM'),
        reason: 'a stop on the volume key is read as a fall in the stream the '
            'clip is on; watching any other one would never see the press.');
    expect(audio, isNot(contains('AudioManager.STREAM_RING')),
        reason: 'watching a stream that is not playing means a rocker press '
            'ends nothing, and the key is swallowed.');
  });
}
