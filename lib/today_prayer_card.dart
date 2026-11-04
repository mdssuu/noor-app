import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_look.dart';
import 'app_settings.dart';
import 'main.dart';
import 'screens/home_extras.dart' show shareTodayTimes;

/// "Today's Prayer Times" card — computed on device with `adhan_dart`.
///
/// Cut the way the reference wears it: one white panel with whose place these
/// times are for at the head, then one row per prayer — icon chip, name, and
/// the clock on the right with a board's Jamaat stacked over the calculated
/// Awwal time where a masjid publishes one. Under each clock sits the
/// prayer's *official* end — the calculated start of whatever follows, which
/// a board's Jamaat cell never moves. The makruh (Zawal) half hour is not
/// repeated here: it stands as its own big line at the top of the hero, and
/// only while it runs. The bell at the end of a row is a
/// three-state switch — azan, silent (banner without sound), off — walked
/// one tap at a time; `off` is the same gate the Settings switch holds.
///
/// The bell no longer walks that ring on its own — it opens a dialog (Azaan /
/// Mute / Band) the reader answers, and only a real answer moves the bell.
///
/// This card always renders, even when the Firestore `masjids` collection is
/// empty, so the home screen never looks blank.
class TodayPrayerCard extends StatefulWidget {
  const TodayPrayerCard({
    super.key,
    required this.latitude,
    required this.longitude,
    required this.areaName,
    this.board,
    this.boards = const <Masjid>[],
  });

  final double latitude;
  final double longitude;
  final String areaName;

  /// The starred masjid whose own Jamaat column this card quotes alongside
  /// the calculated times.
  ///
  /// It has one for every prayer a board actually publishes (`sunrise` never
  /// has one). `null` while nothing is starred, which leaves the card exactly
  /// as it has always been — calculated times alone.
  final Masjid? board;

  /// Every starred masjid, so the card can name whose times they are and let
  /// the reader pick a different board when there is more than one.
  final List<Masjid> boards;

  @override
  State<TodayPrayerCard> createState() => _TodayPrayerCardState();
}

class _TodayPrayerCardState extends State<TodayPrayerCard> {
  Timer? _ticker;
  Timer? _rescheduleTimer;
  List<_Entry> _entries = <_Entry>[];
  _Entry? _next;

  @override
  void initState() {
    super.initState();
    // Anything changed in Settings (method, madhab, 12/24h, city) redraws the
    // card immediately — no restart.
    AppSettings.instance.addListener(_settingsChanged);
    _recompute();
    // 30s keeps the countdown fresh without waking the CPU in the background.
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) => _recompute());
  }

  void _settingsChanged() {
    _recompute();
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(TodayPrayerCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.latitude != widget.latitude ||
        oldWidget.longitude != widget.longitude ||
        oldWidget.areaName != widget.areaName) {
      _recompute();
    }
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_settingsChanged);
    _ticker?.cancel();
    _rescheduleTimer?.cancel();
    super.dispose();
  }

  /// Prayer times come from the pinned city when one is set in Settings,
  /// otherwise from GPS — falling back to Mumbai only when there is no fix.
  double get _lat {
    final AppSettings s = AppSettings.instance;
    return s.customLatitude ?? widget.latitude;
  }

  double get _lng {
    final AppSettings s = AppSettings.instance;
    return s.customLongitude ?? widget.longitude;
  }

  void _recompute() {
    if (!mounted) return;

    final AppSettings settings = AppSettings.instance;
    final DateTime now = DateTime.now();
    final LocalPrayerTimes day =
        settings.compute(latitude: _lat, longitude: _lng);

    setState(() {
      _entries = <_Entry>[
        _Entry('fajr', 'Fajr', day.times['fajr']!, Icons.dark_mode_outlined,
            day.officialEnd('fajr')),
        _Entry('sunrise', 'Sunrise', day.times['sunrise']!,
            Icons.wb_sunny_outlined, day.officialEnd('sunrise')),
        _Entry('dhuhr', 'Dhuhr', day.times['dhuhr']!,
            Icons.light_mode_outlined, day.officialEnd('dhuhr')),
        _Entry('asr', 'Asr', day.times['asr']!, Icons.wb_twilight_outlined,
            day.officialEnd('asr')),
        _Entry('maghrib', 'Maghrib', day.times['maghrib']!,
            Icons.nights_stay_outlined, day.officialEnd('maghrib')),
        _Entry('isha', 'Isha', day.times['isha']!, Icons.dark_mode_outlined,
            day.officialEnd('isha')),
      ];
      _next = _nextEntry(day, now);
    });
  }

  /// The board's own Jamaat time for [key], or `''` when it has none.
  ///
  /// A prayer the board does not publish arrives as `--:--` (a typo'd
  /// `13:60` is refused just the same), so the cell falls back to the
  /// calculated time rather than printing a placeholder at the reader.
  String _jamaat(String key) {
    final Masjid? board = widget.board;
    if (board == null) return '';

    final String stored = board.timeFor(key);
    return NotificationService.parseClockTime(stored) == null ? '' : stored;
  }

  /// The three-state bell at the end of a prayer's row.
  ///
  /// The glyph *is* the state: the active bell is a full azan (banner and
  /// recitation), the plain bell is the banner without any sound, and the
  /// crossed one means nothing at all. Tapping no longer walks the ring
  /// azan → silent → off on its own — a silent tap is exactly the moment a
  /// reader ends up with an azaan they never chose. Instead it *asks*, and
  /// the reader answers the question the bell owes them: which of the three
  /// they want, named in their own words.
  ///
  /// The re-arm rides one debounce, because every schedule pass retires all
  /// the alarms and builds them again, and that is not work worth doing
  /// per tap.
  Widget _bell(String key) {
    final String mode = AppSettings.instance.bellModeFor(key);
    final IconData glyph = switch (mode) {
      kBellAzan => Icons.notifications_active_outlined,
      kBellSilent => Icons.notifications_outlined,
      _ => Icons.notifications_off_outlined,
    };
    return InkWell(
      onTap: () => _askBell(key),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Icon(
          glyph,
          size: 17,
          color: mode == kBellOff ? NoorColors.muted : NoorColors.emeraldDeep,
        ),
      ),
    );
  }

  /// Asks which of the three the reader wants, and arms exactly that.
  ///
  /// Dismissing the question without picking — the backdrop, the gesture,
  /// nothing — changes nothing at all, and the bell keeps the state it had.
  /// The re-arm rides the same debounce the old tap-walk used, because every
  /// schedule pass retires all the alarms and builds them again, and that is
  /// not work worth doing per tap.
  Future<void> _askBell(String key) async {
    final String? picked = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => _bellDialog(context, key),
    );
    if (picked == null || !mounted) return;
    AppSettings.instance.setBellMode(key, picked);

    _rescheduleTimer?.cancel();
    _rescheduleTimer = Timer(const Duration(milliseconds: 400), _reschedule);
  }

  /// The three answers, named the way the reader says them: **Azaan** rings
  /// and shows a card, **Mute** shows the card without a sound, **Band** does
  /// neither. Whatever is already in force is ticked, so the dialog opens as
  /// a question about the present rather than a command over the future.
  Widget _bellDialog(BuildContext context, String key) {
    final String current = AppSettings.instance.bellModeFor(key);
    final List<Widget> children = <Widget>[
      _bellChoice(context, kBellAzan, 'Azaan', Icons.notifications_active_outlined,
          'The card and the recitation both', current),
      _bellChoice(context, kBellSilent, 'Mute', Icons.notifications_outlined,
          'The card, without any sound', current),
      _bellChoice(context, kBellOff, 'Band', Icons.notifications_off_outlined,
          'Nothing at all, not even the card', current),
    ];

    return AlertDialog(
      backgroundColor: NoorColors.cream,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      title: Text(
        '${prayerByKey(key).label} bell',
        style: GoogleFonts.outfit(fontSize: 16, fontWeight: FontWeight.w700, color: NoorColors.ink),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            'Should the Azaan play for this prayer?',
            style: GoogleFonts.outfit(fontSize: 13, color: NoorColors.onGlassMuted),
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            'Not now — keep it as it is',
            style: GoogleFonts.outfit(fontSize: 13, fontWeight: FontWeight.w700, color: NoorColors.muted),
          ),
        ),
      ],
    );
  }

  /// One answer of the bell's: its name, what it means in one line, and the
  /// check that marks the one already in force. Tapping pops with the mode,
  /// which is exactly what `setBellMode` takes.
  Widget _bellChoice(
    BuildContext context,
    String mode,
    String name,
    IconData glyph,
    String note,
    String current,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(glyph, size: 22, color: NoorColors.emeraldDeep),
        title: Text(
          name,
          style: GoogleFonts.outfit(fontSize: 16, fontWeight: FontWeight.w700, color: NoorColors.ink),
        ),
        subtitle: Text(
          note,
          style: GoogleFonts.outfit(fontSize: 12.5, color: NoorColors.onGlassMuted),
        ),
        trailing: mode == current
            ? const Icon(Icons.check_circle_rounded, size: 22, color: NoorColors.emeraldDeep)
            : null,
        onTap: () => Navigator.of(context).pop(mode),
      ),
    );
  }

  /// Re-arms both schedules — the calculated reminders and the Jamaat-time
  /// favourite alerts — since each of them skips a prayer whose bell is
  /// off, and both re-read the per-prayer sound for the ones still on.
  Future<void> _reschedule() async {
    try {
      await NotificationService.scheduleAzan(latitude: _lat, longitude: _lng);
      await NotificationService.scheduleFavouriteAlerts();
    } catch (error) {
      debugPrint('Noor ▸ bell re-arm failed: $error');
    }
  }

  /// Names whose times the rows below are quoting, and opens the chooser.
  Widget _boardChip(BuildContext context) {
    final Masjid? board = widget.board;
    if (board == null) return const SizedBox.shrink();

    return InkWell(
      onTap: () => unawaited(_chooseBoard(context)),
      borderRadius: BorderRadius.circular(30),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: NoorColors.onGlassChip,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: NoorColors.gold.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.mosque_outlined, size: 13, color: NoorColors.emeraldDeep),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'Jamaat times from ${board.name.isEmpty ? 'Unnamed Masjid' : board.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.outfit(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: NoorColors.ink,
                ),
              ),
            ),
            const Icon(Icons.arrow_drop_down, size: 16, color: NoorColors.emeraldDeep),
          ],
        ),
      ),
    );
  }

  /// Asks which starred masjid this card should quote.
  ///
  /// Offered for every starred masjid plus the automatic answer, so a choice
  /// made on a whim is as easy to undo as it was to make.
  Future<void> _chooseBoard(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: NoorColors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext sheetContext) {
        final String current = AppSettings.instance.todayBoardId;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 2),
                child: Text(
                  'Which masjid’s times on this card?',
                  style: GoogleFonts.outfit(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: NoorColors.ink,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Text(
                  'Pick the starred board this card quotes. The small line in '
                  'each cell stays the calculated Awwal time either way.',
                  style: GoogleFonts.outfit(
                    fontSize: 11.5,
                    color: NoorColors.muted,
                    height: 1.45,
                  ),
                ),
              ),
              _boardOption(
                icon: Icons.my_location,
                title: 'Nearest starred masjid',
                subtitle: 'Let the nearby list decide',
                selected: current.isEmpty,
                onTap: () {
                  AppSettings.instance.setTodayBoard('');
                  Navigator.of(sheetContext).pop();
                },
              ),
              for (final Masjid m in widget.boards)
                _boardOption(
                  icon: Icons.mosque_outlined,
                  title: m.name.isEmpty ? 'Unnamed Masjid' : m.name,
                  subtitle:
                      m.address.isEmpty ? 'Address not available yet' : m.address,
                  selected: current == m.id,
                  onTap: () {
                    AppSettings.instance.setTodayBoard(m.id);
                    Navigator.of(sheetContext).pop();
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Widget _boardOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
        child: Row(
          children: <Widget>[
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: NoorColors.onGlassChip,
                borderRadius: BorderRadius.circular(11),
                border:
                    Border.all(color: NoorColors.gold.withValues(alpha: 0.5)),
              ),
              child: Icon(icon, size: 17, color: NoorColors.emeraldDeep),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.outfit(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: NoorColors.ink,
                    ),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.outfit(
                      fontSize: 11,
                      color: NoorColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              selected
                  ? Icons.check_circle_outlined
                  : Icons.radio_button_unchecked,
              size: 20,
              color: selected
                  ? NoorColors.emeraldDeep
                  : NoorColors.muted.withValues(alpha: 0.5),
            ),
          ],
        ),
      ),
    );
  }

  _Entry? _nextEntry(LocalPrayerTimes day, DateTime now) {
    for (final _Entry e in _entries) {
      if (e.time.isAfter(now)) return e;
    }
    // Past Isha — countdown rolls over to tomorrow's Fajr.
    return _Entry('fajr', 'Fajr (tomorrow)', day.fajrTomorrow, Icons.dark_mode_outlined);
  }

  @override
  Widget build(BuildContext context) {
    final _Entry? next = _next;
    final AppSettings settings = AppSettings.instance;

    final BorderRadius r = BorderRadius.circular(NoorGlass.radius);
    final NoorLook look = NoorGlass.of(context);

    // The reference's panel: plain white on the cream page, no glass and no
    // pattern — the icon chips and the type do all the work.
    return Container(
      decoration: BoxDecoration(borderRadius: r, boxShadow: look.shadow),
      child: ClipRRect(
        borderRadius: r,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: NoorColors.white,
            borderRadius: r,
            border: Border.all(color: look.border, width: 1),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // ------------------------------------------------- header
                // Whose place the times below are for — the pin line the
                // reference carries at the head of the list.
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(Icons.location_on_outlined,
                          size: 16, color: NoorColors.emeraldDeep),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            widget.areaName.isEmpty
                                ? 'Your location'
                                : widget.areaName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.outfit(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: NoorColors.ink,
                            ),
                          ),
                          Text(
                            'Prayer times for your location',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.outfit(
                              fontSize: 10.5,
                              color: NoorColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // The WhatsApp forward the family group expects, one tap
                    // from the very card that prints the five times.
                    IconButton(
                      tooltip: 'Share times',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 34, minHeight: 34),
                      onPressed: () => shareTodayTimes(
                        latitude: _lat,
                        longitude: _lng,
                        areaName: widget.areaName,
                        board: widget.board,
                      ),
                      icon: const Icon(Icons.share_outlined,
                          size: 19, color: NoorColors.emeraldDeep),
                    ),
                  ],
                ),

                // Whose times the rows below are quoting — without it the two
                // clocks in every row are anonymous.
                if (widget.board != null && widget.boards.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  _boardChip(context),
                ],

                const SizedBox(height: 8),

                // --------------------------------------------------- rows
                if (_entries.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 30),
                    child: Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: NoorColors.emeraldDeep,
                        ),
                      ),
                    ),
                  )
                else
                  for (final _Entry e in _entries) _row(e, next, settings),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// One prayer: chip, name, clock — and the board's Jamaat over the Awwal
  /// where the board answers, with the mute bell at the end.
  Widget _row(_Entry e, _Entry? next, AppSettings settings) {
    final String jamaat = _jamaat(e.key);
    final bool isNext = next != null && next.label == e.label;

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: isNext ? NoorColors.emerald.withValues(alpha: 0.10) : null,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: NoorColors.onGlassChip,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(e.icon, size: 17, color: NoorColors.emeraldDeep),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              e.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.outfit(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: NoorColors.ink,
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // Jamaat leads when the board answers; the calculated time
              // keeps the big line only where it does not (Sunrise, a blank
              // cell).
              Text(
                jamaat.isEmpty
                    ? settings.format(e.time)
                    : settings.formatClockShort(jamaat),
                maxLines: 1,
                style: GoogleFonts.outfit(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: NoorColors.ink,
                  letterSpacing: 0.2,
                ),
              ),
              if (jamaat.isNotEmpty)
                // …and the Awwal time stays right there beneath it, small.
                Text(
                  settings.formatShort(e.time),
                  maxLines: 1,
                  style: GoogleFonts.outfit(
                    fontSize: 9,
                    color: NoorColors.muted,
                  ),
                ),
              // The *official* end — the calculated clock, never the board's
              // Jamaat cell. Sunrise is not a prayer and ends nothing, so
              // `officialEnd` leaves it without this line.
              if (e.end != null)
                Text(
                  'Ends ${settings.format(e.end!)}',
                  maxLines: 1,
                  style: GoogleFonts.outfit(
                    fontSize: 10,
                    color: NoorColors.muted,
                  ),
                ),
            ],
          ),
          SizedBox(
            width: 26,
            // Sunrise is not a prayer and carries no notification, so its
            // end stays deliberately empty — the fixed-width spacer is what
            // keeps every clock on the same line down the card.
            child: e.key == 'sunrise' ? null : _bell(e.key),
          ),
        ],
      ),
    );
  }
}

class _Entry {
  _Entry(this.key, this.label, this.time, this.icon, [this.end]);

  /// Prayer key (`fajr` …) — matches the keys in [LocalPrayerTimes].
  final String key;
  final String label;
  final DateTime time;
  final IconData icon;

  /// The official end of this prayer's time — the calculated start of
  /// whatever follows (see [LocalPrayerTimes.officialEnd]). `null` for
  /// Sunrise, which ends nothing.
  final DateTime? end;
}
