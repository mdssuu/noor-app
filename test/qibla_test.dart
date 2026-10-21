import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/services/qibla.dart';

/// The compass maths, anchored to the two most widely published Qibla
/// bearings in the world — New York and London — plus the invariants that
/// make a bearing trustworthy anywhere else.
void main() {
  group('bearing to the Kaaba', () {
    test('New York reads 58.48°', () {
      // The published value quoted by every qibla finder.
      expect(Qibla.bearing(40.7128, -74.0060), closeTo(58.48, 0.3));
    });

    test('London reads 118.99°', () {
      expect(Qibla.bearing(51.5074, -0.1278), closeTo(118.99, 0.3));
    });

    test('standing on the Kaaba reads 0°', () {
      expect(Qibla.bearing(Qibla.kaabaLatitude, Qibla.kaabaLongitude),
          closeTo(0, 0.001));
    });

    test('from India the Qibla is west — but never flat west', () {
      // Mumbai (~280°), Delhi (~267°) and Hyderabad (~283°). One number for
      // the whole subcontinent would be the sign of a formula that guessed
      // instead of computed.
      expect(Qibla.bearing(19.0760, 72.8777), inInclusiveRange(278.0, 283.0));
      expect(Qibla.bearing(28.6139, 77.2090), inInclusiveRange(264.0, 270.0));
      expect(Qibla.bearing(17.3850, 78.4867), inInclusiveRange(280.0, 286.0));
    });

    test('southern latitudes still aim north of due west', () {
      // Jakarta's published Qibla is ~295° — north of west, as it must be
      // from below the equator.
      expect(Qibla.bearing(-6.2088, 106.8456), closeTo(295.0, 1.0));
    });
  });

  group('distance to Makkah', () {
    test('London is ~4,800 km away', () {
      expect(Qibla.distanceKm(51.5074, -0.1278), closeTo(4800, 60));
    });

    test('New York is ~10,300 km away', () {
      expect(Qibla.distanceKm(40.7128, -74.0060), closeTo(10300, 80));
    });

    test('zero at the Kaaba itself', () {
      expect(Qibla.distanceKm(Qibla.kaabaLatitude, Qibla.kaabaLongitude),
          closeTo(0, 0.001));
    });
  });

  group('normalize', () {
    test('folds both ends of the circle', () {
      expect(Qibla.normalize(370), 10);
      expect(Qibla.normalize(-10), 350);
      expect(Qibla.normalize(360), 0);
      expect(Qibla.normalize(0), 0);
      expect(Qibla.normalize(180), 180);
    });
  });

  group('turnFrom', () {
    test('takes the short way across north', () {
      expect(Qibla.turnFrom(headingDegrees: 350, qiblaDegrees: 10), 20);
      expect(Qibla.turnFrom(headingDegrees: 10, qiblaDegrees: 350), -20);
    });

    test('half a circle reads as +180', () {
      expect(Qibla.turnFrom(headingDegrees: 0, qiblaDegrees: 180), 180);
    });
  });

  group('heading from the sensors', () {
    // Phone flat, screen up, [x, y, z] in device axes: x right, y up the
    // screen, z out of the glass. Gravity reads +z on Android (the device
    // pushes *up* against being pulled down).
    const List<double> flat = <double>[0, 0, 9.81];

    test('flat and pointing north reads 0°', () {
      expect(Qibla.heading(magnetometer: <double>[0, 40, 0], accelerometer: flat),
          closeTo(0, 0.001));
    });

    test('flat and pointing east reads 90°', () {
      // North now lies along the phone's left edge: field on −x.
      expect(Qibla.heading(magnetometer: <double>[-40, 0, 0], accelerometer: flat),
          closeTo(90, 0.001));
    });

    test('flat and pointing south reads 180°', () {
      expect(Qibla.heading(magnetometer: <double>[0, -40, 0], accelerometer: flat),
          closeTo(180, 0.001));
    });

    test('flat and pointing west reads 270°', () {
      expect(Qibla.heading(magnetometer: <double>[40, 0, 0], accelerometer: flat),
          closeTo(270, 0.001));
    });

    test('a 30° pitch does not move a north reading', () {
      // Phone tilted top-up by 30°: gravity gains a +y component, and the
      // north field vector tips into −z by the same angle. Both go through
      // the same compensation, so a compass held *up* in a mosque still
      // reads what it read on the table.
      const double t = math.pi / 6;
      final List<double> gravity = <double>[0, math.sin(t) * 9.81, math.cos(t) * 9.81];
      final List<double> north = <double>[0, math.cos(t) * 40, -math.sin(t) * 40];
      expect(Qibla.heading(magnetometer: north, accelerometer: gravity),
          closeTo(0, 0.01));
    });

    test('unusable readings answer nothing rather than nonsense', () {
      expect(
        Qibla.heading(magnetometer: <double>[0, 1, 0], accelerometer: <double>[0, 0, 0]),
        isNull,
      );
      expect(
        Qibla.heading(magnetometer: <double>[0, 1], accelerometer: flat),
        isNull,
      );
      expect(
        Qibla.heading(
            magnetometer: <double>[double.nan, 1, 0], accelerometer: flat),
        isNull,
      );
    });
  });

  group('smoothing', () {
    test('steps a fraction of the short way', () {
      expect(Qibla.smooth(0, 10, factor: 0.5), closeTo(5, 0.001));
    });

    test('crosses north the short way, not round the long way', () {
      // 359 → 1 is two degrees apart; a naive average would walk 180°
      // round the wrong side of the dial.
      expect(Qibla.smooth(359, 1, factor: 0.5), closeTo(0, 0.001));
    });

    test('a first reading is taken as given', () {
      expect(Qibla.smooth(double.nan, 123), 123);
    });
  });
}
