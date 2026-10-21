import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_look.dart';
import 'app_settings.dart';
import 'main.dart';
import 'prayer_readings.dart';

// ===========================================================================
//  THE READING CARD
//
//  One ayah or one hadith held on screen for a prayer's own window — Fajr's
//  from the moment Fajr opens until Dhuhr's does — with the Arabic on top in
//  its own script, the translation underneath in whichever of the three the
//  reader chose, and the reference beneath that.
//
//  Nothing here reaches the network: the words are compiled in, so the card
//  is complete at 5 a.m. on a phone with no signal. It refreshes on a 30s
//  tick and on every Settings change, the same rhythm the two cards above it
//  keep, so the window turns over without anyone having to pull.
// ===========================================================================

class PrayerReadingCard extends StatefulWidget {
  const PrayerReadingCard({
    super.key,
    required this.latitude,
    required this.longitude,
  });

  final double latitude;
  final double longitude;

  @override
  State<PrayerReadingCard> createState() => _PrayerReadingCardState();
}

class _PrayerReadingCardState extends State<PrayerReadingCard> {
  Timer? _ticker;

  /// The window this card is inside: [currentKey]'s time has passed and
  /// [nextKey]'s has not yet. `isha` → `fajr` is the overnight case, where
  /// [end] is tomorrow's Fajr from `LocalPrayerTimes.fajrTomorrow`.
  String _currentKey = kReadingPrayerKeys.last;
  String _nextKey = kReadingPrayerKeys.first;
  DateTime _start = DateTime.now();
  DateTime _end = DateTime.now();

  @override
  void initState() {
    super.initState();
    // Any change to Settings — method, madhab, 12/24h, custom city, and now
    // the translation language — redraws and recomputes the window at once.
    AppSettings.instance.addListener(_recompute);
    _recompute();
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) => _recompute());
  }

  @override
  void didUpdateWidget(PrayerReadingCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.latitude != widget.latitude ||
        oldWidget.longitude != widget.longitude) {
      _recompute();
    }
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_recompute);
    _ticker?.cancel();
    super.dispose();
  }

  void _recompute() {
    if (!mounted) return;

    final AppSettings settings = AppSettings.instance;
    final DateTime now = DateTime.now();
    final LocalPrayerTimes day = settings.compute(
      latitude: settings.customLatitude ?? widget.latitude,
      longitude: settings.customLongitude ?? widget.longitude,
    );

    // Walk the five prayers in order: everything already started is left
    // behind us, the first one still ahead closes the window. Past Isha the
    // loop ends without a `break`, leaving `isha` → tomorrow's `fajr`.
    String current = kReadingPrayerKeys.last;
    String next = kReadingPrayerKeys.first;
    DateTime start = day.times['isha']!;
    DateTime end = day.fajrTomorrow;
    for (final String key in kReadingPrayerKeys) {
      if (day.times[key]!.isAfter(now)) {
        next = key;
        end = day.times[key]!;
        break;
      }
      current = key;
      start = day.times[key]!;
    }

    setState(() {
      _currentKey = current;
      _nextKey = next;
      _start = start;
      _end = end;
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = AppSettings.instance;
    final String lang = settings.readingLanguage;
    // The day's reading for the prayer whose window this is: one answer all
    // morning, a new one tomorrow.
    final PrayerReading reading = readingFor(_currentKey, DateTime.now());

    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // ------------------------------------------------------ header row
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child:
                    Icon(Icons.menu_book_outlined, size: 19, color: NoorColors.emeraldDeep),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '${kReadingPrayerLabels[_currentKey]} → '
                      '${kReadingPrayerLabels[_nextKey]}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.outfit(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: NoorColors.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${settings.format(_start)}  –  ${settings.format(_end)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.outfit(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: NoorColors.onGlassMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // ----------------------------------------------- language selector
          Row(
            children: <Widget>[
              Text(
                'TRANSLATION',
                style: GoogleFonts.outfit(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.4,
                  color: NoorColors.onGlassMuted,
                ),
              ),
              const Spacer(),
              for (final String key in kReadingLanguageKeys)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: _langChip(key, key == lang),
                ),
            ],
          ),

          const SizedBox(height: 12),

          // ------------------------------------------------------- the Arabic
          // Always on top and always in Arabic, RTL — the one line that does
          // not move when the reader switches languages underneath it.
          Directionality(
            textDirection: TextDirection.rtl,
            child: Text(
              reading.arabic,
              textAlign: TextAlign.right,
              textDirection: TextDirection.rtl,
              style: GoogleFonts.notoNaskhArabic(
                fontSize: 19,
                height: 1.95,
                color: NoorColors.ink,
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ------------------------------------------------ the translation
          Directionality(
            textDirection: languageIsRtl(lang)
                ? TextDirection.rtl
                : TextDirection.ltr,
            child: Text(
              reading.translationFor(lang),
              textAlign: languageIsRtl(lang)
                  ? TextAlign.right
                  : TextAlign.left,
              textDirection: languageIsRtl(lang)
                  ? TextDirection.rtl
                  : TextDirection.ltr,
              style: _translationStyle(lang),
            ),
          ),

          const SizedBox(height: 13),

          // -------------------------------------------------- the reference
          // A quotation without a source is a rumour, so this row never goes
          // away — not for the ayah, not for the hadith.
          Row(
            children: <Widget>[
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: NoorColors.onGlassChip,
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(
                    color: NoorColors.gold.withValues(alpha: 0.40),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      reading.kind == ReadingKind.quran
                          ? Icons.menu_book_outlined
                          : Icons.format_quote_rounded,
                      size: 13,
                      color: NoorColors.emeraldDeep,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      reading.source,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.outfit(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: NoorColors.ink,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The translation's face: Nastaliq for Urdu (and only Urdu — it is the one
  /// rendering that needs a typeface of its own), the app's plain grotesk for
  /// English and for Roman Urdu, which is Latin text whichever way you spell
  /// it.
  TextStyle _translationStyle(String lang) {
    if (lang == kReadingLanguageUrdu) {
      return GoogleFonts.notoNastaliqUrdu(
        fontSize: 13.5,
        height: 2.05,
        color: NoorColors.ink,
      );
    }
    return GoogleFonts.outfit(
      fontSize: lang == kReadingLanguageRoman ? 13 : 13.5,
      height: 1.5,
      color: NoorColors.ink,
    );
  }

  Widget _langChip(String key, bool selected) {
    return InkWell(
      onTap: () => AppSettings.instance.setReadingLanguage(key),
      borderRadius: BorderRadius.circular(30),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? NoorColors.emeraldSoft
              : NoorColors.onGlassChip,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(
            color: selected
                ? NoorColors.gold
                : const Color(0x1A3A2E22),
          ),
        ),
        child: Text(
          kReadingLanguageLabels[key] ?? key.toUpperCase(),
          style: GoogleFonts.outfit(
            fontSize: 9.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.9,
            color: selected
                ? NoorColors.emeraldDeep
                : NoorColors.muted,
          ),
        ),
      ),
    );
  }
}
