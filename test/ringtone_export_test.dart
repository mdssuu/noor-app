import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Azaan in the phone's own list.
///
/// This file was written for the complaint that the Azaan could only be
/// offered to the system as an *alarm* sound: an alarm rides a slider of
/// its own, one the volume rocker never moves, while a ringtone rides the
/// ringer's — the very number the keys adjust. Inside the app the recitation
/// already answers the rocker (pinned in `azan_stream_test.dart`); what was
/// missing was the other half, the clip existing anywhere the *system* can
/// offer it as a ringtone at all. The app had never written a
/// `MediaStore` row — the clip lived inside the APK where no picker can
/// see it.
///
/// So the pin is the row and the road to it: the `IS_RINGTONE` flag the
/// list is literally a query for, the folder the pickers read, the same
/// bytes the player plays (or the list could carry a different Azaan from
/// the one a reminder recites), and the older phones' permission — asked,
/// answered, and never lost, because a channel result parked behind a
/// prompt that never comes back is a Settings screen waiting forever.
void main() {
  const String kotlin = 'android/app/src/main/kotlin/com/sunesra_app/';
  final String ringtones =
      File('${kotlin}PhoneRingtones.kt').readAsStringSync();
  final String audio = File('${kotlin}AzaanAudio.kt').readAsStringSync();
  final String activity = File('${kotlin}MainActivity.kt').readAsStringSync();
  final String manifest =
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  final String alarm = File('lib/services/azaan_alarm.dart').readAsStringSync();
  final String settings =
      File('lib/screens/settings_screen.dart').readAsStringSync();

  test('the row carries the flag the ringtone list is a query for', () {
    expect(ringtones, contains('MediaStore.Audio.Media.IS_RINGTONE, 1'),
        reason: '"Phone ringtone" is a query over MediaStore for rows '
            'carrying this flag; without it the clip stays reachable only '
            'where the volume rocker does not go — as an alarm, which is '
            'exactly the reported complaint.');
    expect(ringtones, contains('MediaStore.Audio.Media.IS_ALARM, 1'),
        reason: 'the alarm tag is kept as well: that is where the clip '
            'could be reached before this existed, and adding one list must '
            'not cost the other.');
    expect(ringtones, contains('Environment.DIRECTORY_RINGTONES'),
        reason: 'the folder every phone’s own picker reads from — the row '
            'is half of it, the file has to be sitting where the picker '
            'looks.');
  });

  test('the exported bytes are the ones the player would play', () {
    expect(ringtones, contains('AzaanAudio.cachedClip'),
        reason: 'the owner’s download first, the same precedence '
            'AzaanAudio.play walks — or the ringtone could hold a different '
            'Azaan from the one a reminder recites, with nothing to notice.');
    expect(ringtones, contains('AzaanAudio.bundledId'),
        reason: 'and the bundled clip next, so a missing download falls '
            'back instead of falling out of the list.');
    expect(audio, contains('fun bundledId'),
        reason: 'the resolver is shared, not copied — a second copy would '
            'be a second answer to "which file is the Azaan".');
  });

  test('older phones ask first, and their answer is not lost', () {
    expect(manifest, contains('WRITE_EXTERNAL_STORAGE'),
        reason: 'Android 7–9 gate the public Ringtones folder behind it; '
            'undeclared, the prompt it must show can never be granted.');
    expect(manifest, contains('android:maxSdkVersion="28"'),
        reason: 'and Android 10+ needs nothing for a MediaStore row it '
            'creates itself — carrying the ask further would be a prompt '
            'with no purpose on modern phones.');
    expect(activity, contains('requestPermissions('),
        reason: 'the prompt can only be answered while the reader is '
            'looking at it, so this side asks rather than Dart.');
    expect(activity, contains('onRequestPermissionsResult'),
        reason: 'granted or refused, the parked channel result is finished '
            'from the callback — or Settings would await a reply that never '
            'comes and its button would hang.');
    expect(activity, contains('pendingRingtone'),
        reason: 'one prompt at a time: a second tap while the first is up '
            'would strand the first reply.');
  });

  test('the Settings row and the bridge under it agree', () {
    expect(settings, contains("'Add to phone ringtone list'"),
        reason: 'the button the reader actually taps.');
    expect(settings, contains("'Noor Azaan - \${"),
        reason: 'the title the entry lands under — named for the app, so '
            'the phone’s list says whose clip it is among its own sounds.');
    expect(settings, contains('_addToPhoneRingtone'),
        reason: 'and its handler, which answers "None (silent)" with a '
            'sentence instead of exporting nothing.');
    expect(alarm, contains('addToPhoneRingtone'),
        reason: 'the bridge the row dials — a name both sides must spell '
            'the same way, or the tap answers notImplemented.');
    expect(alarm, contains('openSoundSettings'),
        reason: 'the walk to the picker the success snackbar promises.');
    expect(activity, contains('Settings.ACTION_SOUND_SETTINGS'),
        reason: 'the page that holds "Phone ringtone", under whatever name '
            'its maker gave it.');
    expect(manifest, contains('android.settings.SOUND_SETTINGS'),
        reason: 'and Android 11+ hides every package an app has not declared '
            '— undeclared, the intent resolves to null and the promised walk '
            'never starts.');
    expect(activity, contains('"addToPhoneRingtone"'),
        reason: 'the channel key spelled from the Kotlin side — the two '
            'wires of one call, pinned together.');
  });
}
