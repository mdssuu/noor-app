import 'dart:math' as math;

/// Everything the Qibla compass needs to turn a phone's sensors and a
/// location into "turn a little more to your right".
///
/// The maths lives apart from the screen on purpose: bearings are the kind of
/// number that is silently wrong for months if nobody can unit-test it. Two
/// published references anchor the tests — New York 58.48° and London
/// 118.99°, the two most widely quoted Qibla bearings in the world — so a
/// formula change that drifts cannot slip through.
class Qibla {
  Qibla._();

  /// The Kaaba, the one point every bearing in this file aims at.
  static const double kaabaLatitude = 21.4225;
  static const double kaabaLongitude = 39.8262;

  /// Compass bearings are 0…360 with 0 at north, and every subtraction in
  /// this file can walk off either end of that circle. Folding here keeps
  /// the answers canonical: `normalize(370) == 10`, `normalize(-10) == 350`.
  static double normalize(double degrees) {
    final double wrapped = degrees % 360.0;
    return wrapped < 0 ? wrapped + 360.0 : wrapped;
  }

  /// The compass direction, from [latitude]/[longitude], that points at the
  /// Kaaba — the *initial* great-circle bearing, which is what a compass
  /// shows and what every qibla finder in every app quotes.
  ///
  /// The spherical law of cosines form is used rather than a planar
  /// approximation: at India's longitude the flat-earth shortcut is off by
  /// whole degrees, and "off by a degree" on a qibla is a user turning the
  /// wrong way in a mosque.
  static double bearing(double latitude, double longitude) {
    final double phi1 = _rad(latitude);
    final double phi2 = _rad(kaabaLatitude);
    final double delta = _rad(kaabaLongitude - longitude);

    final double y = math.sin(delta);
    final double x = math.cos(phi1) * math.tan(phi2) -
        math.sin(phi1) * math.cos(delta);
    return normalize(_deg(math.atan2(y, x)));
  }

  /// How far the phone is from Makkah, in kilometres — the number every
  /// qibla screen shows under the dial, and the one that tells a user in
  /// Mumbai whether their compass is roughly sane.
  static double distanceKm(double latitude, double longitude) {
    const double earthRadiusKm = 6371.0088;
    final double phi1 = _rad(latitude);
    final double phi2 = _rad(kaabaLatitude);
    final double dPhi = _rad(kaabaLatitude - latitude);
    final double dLambda = _rad(kaabaLongitude - longitude);

    final double a = math.sin(dPhi / 2) * math.sin(dPhi / 2) +
        math.cos(phi1) *
            math.cos(phi2) *
            math.sin(dLambda / 2) *
            math.sin(dLambda / 2);
    return earthRadiusKm * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  /// How far, and which way, the compass must turn from [headingDegrees] to
  /// face the Qibla: signed, −180…+180, so the dial takes the short way
  /// round and a "turn left" never animates the long way across the sky.
  static double turnFrom({
    required double headingDegrees,
    required double qiblaDegrees,
  }) {
    double diff = normalize(qiblaDegrees - headingDegrees);
    if (diff > 180.0) diff -= 360.0;
    return diff;
  }

  /// The device's compass heading from raw sensor readings.
  ///
  /// [magnetometer] is the Earth's field in device coordinates (x right, y
  /// up the screen, z out of it); [accelerometer] is gravity measured the
  /// same way. With the phone flat the answer is simply `atan2(-mx, my)`,
  /// but a phone held upright — the natural way to hold one up in a mosque —
  /// reads the field's *vertical* component too, which tilts the heading by
  /// tens of degrees. The accelerometer's gravity vector undoes that: the
  /// field is rotated into the horizontal plane before the angle is taken.
  ///
  /// Returns `null` when the readings are unusable (a zero accelerometer
  /// vector, or numbers that are not finite), because a compass that shows
  /// a confident wrong number is worse than one that says nothing.
  static double? heading({
    required List<double> magnetometer,
    required List<double> accelerometer,
  }) {
    if (magnetometer.length < 3 || accelerometer.length < 3) return null;
    final double mx = magnetometer[0];
    final double my = magnetometer[1];
    final double mz = magnetometer[2];
    final double ax = accelerometer[0];
    final double ay = accelerometer[1];
    final double az = accelerometer[2];
    if (!mx.isFinite || !my.isFinite || !mz.isFinite) return null;
    if (!ax.isFinite || !ay.isFinite || !az.isFinite) return null;

    final double norm = math.sqrt(ax * ax + ay * ay + az * az);
    if (norm < 1e-6) return null;

    // Pitch and roll from gravity. `asin` of a normalised component is only
    // defined for |v| ≤ 1, and float noise can push it to 1.0000001 — hence
    // the clamp rather than a try/catch around a NaN.
    final double pitch = math.asin((-ax / norm).clamp(-1.0, 1.0));
    final double roll = math.asin((ay / norm).clamp(-1.0, 1.0));

    // Rotate the field into the horizontal plane (tilt compensation).
    final double xh = mx * math.cos(pitch) +
        my * math.sin(roll) * math.sin(pitch) +
        mz * math.cos(roll) * math.sin(pitch);
    final double yh = my * math.cos(roll) - mz * math.sin(roll);

    if (xh == 0 && yh == 0) return null;
    // The heading of the *top edge* of the phone, clockwise from north.
    // With the phone flat and its top pointing north, the field lies along
    // +Y, so the angle is `atan2(-xh, yh)`: 0° for +Y (north), 90° for
    // −X (east — north now along the phone's left edge), and so round.
    return normalize(_deg(math.atan2(-xh, yh)));
  }

  /// One-sided low-pass over successive headings.
  ///
  /// A magnetometer is noisy and a human hand is worse; without smoothing the
  /// dial twitches with every tremor. Circular interpolation is used rather
  /// than plain arithmetic so a heading oscillating across 0°/360° — the
  /// north line, which is exactly where a qibla user spends their time —
  /// averages to 359.9° rather than to 180°.
  static double smooth(double previous, double next, {double factor = 0.18}) {
    if (!previous.isFinite) return next;
    // Step `factor` of the *shortest* way round: a raw `next - previous`
    // across the north line would march the dial the long way round the
    // whole circle, and north is exactly where a qibla user lives.
    final double delta = turnFrom(headingDegrees: previous, qiblaDegrees: next);
    return normalize(previous + factor * delta);
  }

  static double _rad(double degrees) => degrees * math.pi / 180.0;
  static double _deg(double radians) => radians * 180.0 / math.pi;
}
