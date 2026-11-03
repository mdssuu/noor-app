import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
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
/// a board's Jamaat cell never moves. Friday changes the noon row, and only
/// the noon row: it wears Jummah's own name and quotes the board's Juma cell
/// as its Jamaat, while the Awwal beneath stays the calculated Dhuhr it has
/// always been. The makruh (Zawal) half hour is not
/// repeated here: it stands as its own big line at the top of the hero, and
/// only while it runs. The bell at the end of a row is a three-state switch
/// — azan, silent (banner without sound), off — and `off` is the same gate
/// the Settings switch holds.
///
/// The bell does not walk that ring on its own; it opens a dialog the reader
/// answers, and only a real answer moves the bell. That dialog is also where
/// *this prayer's* own answers live: which clock may ring at all (the
/// masjid's Jamaat, the calculated Awwal, both, or neither), and how long
/// before that clock the reminder knocks — each one prayer at a time, which
/// is the only scope either has ever really had. The clip itself stays in
/// Settings — it is one global answer, and a per-prayer door for it would
/// promise a choice no per-prayer alarm can keep.
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
    this.debugNow,
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

  /// Pins "now" for a test.
  ///
  /// The card reads the weekday off this clock to decide whether noon is
  /// Jummah, which no test can reach without it; production passes nothing
  /// and reads the real one.
  @visibleForTesting
  final DateTime? debugNow;

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
    final DateTime now = widget.debugNow ?? DateTime.now();
    final String boardId = widget.board?.id ?? '';
    if (boardId.isEmpty) {
      // No board quoted — Jummah follows the same rule as other prayers.
    }
    final LocalPrayerTimes day =
        settings.compute(latitude: _lat, longitude: _lng, day: now);

    setState(() {
      _entries = <_Entry>[
        _Entry('fajr', 'Fajr', day.times['fajr']!,
            Icons.dark_mode_outlined, day.officialEnd('fajr')),
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
        // The big line is the board's Juma cell (through [_jamaat]). Awwal
        // and Ends are not shown for Jummah.
        _Entry('juma', prayerByKey('juma').label, day.times['dhuhr']!,
            prayerByKey('juma').icon),
      ];
      _next = _nextEntry(day, now);
    });
  }

  /// The board's own Jamaat time for [key], or `''` when it has none.
  ///
  /// For `juma` the board's Juma cell is used. If missing, the row falls back
  /// to the calculated Dhuhr clock — never to the board's *daily* noon cell:
  /// a board that never answered the Friday question does not get its
  /// everyday answer dressed up as the Jummah time.
  String _jamaat(String key) {
    final Masjid? board = widget.board;
    if (board == null) return '';

    final String stored = board.timeFor(key);
    if (NotificationService.parseClockTime(stored) != null) {
      return stored;
    }
    return '';
  }

  /// The name a row carries — Jummah keeps its own name, and the five daily
  /// prayers keep theirs on every weekday, Friday included.
  String _labelFor(String key) => prayerByKey(key).label;

  /// The three-state bell at the end of a prayer's row.
  ///
  /// The glyph *is* the state: the active bell is a full azan (banner and
  /// recitation), the plain bell is the banner without the recitation, and the
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

  /// Asks which of the three the reader wants, and arms exactly that — plus
  /// how long before *this* prayer the reminder rings.
  ///
  /// Every answer files the moment it is picked, so there is no Save to
  /// press: a reader who came here from the times card wants the *next*
  /// reminder changed, not a form confirmed. Dismissing the dialog without
  /// picking — the backdrop, the gesture, Close — changes nothing at all,
  /// and the bell keeps the state it had.
  Future<void> _askBell(String key) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => _bellDialog(context, key),
    );
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

  /// The three answers, named the way the reader says them: **Azaan** rings
  /// and shows a card, **Mute** shows the card without a sound, **Band** does
  /// neither. Whatever is already in force is ticked, so the dialog opens as
  /// a question about the present rather than a command over the future.
  Widget _bellDialog(BuildContext context, String key) {
    return StatefulBuilder(
      builder: (BuildContext context, StateSetter setDialog) {
        final AppSettings settings = AppSettings.instance;
        final String current = settings.bellModeFor(key);
        final int offset = settings.notifyOffsetFor(key);
        final String boardId = widget.board?.id ?? '';
        final String currentClip = settings.azanSoundForMasjid(boardId);
        final bool ownMissing = settings.customAzanPath.isEmpty ||
            !File(settings.customAzanPath).existsSync();

        return AlertDialog(
          backgroundColor: NoorColors.cream,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          title: Text(
            '${_labelFor(key)} bell',
            style: GoogleFonts.outfit(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: NoorColors.ink),
          ),
          content: SizedBox(
            width: 340,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Should the Azaan play for this prayer?',
                    style: GoogleFonts.outfit(
                        fontSize: 13, color: NoorColors.onGlassMuted),
                  ),
                  const SizedBox(height: 8),
                  _bellChoice(
                    kBellAzan,
                    'Azaan',
                    Icons.notifications_active_outlined,
                    'The card and the recitation both',
                    current,
                    () {
                      settings.setBellMode(key, kBellAzan);
                      // The card the Azaan arrives with is a notification: a
                      // reader who has switched those off would hear the
                      // recitation and see nothing. Ask here, where the
                      // promise is made, and name the switch if it stays off.
                      unawaited(_ensureNotifications());
                      _armReschedule();
                      setDialog(() {});
                    },
                  ),
                  _bellChoice(
                    kBellSilent,
                    'Mute',
                    Icons.notifications_outlined,
                    'The card, without any sound',
                    current,
                    () {
                      settings.setBellMode(key, kBellSilent);
                      _armReschedule();
                      setDialog(() {});
                    },
                  ),
                  _bellChoice(
                    kBellOff,
                    'Band',
                    Icons.notifications_off_outlined,
                    'Nothing at all, not even the card',
                    current,
                    () {
                      settings.setBellMode(key, kBellOff);
                      _armReschedule();
                      setDialog(() {});
                    },
                  ),

                  const SizedBox(height: 14),

                  // ------------------------------------------ which clock
                  // The mode Settings' old dropdown asked for, asked of the
                  // prayer whose dialog this is. Four answers do not fit one
                  // line inside a dialog this wide, so they take two rows of
                  // two — and the caption underneath reads the pick back in
                  // the reader's own terms rather than a key.
                  Text(
                    'When will the Azaan play?',
                    style: GoogleFonts.outfit(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: NoorColors.ink,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _azaanTimingCaption(settings.azaanTimingFor(key)),
                    style: GoogleFonts.outfit(
                      fontSize: 11.5,
                      color: NoorColors.onGlassMuted,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: <Widget>[
                      _azaanTimingChip(
                          key, kAzaanTimingJamaatOnly, 'Jamaat time',
                          setDialog),
                      const SizedBox(width: 5),
                      _azaanTimingChip(
                          key, kAzaanTimingAwwalOnly, 'Awwal time', setDialog),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: <Widget>[
                      _azaanTimingChip(
                          key, kAzaanTimingBoth, 'Both times', setDialog),
                      const SizedBox(width: 5),
                      _azaanTimingChip(key, kAzaanTimingNone, 'Off', setDialog),
                    ],
                  ),

                  const SizedBox(height: 14),

                  // ------------------------------------------------- clip
                  // The voice belongs to the masjid whose row this bell sits
                  // on, not to the whole profile: two masjids across the road
                  // may recite two different Azaans, and this is where each
                  // one is chosen. With no board quoted there is no masjid to
                  // file it under, so the choice becomes the profile's own.
                  Text(
                    boardId.isEmpty
                        ? 'Azaan clip'
                        : 'Azaan clip for this masjid',
                    style: GoogleFonts.outfit(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: NoorColors.ink,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    boardId.isEmpty
                        ? 'Used by every prayer until a masjid has a clip '
                            'of its own.'
                        : 'Only this masjid’s reminders recite it. Another '
                            'masjid can keep its own.',
                    style: GoogleFonts.outfit(
                      fontSize: 11.5,
                      color: NoorColors.onGlassMuted,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (final AzanSound sound in kAzanSounds)
                    _clipChoice(
                      clipKey: sound.key,
                      name: sound.label,
                      current: currentClip,
                      onTap: () => unawaited(_pickClip(sound.key, setDialog)),
                    ),
                  _clipChoice(
                    clipKey: kCustomAzanKey,
                    name: ownMissing
                        ? 'Choose a file… (your own Azaan)'
                        : customAzanName(settings.customAzanPath),
                    current: ownMissing ? '' : currentClip,
                    onTap: () => unawaited(_chooseOwnClip(setDialog)),
                  ),
                  if (defaultTargetPlatform == TargetPlatform.android)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => unawaited(_exportRingtone(currentClip)),
                        icon: const Icon(Icons.music_note_outlined,
                            size: 16, color: NoorColors.emeraldDeep),
                        label: Text(
                          'Add to phone ringtone list',
                          style: GoogleFonts.outfit(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: NoorColors.emeraldDeep,
                          ),
                        ),
                      ),
                    ),

                  const SizedBox(height: 14),

                  // ------------------------------------------------ when
                  Text(
                    'When it rings',
                    style: GoogleFonts.outfit(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: NoorColors.ink,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _whenCaption(key),
                    style: GoogleFonts.outfit(
                      fontSize: 11.5,
                      color: NoorColors.onGlassMuted,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  // Six answers do not fit one line inside a dialog this
                  // wide, so they take two rows of three — the same chips
                  // Settings carries, on this prayer alone.
                  Row(
                    children: <Widget>[
                      _offsetChip(key, kNotifyOffsets[0], offset, setDialog),
                      const SizedBox(width: 5),
                      _offsetChip(key, kNotifyOffsets[1], offset, setDialog),
                      const SizedBox(width: 5),
                      _offsetChip(key, kNotifyOffsets[2], offset, setDialog),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: <Widget>[
                      _offsetChip(key, kNotifyOffsets[3], offset, setDialog),
                      const SizedBox(width: 5),
                      _offsetChip(key, kNotifyOffsets[4], offset, setDialog),
                      const SizedBox(width: 5),
                      _customOffsetChip(key, offset, setDialog),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Each prayer keeps its own minutes, so this pick is for '
                    'this bell alone. The clip above belongs to this masjid '
                    'and plays from every bell you switch to Azaan. '
                    'Silence is still yours: on silent or vibrate nothing '
                    'rings.',
                    style: GoogleFonts.outfit(
                      fontSize: 11,
                      color: NoorColors.onGlassMuted,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                'Close',
                style: GoogleFonts.outfit(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: NoorColors.muted),
              ),
            ),
          ],
        );
      },
    );
  }

  /// One answer of the bell's: its name, what it means in one line, and the
  /// check that marks the one already in force. Tapping files it at once
  /// *without* closing the dialog — the reader can still read what the tick
  /// moved to, and reach the timing chips beneath it.
  Widget _bellChoice(
    String mode,
    String name,
    IconData glyph,
    String note,
    String current,
    VoidCallback onTap,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(glyph, size: 22, color: NoorColors.emeraldDeep),
        title: Text(
          name,
          style: GoogleFonts.outfit(
              fontSize: 16, fontWeight: FontWeight.w700, color: NoorColors.ink),
        ),
        subtitle: Text(
          note,
          style:
              GoogleFonts.outfit(fontSize: 12.5, color: NoorColors.onGlassMuted),
        ),
        trailing: mode == current
            ? const Icon(Icons.check_circle_rounded,
                size: 22, color: NoorColors.emeraldDeep)
            : null,
        onTap: onTap,
      ),
    );
  }

  /// One clip the masjid may recite: the radio, its name, and a play sign
  /// when it is the one already in force. Tapping previews it as well as
  /// filing it, so the reader hears the voice they just chose.
  Widget _clipChoice({
    required String clipKey,
    required String name,
    required String current,
    required VoidCallback onTap,
  }) {
    final bool selected = clipKey == current;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_off,
          size: 18,
          color: selected ? NoorColors.emeraldDeep : NoorColors.muted,
        ),
        title: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.outfit(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: NoorColors.ink,
          ),
        ),
        trailing: clipKey == 'silent'
            ? const Icon(Icons.volume_off_outlined,
                size: 18, color: NoorColors.muted)
            : Icon(
                AzanPlayer.instance.playingKey == clipKey
                    ? Icons.stop_circle_outlined
                    : Icons.play_circle_outline,
                size: 18,
                color: NoorColors.emeraldDeep,
              ),
        onTap: onTap,
      ),
    );
  }

  /// Files [clipKey] against the masjid this card quotes — or against the
  /// profile when no board is quoted — and rehearses it.
  Future<void> _pickClip(String clipKey, StateSetter setDialog) async {
    final AppSettings settings = AppSettings.instance;
    final String boardId = widget.board?.id ?? '';
    if (boardId.isEmpty) {
      settings.setAzanSound(clipKey);
    } else {
      settings.setMasjidAzanSound(boardId, clipKey);
    }
    // Android freezes a notification channel's sound at creation; the banner
    // itself stays silent, but the same rebuild Settings used to make still
    // belongs here so no stale audible channel survives a change of voice.
    await NotificationService.applyAzanChannel(AppSettings.instance.azanSound);
    _armReschedule();
    if (!mounted) return;

    if (clipKey == 'silent') {
      unawaited(AzanPlayer.instance.stop());
      _say('“None (silent)” is selected — this masjid’s reminders stay '
          'silent, and nothing is playing now.');
      setDialog(() {});
      return;
    }

    final bool started = clipKey == kCustomAzanKey
        ? await AzanPlayer.instance.previewFile(settings.customAzanPath)
        : await AzanPlayer.instance.preview(clipKey);
    if (!mounted) return;
    if (!started) {
      _say('Your phone is on silent or vibrate, so nothing is playing — '
          'that is the Azaan staying quiet exactly as your reminders will.');
    }
    setDialog(() {});
  }

  /// Opens the phone's file picker and points this masjid — or the profile,
  /// when no board is quoted — at the chosen file.
  Future<void> _chooseOwnClip(StateSetter setDialog) async {
    final String? path = await AzaanAlarm.pickAudioFile();
    if (path == null || !mounted) return;

    final AppSettings settings = AppSettings.instance;
    settings.setCustomAzanPath(path);
    final String boardId = widget.board?.id ?? '';
    if (boardId.isEmpty) {
      settings.setAzanSound(kCustomAzanKey);
    } else {
      settings.setMasjidAzanSound(boardId, kCustomAzanKey);
    }
    await NotificationService.applyAzanChannel(AppSettings.instance.azanSound);
    _armReschedule();
    if (!mounted) return;

    final bool started = await AzanPlayer.instance.previewFile(path);
    if (!mounted) return;
    if (!started) {
      _say('Your phone is on silent or vibrate, so nothing is playing — '
          'turn the ringer up to hear it.');
    }
    setDialog(() {});
  }

  /// Hands the chosen clip to the phone's own ringtone list and says where
  /// to find it — the bell's copy of the row Settings used to carry.
  ///
  /// The bridge answers with *how* it landed rather than a bare success, so
  /// "already there", "refused" and "this platform has no such list" read
  /// differently instead of one silent tap.
  Future<void> _exportRingtone(String key) async {
    final AzanSound chosen = azanSoundByKey(key);
    if (chosen.key == 'silent') {
      _say('“None (silent)” has no clip to add — tap an Azaan above first.');
      return;
    }

    final String own = customAzanName(AppSettings.instance.customAzanPath);
    final String name =
        chosen.key == kCustomAzanKey && own.isNotEmpty ? own : chosen.label;
    final String title = 'Noor Azaan - $name';
    final ({bool added, String code, String? uri}) outcome =
        await AzaanAlarm.addToPhoneRingtone(chosen.key, title);
    if (!mounted) return;

    switch (outcome.code) {
      case 'ok':
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 8),
            content: Text(
              outcome.added
                  ? 'Added — “$title” is in your phone’s ringtone list. Open '
                      'Sound settings and choose it under Phone ringtone.'
                  : '“$title” is already in your ringtone list — open Sound '
                      'settings and choose it under Phone ringtone.',
            ),
            action: SnackBarAction(
              label: 'Open sound settings',
              onPressed: AzaanAlarm.openSoundSettings,
            ),
          ),
        );
        break;
      case 'denied':
        _say('Storage was refused, so the clip cannot leave the app on this '
            'phone. Allow storage for Noor and tap again.');
        break;
      case 'unsupported':
        _say('Only Android phones let Noor add to their ringtone list.');
        break;
      default:
        _say('Couldn’t add it to the ringtone list — please try again.');
    }
  }

  /// Makes sure Android will actually show the reminder card.
  ///
  /// The Azaan rides an exact alarm and plays whether or not this app may
  /// post notifications — the worst pair for a reader: the phone recites at
  /// the right minute and nothing on screen explains why. The bell asks for
  /// the permission the moment Azaan is chosen, and names the system switch
  /// when the reader has already said no.
  Future<void> _ensureNotifications() async {
    if (await AzaanAlarm.notificationsEnabled()) return;
    await NotificationService.requestPermission();
    if (!mounted) return;
    if (await AzaanAlarm.notificationsEnabled()) return;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        content: const Text(
          'Notifications are off for Noor, so the reminder card cannot '
          'appear when the Azaan plays. Allow notifications to see it.',
        ),
        action: SnackBarAction(
          label: 'Open settings',
          onPressed: AzaanAlarm.openNotificationSettings,
        ),
      ),
    );
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(duration: const Duration(seconds: 6), content: Text(message)),
    );
  }

  /// Files [minutes] against [key] alone and keeps the Jamaat source's own
  /// switch in step. Settings' chips do that second half only while the mode
  /// is "Only at my masjid's Jamaat time"; here the mode is not on show, so
  /// the pair is written whichever is in force and survives a later change
  /// of it.
  void _pickOffset(String key, int minutes, StateSetter setDialog) {
    final AppSettings settings = AppSettings.instance;
    settings.setNotifyOffset(key, minutes);
    settings.setFavMode(key, minutes < 0 ? kFavModeAt : kFavModeOffset);
    _armReschedule();
    setDialog(() {});
  }

  /// Asks for a number no chip offers and files it against [key].
  ///
  /// The reader who knows exactly how long before Fajr they want the knock —
  /// seven minutes, not one of the five the chips carry — has always been
  /// able to store it from the owner's config but never from the phone in
  /// their hand. This is that door.
  Future<void> _askCustomOffset(String key, StateSetter setDialog) async {
    final TextEditingController controller = TextEditingController();
    final int? picked = await showDialog<int>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: NoorColors.cream,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Text(
          '${_labelFor(key)} — minutes before',
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
              borderSide:
                  BorderSide(color: NoorColors.gold.withValues(alpha: 0.6)),
            ),
          ),
          style: GoogleFonts.outfit(fontSize: 15, color: NoorColors.ink),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Cancel',
                style: GoogleFonts.outfit(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: NoorColors.muted)),
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
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: NoorColors.emeraldDeep)),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    _pickOffset(key, picked, setDialog);
  }

  /// Which clock [key]'s offset is measured against.
  ///
  /// The mode chips above it are what set this, so the sentence reads the
  /// prayer's own answer rather than the profile's — otherwise "15 min" is
  /// fifteen minutes before nothing in particular the moment a reader picks
  /// "Off" for this bell alone.
  String _whenCaption(String key) {
    switch (AppSettings.instance.azaanTimingFor(key)) {
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

  /// One answer of "When will the Azaan play?" for [prayer] alone — the
  /// same four Settings' dropdown used to offer, cut into chips because a
  /// dialog has room for two rows of two and no room for a menu.
  ///
  /// The pick is filed on the spot and the dialog stays open, exactly like
  /// the offset chips beneath it: a reader comparing "Jamaat time" against
  /// "Both times" should not have to reopen the question for each one.
  Widget _azaanTimingChip(
      String prayer, String mode, String label, StateSetter setDialog) {
    final String current = AppSettings.instance.azaanTimingFor(prayer);
    final bool selected = current == mode;
    return Expanded(
      child: InkWell(
        onTap: () {
          // A profile-wide answer re-answered for this prayer alone: the
          // setter clears rather than writes when the two agree, so this
          // prayer never pins a copy of the default it is simply following.
          AppSettings.instance.setAzaanTimingFor(prayer, mode);
          _armReschedule();
          setDialog(() {});
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? NoorColors.emerald : NoorColors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? NoorColors.emerald
                  : NoorColors.gold.withValues(alpha: 0.6),
            ),
          ),
          child: Text(
            label,
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

  /// The sentence under the mode chips, in the words the chips themselves
  /// are too short to carry — the four answers a reader might have just
  /// picked, each said back in the terms that decide what actually rings.
  String _azaanTimingCaption(String mode) {
    switch (mode) {
      case kAzaanTimingAwwalOnly:
        return 'The Azaan plays at the calculated Awwal time — the earliest '
            'moment this prayer begins.';
      case kAzaanTimingBoth:
        return 'The Azaan plays twice for this prayer: once at the '
            'calculated Awwal time, then again at your favourite masjid’s '
            'own Jamaat time.';
      case kAzaanTimingNone:
        return 'No Azaan will sound for this prayer. The prohibited-time '
            '(zawal) banner is unaffected.';
      case kAzaanTimingJamaatOnly:
      default:
        return 'The Azaan plays once for this prayer, at your favourite '
            'masjid’s own Jamaat time.';
    }
  }

  /// One of the offered offsets for [key], cut the way Settings cuts its own
  /// chips. [offset] is read once by the dialog and passed down, so a tap
  /// and the rebuild it triggers agree about what was selected.
  Widget _offsetChip(
      String key, int minutes, int offset, StateSetter setDialog) {
    final bool selected = offset == minutes;
    return Expanded(
      child: InkWell(
        onTap: () => _pickOffset(key, minutes, setDialog),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? NoorColors.emerald : NoorColors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? NoorColors.emerald
                  : NoorColors.gold.withValues(alpha: 0.6),
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

  /// The last chip of the second row: the door to a number no chip carries.
  ///
  /// Lit when [key]'s live offset is one the chips have never heard of — a
  /// custom number is a *kept* answer, and a reader returning to the dialog
  /// should see which door they came through rather than a plain "Custom…"
  /// that hides a seven already filed.
  Widget _customOffsetChip(
      String key, int offset, StateSetter setDialog) {
    final bool lit = offset >= 0 && !kNotifyOffsets.contains(offset);
    return Expanded(
      child: InkWell(
        onTap: () => unawaited(_askCustomOffset(key, setDialog)),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: lit
                ? NoorColors.gold.withValues(alpha: 0.35)
                : NoorColors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: lit
                  ? NoorColors.gold
                  : NoorColors.gold.withValues(alpha: 0.6),
            ),
          ),
          child: Text(
            lit ? notifyOffsetChipLabel(offset) : 'Custom…',
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

  /// Re-arms both schedules — the calculated reminders and the Jamaat-time
  /// favourite alerts — since each of them skips a prayer whose bell is
  /// off, and both re-read the per-prayer sound for the ones still on.
  Future<void> _reschedule() async {
    try {
      await NotificationService.scheduleAzan(
        latitude: _lat,
        longitude: _lng,
        masjidId: widget.board?.id ?? '',
      );
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
                  'Pick the starred board this card quotes. The Azaan follows '
                  'the same masjid, so picking one here changes both. The '
                  'small line in each cell stays the calculated Awwal time '
                  'either way.',
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
                // The name and the clock share the row and are the same
                // fact twice over — which prayer, what time — so they wear
                // one size. 13.5 read as fine print beside the hero above
                // it; the reader's word for it was "bohot chota".
                fontSize: 15,
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
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: NoorColors.ink,
                  letterSpacing: 0.2,
                ),
              ),
              if (jamaat.isNotEmpty && e.key != 'juma')
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
              if (e.end != null && e.key != 'juma')
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
            // Sunrise is not a prayer and carries no notification; Jummah
            // carries no bell either.
            child: e.key == 'sunrise' || e.key == 'juma' ? null : _bell(e.key),
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
