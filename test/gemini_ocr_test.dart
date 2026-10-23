import 'dart:typed_data';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/services/gemini_ocr_service.dart';

/// The contract that matters most: a board showing two times per prayer must
/// yield the JAMAAT column, in 24-hour form, in day order.
void main() {
  group('Gemini board parsing', () {
    test('lifts a 12-hour Jamaat column into one ordered 24-hour day', () {
      // Exactly the readings on the board: Jamaat 5:50, 1:15, 5:40, 6:31,
      // 7:39 — afternoons printed without a PM marker.
      final GeminiOcrResult? result = GeminiOcrService.parseResponse('''
{"name":"RIZWAN MASJID","fajr":"05:50","dhuhr":"01:15","asr":"05:40","maghrib":"06:31","isha":"07:39"}
''');

      expect(result, isNotNull);
      expect(result!.masjidName, 'RIZWAN MASJID');
      expect(result.times['fajr'], '05:50');
      expect(result.times['dhuhr'], '13:15');
      expect(result.times['asr'], '17:40');
      expect(result.times['maghrib'], '18:31');
      expect(result.times['isha'], '19:39');
      expect(result.outOfOrder, isFalse);
    });

    test('leaves a board already written in 24-hour time untouched', () {
      final GeminiOcrResult? result = GeminiOcrService.parseResponse(
        '{"fajr":"05:50","dhuhr":"13:15","asr":"17:40","maghrib":"18:31","isha":"19:39"}',
      );

      expect(result, isNotNull);
      expect(result!.times['dhuhr'], '13:15');
      expect(result.times['maghrib'], '18:31');
      expect(result.outOfOrder, isFalse);
    });

    test('does not lift anything when the readings are already ordered', () {
      // A board that genuinely prints a late-morning Dhuhr.
      final GeminiOcrResult? result = GeminiOcrService.parseResponse(
        '{"fajr":"05:17","dhuhr":"11:45","asr":"15:30","maghrib":"18:39","isha":"19:56"}',
      );

      expect(result, isNotNull);
      expect(result!.times['dhuhr'], '11:45');
      expect(result.outOfOrder, isFalse);
    });

    test('flags a column mix-up that no amount of lifting can repair', () {
      // Asr later than its Maghrib: a label paired with the wrong clock.
      final GeminiOcrResult? result = GeminiOcrService.parseResponse(
        '{"fajr":"05:17","dhuhr":"13:39","asr":"17:50","maghrib":"16:47","isha":"21:28"}',
      );

      expect(result, isNotNull);
      expect(result!.times['maghrib'], '16:47');
      expect(result.outOfOrder, isTrue);
    });

    test('accepts the common alternate spellings for each prayer', () {
      final GeminiOcrResult? result = GeminiOcrService.parseResponse(
        '{"Fajar":"05:50","Zohar":"01:15","Asar":"05:40","Magrib":"06:31","Ishaa":"07:39"}',
      );

      expect(result, isNotNull);
      expect(result!.times.keys.toSet(), <String>{'fajr', 'dhuhr', 'asr', 'maghrib', 'isha'});
      expect(result.times['dhuhr'], '13:15');
      expect(result.times['isha'], '19:39');
    });

    test('reads a colon-less clock and a model that ignores JSON mode', () {
      final GeminiOcrResult? result = GeminiOcrService.parseResponse(
        'Sure! Here are the times:\n'
        '```json\n'
        '{"fajr":"0550","dhuhr":"1315","asr":"1740","maghrib":"1831","isha":"1939"}\n'
        '```',
      );

      expect(result, isNotNull);
      expect(result!.times['fajr'], '05:50');
      expect(result.times['isha'], '19:39');
      expect(result.outOfOrder, isFalse);
    });

    test('returns nothing for a response that is not a board at all', () {
      expect(GeminiOcrService.parseResponse('I cannot read this image.'), isNull);
      expect(GeminiOcrService.parseResponse('{"note":"no times here"}'), isNull);
    });
  });

  group('key handling', () {
    test('is not configured before .env is loaded', () {
      // `dotenv.env` throws when uninitialised; the service must treat that
      // as "no Gemini" rather than crashing at boot or mid-scan.
      expect(GeminiOcrService.isConfigured, isFalse);
    });

    test('degrades to null instead of throwing when there is no key', () async {
      final GeminiOcrResult? result =
          await GeminiOcrService.extractJamaatTimes(Uint8List.fromList(<int>[0xff, 0xd8]));

      expect(result, isNull);

      // ...and says why. A fallback nobody can see is the bug: the scan keeps
      // going with the weaker on-device reader and looks like the AI simply
      // read the board wrong. The review screen surfaces this.
      expect(GeminiOcrService.lastFailureReason, isNotNull);
      expect(GeminiOcrService.lastFailureReason, isNotEmpty);
    });

    test('reads GEMINI_API_KEY out of .env', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      try {
        await dotenv.load();
      } catch (_) {
        // No .env in this checkout — the key is git-ignored, so a fresh clone
        // legitimately has none. Nothing to assert.
        return;
      }

      // Proves both halves of the wiring: flutter_dotenv parsed the file and
      // the service found a real key in it rather than the placeholder.
      expect(GeminiOcrService.isConfigured, isTrue);
    });
  });
}
