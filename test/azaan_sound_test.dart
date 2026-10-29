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

    // A stored "custom" is a known key with no catalogue entry, and it used
    // to answer `kAzanSounds.first` — Makkah. The lookup is one function,
    // so the one wrong answer was everywhere a stored key was resolved: the
    // alarm recited a clip the reader had *replaced*, at prayer time, with
    // the app closed; and "Add to phone ringtone" handed the phone that
    // same Makkah clip under a title the reader had never chosen. The
    // preview did not show it, because the player asks the custom question
    // before it ever reaches this function — which is why the bug could sit
    // under a working "Test Azaan".
    test('the reader’s own clip resolves to itself, not to the first entry',
        () {
      final AzanSound custom = azanSoundByKey(kCustomAzanKey);
      expect(custom.key, kCustomAzanKey,
          reason: 'the key a stored choice is written under has to be the '
              'key it comes back as, or every caller reads a different clip.');
      expect(kAzanSounds.any((AzanSound s) => s.key == kCustomAzanKey), isFalse,
          reason: 'and it stays out of the catalogue on purpose: no bundled '
              'resource, no URL, nothing any other phone could be seeded '
              'with — it is one reader’s file.');
      expect(custom.androidRaw, isNull,
          reason: 'its bytes live on the reader’s phone; the Kotlin side '
              'opens them by path and never asks for a resource id.');
      expect(custom.label, isNotEmpty,
          reason: 'a sound with nowhere to be named still has to read as '
              'something in the admin panel’s summary.');
    });

    test('the clip is named by its file, the same name everywhere', () {
      expect(customAzanName(''), '',
          reason: 'no file picked, no name — the row keeps its own sentence '
              'for that case.');
      expect(customAzanName('/storage/emulated/0/Music/Adhan.mp3'), 'Adhan.mp3',
          reason: 'a reader cares about Adhan.mp3, not the road to it.');
      expect(customAzanName('Adhan.mp3'), 'Adhan.mp3',
          reason: 'and a name with no road under it stays itself.');
    });
  });
}
