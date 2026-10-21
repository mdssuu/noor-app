import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/main.dart';

/// The nearby list is sorted by distance, but a starred masjid is a choice
/// rather than a measurement — so it has to lead the list whatever the GPS
/// says, and everything else follows in the order distance already gave it.
///
/// These tests pin the ordering contract of `favouritesFirst`, which is the
/// one place that decides it.
void main() {
  Masjid masjid(String id) => Masjid(
        id: id,
        name: 'Masjid $id',
        fajr: '05:15',
        dhuhr: '13:20',
        asr: '16:40',
        maghrib: '18:45',
        isha: '20:10',
        juma: '13:30',
        latitude: 19.076,
        longitude: 72.8777,
        address: 'Kurla, Mumbai',
        photoProofPath: '',
        photoProofBase64: '',
        lastUpdated: Timestamp.fromMillisecondsSinceEpoch(1700000000000),
        updatedBy: 'Ayesha',
        updatedByUid: 'uid-editor',
      );

  /// A list that has already been sorted by distance — nearest first.
  MapEntry<Masjid, double> near(String id, double metres) =>
      MapEntry<Masjid, double>(masjid(id), metres);

  List<String> ids(List<MapEntry<Masjid, double>> entries) =>
      entries.map((MapEntry<Masjid, double> e) => e.key.id).toList();

  group('favouritesFirst', () {
    test('a starred masjid jumps to the top, the rest keep their order', () {
      final List<MapEntry<Masjid, double>> ordered = <MapEntry<Masjid, double>>[
        near('a', 120),
        near('b', 300),
        near('c', 900),
      ];

      expect(
        ids(favouritesFirst(ordered, <String>['c'])),
        <String>['c', 'a', 'b'],
      );
    });

    test('every starred masjid lands above every unstarred one', () {
      final List<MapEntry<Masjid, double>> ordered = <MapEntry<Masjid, double>>[
        near('a', 120),
        near('b', 300),
        near('c', 900),
        near('d', 1500),
      ];

      expect(
        ids(favouritesFirst(ordered, <String>['d', 'b'])),
        <String>['b', 'd', 'a', 'c'],
      );
    });

    test('starred masjids keep the arrival order between themselves', () {
      // This is the GPS-off path: there is no distance to sort by, so the
      // partition must leave ties exactly where it found them rather than
      // reshuffling them on the next rebuild.
      final List<MapEntry<Masjid, double>> unsorted = <MapEntry<Masjid, double>>[
        near('a', 900),
        near('b', 120),
        near('c', 300),
      ];

      expect(
        ids(favouritesFirst(unsorted, <String>['a', 'c'])),
        <String>['a', 'c', 'b'],
      );
    });

    test('with nothing starred the order is untouched', () {
      final List<MapEntry<Masjid, double>> ordered = <MapEntry<Masjid, double>>[
        near('a', 120),
        near('b', 300),
        near('c', 900),
      ];

      expect(
        ids(favouritesFirst(ordered, <String>[])),
        <String>['a', 'b', 'c'],
      );
    });

    test('with everything starred the order is untouched', () {
      final List<MapEntry<Masjid, double>> ordered = <MapEntry<Masjid, double>>[
        near('a', 120),
        near('b', 300),
        near('c', 900),
      ];

      expect(
        ids(favouritesFirst(ordered, <String>['a', 'b', 'c'])),
        <String>['a', 'b', 'c'],
      );
    });

    test('an empty list stays empty', () {
      expect(favouritesFirst(<MapEntry<Masjid, double>>[], <String>['a']), isEmpty);
    });
  });
}
