import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/main.dart';
import 'package:noor_masjid_time/screens/home_extras.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The WhatsApp-forward feature: the text that has to be *complete enough*
/// that nobody opens the app to check it.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.instance.load();
  });

  final Masjid board = Masjid(
    id: 'm1',
    name: 'Masjid-e-Noor',
    fajr: '05:30',
    dhuhr: '13:00',
    asr: '16:15',
    maghrib: '18:10',
    isha: '20:00',
    juma: '13:15',
    latitude: 19.0760,
    longitude: 72.8777,
    address: 'Kurla West',
    photoProofPath: '',
    photoProofBase64: '',
    lastUpdated: Timestamp.fromDate(DateTime(2026, 10, 1)),
    updatedBy: '',
    updatedByUid: '',
  );

  group('the shared message', () {
    final String text = buildShareText(
      latitude: 19.0760,
      longitude: 72.8777,
      areaName: 'Kurla',
      now: DateTime(2026, 10, 12, 10, 30),
    );

    test('opens with the app, the day and the place', () {
      expect(text, contains('Noor'));
      expect(text, contains('Monday, 12 October 2026'));
      expect(text, contains('Kurla'));
      expect(text, contains('1448'), reason: 'both calendars, or it is a screenshot');
    });

    test('carries every one of the day’s times', () {
      for (final String label in <String>[
        'Fajr', 'Sunrise', 'Dhuhr', 'Asr', 'Maghrib', 'Isha',
      ]) {
        expect(text, contains(label), reason: '$label is why it was shared');
      }
    });

    test('adds the starred board’s Jamaat column — including Jumu’ah', () {
      final String withBoard = buildShareText(
        latitude: 19.0760,
        longitude: 72.8777,
        areaName: 'Kurla',
        board: board,
        now: DateTime(2026, 10, 12, 10, 30),
      );
      expect(withBoard, contains('Masjid-e-Noor'));
      expect(withBoard, contains('Jamaat'));
      expect(withBoard, contains('Jumu'));
      expect(withBoard.length, greaterThan(text.length),
          reason: 'the board only ever adds, never replaces');
    });

    test('leaves the board out when nothing is starred', () {
      expect(text, isNot(contains('Jamaat')));
      expect(text, isNot(contains('Masjid-e-Noor')));
    });
  });
}
