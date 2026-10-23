import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../app_look.dart';
import '../app_settings.dart';
import '../main.dart';
import '../services/prayer_tracker.dart';

/// The salah log: a month of dots, a streak to keep, and today's five in
/// one row.
///
/// The whole record is a local one — it never leaves the phone, needs no
/// account and no network, and is scoped to whichever profile is signed in.
/// That is deliberate: a log of a person's prayers is theirs, and an app
/// that keeps it on the device keeps that promise by construction.
class TrackerScreen extends StatefulWidget {
  const TrackerScreen({super.key});

  @override
  State<TrackerScreen> createState() => _TrackerScreenState();
}

class _TrackerScreenState extends State<TrackerScreen> {
  final PrayerTracker _tracker = PrayerTracker.instance;

  /// The day the lower chips edit; today until another cell is tapped.
  DateTime? _picked;

  @override
  void initState() {
    super.initState();
    _tracker.addListener(_changed);
    if (!_tracker.isLoaded) _tracker.load();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tracker.removeListener(_changed);
    super.dispose();
  }

  DateTime get _today {
    final DateTime now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  @override
  Widget build(BuildContext context) {
    final DateTime picked = _picked ?? _today;
    final MonthSummary month = _tracker.monthOf(picked);
    final List<DateTime> days = _monthDays(picked);
    final Set<String> pickedPrayers = _tracker.day(picked);

    return NoorScaffold(
      appBar: AppBar(title: const Text('Prayer tracker')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
        children: <Widget>[
          _streakCard(),
          const SizedBox(height: 12),

          // Today's five, unless another day has been picked below — then
          // the row says which day it is editing, so a tap on the 14th can
          // never quietly edit today.
          GoldCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  picked == _today
                      ? 'Today'
                      : DateFormat('EEEE, d MMMM').format(picked),
                  style: GoogleFonts.outfit(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: NoorColors.onGlass,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final String key in kNotifiablePrayers)
                      _prayerChip(key, pickedPrayers.contains(key)),
                  ],
                ),
                if (picked == _today) ...<Widget>[
                  const SizedBox(height: 12),
                  GradientButton(
                    label: 'All five offered',
                    icon: Icons.done_all,
                    expand: false,
                    onPressed: pickedPrayers.length >= 5
                        ? null
                        : () {
                            _tracker.markTodayComplete();
                            HapticFeedback.mediumImpact();
                          },
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),

          GoldCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        DateFormat('MMMM yyyy').format(picked),
                        style: GoogleFonts.outfit(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: NoorColors.onGlass,
                        ),
                      ),
                    ),
                    Text(
                      '${month.daysComplete} complete · '
                      '${month.daysLogged} logged',
                      style: GoogleFonts.outfit(
                        fontSize: 11,
                        color: NoorColors.onGlassMuted,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // Weekday letters, Monday-first like the grid below.
                Row(
                  children: <Widget>[
                    for (final String d in const <String>[
                      'M', 'T', 'W', 'T', 'F', 'S', 'S',
                    ])
                      Expanded(
                        child: Center(
                          child: Text(
                            d,
                            style: GoogleFonts.outfit(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w700,
                              color: NoorColors.onGlassMuted,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                _monthGrid(days),
                const SizedBox(height: 8),
                Text(
                  'One dot per prayer offered; a full ring of five is a '
                  'complete day, and complete days in a row are the streak '
                  'above. Tap any day to edit it.',
                  style: GoogleFonts.outfit(
                    fontSize: 10.5,
                    height: 1.45,
                    color: NoorColors.onGlassMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _streakCard() {
    final int streak = _tracker.streak;
    return GoldCard(
      child: Row(
        children: <Widget>[
          Icon(
            streak > 0 ? Icons.local_fire_department : Icons.more_horiz,
            size: 30,
            color: streak > 0 ? NoorColors.gold : NoorColors.onGlassMuted,
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  streak == 0
                      ? 'No streak yet'
                      : '$streak day${streak == 1 ? '' : 's'} in a row',
                  style: GoogleFonts.outfit(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: streak > 0 ? NoorColors.gold : NoorColors.onGlass,
                  ),
                ),
                Text(
                  streak == 0
                      ? 'Offer all five today to start one.'
                      : 'All five prayers, every day. Keep it going.',
                  style: GoogleFonts.outfit(
                    fontSize: 11.5,
                    color: NoorColors.onGlassMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<DateTime> _monthDays(DateTime anchor) {
    final DateTime first = DateTime(anchor.year, anchor.month, 1);
    final DateTime next = DateTime(anchor.year, anchor.month + 1, 1);
    return List<DateTime>.generate(
      next.difference(first).inDays,
      (int i) => first.add(Duration(days: i)),
    );
  }

  Widget _monthGrid(List<DateTime> days) {
    final int lead = days.isEmpty ? 0 : (days.first.weekday - 1) % 7;
    return GridView.count(
      crossAxisCount: 7,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 2,
      crossAxisSpacing: 2,
      childAspectRatio: 0.74,
      children: <Widget>[
        for (int i = 0; i < lead; i++) const SizedBox.shrink(),
        for (final DateTime day in days) _dayCell(day),
      ],
    );
  }

  Widget _dayCell(DateTime day) {
    final Set<String> prayed = _tracker.day(day);
    final bool isToday = day == _today;
    final bool isPicked = day == _picked;
    final bool future = day.isAfter(_today);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: future ? null : () => setState(() => _picked = day),
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isPicked
              ? NoorColors.gold.withValues(alpha: 0.22)
              : isToday
                  ? NoorColors.gold.withValues(alpha: 0.10)
                  : null,
          border: isToday || isPicked
              ? Border.all(
                  color: NoorColors.gold.withValues(alpha: isPicked ? 1 : 0.7),
                  width: isPicked ? 1.6 : 1.2,
                )
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(
              '${day.day}',
              style: GoogleFonts.outfit(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: future
                    ? NoorColors.onGlassMuted.withValues(alpha: 0.5)
                    : NoorColors.onGlass,
              ),
            ),
            const SizedBox(height: 2),
            // The five dots — the month's whole story in one cell.
            Wrap(
              spacing: 1.5,
              runSpacing: 1.5,
              alignment: WrapAlignment.center,
              children: <Widget>[
                for (final String key in kNotifiablePrayers)
                  Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: prayed.contains(key)
                          ? NoorColors.gold
                          : NoorColors.onGlass.withValues(alpha: 0.16),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _prayerChip(String key, bool on) {
    return FilterChip(
      selected: on,
      onSelected: (bool v) {
        _tracker.toggle(_picked ?? _today, key);
        HapticFeedback.selectionClick();
      },
      label: Text(
        prayerByKey(key).label,
        style: GoogleFonts.outfit(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: on ? NoorColors.ink : NoorColors.onGlass,
        ),
      ),
      selectedColor: NoorColors.gold,
      backgroundColor: NoorColors.onGlassChip,
      side: BorderSide(
        color: on ? NoorColors.gold : NoorColors.onGlassMuted.withValues(alpha: 0.4),
      ),
      showCheckmark: false,
    );
  }
}
