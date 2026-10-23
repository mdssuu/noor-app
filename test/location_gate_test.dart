import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:noor_masjid_time/main.dart';

/// The contract behind "hide the distance until GPS is on".
///
/// `LocationService.distanceTo` deliberately falls back to Mumbai so a cold
/// start can still sort a list — which means it always returns a *number*,
/// even when that number is fiction. These tests pin the second half of the
/// contract: `distanceAvailable` must be false in exactly those cases, so the
/// UI has a reliable switch to read.
void main() {
  final Position fix = Position(
    latitude: 19.0760,
    longitude: 72.8777,
    timestamp: DateTime.utc(2026),
    accuracy: 5,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0,
  );

  setUp(() {
    LocationService.serviceEnabled = false;
    LocationService.permissionState = LocationPermission.denied;
    LocationService.lastPosition = null;
    LocationService.syncDistanceGate();
  });

  tearDown(() {
    LocationService.serviceEnabled = false;
    LocationService.permissionState = LocationPermission.denied;
    LocationService.lastPosition = null;
    LocationService.syncDistanceGate();
  });

  group('LocationService.distanceAvailable', () {
    test('is off at a cold start, before anything is known', () {
      expect(LocationService.distanceAvailable, isFalse);
      expect(LocationService.distanceGate.value, isFalse);
    });

    test('stays off while the OS location switch is off, even with a fix', () {
      LocationService.serviceEnabled = false;
      LocationService.permissionState = LocationPermission.whileInUse;
      LocationService.lastPosition = fix;

      expect(LocationService.distanceAvailable, isFalse);
    });

    test('stays off when permission is refused', () {
      LocationService.serviceEnabled = true;
      LocationService.permissionState = LocationPermission.denied;
      LocationService.lastPosition = fix;

      expect(LocationService.distanceAvailable, isFalse);
    });

    test('stays off when permission is blocked in system settings', () {
      LocationService.serviceEnabled = true;
      LocationService.permissionState = LocationPermission.deniedForever;
      LocationService.lastPosition = fix;

      expect(LocationService.distanceAvailable, isFalse);
    });

    test('stays off when permission is fine but there is no fix yet', () {
      LocationService.serviceEnabled = true;
      LocationService.permissionState = LocationPermission.whileInUse;
      LocationService.lastPosition = null;

      expect(LocationService.distanceAvailable, isFalse);
    });

    test('comes on only with switch + permission + fix together', () {
      LocationService.serviceEnabled = true;
      LocationService.permissionState = LocationPermission.always;
      LocationService.lastPosition = fix;

      expect(LocationService.distanceAvailable, isTrue);
    });

    test('goes off again the moment the switch is turned off', () {
      LocationService.serviceEnabled = true;
      LocationService.permissionState = LocationPermission.whileInUse;
      LocationService.lastPosition = fix;
      LocationService.syncDistanceGate();
      expect(LocationService.distanceGate.value, isTrue);

      LocationService.serviceEnabled = false;

      expect(LocationService.distanceAvailable, isFalse);
      expect(LocationService.syncDistanceGate(), isTrue);
      expect(LocationService.distanceGate.value, isFalse);
    });

    test('a stale fix alone never opens the gate', () {
      // This is the exact state `_lastKnown()` leaves behind when the user has
      // location switched off: a cached position on disk and no live service.
      LocationService.serviceEnabled = false;
      LocationService.permissionState = LocationPermission.whileInUse;
      LocationService.lastPosition = fix;

      expect(LocationService.lastPosition, isNotNull);
      expect(LocationService.distanceAvailable, isFalse);
    });
  });

  group('LocationService.syncDistanceGate', () {
    test('notifies only when the answer actually flips', () {
      expect(LocationService.syncDistanceGate(), isFalse);

      LocationService.serviceEnabled = true;
      LocationService.permissionState = LocationPermission.whileInUse;
      LocationService.lastPosition = fix;

      expect(LocationService.syncDistanceGate(), isTrue);
      expect(LocationService.distanceGate.value, isTrue);

      // Publishing the same answer again must not wake every listener.
      expect(LocationService.syncDistanceGate(), isFalse);
    });
  });

  group('distanceTo still measures while the gate is shut', () {
    test('keeps returning a number so sorting never divides by zero', () {
      LocationService.serviceEnabled = false;
      LocationService.lastPosition = null;

      expect(LocationService.distanceAvailable, isFalse);
      expect(LocationService.distanceTo(19.0760, 72.8777).isFinite, isTrue);
      // The 50 m floor still applies — nothing may read as "0 m away".
      expect(LocationService.distanceTo(19.0760, 72.8777),
          greaterThanOrEqualTo(LocationService.minDistanceMetres));
    });
  });

  group('LocationOffBanner', () {
    testWidgets('states why the distance is gone and offers the way back',
        (WidgetTester tester) async {
      bool tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LocationOffBanner(
              reason: 'Location is off — distances are hidden',
              onTurnOn: () => tapped = true,
            ),
          ),
        ),
      );

      expect(find.text('Location is off — distances are hidden'), findsOneWidget);
      expect(find.byIcon(Icons.location_off_outlined), findsOneWidget);

      await tester.tap(find.text('Turn on'));
      await tester.pump();

      expect(tapped, isTrue);
    });

    testWidgets('long reason still fits on one line of the banner',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LocationOffBanner(
              reason: 'No location permission — distances are hidden',
              onTurnOn: _noop,
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Turn on'), findsOneWidget);
    });
  });
}

void _noop() {}
