// Verifies lib/prayer_readings.dart against live Quran.com data.
//
// The Arabic is compared byte for byte (Quran.com's exact Uthmani codepoints,
// diacritic order included). The three renderings are compared as
// letter-and-digit sequences, so casing, punctuation, spacing and line joins
// between two ayat do not count as drift — only a changed word does.
//
// `knownDeviations` lists the handful of deliberate fixes for obvious glitches
// in the Quran.com source itself (an OCR-split word, a missing letter), so the
// test stays green without pretending those are verbatim.
//
// Needs the network. If it fails offline, that is all it means.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/prayer_readings.dart';

/// `source · field` pairs that knowingly differ from Quran.com, with the
/// reason. Everything else must match.
const Map<String, String> knownDeviations = <String, String>{
  'Quran 4:103 · urdu':
      'quran.com splits "نماز" as "نما ز" — joined back',
  'Quran 2:238 · urdu': 'quran.com has "ہوتےہیں" — spaced',
  'Quran 3:41 · urdu': 'quran.com runs "دے۔کہا" together — spaced',
  'Quran 29:45 · urdu':
      'quran.com runs "(اے نبی ؐ)تلاوت" together and drops the final full '
      'stop — spaced and closed',
  'Quran 31:17 · urdu': 'quran.com spaces before commas — tidied',
  'Quran 24:36 · urdu': 'quran.com runs ")اُن" together — spaced',
  'Quran 23:1-2 · urdu': 'quran.com reads "کرتے ہوں" — "کرتے ہیں"',
  'Quran 23:1-2 · roman': 'quran.com reads "karte hai" — "karte hain"',
  'Quran 70:22-23 · roman': 'quran.com reads "karte hai" — "karte hain"',
  'Quran 20:130 · urdu':
      'quran.com writes "جاوٴ" and runs "اپنےربّ" — "جاؤں", spaced',
  'Quran 3:190-191 · urdu':
      'quran.com has "نشانیا ں", "کےلیے", "بچالے" — rejoined',
};

String clean(Object? s) => (s ?? '')
    .toString()
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .replaceAll(RegExp(r'\d+'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

bool _keep(int unit) {
  if (unit >= 0x30 && unit <= 0x39) return true; // 0-9
  if (unit >= 0x61 && unit <= 0x7a) return true; // a-z
  // Arabic script: letters, vowel marks, Urdu additions — but not the
  // Arabic punctuation (، ; ؟ ؎ ؏ ؐ … ة ء are letters, ۔ ء delimiters).
  if (unit >= 0x0621 && unit <= 0x064a) return true; // letters
  if (unit >= 0x064b && unit <= 0x065f) return true; // harakat
  if (unit >= 0x0660 && unit <= 0x06ff) {
    // Arabic-Indic digits, letters, Urdu additions — but not the full stop
    // (U+06D4) or the end-of-ayah sign (U+06DD), which are not letters.
    return unit != 0x06d4 && unit != 0x06dd;
  }
  if (unit >= 0x0750 && unit <= 0x077f) return true; // Arabic Supplement
  if (unit >= 0xfb50 && unit <= 0xfdff) return true; // Presentation Forms A
  if (unit >= 0xfe70 && unit <= 0xfeff) return true; // Presentation Forms B
  return false;
}

/// Words only: every character that is not a Latin or Arabic letter or digit
/// is dropped, and case is folded. Whitespace and punctuation then cannot
/// fail the comparison; a different word still does.
String wording(String s) {
  final StringBuffer out = StringBuffer();
  for (final int unit in s.toLowerCase().runes) {
    if (_keep(unit)) out.writeCharCode(unit);
  }
  return out.toString();
}

Future<Map<String, String>> fetchKey(String key) async {
  final Uri uri = Uri.parse(
      'https://api.quran.com/api/v4/verses/by_key/$key'
      '?fields=text_uthmani&translations=20,97,831&language=en');
  final HttpClient client = HttpClient();
  final HttpClientRequest req = await client.getUrl(uri);
  final HttpClientResponse res = await req.close();
  final String body = await res.transform(utf8.decoder).join();
  client.close(force: true);
  final Map<String, dynamic> j = jsonDecode(body) as Map<String, dynamic>;
  final dynamic v = j['verse'];
  final List<dynamic> trs = v['translations'] as List<dynamic>;
  return <String, String>{
    'arabic': clean(v['text_uthmani']),
    'english': clean(trs[0]['text']),
    'urdu': clean(trs[1]['text']),
    'roman': clean(trs[2]['text']),
  };
}

String field(PrayerReading r, String name) {
  switch (name) {
    case 'arabic':
      return r.arabic;
    case 'english':
      return r.english;
    case 'urdu':
      return r.urdu;
    default:
      return r.roman;
  }
}

void main() {
  test('every Quran reading matches Quran.com', () async {
    final List<PrayerReading> quran = kReadingsByPrayer.values
        .expand((List<PrayerReading> p) => p)
        .where((PrayerReading r) => r.kind == ReadingKind.quran)
        .toList();

    final List<String> failures = <String>[];

    for (final PrayerReading reading in quran) {
      final RegExpMatch m =
          RegExp(r'^Quran (\d+):(\d+)(?:-(\d+))?$').firstMatch(reading.source)!;
      final String chapter = m.group(1)!;
      final int from = int.parse(m.group(2)!);
      final int to = int.parse(m.group(3) ?? m.group(2)!);

      final Map<String, List<String>> exp = <String, List<String>>{
        'arabic': <String>[],
        'english': <String>[],
        'urdu': <String>[],
        'roman': <String>[],
      };
      for (int i = from; i <= to; i++) {
        final Map<String, String> v = await fetchKey('$chapter:$i');
        exp.forEach((String k, List<String> list) => list.add(v[k]!));
      }

      exp.forEach((String name, List<String> parts) {
        final String expected = parts.join(' ');
        final String actual = field(reading, name);
        final String key = '${reading.source} · $name';
        final bool same = name == 'arabic'
            ? expected == actual
            : wording(expected) == wording(actual);
        if (!same && !knownDeviations.containsKey(key)) {
          failures.add('$key\n'
              '  file: $actual\n'
              '  api : $expected');
        }
      });
    }

    expect(failures, isEmpty,
        reason: 'Differences vs Quran.com:\n${failures.join('\n')}');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('every declared deviation still points at a real reading', () {
    final Set<String> keys = <String>{
      for (final List<PrayerReading> pool in kReadingsByPrayer.values)
        for (final PrayerReading r in pool)
          if (r.kind == ReadingKind.quran)
            for (final String f in <String>[
              'arabic',
              'english',
              'urdu',
              'roman',
            ])
              '${r.source} · $f',
    };
    for (final String key in knownDeviations.keys) {
      expect(keys, contains(key), reason: 'stale entry: $key');
    }
  });
}
