import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_look.dart';
import 'app_settings.dart';
import 'main.dart';
import 'screens/home_extras.dart' show shareTodayTimes;
import 'services/azaan_alarm.dart';
import 'services/azan_player.dart';

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

    _armReschedule();
  }

  /// Re-arms on a debounce, after whichever change just landed.
  ///
  /// Every schedule pass retires all the alarms and builds them again, so
  /// five chips tapped in a row must cost one pass, not five — the same
  /// reason the bell dialog and Settings both coalesce. A card already gone
  /// has cancelled its own timer, and arming one now would leave it firing
  /// against a tree that is no longer there.
  void _armReschedule() {
    if (!mounted) return;
    _rescheduleTimer?.cancel();
    _rescheduleTimer = Timer(const Duration(milliseconds: 400), _reschedule);
  }

  /// The two choices that decide what the reader hears and when: which Azaan
  /// clip, and how long before the prayer it rings.
  ///
  /// Settings holds both, but the reader who has just read the times is the
  /// one who wants to change them — so the same two answers live here too,
  /// applied the moment they are picked. Both land exactly as Settings' own
  /// do: a new clip rebuilds the notification channel (Android freezes a
  /// channel's sound the instant it is created) before it is previewed, an
  /// offset is filed for every prayer, and either re-arms through
  /// [_armReschedule].
  Future<void> _openAzaanSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: NoorColors.cream,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (BuildContext context) => SafeArea(
        child: _AzaanAlertSheet(onChanged: _armReschedule),
      ),
    );
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
                    // What the reader hears, and when — the two choices that
                    // used to live only in Settings, one tap from the card
                    // that prints the times.
                    IconButton(
                      tooltip: 'Azaan sound & timing',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 34, minHeight: 34),
                      onPressed: () => unawaited(_openAzaanSheet()),
                      icon: const Icon(Icons.tune_outlined,
                          size: 19, color: NoorColors.emeraldDeep),
                    ),
                    const SizedBox(width: 2),
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

/// What the wocard's tune button opens: which Azaan clip, and how long before
/// the prayer it rings.
///
/// Every row is an answer rather than a form — there is no Save to press,
/// because Settings has no Save either, and a reader who opened this from the
/// times card wants the *next* reminder changed, not a dialog confirmed. It
/// listens to [AzanPlayer] on its own: a modal route does not rebuild when
/// the card behind it does, so without that listener a row whose preview had
/// ended would keep wearing the stop icon until somebody tapped it again.
/// Leaving takes the preview with it — this sheet started it, and the only
/// button that could stop it lives inside it.
class _AzaanAlertSheet extends StatefulWidget {
  const _AzaanAlertSheet({required this.onChanged});

  /// Called after a pick that changes what will be armed; the card turns it
  /// into one debounced reschedule.
  final VoidCallback onChanged;

  @override
  State<_AzaanAlertSheet> createState() => _AzaanAlertSheetState();
}

class _AzaanAlertSheetState extends State<_AzaanAlertSheet> {
  /// Why nothing sounded, in one line — present only until something does.
  ///
  /// Kept inside the sheet rather than as a snackbar: a snackbar lands on the
  /// Home scaffold *behind* this route, where the reader who just tapped
  /// cannot see it.
  String? _note;

  @override
  void initState() {
    super.initState();
    AzanPlayer.instance.addListener(_onPlaybackChanged);
  }

  void _onPlaybackChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    AzanPlayer.instance.removeListener(_onPlaybackChanged);
    unawaited(AzanPlayer.instance.stop());
    super.dispose();
  }

  /// Files [minutes] against [prayer] alone and keeps the Jamaat source's own
  /// switch in step. Settings' chips do that second half only while the mode
  /// is "Only at my masjid's Jamaat time"; here the mode is not on show, so
  /// the pair is written whichever is in force and survives a later change
  /// of it.
  void _pickOffset(String prayer, int minutes) {
    final AppSettings settings = AppSettings.instance;
    settings.setNotifyOffset(prayer, minutes);
    settings.setFavMode(prayer, minutes < 0 ? kFavModeAt : kFavModeOffset);
    setState(() {});
    widget.onChanged();
  }

  /// Asks for a number no chip offers and files it against [prayer].
  ///
  /// The reader who knows exactly how long before Fajr they want the knock —
  /// seven minutes, not one of the four the chips carry — has always been
  /// able to store it from the owner's config but never from the phone in
  /// their hand. This is that door.
  Future<void> _askCustomOffset(String prayer) async {
    final TextEditingController controller = TextEditingController();
    final int? picked = await showDialog<int>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: NoorColors.cream,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Text(
          '${prayerByKey(prayer).label} — minutes before',
          style: GoogleFonts.outfit(
              fontSize: 16, fontWeight: FontWeight.w700, color: NoorColors.ink),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            hintText: 'e.g. 7',
            filled: true,
            fillColor: NoorColors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(13),
              borderSide: BorderSide(
                  color: NoorColors.gold.withValues(alpha: 0.6)),
            ),
          ),
          style: GoogleFonts.outfit(fontSize: 15, color: NoorColors.ink),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Cancel',
                style: GoogleFonts.outfit(
                    fontSize: 13, fontWeight: FontWeight.w700, color: NoorColors.muted)),
          ),
          TextButton(
            onPressed: () {
              final int minutes = int.tryParse(controller.text.trim()) ?? -999;
              // `-1` is "At time", so a real number starts at 0; past two
              // hours is a typo rather than a reminder.
              if (minutes < 0 || minutes > 120) return;
              Navigator.of(context).pop(minutes);
            },
            child: Text('Set',
                style: GoogleFonts.outfit(
                    fontSize: 13, fontWeight: FontWeight.w700, color: NoorColors.emeraldDeep)),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    _pickOffset(prayer, picked);
  }

  /// Selects a chip only when *this prayer* already answers with it.
  bool _offsetOn(String prayer, int minutes) =>
      AppSettings.instance.notifyOffsetFor(prayer) == minutes;

  /// The offered offsets for [prayer] — the four the chips carry, no more.
  ///
  /// Settings folds a live value the chips have never heard of into its own
  /// row, because a chip that is not drawn cannot show that it is in force.
  /// This sheet already has a door for exactly that case: a value outside
  /// these four is a *custom* one, and the Custom… chip wears the number
  /// itself. Folding it in here as well would print "7 min" twice on one row
  /// — once as a chip the reader never picked, once as the answer they did.
  List<int> _offsetChoices(String prayer) => kNotifyOffsets;

  /// Which clock the offset is measured against. Settings says it under a
  /// mode dropdown this sheet does not carry, so the sentence has to carry
  /// the mode instead — otherwise "15 min" is fifteen minutes before
  /// nothing in particular.
  String get _whenCaption {
    switch (AppSettings.instance.azaanTiming) {
      case kAzaanTimingAwwalOnly:
        return 'How long before your calculated prayer time the reminder rings.';
      case kAzaanTimingBoth:
        return 'How long before each of the two times the reminder rings.';
      case kAzaanTimingNone:
        return 'No Azaan is armed in Settings, so nothing will ring — this '
            'pick is kept for the day you switch it back on.';
      case kAzaanTimingJamaatOnly:
      default:
        return 'How long before your favourite masjid’s Jamaat time the '
            'reminder rings.';
    }
  }

  /// Picks a clip, rebuilds the channel around it when it changed, then
  /// rehearses it — in that order, because a preview of the *old* sound is
  /// how a reader ends up trusting a choice that did not land.
  Future<void> _pickSound(AzanSound sound) async {
    // The custom row has no [AzanSound] of its own — its bytes are a file on
    // disk and its preview opens a path, not a resource id — so it takes its
    // own door rather than falling through a lookup that would answer null.
    if (sound.key == kCustomAzanKey) {
      await _pickCustomFile();
      return;
    }
    final AppSettings settings = AppSettings.instance;
    final bool changed = settings.azanSound != sound.key;
    settings.setAzanSound(sound.key);
    if (changed) {
      // Android freezes a channel's sound the instant the channel is
      // created, so a new pick only lands once the old channel has been
      // dropped and rebuilt around it.
      await NotificationService.applyAzanChannel();
      widget.onChanged();
    }
    if (!mounted) return;
    setState(() => _note = null);

    // "None (silent)" has nothing to rehearse — and answering it with the
    // built-in Azaan was the whole of the complaint: a reader who had just
    // chosen *silence* heard a full recitation the moment the row was
    // tapped. The row's only honest job is to file the choice and quiet
    // whatever an earlier row started, which is the one sound "silent" can
    // make without contradicting itself.
    if (sound.key == 'silent') {
      // The note lands first, on its own: the row's answer is the sentence,
      // and a sentence the reader has to wait on a platform round-trip for
      // is a sentence that can go missing when that round-trip does.
      setState(() {
        _note = '“None (silent)” is what your reminders will use from now on — '
            'no Azaan at prayer time, and none on this tap.';
      });
      unawaited(AzanPlayer.instance.stop());
      return;
    }

    final bool started = await AzanPlayer.instance.preview(sound.key);
    if (!mounted) return;
    setState(() {
      if (!started) {
        _note = 'Your phone is on silent or vibrate, so nothing played — that '
            'is the Azaan staying quiet exactly as your reminders will. Turn '
            'the ringer up to hear it.';
      }
    });
  }

  /// Opens the phone's file picker, copies the chosen clip into the one slot
  /// the alarm player reads, points every prayer at it and rehearses it.
  ///
  /// The copy is what makes the pick survive: a `content://` URI's grant
  /// lapses the moment the reader's phone sleeps, and the alarm fires with
  /// the app not running — so the bytes are copied into the app-private
  /// directory and the stored path is what every future ring opens. The
  /// preview plays the *copied* file, not the picked one, because that is
  /// exactly what tomorrow's alarm will play.
  Future<void> _pickCustomFile() async {
    final AppSettings settings = AppSettings.instance;
    final String? path = await AzaanAlarm.pickAudioFile();
    if (path == null || !mounted) return;

    settings.setCustomAzanPath(path);
    // The profile's clip is one global choice — the bells only gate *whether*
    // a prayer recites, not what it recites — so pointing the pick at the
    // profile is pointing every praying bell at this file.
    settings.setAzanSound(kCustomAzanKey);
    // Android freezes a channel's sound the instant it is created; the
    // banner stays silent either way, so this is the same rebuild the
    // built-in rows make rather than anything the custom clip needs.
    await NotificationService.applyAzanChannel();
    if (!mounted) return;
    setState(() => _note = null);
    widget.onChanged();

    final bool started = await AzanPlayer.instance.previewFile(path);
    if (!mounted) return;
    setState(() {
      if (!started) {
        _note = 'Your phone is on silent or vibrate, so nothing played — that '
            'is the Azaan staying quiet exactly as your reminders will. Turn '
            'the ringer up to hear it.';
      }
    });
  }

  Widget _heading(String text) => Text(
        text,
        style: GoogleFonts.outfit(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: NoorColors.ink,
        ),
      );

  Widget _hint(String text) => Text(
        text,
        style: GoogleFonts.outfit(
          fontSize: 11.5,
          color: NoorColors.onGlassMuted,
          height: 1.5,
        ),
      );

  /// One clip: which one is in force, and the play/stop icon that answers it.
  ///
  /// The custom row is the one row whose label is *not* a constant: it names
  /// the file the reader chose, so a second pick is visibly a replacement.
  Widget _soundRow(AzanSound sound) {
    final bool selected = AppSettings.instance.azanSound == sound.key;
    final bool playing = AzanPlayer.instance.playingKey == sound.key;
    final String label = sound.key == kCustomAzanKey
        ? _customLabel(AppSettings.instance.customAzanPath)
        : sound.label;

    return InkWell(
      onTap: () => unawaited(_pickSound(sound)),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          children: <Widget>[
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 19,
              color: selected ? NoorColors.emeraldDeep : NoorColors.muted,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.outfit(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: NoorColors.ink,
                ),
              ),
            ),
            // The one row with nothing to play wears the mute sign instead of
            // a play button: a play icon promising a sound on a row whose
            // whole answer is silence is the same lie the preview used to
            // tell, only drawn this time.
            Icon(
              sound.key == 'silent'
                  ? Icons.volume_off_outlined
                  : playing
                      ? Icons.stop_circle_outlined
                      : Icons.play_circle_outline,
              size: 22,
              color: NoorColors.gold,
            ),
          ],
        ),
      ),
    );
  }

  /// The custom row's own label: the file's name, or the door that opens one.
  ///
  /// The name itself is [customAzanName] — the same answer the ringtone
  /// export titles its entry with, so the row in the sheet and the row in
  /// the phone's own list are recognisably one clip.
  String _customLabel(String path) {
    if (path.isEmpty) return 'Choose a file… (your own Azaan)';
    return customAzanName(path);
  }

  /// A file that was picked once and has since gone missing — an SD card
  /// pulled, a download deleted — must not keep wearing its own name as if
  /// it were still there.
  bool get _customMissing {
    final String path = AppSettings.instance.customAzanPath;
    return path.isEmpty || !File(path).existsSync();
  }

  /// The reader's own clip, sitting last so the five built-in answers stay
  /// where a returning reader left them.
  Widget _customSoundRow() {
    final bool selected =
        AppSettings.instance.azanSound == kCustomAzanKey && !_customMissing;
    final bool playing = AzanPlayer.instance.playingKey == kCustomAzanKey;

    return InkWell(
      onTap: () => unawaited(_pickCustomFile()),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          children: <Widget>[
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 19,
              color: selected ? NoorColors.emeraldDeep : NoorColors.muted,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _customMissing
                    ? 'Choose a file… (your own Azaan)'
                    : _customLabel(AppSettings.instance.customAzanPath),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.outfit(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: NoorColors.ink,
                ),
              ),
            ),
            Icon(
              playing ? Icons.stop_circle_outlined : Icons.play_circle_outline,
              size: 22,
              color: NoorColors.gold,
            ),
          ],
        ),
      ),
    );
  }

  /// One of the offset choices for [prayer], cut the way Settings cuts its
  /// own chips.
  Widget _offsetChip(String prayer, int minutes) {
    final bool selected = _offsetOn(prayer, minutes);
    return Expanded(
      child: InkWell(
        onTap: () => _pickOffset(prayer, minutes),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? NoorColors.emerald : NoorColors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color:
                  selected ? NoorColors.emerald : NoorColors.gold.withValues(alpha: 0.6),
            ),
          ),
          child: Text(
            notifyOffsetChipLabel(minutes),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.outfit(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: NoorColors.ink,
            ),
          ),
        ),
      ),
    );
  }

  /// The last chip of every row: the door to a number no chip carries.
  ///
  /// Lit whenever [prayer]'s live offset is one of the four — a custom
  /// number is a *kept* answer, and a reader returning to the row should see
  /// which door they came through.
  Widget _customOffsetChip(String prayer) {
    final int current = AppSettings.instance.notifyOffsetFor(prayer);
    final bool lit = current >= 0 && !kNotifyOffsets.contains(current);
    return Expanded(
      child: InkWell(
        onTap: () => unawaited(_askCustomOffset(prayer)),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: lit ? NoorColors.gold.withValues(alpha: 0.35) : NoorColors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: lit ? NoorColors.gold : NoorColors.gold.withValues(alpha: 0.6),
            ),
          ),
          child: Text(
            lit ? '$current min' : 'Custom…',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.outfit(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: NoorColors.ink,
            ),
          ),
        ),
      ),
    );
  }

  /// One prayer's whole timing answer: its name and one row of chips.
  Widget _offsetRow(String prayer) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            prayerByKey(prayer).label,
            style: GoogleFonts.outfit(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: NoorColors.onGlass,
            ),
          ),
          const SizedBox(height: 5),
          Row(
            children: <Widget>[
              for (final MapEntry<int, int> choice
                  in _offsetChoices(prayer).asMap().entries) ...<Widget>[
                if (choice.key > 0) const SizedBox(width: 5),
                _offsetChip(prayer, choice.value),
              ],
              const SizedBox(width: 5),
              _customOffsetChip(prayer),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      // Hugged to what it holds and clipped by its ceiling: the scroll view
      // sizes to its own content, so a short sheet ends on its last line
      // rather than on a band of empty cream, and one taller than the window
      // still scrolls — which is what this is for on a short phone.
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Center(
            child: Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: NoorColors.gold.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // --------------------------------------------------- what plays
          _heading('What should play'),
          const SizedBox(height: 4),
          for (final AzanSound sound in kAzanSounds) _soundRow(sound),
          // The reader's own clip last: five built-in answers stay where a
          // returning reader left them, and the door to their own file is
          // still one line down rather than a screen away.
          const SizedBox(height: 2),
          _customSoundRow(),
          if (_note != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4, right: 4),
              child: _hint(_note!),
            ),

          const SizedBox(height: 14),

          // ------------------------------------------------- when it rings
          _heading('When it rings'),
          const SizedBox(height: 4),
          _hint(_whenCaption),
          const SizedBox(height: 10),
          for (final String prayer in kNotifiablePrayers)
            _offsetRow(prayer),
          const SizedBox(height: 2),
          _hint(
            'Each prayer sets its own minutes. “Custom…” lets you type any '
            'number. Each row’s own bell still decides whether it rings.',
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
