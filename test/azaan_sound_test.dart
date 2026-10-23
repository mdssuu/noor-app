import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';

/// Guards the wiring behind "the Azaan plays instead of the default ding".
///
/// The sound only reaches the phone if the file named by `androidRaw` really
/// sits in `android/app/src/main/res/raw/` — Android resolves the name at
/// runtime and simply stays silent when the resource is missing, which is
/// exactly the bug this all started from. A rename in one place with no
/// matching file in the other now fails the build instead of the user's Fajr.
void main() {
  group('Azaan sound catalogue', () {
    test('every audible entry names a file in res/raw', () {
      for (final AzanSound sound in kAzanSounds) {
        if (sound.key == 'silent') {
          expect(sound.androidRaw, isNull,
              reason: '"None" must not carry a resource');
          expect(sound.iosSound, isNull);
          continue;
        }
        expect(sound.androidRaw, isNotNull,
            reason: '${sound.key} needs an Android resource');

        final File raw = File(
            'android/app/src/main/res/raw/${sound.androidRaw}.mp3');
        final File wav =
            File('android/app/src/main/res/raw/${sound.androidRaw}.wav');
        final File file = raw.existsSync()
            ? raw
            : (wav.existsSync() ? wav : File('missing'));
        expect(file.existsSync(), isTrue,
            reason: 'res/raw/${sound.androidRaw} is not on disk');
        expect(file.lengthSync(), greaterThan(1000),
            reason: '${sound.androidRaw} looks truncated');
      }
    });

    test('every audible entry names a file in the iOS bundle', () {
      for (final AzanSound sound in kAzanSounds) {
        if (sound.key == 'silent') continue;
        expect(sound.iosSound, isNotNull, reason: '${sound.key} needs an iOS sound');
        expect(File('ios/Runner/${sound.iosSound}').existsSync(), isTrue,
            reason: 'ios/Runner/${sound.iosSound} is not on disk');
      }
    });

    test('the keys Settings writes are stable', () {
      expect(kAzanSounds.map((AzanSound s) => s.key).toList(),
          <String>['makkah', 'madina', 'mishary', 'beep', 'silent']);
    });

    test('an unknown stored key falls back to an audible default', () {
      final AzanSound fallback = azanSoundByKey('some-key-from-an-old-build');
      expect(fallback, kAzanSounds.first);
      expect(fallback.androidRaw, isNotNull);
    });

    test('a stored silent choice resolves to silence', () {
      expect(azanSoundByKey('silent').androidRaw, isNull);
    });
  });
}
