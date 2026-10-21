import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

// =============================================================================
//  PROVIDER SWITCH  —  swap OSM for Google Places later by editing ONE place
// =============================================================================
//
// The whole app only ever calls two functions in this file:
//
//     searchMasjid(query, lat, lon)   -> universal search box
//     nearbyMasjids(lat, lon)         -> the "nearby" list on app open
//
// To move to Google Places later:
//   1. set [kPlacesProvider] to PlacesProvider.google
//   2. paste your key into [kGooglePlacesApiKey]
//   3. fill in the two `_google*` bodies at the bottom of this file
// No other file in the project needs to change.
//
enum PlacesProvider {
  /// Free. No key, no billing. Nominatim (text + area) + Overpass (radius).
  osm,

  /// Needs an `AIza...` key and the Places API enabled in Google Cloud.
  google,
}

const PlacesProvider kPlacesProvider = PlacesProvider.osm;

/// Only consulted when [kPlacesProvider] is [PlacesProvider.google].
/// Supply at build time with `--dart-define=PLACES_API_KEY=AIza...`.
const String kGooglePlacesApiKey = String.fromEnvironment(
  'PLACES_API_KEY',
  defaultValue: '',
);

/// Whether search is switched on. OSM is always on — no key required.
bool get kPlacesEnabled => switch (kPlacesProvider) {
      PlacesProvider.osm => true,
      PlacesProvider.google =>
        kGooglePlacesApiKey.startsWith('AIza'),
    };

const String kProviderLabel =
    kPlacesProvider == PlacesProvider.osm ? 'OpenStreetMap' : 'Google Places';

// =============================================================================
//  MODEL
// =============================================================================

/// One place found by [searchMasjid] or [nearbyMasjids].
class MasjidSearchResult {
  const MasjidSearchResult({
    required this.id,
    required this.name,
    required this.address,
    required this.latitude,
    required this.longitude,
    this.distanceMetres,
    this.source = 'osm',
  });

  final String id;
  final String name;
  final String address;
  final double latitude;
  final double longitude;

  /// Straight-line metres from the user's GPS fix, when known.
  final double? distanceMetres;

  /// `'osm'` or `'google'` — surfaced in the UI so contributions stay honest.
  final String source;

  bool get isMosque {
    final String s = name.toLowerCase();
    return s.contains('masjid') || s.contains('mosque') || s.contains('mosk');
  }

  MasjidSearchResult withDistance(double metres) => MasjidSearchResult(
        id: id,
        name: name,
        address: address,
        latitude: latitude,
        longitude: longitude,
        distanceMetres: metres,
        source: source,
      );
}

// =============================================================================
//  ENDPOINTS
// =============================================================================

const String _nominatimBase = 'https://nominatim.openstreetmap.org';
const String _overpassPrimary = 'https://overpass-api.de/api/interpreter';
const String _overpassBackup = 'https://overpass.kumi.systems/api/interpreter';

/// Nominatim's usage policy allows at most one request per second per client.
const Duration _nominatimMinInterval = Duration(milliseconds: 1000);
DateTime _lastNominatimCall = DateTime.fromMillisecondsSinceEpoch(0);
Future<void> _nominatimGate = Future<void>.value();

final http.Client _client = http.Client();

const Map<String, String> _headers = <String, String>{
  // Nominatim rejects requests without a UA identifying the app.
  'User-Agent': 'NoorMasjidTimeApp/1.0 (Masjid Jamaat Times)',
  'Accept': 'application/json',
};

/// Serialises Nominatim hits so we never trip the 1 req/s ban.
Future<void> _throttleNominatim() {
  final Future<void> next = _nominatimGate.then((_) async {
    final Duration waited = DateTime.now().difference(_lastNominatimCall);
    if (waited < _nominatimMinInterval) {
      await Future<void>.delayed(_nominatimMinInterval - waited);
    }
    _lastNominatimCall = DateTime.now();
  });
  _nominatimGate = next.catchError((_) {});
  return next;
}

// =============================================================================
//  1. UNIVERSAL SEARCH
// =============================================================================

/// Free text search across OpenStreetMap.
///
/// `query` is what the user typed ("Kurla"), `lat`/`lon` are their GPS fix and
/// are used purely as a bias so results near them rank first.
///
/// Never throws: a network failure, rate limit or bad JSON all yield `[]`.
Future<List<MasjidSearchResult>> searchMasjid({
  required String query,
  double? lat,
  double? lon,
  int limit = 10,
}) async {
  final String text = query.trim();
  if (text.length < 2) return const <MasjidSearchResult>[];
  if (!kPlacesEnabled) return const <MasjidSearchResult>[];

  return kPlacesProvider == PlacesProvider.osm
      ? _osmSearch(text, lat: lat, lon: lon, limit: limit)
      : _googleSearch(text, lat: lat, lon: lon, limit: limit);
}

/// Locality lookup for Settings → "Change City Manually".
///
/// Same free Nominatim endpoint as [searchMasjid], minus the " masjid" hint —
/// asking Nominatim for "Mumbai masjid" would rank buildings, not the city.
Future<List<MasjidSearchResult>> searchCity(String query, {int limit = 6}) async {
  final String text = query.trim();
  if (text.length < 2 || !kPlacesEnabled) return const <MasjidSearchResult>[];

  try {
    await _throttleNominatim();

    final Uri uri = Uri.parse('$_nominatimBase/search').replace(queryParameters: <String, String>{
      'q': text,
      'format': 'json',
      'addressdetails': '1',
      'dedupe': '1',
      'limit': '$limit',
      'countrycodes': 'in',
      'accept-language': 'en',
    });

    debugPrint('Searching OSM city for: $text');
    final http.Response res =
        await _client.get(uri, headers: _headers).timeout(const Duration(seconds: 10));
    debugPrint('OSM Response: HTTP ${res.statusCode} '
        '${res.body.length > 400 ? '${res.body.substring(0, 400)}…' : res.body}');
    if (res.statusCode != 200) return const <MasjidSearchResult>[];

    final List<dynamic> json = jsonDecode(utf8.decode(res.bodyBytes)) as List<dynamic>;
    return json
        .map((dynamic raw) => parseNominatimResult(raw, lat: null, lon: null))
        .whereType<MasjidSearchResult>()
        .toList();
  } catch (error) {
    debugPrint('OSM city search failed: $error');
    return const <MasjidSearchResult>[];
  }
}

// =============================================================================
//  2. NEARBY MASJIDS
// =============================================================================

/// Mosques around a GPS fix, sorted nearest-first and clipped to [radiusMetres].
///
/// Runs Nominatim (per spec: `q=masjid&lat=&lon=`) and Overpass (a true radius
/// query) at the same time and merges them — Overpass is precise, Nominatim
/// catches things Overpass has not mapped. Either can fail alone without
/// losing the other.
Future<List<MasjidSearchResult>> nearbyMasjids({
  required double lat,
  required double lon,
  double radiusMetres = 10000,
  int limit = 20,
}) async {
  if (!kPlacesEnabled) return const <MasjidSearchResult>[];
  if (lat == 0 && lon == 0) return const <MasjidSearchResult>[];

  final List<List<MasjidSearchResult>> batches = await Future.wait(
    <Future<List<MasjidSearchResult>>>[
      if (kPlacesProvider == PlacesProvider.osm) ...<Future<List<MasjidSearchResult>>>[
        // Nominatim gives a near-centred text result (spec URL);
        _nominatimNearby(lat: lat, lon: lon, radiusMetres: radiusMetres),
        // Overpass gives the true radius query Nominatim cannot express.
        _overpassNearby(lat: lat, lon: lon, radiusMetres: radiusMetres),
      ] else
        _googleSearch('mosque', lat: lat, lon: lon, limit: limit),
    ],
  );

  final Map<String, MasjidSearchResult> merged = <String, MasjidSearchResult>{};
  for (final List<MasjidSearchResult> batch in batches) {
    for (final MasjidSearchResult r in batch) {
      final double d = Geolocator.distanceBetween(lat, lon, r.latitude, r.longitude);
      if (d > radiusMetres) continue;
      // Two providers describe the same building — keep the closer match.
      final String key = '${r.latitude.toStringAsFixed(4)},${r.longitude.toStringAsFixed(4)}';
      final MasjidSearchResult? existing = merged[key];
      if (existing != null && (existing.distanceMetres ?? double.infinity) <= d) continue;
      merged[key] = r.withDistance(d);
    }
  }

  final List<MasjidSearchResult> out = merged.values.toList();
  out.sort((MasjidSearchResult a, MasjidSearchResult b) =>
      (a.distanceMetres ?? double.infinity).compareTo(b.distanceMetres ?? double.infinity));
  return out.take(limit).toList();
}

// =============================================================================
//  OSM implementation
// =============================================================================

/// Nominatim text search. Adds a mosque hint so an area-only query still
/// surfaces masjids instead of the locality itself.
Future<List<MasjidSearchResult>> _osmSearch(
  String query, {
  double? lat,
  double? lon,
  required int limit,
}) async {
  try {
    await _throttleNominatim();

    final Uri uri = Uri.parse('$_nominatimBase/search').replace(queryParameters: <String, String>{
      'q': _withMosqueHint(query),
      'format': 'json',
      'addressdetails': '1',
      'dedupe': '1',
      'limit': '$limit',
      'countrycodes': 'in',
      'accept-language': 'en',
      if (lat != null && lon != null) ...<String, String>{
        'lat': lat.toStringAsFixed(6),
        'lon': lon.toStringAsFixed(6),
        'viewbox': _viewbox(lat, lon, 25000),
        // Bias, don't restrict — a user searching a distant city still works.
        'bounded': '0',
      },
    });

    debugPrint('Searching OSM for: ${_withMosqueHint(query)}');
    debugPrint('OSM URL: $uri');

    final http.Response res =
        await _client.get(uri, headers: _headers).timeout(const Duration(seconds: 10));
    debugPrint('OSM Response: HTTP ${res.statusCode} '
        '${res.body.length > 400 ? '${res.body.substring(0, 400)}…' : res.body}');
    if (res.statusCode != 200) return const <MasjidSearchResult>[];

    final List<dynamic> json = jsonDecode(utf8.decode(res.bodyBytes)) as List<dynamic>;
    final List<MasjidSearchResult> out = <MasjidSearchResult>[];
    for (final dynamic raw in json) {
      final MasjidSearchResult? r = parseNominatimResult(raw, lat: lat, lon: lon);
      if (r != null) out.add(r);
    }
    // "HTTP 200 but nothing usable" used to be invisible — log the gap so a
    // shape change upstream shows up as a number instead of an empty list.
    debugPrint('OSM parsed ${out.length}/${json.length} row(s)');

    // Rank actual mosques above anything Nominatim matched by accident.
    out.sort((MasjidSearchResult a, MasjidSearchResult b) {
      final int byKind = (b.isMosque ? 1 : 0).compareTo(a.isMosque ? 1 : 0);
      if (byKind != 0) return byKind;
      return (a.distanceMetres ?? 0).compareTo(b.distanceMetres ?? 0);
    });
    return out;
  } catch (error) {
    debugPrint('OSM search failed: $error');
    return const <MasjidSearchResult>[];
  }
}

/// Nominatim "nearby" call — the URL shape from the spec plus a `viewbox`
/// bias, because Nominatim has no true radius endpoint.
Future<List<MasjidSearchResult>> _nominatimNearby({
  required double lat,
  required double lon,
  required double radiusMetres,
}) async {
  try {
    await _throttleNominatim();

    final Uri uri = Uri.parse('$_nominatimBase/search').replace(queryParameters: <String, String>{
      'q': 'masjid',
      'format': 'json',
      'addressdetails': '1',
      'limit': '20',
      'countrycodes': 'in',
      'accept-language': 'en',
      'lat': lat.toStringAsFixed(6),
      'lon': lon.toStringAsFixed(6),
      'viewbox': _viewbox(lat, lon, radiusMetres * 1.4),
      'bounded': '0',
    });

    debugPrint('OSM nearby URL: $uri');
    final http.Response res =
        await _client.get(uri, headers: _headers).timeout(const Duration(seconds: 10));
    debugPrint('OSM nearby: HTTP ${res.statusCode}, ${res.body.length} bytes');
    if (res.statusCode != 200) return const <MasjidSearchResult>[];

    final List<dynamic> json = jsonDecode(utf8.decode(res.bodyBytes)) as List<dynamic>;
    final List<MasjidSearchResult> out = json
        .map((dynamic raw) => parseNominatimResult(raw, lat: lat, lon: lon))
        .whereType<MasjidSearchResult>()
        .toList();
    debugPrint('OSM nearby parsed ${out.length}/${json.length} row(s)');
    return out;
  } catch (error) {
    debugPrint('OSM nearby search failed: $error');
    return const <MasjidSearchResult>[];
  }
}

/// Overpass gives an exact radius query, which Nominatim cannot do.
Future<List<MasjidSearchResult>> _overpassNearby({
  required double lat,
  required double lon,
  required double radiusMetres,
}) async {
  final int radius = radiusMetres.round();
  final String around = 'around:$radius,$lat,$lon';

  // amenity=mosque is the explicit tag; place_of_worship+muslim catches the
  // ones mappers tagged loosely.
  final String q = '''
[out:json][timeout:25];
(
  node["amenity"="mosque"]($around);
  way["amenity"="mosque"]($around);
  relation["amenity"="mosque"]($around);
  node["amenity"="place_of_worship"]["religion"="muslim"]($around);
  way["amenity"="place_of_worship"]["religion"="muslim"]($around);
  relation["amenity"="place_of_worship"]["religion"="muslim"]($around);
);
out center 60;''';

  for (final String host in <String>[_overpassPrimary, _overpassBackup]) {
    try {
      final http.Response res = await _client
          .post(
            Uri.parse(host),
            headers: <String, String>{
              'User-Agent': 'NoorApp/1.0 (Masjid Jamaat Times)',
              'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
            },
            body: <String, String>{'data': q},
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) continue;

      final Map<String, dynamic> json =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final List<dynamic> elements = json['elements'] as List<dynamic>? ?? <dynamic>[];

      final List<MasjidSearchResult> out = <MasjidSearchResult>[];
      for (final dynamic raw in elements) {
        final Map<String, dynamic> el = raw as Map<String, dynamic>;
        final Map<String, dynamic>? center = el['center'] as Map<String, dynamic>?;
        final double? dLat =
            (el['lat'] as num?)?.toDouble() ?? (center?['lat'] as num?)?.toDouble();
        final double? dLon =
            (el['lon'] as num?)?.toDouble() ?? (center?['lon'] as num?)?.toDouble();
        if (dLat == null || dLon == null) continue;

        final Map<String, dynamic> tags =
            el['tags'] as Map<String, dynamic>? ?? <String, dynamic>{};
        final String name =
            ((tags['name'] as String?) ?? (tags['name:en'] as String?) ?? '').trim();
        if (name.isEmpty) continue;

        out.add(MasjidSearchResult(
          id: 'osm-${el['type']}-${el['id']}',
          name: name,
          address: _overpassAddress(tags),
          latitude: dLat,
          longitude: dLon,
        ));
      }
      return out;
    } catch (_) {
      // Try the backup host.
    }
  }
  return const <MasjidSearchResult>[];
}

// =============================================================================
//  Shared parsing helpers
// =============================================================================

/// Nominatim hands back strings, Overpass hands back numbers, and Firestore
/// hands back whatever a mobile client wrote — accept all three rather than
/// throwing away a perfectly good result.
double? _asDouble(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

MasjidSearchResult? parseNominatimResult(
  dynamic raw, {
  double? lat,
  double? lon,
}) {
  if (raw is! Map<String, dynamic>) return null;

  // Nominatim quotes its coordinates — `"lat":"18.9535986"` — so a `as num?`
  // cast throws a TypeError on every single row. That used to escape to the
  // caller's blanket catch and hand back an empty list, which is how "OSM
  // returned HTTP 200 with six results" became "0 mosques found".
  final double? dLat = _asDouble(raw['lat']);
  final double? dLon = _asDouble(raw['lon']);
  if (dLat == null || dLon == null) return null;

  // Everything below is read with `is`/`toString` rather than `as String`: one
  // bad type in one field used to blow up the whole row (and, via the caller's
  // blanket catch, the entire result list).
  final String display = _asText(raw['display_name']);
  final String name = _asText(raw['name']);
  final String first = display.isEmpty ? '' : display.split(',').first.trim();

  final String title = name.isNotEmpty ? name : first;
  if (title.isEmpty) return null;

  final dynamic address = raw['address'];
  final Map<String, dynamic>? addr =
      address is Map ? Map<String, dynamic>.from(address) : null;
  String subtitle = _shortAddress(addr);
  if (subtitle.isEmpty || subtitle.toLowerCase() == title.toLowerCase()) {
    subtitle = display;
  }

  return MasjidSearchResult(
    id: 'osm-nominatim-${raw['place_id'] ?? raw['osm_id'] ?? title}',
    name: title,
    address: subtitle,
    latitude: dLat,
    longitude: dLon,
    distanceMetres: (lat != null && lon != null)
        ? Geolocator.distanceBetween(lat, lon, dLat, dLon)
        : null,
  );
}

/// Keeps the locality line short: "Bandra West, Mumbai, Maharashtra".
String _shortAddress(Map<String, dynamic>? addr) {
  if (addr == null) return '';
  const List<String> keep = <String>[
    'suburb',
    'quarter',
    'neighbourhood',
    'city_district',
    'town',
    'village',
    'city',
    'county',
    'state',
  ];
  final List<String> parts = <String>[];
  for (final String key in keep) {
    final String value = _clean(addr[key] as String? ?? '');
    if (value.isEmpty) continue;
    if (!parts.contains(value)) parts.add(value);
  }
  return parts.take(3).join(', ');
}

String _overpassAddress(Map<String, dynamic> tags) {
  final List<String> parts = <String>[];
  for (final String key in <String>[
    'addr:street',
    'addr:suburb',
    'addr:city',
    'addr:state',
    'addr:postcode',
  ]) {
    final String value = _clean(tags[key] as String? ?? '');
    if (value.isNotEmpty && !parts.contains(value)) parts.add(value);
  }
  return parts.join(', ');
}

/// Never returns null — callers just check `.isEmpty`.
/// Never let one odd JSON type cost us a whole result row: read whatever the
/// payload held as text instead of casting and throwing.
String _asText(dynamic value) {
  if (value == null) return '';
  if (value is String) return _clean(value);
  return _clean(value.toString());
}

String _clean(String value) => value.trim();

/// "Kurla" -> "Kurla masjid" so an area-only query still returns mosques.
String _withMosqueHint(String query) {
  final String lower = query.toLowerCase();
  const List<String> keywords = <String>['masjid', 'mosque', 'mosk', 'musjid'];
  final bool already = keywords.any(lower.contains);
  return already ? query : '$query masjid';
}

/// `left,top,right,bottom` box centred on a point.
String _viewbox(double lat, double lon, double radiusMetres) {
  final double dLat = radiusMetres / 111320.0;
  final double dLon = radiusMetres / math.max(111320.0 * math.cos(lat * math.pi / 180), 1000);
  return [
    (lon - dLon).toStringAsFixed(6),
    (lat + dLat).toStringAsFixed(6),
    (lon + dLon).toStringAsFixed(6),
    (lat - dLat).toStringAsFixed(6),
  ].join(',');
}

// =============================================================================
//  GOOGLE implementation (dormant — flip kPlacesProvider to activate)
// =============================================================================

Future<List<MasjidSearchResult>> _googleSearch(
  String query, {
  double? lat,
  double? lon,
  required int limit,
}) async {
  try {
    final Uri uri = Uri.parse('https://places.googleapis.com/v1/places:autocomplete');
    final http.Response res = await _client
        .post(
          uri,
          headers: <String, String>{
            'Content-Type': 'application/json',
            'X-Goog-Api-Key': kGooglePlacesApiKey,
            'X-Goog-FieldMask':
                'suggestions.placePrediction.placeId,'
                'suggestions.placePrediction.structuredFormat.mainText.text,'
                'suggestions.placePrediction.structuredFormat.secondaryText.text',
          },
          body: jsonEncode(<String, dynamic>{
            'input': query,
            'sessionToken': 'noor',
            'languageCode': 'en',
            if (lat != null && lon != null)
              'locationBias': <String, dynamic>{
                'circle': <String, dynamic>{
                  'center': <String, dynamic>{'latitude': lat, 'longitude': lon},
                  'radius': 50000.0,
                },
              },
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return const <MasjidSearchResult>[];

    final Map<String, dynamic> body = jsonDecode(res.body) as Map<String, dynamic>;
    final List<dynamic> suggestions = body['suggestions'] as List<dynamic>? ?? <dynamic>[];

    final List<MasjidSearchResult> out = <MasjidSearchResult>[];
    for (final dynamic raw in suggestions) {
      final Map<String, dynamic>? prediction =
          (raw as Map<String, dynamic>)['placePrediction'] as Map<String, dynamic>?;
      if (prediction == null) continue;

      final String placeId = (prediction['placeId'] as String?) ?? '';
      if (placeId.isEmpty) continue;

      final String main =
          ((prediction['structuredFormat'] as Map<String, dynamic>?)?['mainText']
                  as Map<String, dynamic>?)
              ?['text'] as String? ??
          '';
      final String secondary =
          ((prediction['structuredFormat'] as Map<String, dynamic>?)?['secondaryText']
                  as Map<String, dynamic>?)
              ?['text'] as String? ??
          '';

      // Google autocomplete gives no coordinates — the details round-trip is
      // what keeps every provider returning the same shape.
      final MasjidSearchResult? resolved = await _googleDetails(placeId, main, secondary);
      out.add(resolved ??
          MasjidSearchResult(
            id: placeId,
            name: main.isEmpty ? secondary : main,
            address: secondary,
            latitude: 0,
            longitude: 0,
            source: 'google',
          ));
      if (out.length >= limit) break;
    }
    return out;
  } catch (_) {
    return const <MasjidSearchResult>[];
  }
}

Future<MasjidSearchResult?> _googleDetails(
  String placeId,
  String fallbackName,
  String fallbackAddress,
) async {
  try {
    final http.Response res = await _client
        .get(
          Uri.parse('https://places.googleapis.com/v1/places/$placeId'),
          headers: <String, String>{
            'X-Goog-Api-Key': kGooglePlacesApiKey,
            'X-Goog-FieldMask': 'displayName,formattedAddress,location',
          },
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;

    final Map<String, dynamic> data = jsonDecode(res.body) as Map<String, dynamic>;
    final Map<String, dynamic>? location = data['location'] as Map<String, dynamic>?;
    if (location == null) return null;

    return MasjidSearchResult(
      id: placeId,
      name: (data['displayName'] as Map<String, dynamic>?)?['text'] as String? ?? fallbackName,
      address: (data['formattedAddress'] as String?) ?? fallbackAddress,
      latitude: (location['latitude'] as num).toDouble(),
      longitude: (location['longitude'] as num).toDouble(),
      source: 'google',
    );
  } catch (_) {
    return null;
  }
}
