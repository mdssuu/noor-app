import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/main.dart';
import 'package:noor_masjid_time/screens/fix_location_map.dart';

Masjid masjid({double latitude = 19.076, double longitude = 72.8777}) => Masjid(
      id: 'masjid-x',
      name: 'Aqsa Masjid Road',
      fajr: '05:15',
      dhuhr: '13:20',
      asr: '16:40',
      maghrib: '18:45',
      isha: '20:10',
      juma: '13:30',
      latitude: latitude,
      longitude: longitude,
      address: 'Kurla, Mumbai',
      photoProofPath: '',
      photoProofBase64: '',
      lastUpdated: Timestamp.fromMillisecondsSinceEpoch(1700000000000),
      updatedBy: 'Ayesha',
      updatedByUid: 'uid-editor',
      area: 'Jogeshwari West',
      createdByUid: 'uid-owner',
    );

/// The chip the nearby card carries at its trailing edge — the actual figure,
/// in the form that survives both ends of the range.
Future<void> _pumpBadge(WidgetTester tester, double metres) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: Center(child: DistanceBadge(metres: metres))),
  ));
}

void main() {
  group('distance repair', () {
    test('a longitude written into the latitude field is swapped back', () {
      expect(LocationService.repairLatLon(72.8777, 19.076), <double>[19.076, 72.8777]);
    });

    test('a correctly ordered pair is left alone', () {
      expect(LocationService.repairLatLon(19.076, 72.8777), <double>[19.076, 72.8777]);
    });

    test('a document with no position at all is not rewritten', () {
      expect(LocationService.repairLatLon(0, 0), <double>[0, 0]);
    });

    test('the Mumbai box accepts the city and rejects the sea', () {
      expect(LocationService.isInMumbai(19.076, 72.8777), isTrue);
      expect(LocationService.isInMumbai(72.8777, 19.076), isFalse);
      expect(LocationService.isInMumbai(0, 0), isFalse);
    });

    test('the reported distance never falls below the floor', () {
      // Same point as the fallback anchor, so the raw reading is zero.
      expect(LocationService.distanceTo(19.076, 72.8777),
          LocationService.minDistanceMetres);
      expect(LocationService.minDistanceMetres, 50);
    });
  });

  group('DistanceBadge', () {
    testWidgets('a short walk is called out in metres, not in words',
        (WidgetTester tester) async {
      await _pumpBadge(tester, 40);
      expect(find.text('40 m away'), findsOneWidget);
    });

    testWidgets('just under a kilometre stays in metres', (WidgetTester tester) async {
      await _pumpBadge(tester, 999);
      expect(find.text('999 m away'), findsOneWidget);
    });

    testWidgets('a kilometre or more switches to kilometres', (WidgetTester tester) async {
      await _pumpBadge(tester, 1234);
      expect(find.text('1.2 km away'), findsOneWidget);
    });

    testWidgets('a broken reading still says something', (WidgetTester tester) async {
      await _pumpBadge(tester, double.infinity);
      expect(find.text('—'), findsOneWidget);
    });
  });

  group('fix location screen', () {
    Future<void> pumpScreen(WidgetTester tester, {Masjid? input}) async {
      await tester.pumpWidget(MaterialApp(home: FixLocationMapScreen(masjid: input ?? masjid())));
      // Deliberately not pumpAndSettle: a tile provider that never answers
      // would keep frames coming forever.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('opens on the masjid coordinates and refuses to save a no-op',
        (WidgetTester tester) async {
      await pumpScreen(tester);

      // Current and New start out identical, so two readings of the same fix.
      expect(find.text('19.07600, 72.87770'), findsNWidgets(2));
      expect(find.text('Not moved yet'), findsOneWidget);
      expect(find.text('Drag the marker, or tap anywhere on the map, to move it.'), findsOneWidget);

      final FilledButton save = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save Location'),
      );
      expect(save.onPressed, isNull, reason: 'nothing has moved, so there is nothing to write');
    });

    testWidgets('tapping the map moves the marker and arms the save button',
        (WidgetTester tester) async {
      await pumpScreen(tester);

      // Well clear of the panel pinned to the bottom of the screen.
      await tester.tapAt(const Offset(150, 250));
      // flutter_map arms a hard-coded 250 ms state-reset timer on every
      // tap-up (FlutterMapInteractiveViewer.doubleTapDelay). Leaving it
      // pending trips the test binding's "no timers after dispose" check, so
      // let it run out before the tree goes away.
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Moved'), findsOneWidget);
      expect(find.text('Drag the marker, or tap anywhere on the map, to move it.'), findsNothing);

      final FilledButton save = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save Location'),
      );
      expect(save.onPressed, isNotNull);

      // And the new reading is shown next to the old one.
      expect(find.text('19.07600, 72.87770'), findsOneWidget, reason: 'the original stays put');
    });

    testWidgets('a coordinate outside Mumbai is called out', (WidgetTester tester) async {
      await pumpScreen(tester, input: masjid(latitude: 72.8777, longitude: 19.076));

      expect(
        find.textContaining('outside Mumbai'),
        findsOneWidget,
        reason: 'a transposed pair must be visible, not quietly sorted away',
      );
    });

    testWidgets('cancel closes the screen without writing', (WidgetTester tester) async {
      await pumpScreen(tester);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(FixLocationMapScreen), findsNothing);
    });
  });
}
