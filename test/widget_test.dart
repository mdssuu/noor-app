import 'package:flutter_test/flutter_test.dart';

import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/main.dart';

void main() {
  group('MasjidOcrParser', () {
    test('reads a typical masjid prayer board', () {
      const String board = '''
MASJID AL-FALAH
PRAYER TIMINGS
FAJR   05:15 AM
ZUHR   12:45 PM
ASAR   04:30 PM
MAGHRIB 06:50 PM
ISHA   08:15 PM
JUMA   13:30
''';

      final OcrResult result = MasjidOcrParser.parse(board);

      expect(result.times['fajr'], '05:15');
      expect(result.times['dhuhr'], '12:45');
      expect(result.times['asr'], '16:30');
      expect(result.times['maghrib'], '18:50');
      expect(result.times['isha'], '20:15');
      expect(result.times['juma'], '13:30');
      expect(result.masjidName, 'MASJID AL-FALAH');
    });

    test('handles alternate spellings and dot separators', () {
      const String board = '''
FAJAR 5.15
ZOHAR 1.05 PM
ASR 4.40
MAGRIB 6.45 pm
ESHA 8.05
JUMMA 1.30
''';

      final OcrResult result = MasjidOcrParser.parse(board);

      expect(result.times['fajr'], '05:15');
      expect(result.times['dhuhr'], '13:05');
      expect(result.times['asr'], '16:40');
      expect(result.times['maghrib'], '18:45');
      expect(result.times['isha'], '20:05');
      expect(result.times['juma'], '13:30');
    });

    test('returns no name when the board has no masjid header', () {
      final OcrResult result = MasjidOcrParser.parse('FAJR 05:15\nISHA 20:15');
      expect(result.nameFound, isFalse);
    });

    test('pairs a label row over a grid of times (sunrise column included)',
        () {
      const String board = '''
NOOR MASJID PRAYER TIMES
FAJR  SUNRISE  ZUHR   ASR    MAGHRIB ISHA
05:30 06:45    13:00  17:00  18:45   20:30
''';

      final OcrResult result = MasjidOcrParser.parse(board);

      expect(result.times['fajr'], '05:30');
      expect(result.times['dhuhr'], '13:00');
      expect(result.times['asr'], '17:00');
      expect(result.times['maghrib'], '18:45');
      expect(result.times['isha'], '20:30');
      expect(result.lowConfidence, isFalse);
      expect(result.masjidName, 'NOOR MASJID');
    });

    test('pairs a grid whose times sit above their labels', () {
      const String board = '''
05:30 13:00 17:00 18:45 20:30
FAJR  ZUHR  ASR   MAGHRIB ISHA
''';

      final OcrResult result = MasjidOcrParser.parse(board);

      expect(result.times['fajr'], '05:30');
      expect(result.times['dhuhr'], '13:00');
      expect(result.times['asr'], '17:00');
      expect(result.times['maghrib'], '18:45');
      expect(result.times['isha'], '20:30');
    });

    test('reads the whole board as one comma separated line', () {
      const String board =
          'Fajr 5:30, Zohar 1:30, Asar 5:00, Magrib 6:45, Isha 8:30';

      final OcrResult result = MasjidOcrParser.parse(board);

      expect(result.times['fajr'], '05:30');
      expect(result.times['dhuhr'], '13:30');
      expect(result.times['asr'], '17:00');
      expect(result.times['maghrib'], '18:45');
      expect(result.times['isha'], '20:30');
    });

    test('recovers a reading when OCR drops the colon', () {
      final OcrResult result = MasjidOcrParser.parse('''
NOOR MASJID
FAJR 0515
ZUHR 1300
ASAR 1700
MAGHRIB 1845
ISHA 2000
''');

      expect(result.times['fajr'], '05:15');
      expect(result.times['dhuhr'], '13:00');
      expect(result.times['asr'], '17:00');
      expect(result.times['maghrib'], '18:45');
      expect(result.times['isha'], '20:00');
      expect(result.masjidName, 'NOOR MASJID');
    });

    test('reads Devanagari digits used on Hindi boards', () {
      final OcrResult result = MasjidOcrParser.parse('''
नूर मस्जिद
FAJR ०५:३०
ZUHR १३:००
ASR १७:००
MAGHRIB १८:४५
ISHA २०:३०
''');

      expect(result.times['fajr'], '05:30');
      expect(result.times['dhuhr'], '13:00');
      expect(result.times['asr'], '17:00');
      expect(result.times['maghrib'], '18:45');
      expect(result.times['isha'], '20:30');
      expect(result.timesMissing, isFalse);
    });

    test('reads a board whose labels are written in Hindi', () {
      final OcrResult result = MasjidOcrParser.parse('''
फजर 05:30
ज़ोहर 13:00
असर 17:00
मग़रिब 18:45
इशा 20:30
''');

      expect(result.times['fajr'], '05:30');
      expect(result.times['dhuhr'], '13:00');
      expect(result.times['asr'], '17:00');
      expect(result.times['maghrib'], '18:45');
      expect(result.times['isha'], '20:30');
      expect(result.lowConfidence, isFalse);
    });

    test('guesses the five prayers when no label survives OCR', () {
      final OcrResult result = MasjidOcrParser.parse('''
05:30
13:00
17:00
18:45
20:30
''');

      expect(result.times['fajr'], '05:30');
      expect(result.times['dhuhr'], '13:00');
      expect(result.times['asr'], '17:00');
      expect(result.times['maghrib'], '18:45');
      expect(result.times['isha'], '20:30');
      expect(result.lowConfidence, isTrue);
    });

    test('skips sunrise when guessing from six readings', () {
      final OcrResult result = MasjidOcrParser.parse('''
05:30
06:45
13:00
17:00
18:45
20:30
''');

      expect(result.times['fajr'], '05:30');
      expect(result.times['dhuhr'], '13:00');
      expect(result.times['maghrib'], '18:45');
      expect(result.times['isha'], '20:30');
      expect(result.lowConfidence, isTrue);
    });

    test('flags readings that do not rise through the day', () {
      // Straight from a real board: the Maghrib clock came back earlier than
      // the Asr clock, which is impossible and means a label was mismatched.
      final OcrResult result = MasjidOcrParser.parse('''
FAJR 05:17
ZUHR 07:39
ASR 17:50
MAGHRIB 16:47
ISHA 21:28
''');

      expect(result.times['asr'], '17:50');
      expect(result.times['maghrib'], '16:47');
      expect(result.outOfOrder, isTrue);
      expect(result.lowConfidence, isFalse,
          reason: 'labels were read fine — this is a pairing problem, not a '
              'guessing problem');
    });

    test('does not flag a correctly ordered board', () {
      final OcrResult result = MasjidOcrParser.parse('''
FAJR 05:17
ZUHR 13:39
ASR 15:50
MAGHRIB 18:47
ISHA 20:28
''');

      expect(result.outOfOrder, isFalse);
      expect(result.timesMissing, isFalse);
    });

    test('flags a board whose name reads but whose times do not', () {
      final OcrResult result =
          MasjidOcrParser.parse('MASJID-E-NOOR\n timings unreadable here');

      expect(result.nameFound, isTrue);
      expect(result.times, isEmpty);
      expect(result.timesMissing, isTrue);
      expect(result.rawText, contains('MASJID-E-NOOR'));
    });
  });

  group('Prayer times', () {
    // Regression test for the "Fajr 23:47" bug: adhan_dart hands back UTC
    // DateTimes built from astronomical hours, and displaying those raw gave
    // the previous evening's clock reading — and, because of the day rollover,
    // also made the "Next prayer" countdown pick the wrong row.
    test('Mumbai Fajr is a local morning time on today, not 23:47 UTC', () {
      final DateTime today = DateTime.now();
      final LocalPrayerTimes day = AppSettings.instance.compute(
        latitude: 19.0760,
        longitude: 72.8777,
      );

      final DateTime fajr = day.times['fajr']!;
      expect(fajr.isUtc, isFalse, reason: 'times must be device-local');
      expect(fajr.hour, inInclusiveRange(4, 6),
          reason: 'Mumbai Fajr should be ~05:17, got ${fajr.hour}:${fajr.minute}');
      expect(fajr.day, today.day);

      // Nothing may leak onto an adjacent calendar day.
      day.times.forEach((String key, DateTime value) {
        expect(value.day, today.day, reason: '$key landed on the wrong day');
        expect(value.isUtc, isFalse, reason: '$key is still UTC');
      });

      // Tomorrow's Fajr must be exactly a day later, or the countdown after
      // Isha reads 48 h / 0 h instead of 24 h.
      expect(day.fajrTomorrow.difference(fajr).inHours, 24);
    });

    test('Hanafi Asr is later than Shafi Asr', () {
      final AppSettings s = AppSettings.instance;
      final String originalMadhab = s.madhabKey;

      s.setMadhab('shafi');
      final DateTime shafi = s.compute(latitude: 19.0760, longitude: 72.8777).times['asr']!;

      s.setMadhab('hanafi');
      final DateTime hanafi = s.compute(latitude: 19.0760, longitude: 72.8777).times['asr']!;

      s.setMadhab(originalMadhab);

      expect(hanafi.difference(shafi).inMinutes, inInclusiveRange(45, 90),
          reason: 'shadow 2× should push Asr about an hour later');
    });
  });
}
