import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/main.dart';

/// Regression for "Aqsa Masjid Road ko Noor Masjid karna hai": the detail
/// screen swaps its own model the instant the write lands, so the corrected
/// name is on screen before the snapshot arrives. Everything else about the
/// document has to survive that copy untouched — prayer times, coordinates
/// and ownership all ride along on it.
void main() {
  group('Masjid.withName', () {
    final Masjid original = Masjid(
      id: 'masjid-x',
      name: 'Aqsa Masjid Road',
      fajr: '05:15',
      dhuhr: '13:20',
      asr: '16:40',
      maghrib: '18:45',
      isha: '20:10',
      juma: '13:30',
      latitude: 19.0760,
      longitude: 72.8777,
      address: 'Kurla, Mumbai',
      photoProofPath: '/proof/board.jpg',
      photoProofBase64: 'aGVsbG8=',
      lastUpdated: Timestamp.fromMillisecondsSinceEpoch(1700000000000),
      updatedBy: 'Ayesha',
      updatedByUid: 'uid-editor',
      area: 'Kurla',
      createdByUid: 'uid-owner',
      updateCount: 4,
    );

    test('takes the corrected spelling', () {
      expect(original.withName('Noor Masjid').name, 'Noor Masjid');
    });

    test('leaves the receiver as it was', () {
      expect(original.name, 'Aqsa Masjid Road',
          reason: 'the source model must not be mutated');
    });

    test('carries every other field across', () {
      final Masjid renamed = original.withName('Noor Masjid');

      expect(renamed.id, original.id);
      expect(renamed.fajr, original.fajr);
      expect(renamed.dhuhr, original.dhuhr);
      expect(renamed.asr, original.asr);
      expect(renamed.maghrib, original.maghrib);
      expect(renamed.isha, original.isha);
      expect(renamed.juma, original.juma);
      expect(renamed.latitude, original.latitude);
      expect(renamed.longitude, original.longitude);
      expect(renamed.address, original.address);
      expect(renamed.area, original.area);
      expect(renamed.photoProofPath, original.photoProofPath);
      expect(renamed.photoProofBase64, original.photoProofBase64);
      expect(renamed.lastUpdated, original.lastUpdated);
      expect(renamed.updatedBy, original.updatedBy);
      expect(renamed.updatedByUid, original.updatedByUid);
      expect(renamed.createdByUid, original.createdByUid);
      expect(renamed.updateCount, original.updateCount);
    });

    test('keeps the derived readings the UI shows', () {
      final Masjid renamed = original.withName('Noor Masjid');

      expect(renamed.hasProof, original.hasProof);
      expect(renamed.areaLabel, original.areaLabel);
      expect(renamed.timeFor('maghrib'), '18:45');
      expect(renamed.timeFor('unknown'), '--:--');
      // `canDelete` is deliberately not asserted: it reads FirebaseAuth, which
      // has no app in a unit test, and it does not consult the name anyway.
    });
  });
}
