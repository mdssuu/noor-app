import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The stream, and the rocker.
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
/// The player went back to `USAGE_ALARM` for that, and stayed there until the
/// opposite complaint arrived: an Azaan nobody could turn off with the volume
/// button. The stream is `USAGE_NOTIFICATION_RINGTONE` again now, deliberately
/// and for the other reason — the reader's ringer is their choice, one slider
/// and one key and one sound. What is left of the silence promise is asked,
/// not assumed: `ringerMode` on every path, pinned in
/// `azan_silence_test.dart`.
///
/// Whether the app rings at all on a silenced phone is a *different* question
/// and is no longer answered here: the reader's ringer mode is asked first, on
/// every path, and pinned in `azan_silence_test.dart`. What stays pinned is
/// the stream itself — it used to be `USAGE_ALARM`, loud and deaf to the
/// rocker, which is exactly how "the volume button cannot stop it" came to be
/// a complaint: the clip played where the key did not go. It is the reader's
/// own ringer now, so the slider and the key and the clip are one thing.
///
/// The other half is the rocker, and it used to be answered with a single
/// line: watch `STREAM_ALARM`, because that is where the clip is, so a press
/// must be a fall there. It was wrong twice over, and the reader said so —
/// the Azaan could not be turned off with the volume button at all. Android
/// does not send a key to whatever is sounding; it sends it to its own idea
/// of what is active, which is the ringtone. And a press is not a fall: the
/// reader reaching for the rocker wants the thing gone, up or down, and the
/// alarm stream has no zero to fall to anyway.
///
/// So the pin is the *set*, not the single stream, and the direction. Every
/// stream a key could plausibly move is watched, any movement of any of them
/// ends the recitation, and the alarm stream stays in the set because some
/// builds route the key there regardless of what is playing.
void main() {
  final String audio = File(
    'android/app/src/main/kotlin/com/sunesra_app/AzaanAudio.kt',
  ).readAsStringSync();

  test('the clip is played on the reader\u2019s own ringer', () {
    expect(audio, contains('AudioAttributes.USAGE_NOTIFICATION_RINGTONE'),
        reason: 'one slider sets how loud a prayer may be, and it is the same '
            'slider the volume keys move — so a press lands on the number the '
            'Azaan is actually playing at. The old `USAGE_ALARM` was loud and '
            'deliberately deaf to the rocker, which is the complaint this '
            'reverses: no key could reach the clip at all.');
    expect(audio, isNot(contains('AudioAttributes.USAGE_ALARM')),
        reason: 'the alarm stream is the one position a ringer key does not '
            'move; keeping the clip there would put the sound and the control '
            'on two different numbers again.');
  });

  test('the watcher reads every stream a key could move', () {
    expect(audio, contains('AudioManager.STREAM_ALARM'),
        reason: 'some builds route the key here regardless of what is '
            'playing, so it stays in the set — that half was always right.');
    expect(audio, contains('AudioManager.STREAM_RING'),
        reason: 'this is the stream Android actually hands a volume key to '
            'while nothing else is active, which is nearly always. Watching '
            'only the alarm stream meant the key moved a number nobody was '
            'reading and the Azaan played to the end — the reported bug.');
    expect(audio, contains('AudioManager.STREAM_NOTIFICATION'),
        reason: 'aliased to the ring stream on most builds, so it moves with '
            'it; reading it too costs nothing and covers the build that '
            'does not alias.');
    expect(audio, contains('AudioManager.STREAM_MUSIC'),
        reason: 'a session holding transport controls can make Android treat '
            'media as the active stream, and then the key lands here instead.');
  });

  test('any movement of any watched stream ends the recitation', () {
    // The stop condition used to be `level >= startLevel` — a *fall*, and only
    // on the alarm stream. Two things were wrong with it: the reader pressing
    // the key is not adjusting a level, they are ending a sound, and waiting
    // for the alarm stream's floor asked for fifteen presses that could never
    // arrive because it has no zero without an app-op.
    expect(audio, isNot(contains('if (level >= startLevel)')),
        reason: 'a rise must end the clip as surely as a fall — the rocker '
            'means "stop", strictly, in either direction.');
    expect(audio, contains('if (level == startLevels[i]) continue'),
        reason: 'the comparison that stays is the one that skips levels that '
            'did not move: everything else reads as the press.');
  });

  test('the poll is fast enough to feel like the press itself', () {
    expect(audio, contains('POLL_INTERVAL_MS = 250L'),
        reason: 'the watcher is polled rather than observed, so it only feels '
            'immediate if the interval says so; a full second is a beat the '
            'reader watches the Azaan keep sounding through.');
  });
}
