import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Settings me jo city set kare uske hisaab se times and masjid dikhe."
///
/// A city pinned in Settings is a *place the reader chose*, so it has to
/// answer three questions on its own — where distances are measured from,
/// where the OSM masjid search looks, and what the Azaan clock runs on —
/// without asking GPS for permission first. That is exactly what goes wrong
/// if the pin is treated as a display nicety: the header says Hyderabad while
/// the badges say Mumbai's, or the distances vanish because the phone never
/// got a fix.
///
/// Home cannot be pumped (Firebase, platform channels), so the screen wiring
/// is pinned where it lives and the anchor itself is exercised for real.
void main() {
  final Position fix = Position(
    latitude: 17.3850,
    longitude: 78.4867,
    timestamp: DateTime.utc(2026),
    accuracy: 5,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0,
  );

  TestWidgetsFlutterBinding.ensureInitialized();

  final String main = File('lib/main.dart').readAsStringSync();
  final String settings = File('lib/screens/settings_screen.dart').readAsStringSync();

  setUp(() {
    LocationService.serviceEnabled = false;
    LocationService.permissionState = LocationPermission.denied;
    LocationService.lastPosition = null;
    LocationService.syncDistanceGate();
  });

  tearDown(() {
    // The pin lives on the AppSettings singleton, which outlives a test —
    // leaving one behind would hand the next test an open distance gate
    // before it has done anything.
    AppSettings.instance.setCustomLocation(null, null, '');
    LocationService.serviceEnabled = false;
    LocationService.permissionState = LocationPermission.denied;
    LocationService.lastPosition = null;
    LocationService.syncDistanceGate();
  });

  /// Loads a profile no other test in this file has used, so the singleton
  /// really re-reads the mock preferences instead of returning early.
  Future<AppSettings> profile(String uid) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final AppSettings app = AppSettings.instance;
    await app.useProfile(uid);
    return app;
  }

  group('the anchor every distance is measured from', () {
    test('without a pin the phone fix decides, exactly as before', () async {
      final AppSettings app = await profile('anchor-gps');

      LocationService.lastPosition = fix;

      expect(app.hasCustomLocation, isFalse);
      expect(LocationService.anchorLatitude, closeTo(17.3850, 1e-9));
      expect(LocationService.anchorLongitude, closeTo(78.4867, 1e-9));
    });

    test('with no pin and no fix it is still Mumbai', () async {
      await profile('anchor-fallback');

      expect(LocationService.anchorLatitude,
          closeTo(LocationService.fallbackAnchor.x, 1e-9));
      expect(LocationService.anchorLongitude,
          closeTo(LocationService.fallbackAnchor.y, 1e-9));
    });

    test('the pinned city outranks a fix the reader has stopped using', () async {
      final AppSettings app = await profile('anchor-pin');
      app.setCustomLocation(17.3850, 78.4867, 'Hyderabad');
      LocationService.lastPosition = fix;

      expect(app.customCity, 'Hyderabad');
      expect(LocationService.anchorLatitude, closeTo(17.3850, 1e-9));
      expect(LocationService.anchorLongitude, closeTo(78.4867, 1e-9));
    });

    test('a pin answers alone, with the GPS never asked', () async {
      final AppSettings app = await profile('anchor-pin-only');
      app.setCustomLocation(12.9716, 77.5946, 'Bengaluru');

      expect(LocationService.lastPosition, isNull);
      expect(LocationService.anchorLatitude, closeTo(12.9716, 1e-9));
      expect(LocationService.anchorLongitude, closeTo(77.5946, 1e-9));
    });

    test('clearing the pin hands the anchor straight back to the fix', () async {
      final AppSettings app = await profile('anchor-clear');
      app.setCustomLocation(17.3850, 78.4867, 'Hyderabad');
      expect(LocationService.anchorLatitude, closeTo(17.3850, 1e-9));

      app.setCustomLocation(null, null, '');
      LocationService.lastPosition = fix;

      expect(app.hasCustomLocation, isFalse);
      expect(LocationService.anchorLatitude, closeTo(17.3850, 1e-9));
      // ...and with the fix gone too, the fallback again.
      LocationService.lastPosition = null;
      expect(LocationService.anchorLatitude,
          closeTo(LocationService.fallbackAnchor.x, 1e-9));
    });

    test('the pin is saved under the profile that set it', () async {
      final AppSettings app = await profile('anchor-persist');
      app.setCustomLocation(17.3850, 78.4867, 'Hyderabad');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble(AppSettings.scopedKeyFor('customLat', 'anchor-persist')),
          closeTo(17.3850, 1e-9));
      expect(prefs.getDouble(AppSettings.scopedKeyFor('customLng', 'anchor-persist')),
          closeTo(78.4867, 1e-9));
      expect(prefs.getString(AppSettings.scopedKeyFor('customCity', 'anchor-persist')),
          'Hyderabad');
    });
  });

  group('distanceAvailable with a pin', () {
    test('the pin opens the gate on its own — no service, no permission',
        () async {
      final AppSettings app = await profile('gate-pin');

      LocationService.serviceEnabled = false;
      LocationService.permissionState = LocationPermission.denied;
      LocationService.lastPosition = null;
      app.setCustomLocation(17.3850, 78.4867, 'Hyderabad');

      expect(LocationService.distanceAvailable, isTrue);
      expect(LocationService.syncDistanceGate(), isTrue,
          reason: 'the switch has to be published too, or the Home banner '
              'and the badges disagree about the same answer');
      expect(LocationService.distanceGate.value, isTrue);
    });

    test('without a pin the old gate still applies', () async {
      final AppSettings app = await profile('gate-gps');

      LocationService.serviceEnabled = false;
      LocationService.permissionState = LocationPermission.denied;
      LocationService.lastPosition = fix;

      expect(app.hasCustomLocation, isFalse);
      expect(LocationService.distanceAvailable, isFalse);
    });

    test('clearing the pin drops the gate back to the phone fix', () async {
      final AppSettings app = await profile('gate-clear');
      app.setCustomLocation(17.3850, 78.4867, 'Hyderabad');
      expect(LocationService.distanceAvailable, isTrue);

      app.setCustomLocation(null, null, '');
      LocationService.lastPosition = null;

      expect(LocationService.distanceAvailable, isFalse);
    });
  });

  group('the home screen follows the pin', () {
    test('a pin move re-runs the position work, not just a redraw', () {
      // `_settingsChanged` is the only door Settings has into Home. A pin
      // that only reached `setState` would leave the masjid list, the
      // distances and the schedule built from the previous place — the exact
      // "setting does nothing" read.
      final int start = main.indexOf('void _settingsChanged() {');
      expect(start, greaterThanOrEqualTo(0));
      final String body = main.substring(start, start + 800);

      expect(body, contains("if (anchor != _pinnedAnchor)"),
          reason: 'every toggle notifies, so the pin must be compared, not '
              'trusted — a madhab flip may not re-fetch the neighbourhood');
      expect(body, contains('LocationService.syncDistanceGate();'),
          reason: 'pinning and unpinning flips the distance gate, and nothing '
              'else in Settings republishes it');
      expect(body, contains('unawaited(_applyPosition(_position));'),
          reason: 'the anchor change has to reach the OSM search, the header '
              'name and the Azaan schedule, which all live in _applyPosition');
    });

    test('the anchor is recorded before the first Settings notification', () {
      // Bootstrap seeds the comparison value, otherwise the very first
      // notify (any setting at all) reads as a pin move.
      expect(main, contains("_pinnedAnchor = '\${settings.customLatitude},\${settings.customLongitude}';"),
          reason: 'without seeding, the first toggle after launch would look '
              'like the city just moved and re-fetch the neighbourhood');
      expect(main, contains('if (settings.hasCustomLocation && mounted)'),
          reason: 'a cold start with a pin must not greet the reader with '
              '"Near Mumbai" while their own city is already on disk');
    });

    test('_applyPosition builds the whole picture from the pin', () {
      final int start = main.indexOf('Future<void> _applyPosition(Position? position) async {');
      expect(start, greaterThanOrEqualTo(0));
      final String body = main.substring(start, main.indexOf('_showLocationHelp', start));

      expect(body, contains('final bool pinned = pinnedLat != null && pinnedLng != null;'),
          reason: 'half a pin is no pin: one null coordinate must not '
              'silently schedule against 0');
      expect(body, contains('setState(() => _locality = settings.customCity);'),
          reason: 'the header names the city the reader chose, not a '
              'reverse-geocoded fix that no longer decides anything');
      expect(body, contains('unawaited(_loadNearbyPlaces(pinnedLat, pinnedLng));'),
          reason: 'the masjid list must be the pinned city\'s, or the list '
              'and the header are two different places');
      expect(body, contains('unawaited(_loadNearbyPlaces(position.latitude, position.longitude));'),
          reason: 'the GPS path must stay exactly as it was when there is '
              'no pin');
      expect(body, contains('_refreshHomeWidget();'),
          reason: 'the widget tail runs for both branches — a pinned city '
              'would otherwise leave yesterday\'s widget coords on the '
              'home screen');
    });

    test('the widget is fed the shared anchor, not the raw GPS fix', () {
      final int start = main.indexOf('void _refreshHomeWidget() {');
      expect(start, greaterThanOrEqualTo(0));
      final String body = main.substring(start, start + 700);

      expect(body, contains('latitude: LocationService.anchorLatitude,'),
          reason: 'the widget computes the same times the app shows, or the '
              'lock screen and the Home card disagree about Fajr');
      expect(body, contains('longitude: LocationService.anchorLongitude,'));
      expect(body, contains("areaName: settings.hasCustomLocation"),
          reason: 'the widget names the pinned city too');
    });

    test('the OSM search is biased toward the pin first', () {
      expect(main, contains('lat: AppSettings.instance.customLatitude ?? _position?.latitude,'),
          reason: 'a search around the phone while the list is sorted from '
              'the pinned city returns masjids in the wrong place');
      expect(main, contains('lon: AppSettings.instance.customLongitude ?? _position?.longitude,'));
    });

    test('a healthy pin silences the "location is off" banner', () {
      final int start = main.indexOf('void _showLocationHelp(Position? position) {');
      expect(start, greaterThanOrEqualTo(0));
      final String body = main.substring(start, start + 1400);

      final int early = body.indexOf('if (AppSettings.instance.hasCustomLocation) return;');
      expect(early, greaterThanOrEqualTo(0),
          reason: 'nothing about a switched-off GPS is wrong for a reader '
              'whose city is pinned — the banner would be lying');
      expect(early, lessThan(body.indexOf('ScaffoldMessenger')),
          reason: 'and it has to return before the snackbar, not after');
    });
  });

  group('the settings row that moves the pin', () {
    test('pinning is offered and the pin can be taken off again', () {
      expect(settings, contains("Pinned city · \${_settings.customCity}"),
          reason: 'the reader needs to see which city is currently winning');
      expect(settings, contains('Icons.push_pin'),
          reason: 'a pinned city with no marker is indistinguishable from '
              'GPS');
      expect(settings,
          contains('onPressed: () => _settings.setCustomLocation(null, null, \'\')'),
          reason: 'a pin that cannot be cleared traps the reader in a city '
              'they chose once');
      expect(settings, contains('_settings.setCustomLocation('),
          reason: 'and something has to write it in the first place');
    });
  });
}
