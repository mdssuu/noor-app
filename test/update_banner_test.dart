import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The wiring behind Home's update card.
///
/// Home itself cannot be pumped in a widget test — it listens to Firebase
/// and the platform channels — so the parts that would silently stop
/// working (a card defined but never shown, a button opening the wrong
/// door, a panel field nothing saves) are pinned where they live.
void main() {
  test('Home offers the update the panel announced', () {
    final String main = File('lib/main.dart').readAsStringSync();

    expect(main, contains('_updateBanner(),'),
        reason: 'a card defined but never added to the list is a card '
            'nobody sees');
    expect(main, contains('AboutScreen.downloadUrl'),
        reason: 'the button opens the same APK the About page offers, or '
            'the two doors disagree about where an update comes from');
    expect(main, contains('_dismissedUpdateVersion = latest'),
        reason: 'dismissing is per version, so a newer release can come '
            'back while the old one stays closed');
    expect(main, contains('isVersionNewer(latest, installed)'),
        reason: 'without the comparison every phone would be told to '
            'update to whatever the owner last typed');
  });

  test('the panel sets the version and the save actually carries it', () {
    final String admin =
        File('lib/screens/admin_config_screen.dart').readAsStringSync();
    expect(admin, contains('latestVersion: _latestVersion.text.trim()'),
        reason: 'a field the panel never saves is a field no phone sees');

    final String config =
        File('lib/services/app_config.dart').readAsStringSync();
    expect(config, contains("'latestVersion': latestVersion,"),
        reason: 'toMap must carry it or the save has nothing to write');
    expect(config, contains("\n          'latestVersion',"),
        reason: 'the field mask must name it, or Firestore keeps the old '
            'value under merge semantics');
  });
}
