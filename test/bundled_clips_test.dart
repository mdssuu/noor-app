import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';

/// A clip a reader picks has to survive three places that know nothing about
/// each other: the file in `res/raw`, the `when` in `AzaanAudio.bundledId`,
/// and the release build's resource shrinker.
///
/// All three once drifted apart in the worst way it is possible to drift. The
/// shrinker — switched on for release by Flutter's own Gradle plugin — cannot
/// see a resource that is only ever named through
/// `Resources.getIdentifier()`, so it dropped **every** clip from the APK:
/// `getIdentifier` answered `0`, `AzaanAudio` logged "no downloaded clip and
/// no res/raw/… — nothing to play", and the Azaan never sounded on a phone
/// whose repository held all four files. It looked like a settings bug, a
/// volume bug, a MIUI bug; it was a build that quietly threw the sound away.
///
/// Naming the clips from Kotlin is what keeps them in the APK. These tests
/// are what keep the names honest — a new sound added to [kAzanSounds] and
/// forgotten in `bundledId()` is a silent Azaan again, and silence is exactly
/// the symptom no one can debug from the phone.
void main() {
  const String kotlinPath =
      'android/app/src/main/kotlin/com/sunesra_app/AzaanAudio.kt';
  const String gradlePath = 'android/app/build.gradle.kts';

  Iterable<String> bundled() =>
      kAzanSounds.map((AzanSound s) => s.androidRaw).whereType<String>();

  test('every sound that claims a bundle has a file in res/raw', () {
    final List<FileSystemEntity> files =
        Directory('android/app/src/main/res/raw').listSync();

    for (final String raw in bundled()) {
      final bool present = files.any((FileSystemEntity e) {
        final String name = e.uri.pathSegments.last;
        return name == raw || name.startsWith('$raw.');
      });
      expect(
        present,
        isTrue,
        reason: 'kAzanSounds offers "$raw", and no file matching '
            '$raw.* is in android/app/src/main/res/raw — the row would '
            'offer a clip that cannot be played.',
      );
    }
  });

  test('every bundled clip is named in AzaanAudio.bundledId', () {
    final String source = File(kotlinPath).readAsStringSync();

    for (final String raw in bundled()) {
      expect(
        source,
        contains('"$raw" -> R.raw.$raw'),
        reason: '"$raw" is now looked up by name only, which the resource '
            'shrinker cannot see — a direct R.raw reference is what holds the '
            'clip in a release APK. Add it to AzaanAudio.bundledId().',
      );
    }
  });

  test('the release build does not shrink resources', () {
    final String gradle = File(gradlePath).readAsStringSync();

    expect(
      gradle,
      contains('isShrinkResources = false'),
      reason: 'Resource shrinking strips anything only reachable through '
          'getIdentifier() — which is how every Azaan clip is reached. It '
          'removed them from the shipped APK while the repository kept all '
          'four, and no amount of code reading explains a silent Azaan.',
    );
  });
}
