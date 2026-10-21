import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hijri/hijri_calendar.dart';
import 'package:intl/intl.dart';

import '../app_look.dart';
import '../app_settings.dart';
import '../main.dart';
import '../services/islamic_calendar.dart';

/// The Hijri month as a screen: the grid of the month with *both* calendars
/// on every cell, the occasions that fall on it, and the prayer times of
/// whichever day the reader taps.
///
/// The app had the whole machinery — the month grid, the ten fixed
/// occasions, the next-event lookup — sitting in `services/`, tested and
/// unused, and the onboarding page promising "the Hijri calendar, one tap
/// from Home". This is the screen that makes both true.
///
/// Two rules the screen keeps:
///
///  * the month shown is always a whole Hijri month, navigated by *month*
///    rather than by a fixed 29-day hop, so "next" always lands on the 1st;
///  * every cell knows both of its dates, so the number under a date can
///    never be for a different day than the date above it.
class HijriCalendarScreen extends StatefulWidget {
  const HijriCalendarScreen({super.key, this.latitude, this.longitude});

  final double? latitude;
  final double? longitude;

  @override
  State<HijriCalendarScreen> createState() => _HijriCalendarScreenState();
}

class _HijriCalendarScreenState extends State<HijriCalendarScreen> {
  /// The day whose Hijri month is on screen. Moving the month moves this
  /// to the 1st of the new one.
  late DateTime _anchor;

  /// The day the reader is looking at — its times are printed underneath
  /// the grid. Starts on today, because today is what the reader came for.
  late DateTime _selected;

  @override
  void initState() {
    super.initState();
    final DateTime now = DateTime.now();
    _anchor = DateTime(now.year, now.month, now.day);
    _selected = _anchor;
    // The ±days correction is a setting the reader can change from the
    // Settings screen; while this one is open the grid must follow it.
    AppSettings.instance.addListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  /// The user's own correction, in days — the same one the Home greeting
  /// and the Ramadan banner use, so the two can never disagree.
  int get _adjustment => AppSettings.instance.hijriAdjustment;

  /// Where the times under the grid are calculated for: the pinned city
  /// first (what the Today card uses), the app's fallback anchor otherwise.
  ({double latitude, double longitude}) get _here {
    final AppSettings settings = AppSettings.instance;
    if (widget.latitude != null && widget.longitude != null) {
      return (latitude: widget.latitude!, longitude: widget.longitude!);
    }
    if (settings.hasCustomLocation) {
      return (
        latitude: settings.customLatitude ?? 19.0760,
        longitude: settings.customLongitude ?? 72.8777,
      );
    }
    return (latitude: 19.0760, longitude: 72.8777);
  }

  /// Walks a whole Hijri month at a time — never a fixed 29 or 30 days,
  /// which lands in the middle of a month as soon as the lengths differ.
  void _step(int delta) {
    setState(() {
      _anchor = NoorHijri.monthStartBy(_anchor, delta, adjustment: _adjustment);
    });
  }

  void _backToToday() {
    final DateTime now = DateTime.now();
    setState(() {
      _anchor = DateTime(now.year, now.month, now.day);
      _selected = _anchor;
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = AppSettings.instance;
    final HijriCalendar hijri = NoorHijri.hijriOf(
      _anchor,
      adjustment: _adjustment,
    );
    final List<HijriGridDay> cells = hijriMonthGrid(
      _anchor,
      adjustment: _adjustment,
    );

    final DateTime start = cells.isEmpty ? _anchor : cells.first.gregorian;
    final DateTime end = cells.isEmpty ? _anchor : cells.last.gregorian;

    return NoorScaffold(
      appBar: AppBar(title: const Text('Hijri calendar')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
        children: <Widget>[
          _monthHeader(hijri, start, end),
          const SizedBox(height: 14),
          _gridCard(cells),
          const SizedBox(height: 14),
          _selectedDayCard(settings),
          const SizedBox(height: 14),
          _occasionsCard(hijri),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ header

  Widget _monthHeader(HijriCalendar hijri, DateTime start, DateTime end) {
    final (IslamicEvent event, DateTime date)? next = _nextOccasion();

    return GoldCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              _monthButton(
                icon: Icons.chevron_left,
                tooltip: 'Previous month',
                onTap: () => _step(-1),
              ),
              Expanded(
                child: Column(
                  children: <Widget>[
                    Text(
                      '${hijri.getLongMonthName()} ${hijri.hYear} AH',
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.outfit(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: NoorColors.onGlass,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${DateFormat('d MMM').format(start)} – '
                      '${DateFormat('d MMM yyyy').format(end)}',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.outfit(
                        fontSize: 11,
                        color: NoorColors.onGlassMuted,
                      ),
                    ),
                  ],
                ),
              ),
              _monthButton(
                icon: Icons.chevron_right,
                tooltip: 'Next month',
                onTap: () => _step(1),
              ),
            ],
          ),
          if (next != null) ...<Widget>[
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                const Icon(
                  Icons.event_outlined,
                  size: 15,
                  color: NoorColors.gold,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    '${next.$1.title} ${_inWords(_daysUntil(next.$2))} · '
                    '${DateFormat('d MMM').format(next.$2)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.outfit(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: NoorColors.onGlass,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _backToToday,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    'Today',
                    style: GoogleFonts.outfit(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: NoorColors.emeraldDeep,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _monthButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: Icon(icon, size: 22, color: NoorColors.emeraldDeep),
      visualDensity: VisualDensity.compact,
    );
  }

  /// The next occasion — skipping "Ramadan begins", because the Ramadan
  /// banner on Home already counts that one down and two countdowns for the
  /// same night would only confuse.
  (IslamicEvent, DateTime)? _nextOccasion() {
    final DateTime now = DateTime.now();
    final (IslamicEvent, DateTime)? first = nextEvent(
      now,
      adjustment: _adjustment,
    );
    if (first == null) return null;
    if (!isRamadanStart(first.$1)) return first;
    return nextEvent(
      first.$2.add(const Duration(days: 1)),
      adjustment: _adjustment,
    );
  }

  int _daysUntil(DateTime date) {
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    final DateTime that = DateTime(date.year, date.month, date.day);
    return that.difference(today).inDays;
  }

  String _inWords(int days) {
    if (days <= 0) return 'today';
    if (days == 1) return 'tomorrow';
    return 'in $days days';
  }

  // -------------------------------------------------------------------- grid

  Widget _gridCard(List<HijriGridDay> cells) {
    // Sunday first — the way the printed calendars in India are set.
    const List<String> weekdays = <String>['S', 'M', 'T', 'W', 'T', 'F', 'S'];

    // The month starts on a weekday that is not Sunday, so the first cells
    // of the first row are empty — the month is a whole Hijri month, not a
    // gregorian one, and it must not borrow days from the month before it.
    final int leading = cells.isEmpty ? 0 : cells.first.gregorian.weekday % 7;
    final int rows = ((leading + cells.length) / 7).ceil();

    final List<Widget> rowsWidgets = <Widget>[];
    for (int r = 0; r < rows; r++) {
      final List<Widget> row = <Widget>[];
      for (int c = 0; c < 7; c++) {
        final int index = r * 7 + c - leading;
        if (index < 0 || index >= cells.length) {
          row.add(const SizedBox(height: 54));
        } else {
          row.add(_cell(cells[index]));
        }
      }
      rowsWidgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            children: <Widget>[
              for (int c = 0; c < 7; c++) Expanded(child: row[c]),
            ],
          ),
        ),
      );
    }

    return GoldCard(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              for (final String day in weekdays)
                Expanded(
                  child: Center(
                    child: Text(
                      day,
                      style: GoogleFonts.outfit(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: NoorColors.onGlassMuted,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          ...rowsWidgets,
        ],
      ),
    );
  }

  /// One day of the grid: the Hijri number big, the gregorian number
  /// small, and a dot when the day carries an occasion.
  Widget _cell(HijriGridDay day) {
    final bool selected = day.gregorian == _selected;
    final bool today = day.isToday;
    final bool marked = day.events.isNotEmpty;

    return InkWell(
      key: ValueKey<String>('hijri-day-${day.hijriDay}'),
      onTap: () => setState(() => _selected = day.gregorian),
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: 54,
        child: Column(
          children: <Widget>[
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? NoorColors.gold : Colors.transparent,
                border: today && !selected
                    ? Border.all(color: NoorColors.emeraldDeep, width: 1.4)
                    : null,
              ),
              child: Text(
                '${day.hijriDay}',
                style: GoogleFonts.outfit(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: selected ? NoorColors.ink : NoorColors.onGlass,
                ),
              ),
            ),
            const SizedBox(height: 1),
            Text(
              '${day.gregorian.day}',
              style: GoogleFonts.outfit(
                fontSize: 9.5,
                color: selected
                    ? NoorColors.emeraldDeep
                    : NoorColors.onGlassMuted,
              ),
            ),
            const SizedBox(height: 2),
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: marked ? NoorColors.emeraldDeep : Colors.transparent,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ----------------------------------------------------------- selected day

  /// The day the reader picked: both of its dates, and the times of that
  /// day calculated for the same place the Today card uses.
  Widget _selectedDayCard(AppSettings settings) {
    final DateTime day = _selected;
    final HijriCalendar hijri = NoorHijri.hijriOf(day, adjustment: _adjustment);
    final ({double latitude, double longitude}) here = _here;
    final LocalPrayerTimes times = settings.compute(
      latitude: here.latitude,
      longitude: here.longitude,
      day: day,
    );

    const List<String> keys = <String>[
      'fajr',
      'sunrise',
      'dhuhr',
      'asr',
      'maghrib',
      'isha',
      'sunset',
    ];

    // Sunrise and sunset are not prayers, so they are not in the app's
    // prayer list — they are named here instead of being forced into it.
    const Map<String, String> labels = <String, String>{
      'fajr': 'Fajr',
      'sunrise': 'Sunrise',
      'dhuhr': 'Dhuhr',
      'asr': 'Asr',
      'maghrib': 'Maghrib',
      'isha': 'Isha',
      'sunset': 'Sunset',
    };

    return GoldCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            DateFormat('EEEE, d MMMM yyyy').format(day),
            style: GoogleFonts.outfit(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: NoorColors.onGlass,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            '${hijri.hDay} ${hijri.getLongMonthName()} ${hijri.hYear} AH',
            style: GoogleFonts.outfit(
              fontSize: 11.5,
              color: NoorColors.onGlassMuted,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final String key in keys)
                _timeChip(
                  labels[key] ?? key,
                  times.times[key] == null
                      ? '—'
                      : settings.format(times.times[key]!),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _timeChip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: NoorColors.onGlassChip,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            style: GoogleFonts.outfit(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: NoorColors.onGlassMuted,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            value,
            style: GoogleFonts.outfit(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: NoorColors.onGlass,
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- occasions

  /// The occasions of the month on screen, with the gregorian day each one
  /// lands on.
  Widget _occasionsCard(HijriCalendar hijri) {
    final List<IslamicEvent> events = kIslamicEvents
        .where((IslamicEvent e) => e.month == hijri.hMonth)
        .toList(growable: false);

    return GoldCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(
                Icons.event_available_outlined,
                size: 16,
                color: NoorColors.gold,
              ),
              const SizedBox(width: 7),
              Text(
                'Occasions this month',
                style: GoogleFonts.outfit(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: NoorColors.onGlass,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (events.isEmpty)
            Text(
              'No fixed occasion falls in ${hijri.getLongMonthName()}.',
              style: GoogleFonts.outfit(
                fontSize: 11.5,
                color: NoorColors.onGlassMuted,
              ),
            )
          else
            for (final IslamicEvent event in events)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox(
                      width: 52,
                      child: Text(
                        DateFormat('d MMM').format(
                          NoorHijri.gregorianOf(
                            hijri.hYear,
                            event.month,
                            event.day,
                            adjustment: _adjustment,
                          ),
                        ),
                        style: GoogleFonts.outfit(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: NoorColors.emeraldDeep,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            event.title,
                            style: GoogleFonts.outfit(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: NoorColors.onGlass,
                            ),
                          ),
                          if (event.note.isNotEmpty)
                            Text(
                              event.note,
                              style: GoogleFonts.outfit(
                                fontSize: 10,
                                height: 1.35,
                                color: NoorColors.onGlassMuted,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          const SizedBox(height: 6),
          Text(
            'Dates follow the moon, not a committee — a sighting may move any '
            'of them by a day. The ±days correction in Settings shifts the '
            'whole calendar.',
            style: GoogleFonts.outfit(
              fontSize: 9.5,
              height: 1.4,
              color: NoorColors.onGlassMuted,
            ),
          ),
        ],
      ),
    );
  }
}
