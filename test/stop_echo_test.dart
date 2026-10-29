import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A stop travels in both directions over the channel, and only one of them
/// is safe to send twice.
///
/// The native side answers a stop it started — a volume key, the playback
/// notification, the lock-screen card — by calling `notifyDartToStop()`, so
/// the Dart player this side holds goes quiet too. But when Dart itself asked,
/// that call is an echo: it comes back as a *second* stop one frame later,
/// after whatever Dart started in the meantime. `preview()` does exactly that
/// — stop, then play — so the reply landed on top of the clip it had just
/// begun. Every "Test Azaan" tap started a recitation and had it torn down
/// 20 ms later, on every device, for as long as the bug existed: the player
/// was genuinely running, the log said so, and not one sound escaped.
///
/// The second half is the same shape on the other side of the fence.
/// `startService(ACTION_STOP)` against a service that is not running does not
/// stop anything — it *creates* one, and the fresh instance's first act is
/// `AzaanAudio.stop()`, arriving late enough to catch a playback that was not
/// there when the request was written. The preview's own stop went through
/// that path too, which is why it needed two fixes and not one.
///
/// Both are invisible in review and untestable from Dart, so they are pinned
/// here against the Kotlin they live in.
void main() {
  final String mainActivity = File(
    'android/app/src/main/kotlin/com/sunesra_app/MainActivity.kt',
  ).readAsStringSync();
  final String service = File(
    'android/app/src/main/kotlin/com/sunesra_app/AzaanPlaybackService.kt',
  ).readAsStringSync();

  /// The text from [marker] through the brace that closes it.
  String block(String source, String marker) {
    final int head = source.indexOf(marker);
    expect(head, greaterThanOrEqualTo(0),
        reason: '$marker is gone from the source — the test guarding it is '
            'now describing code that does not exist.');
    final int open = source.indexOf('{', head);
    int depth = 0;
    for (int i = open; i < source.length; i++) {
      if (source[i] == '{') depth++;
      if (source[i] == '}') {
        depth--;
        if (depth == 0) return source.substring(head, i + 1);
      }
    }
    return source.substring(head);
  }

  test('a stop Dart asked for is not echoed back to Dart', () {
    final String handler = block(mainActivity, 'METHOD_STOP ->');
    expect(handler, contains('AzaanAudio.stop()'),
        reason: 'the stop Dart asked for still has to actually stop '
            'something — that part was never in doubt.');
    expect(handler, isNot(contains('notifyDartToStop')),
        reason: 'METHOD_STOP came from Dart, which already knows it stopped. '
            'Echoing back starts a second stop a frame later, on the clip '
            'that has just begun — the preview died 20 ms in, every time.');
    expect(handler, isNot(contains('announceStopped')),
        reason: 'Dart cleared its own playing state before asking; a late '
            '`playbackFinished` would clear the state of whatever is playing '
            'now.');
  });

  test('a stop that started natively still reaches the Dart player', () {
    final String handler = block(mainActivity, 'private fun stopAzaan()');
    expect(handler, contains('notifyDartToStop'),
        reason: 'this is the half the echo exists for: a volume key or the '
            'notification stops the native player, and the Dart-side clip '
            'must go with it or the key is swallowed.');
  });

  test('no service is started just to be asked to stop', () {
    expect(service, contains('if (!up) return'),
        reason: 'startService(ACTION_STOP) on a down service creates one '
            'whose first act is AzaanAudio.stop() — late enough to hit a '
            'playback that did not exist when the request was written.');
    expect(block(service, 'override fun onDestroy()'), contains('up = false'),
        reason: 'the flag has to be released with the instance, or every '
            'later stop would be dispatched for a service long gone.');
  });

  // The volume rocker is the mute a reader reaches for at 5 a.m., and it
  // stopped answering the moment the screen went fully off. Two roads exist
  // for it and the screen-off case killed both at once: [AzaanActivity]'s
  // `onKeyDown` needs a focused window, and with the display off no window
  // of any app holds focus — while this session, which *does* still receive
  // the press as a media-button event, returned `false` for volume keys
  // without ever touching a stream, so the watcher one layer down saw
  // nothing move either. Both halves are pinned here.
  test('a volume key reaches the media session and is answered', () {
    final String handler = block(service, 'override fun onMediaButtonEvent');
    expect(handler, contains('KeyEvent.KEYCODE_VOLUME_DOWN'),
        reason: 'with the screen off this session is the only road left, '
            'and it was declining the very key the report is about.');
    expect(handler, contains('KeyEvent.KEYCODE_VOLUME_UP'),
        reason: 'either direction is the same press — the rocker means "off", '
            'strictly, not "softer".');
    expect(handler, contains('stopFromKey()'),
        reason: 'and answering it means stopping, not returning true for a '
            'keypress nothing then acted on.');
  });

  test('the rocker still has its own roads for the screen that is on', () {
    final String activity = File(
      'android/app/src/main/kotlin/com/sunesra_app/AzaanActivity.kt',
    ).readAsStringSync();
    expect(activity, contains('KEYCODE_VOLUME_DOWN'),
        reason: 'the focused-window road is the strict one: it catches a '
            'press that would change no stream at all, so a ring volume '
            'already at zero still answers.');
    expect(activity, contains('AzaanPlaybackService.stopFromAnywhere'),
        reason: 'and it stops through the same door as every other road, or '
            'two stops could race each other.');
  });
}
