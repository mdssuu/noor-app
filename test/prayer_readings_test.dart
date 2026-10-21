import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/prayer_readings.dart';
import 'package:noor_masjid_time/reading_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Home card that carries one ayah or hadith through a prayer's window.
///
/// Three things have to hold for it to be worth having: the words are all
/// there (all four renderings, a real reference), the card shows a different
/// one tomorrow without changing under today's reader, and the toggle
/// actually puts the chosen language on screen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const double lat = 19.0760;
  const double lng = 72.8777;

  /// The prayer whose window the card is in right now — the same walk the
  /// card itself takes, so a test can ask what is on show.
  String currentWindow(AppSettings settings) {
    final DateTime now = DateTime.now();
    final LocalPrayerTimes day = settings.compute(latitude: lat, longitude: lng);
    String current = kReadingPrayerKeys.last;
    for (final String key in kReadingPrayerKeys) {
      if (day.times[key]!.isAfter(now)) break;
      current = key;
    }
    return current;
  }

  Future<AppSettings> freshSettings({String language = kReadingLanguageUrdu}) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final AppSettings settings = AppSettings.instance;
    await settings.useProfile('reading-card-$language');
    settings.setReadingLanguage(language);
    return settings;
  }

  Future<void> pumpCard(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PrayerReadingCard(latitude: lat, longitude: lng),
        ),
      ),
    ));
  }

  /// Unmounts the card, which cancels its 30-second ticker; a widget test
  /// fails at teardown if a timer outlives it.
  Future<void> tearDownCard(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
  }

  group('the pools themselves', () {
    test('every prayer carries one, and sunrise carries none', () {
      expect(kReadingPrayerKeys, <String>['fajr', 'dhuhr', 'asr', 'maghrib', 'isha']);
      expect(kReadingsByPrayer.keys.toSet(), kReadingPrayerKeys.toSet());
      expect(kReadingsByPrayer.containsKey('sunrise'), isFalse);
      for (final String key in kReadingPrayerKeys) {
        // Six means a week of days before anything repeats.
        expect(kReadingsByPrayer[key]!.length, greaterThanOrEqualTo(5),
            reason: '$key needs enough to rotate');
      }
    });

    test('every entry carries all four renderings and a reference', () {
      for (final MapEntry<String, List<PrayerReading>> entry
          in kReadingsByPrayer.entries) {
        for (final PrayerReading reading in entry.value) {
          expect(reading.arabic.trim(), isNotEmpty, reason: '${entry.key} arabic');
          expect(reading.english.trim(), isNotEmpty, reason: '${entry.key} english');
          expect(reading.urdu.trim(), isNotEmpty, reason: '${entry.key} urdu');
          expect(reading.roman.trim(), isNotEmpty, reason: '${entry.key} roman');
          expect(reading.source.trim(), isNotEmpty, reason: '${entry.key} source');
        }
      }
    });

    test('a reference is a reference: Quran verse or a named collection', () {
      for (final List<PrayerReading> pool in kReadingsByPrayer.values) {
        for (final PrayerReading reading in pool) {
          if (reading.kind == ReadingKind.quran) {
            expect(reading.source, startsWith('Quran '),
                reason: 'an ayah names its surah: ${reading.source}');
          } else {
            expect(
              reading.source.contains('Bukhari') ||
                  reading.source.contains('Muslim'),
              isTrue,
              reason: 'a hadith names its collection: ${reading.source}',
            );
          }
        }
      }
    });

    test('the words are never shown twice across the day', () {
      final List<PrayerReading> all = <PrayerReading>[
        for (final List<PrayerReading> pool in kReadingsByPrayer.values) ...pool,
      ];
      final Set<String> arabic = all.map((PrayerReading r) => r.arabic).toSet();
      final Set<String> sources = all.map((PrayerReading r) => r.source).toSet();
      expect(arabic, hasLength(all.length));
      expect(sources, hasLength(all.length));
    });
  });

  group('which reading is on show', () {
    test('one answer for the whole day, a new one tomorrow', () {
      final DateTime day = DateTime(2026, 3, 3);
      for (final String key in kReadingPrayerKeys) {
        expect(readingFor(key, day), readingFor(key, day.add(const Duration(hours: 23))));
        expect(readingFor(key, day), isNot(readingFor(key, day.add(const Duration(days: 1)))));
      }
    });

    test('one full cycle walks every entry in the pool', () {
      final DateTime day = DateTime(2026, 6, 1);
      final List<PrayerReading> pool = kReadingsByPrayer['isha']!;
      final Set<PrayerReading> seen = <PrayerReading>{
        for (int i = 0; i < pool.length; i++) readingFor('isha', day.add(Duration(days: i))),
      };
      expect(seen.length, pool.length);
    });

    test('each prayer has its own — a Fajr reading is never also Dhuhr’s',
        () {
      final DateTime day = DateTime(2026, 3, 3);
      final Set<String> fajrArabic =
          kFajrReadings.map((PrayerReading r) => r.arabic).toSet();
      final Set<String> dhuhrArabic =
          kDhuhrReadings.map((PrayerReading r) => r.arabic).toSet();
      expect(fajrArabic.intersection(dhuhrArabic), isEmpty);
      expect(readingFor('fajr', day).arabic,
          isNot(readingFor('dhuhr', day).arabic));
    });

    test('a key with no pool falls back instead of throwing', () {
      expect(() => readingFor('sunrise', DateTime.now()), returnsNormally);
      // No pool of its own, so it lands on Fajr's — the same day's entry.
      expect(readingFor('sunrise', DateTime.now()),
          readingFor('fajr', DateTime.now()));
    });
  });

  group('the three renderings', () {
    test('each language gets its own words, and an unknown one gets Urdu',
        () {
      const PrayerReading sample = PrayerReading(
        kind: ReadingKind.quran,
        arabic: 'إِنَّ الصَّلَاةَ',
        english: 'Indeed, prayer',
        urdu: 'بے شک نماز',
        roman: 'Be shak namaz',
        source: 'Quran 4:103',
      );
      expect(sample.translationFor(kReadingLanguageUrdu), sample.urdu);
      expect(sample.translationFor(kReadingLanguageEnglish), sample.english);
      expect(sample.translationFor(kReadingLanguageRoman), sample.roman);
      // A stale key must not print nothing.
      expect(sample.translationFor('french'), sample.urdu);
    });

    test('only Urdu runs right to left', () {
      expect(languageIsRtl(kReadingLanguageUrdu), isTrue);
      expect(languageIsRtl(kReadingLanguageEnglish), isFalse);
      expect(languageIsRtl(kReadingLanguageRoman), isFalse);
    });

    test('the toggle has a label for every key it offers', () {
      expect(kReadingLanguageKeys,
          <String>[kReadingLanguageUrdu, kReadingLanguageEnglish, kReadingLanguageRoman]);
      for (final String key in kReadingLanguageKeys) {
        expect(kReadingLanguageLabels[key], isNotNull);
      }
    });
  });

  group('the language preference', () {
    test('opens on Urdu and keeps whatever the reader picks', () async {
      final AppSettings settings = await freshSettings();
      expect(settings.readingLanguage, kReadingLanguageUrdu);

      settings.setReadingLanguage(kReadingLanguageEnglish);
      expect(settings.readingLanguage, kReadingLanguageEnglish);

      settings.setReadingLanguage(kReadingLanguageRoman);
      expect(settings.readingLanguage, kReadingLanguageRoman);
    });

    test('a key that is not one of the three is refused', () async {
      final AppSettings settings =
          await freshSettings(language: kReadingLanguageUrdu);
      settings.setReadingLanguage('french');
      expect(settings.readingLanguage, kReadingLanguageUrdu);
    });

    test('a stored key outside the three is read back as Urdu', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'readingLanguage::reading-card-junk': 'french',
      });
      final AppSettings settings = AppSettings.instance;
      await settings.useProfile('reading-card-junk');
      expect(settings.readingLanguage, kReadingLanguageUrdu);
    });
  });

  group('on the card', () {
    testWidgets('the Arabic is on top with its reference beneath',
        (WidgetTester tester) async {
      final AppSettings settings = await freshSettings();
      final PrayerReading reading =
          readingFor(currentWindow(settings), DateTime.now());

      await pumpCard(tester);

      expect(find.text(reading.arabic), findsOneWidget);
      expect(find.text(reading.source), findsOneWidget);
      expect(find.text(reading.urdu), findsOneWidget);

      // The window the card is sitting inside, named and timed.
      expect(find.textContaining('→'), findsOneWidget);
      expect(find.textContaining('–'), findsOneWidget);

      // RTL: the Arabic's own text direction, and Urdu's beneath it.
      final Text arabic =
          tester.widget<Text>(find.text(reading.arabic));
      expect(arabic.textDirection, TextDirection.rtl);

      await tearDownCard(tester);
    });

    testWidgets('tapping a language puts that language on screen and keeps it',
        (WidgetTester tester) async {
      final AppSettings settings = await freshSettings();
      final PrayerReading reading =
          readingFor(currentWindow(settings), DateTime.now());

      await pumpCard(tester);
      expect(find.text(reading.urdu), findsOneWidget);

      await tester.tap(find.text('ENGLISH'));
      await tester.pump();
      expect(settings.readingLanguage, kReadingLanguageEnglish);
      expect(find.text(reading.english), findsOneWidget);
      expect(find.text(reading.urdu), findsNothing);

      await tester.tap(find.text('ROMAN'));
      await tester.pump();
      expect(settings.readingLanguage, kReadingLanguageRoman);
      expect(find.text(reading.roman), findsOneWidget);
      expect(find.text(reading.english), findsNothing);

      // English and Roman are Latin scripts — they must not inherit the RTL
      // direction the Arabic above them is sitting in.
      final Text english = tester.widget<Text>(find.text(reading.roman));
      expect(english.textDirection, TextDirection.ltr);

      await tearDownCard(tester);
    });

    testWidgets('the chosen language survives a rebuild of the card',
        (WidgetTester tester) async {
      final AppSettings settings = await freshSettings();
      final PrayerReading reading =
          readingFor(currentWindow(settings), DateTime.now());

      await pumpCard(tester);
      await tester.tap(find.text('ENGLISH'));
      await tester.pump();

      // Pumps the card again — the same preference comes back off disk's
      // worth of state rather than resetting to the default.
      await pumpCard(tester);
      expect(settings.readingLanguage, kReadingLanguageEnglish);
      expect(find.text(reading.english), findsOneWidget);

      await tearDownCard(tester);
    });
  });
}
