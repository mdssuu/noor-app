import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app_look.dart';
import '../app_settings.dart';
import '../main.dart';
import '../screens/admin_panel_screen.dart';
import '../services/admin_access.dart';
import '../services/azaan_alarm.dart';
import '../services/azan_player.dart';
import '../services/places_service.dart';
import '../services/prayer_widget.dart';

/// Everything the user can tune, grouped into the five cards from the spec:
/// calculation, location, notifications, Azan sound, and the small extras.
///
/// Every setter writes straight through [AppSettings], which persists to
/// SharedPreferences and notifies listeners — the Today card on the home
/// screen redraws before this screen is even popped.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.gpsLatitude, this.gpsLongitude, this.locality});

  final double? gpsLatitude;
  final double? gpsLongitude;

  /// Reverse-geocoded area name from the home screen, so the location card
  /// can say "Current GPS - Kurla 19.076, 72.877" instead of bare numbers.
  final String? locality;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  final AppSettings _settings = AppSettings.instance;
  final TextEditingController _cityController = TextEditingController();

  List<MasjidSearchResult> _cityResults = <MasjidSearchResult>[];
  bool _cityLoading = false;
  int _cityToken = 0;
  Timer? _rescheduleTimer;

  /// The starred masjids, so their alert switches can be edited from here as
  /// well as from each masjid's own page.
  List<Masjid> _favMasjids = <Masjid>[];
  bool _favLoaded = false;

  /// The lock-screen card's two upstream switches, `null` until the first
  /// read — the row it feeds says "checking" rather than guessing.
  ({bool notificationsEnabled, bool onLockScreen})? _lockScreenStatus;

  /// What the lock-screen row is telling: `null` while still unknown,
  /// `false` while something in the phone's own settings hides the card.
  bool? get _lockScreenOk => _lockScreenStatus == null
      ? null
      : _lockScreenStatus!.notificationsEnabled &&
          _lockScreenStatus!.onLockScreen;

  @override
  void initState() {
    super.initState();
    _settings.addListener(_onSettingsChanged);
    // The row highlight and the Test Azaan button both read the player's
    // playing key, so the screen has to repaint when a clip starts or stops.
    // Registered as a listener rather than assigned: two screens listening
    // used to overwrite each other, and whichever opened second froze.
    AzanPlayer.instance.addListener(_onPlaybackChanged);
    _loadFavouriteMasjids();
    // The lock-screen row reads the phone's own toggles: once here, and
    // again on every resume — the settings page it opens lives outside the
    // app, and coming back is the first moment a flip there can be seen.
    WidgetsBinding.instance.addObserver(this);
    _refreshLockScreenStatus();
  }

  /// Re-reads the two switches the lock-screen card depends on. Never throws:
  /// a phone that will not answer gets the "checking" row, not a red screen.
  Future<void> _refreshLockScreenStatus() async {
    final ({bool notificationsEnabled, bool onLockScreen}) status =
        await AzaanAlarm.lockScreenStatus();
    if (!mounted) return;
    setState(() => _lockScreenStatus = status);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) _refreshLockScreenStatus();
  }

  void _onPlaybackChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadFavouriteMasjids() async {
    // The loading flag comes down on *every* path out of here. An offline
    // `.get()` does not fail — it waits, and the screen sat on its spinner
    // forever; a throw out of the cache read did the same thing from the
    // other end.
    final List<Masjid> loaded = <Masjid>[];
    try {
      final List<String> ids = await FavouriteStore.cached();
      for (final String id in ids) {
        try {
          final DocumentSnapshot<Map<String, dynamic>> snap = await FirebaseFirestore
              .instance
              .collection('masjids')
              .doc(id)
              .get()
              .timeout(const Duration(seconds: 20));
          if (snap.exists) loaded.add(Masjid.fromDoc(snap));
        } catch (error) {
          debugPrint('Noor ▸ settings favourite lookup failed: $error');
        }
      }
    } catch (error) {
      debugPrint('Noor ▸ settings favourites could not be listed: $error');
    }
    if (!mounted) return;
    setState(() {
      _favMasjids = loaded;
      _favLoaded = true;
    });
  }

  /// Which prayers a masjid can currently alert for, for the line under each
  /// switch — "Alerts on" on its own says nothing about what will actually
  /// happen at prayer time.
  String _prayerSummary(Masjid masjid) {
    final List<String> armed = <String>[
      for (final String key in kNotifiablePrayers)
        if (_settings.notifyOnFor(key) &&
            NotificationService.parseClockTime(masjid.timeFor(key)) != null)
          prayerByKey(key).label,
    ];
    return armed.isEmpty ? 'no prayer switched on yet' : armed.join(', ');
  }

  /// True while the selected Azaan is audibly playing, so the Test button can
  /// turn into a Stop button instead of stacking a second clip on the first.
  bool get _testPlaying => AzanPlayer.instance.playingKey == _settings.azanSound;

  /// Says why nothing sounded when the reader pressed for something to.
  ///
  /// [AzanPlayer.preview] answers `false` when the phone is on silent or
  /// vibrate — the reminder does not override a silence somebody set on
  /// purpose, and neither does a button that is only an honest rehearsal of
  /// it. Unexplained, that is the original complaint again: a button that
  /// does nothing. Every `false` therefore gets one sentence, once.
  void _explainSilenced() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(
          'Your phone is on silent or vibrate, so nothing is playing — that '
          'is the Azaan staying quiet exactly as your reminders will. Turn '
          'the ringer up to hear it.',
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _settings.removeListener(_onSettingsChanged);
    _rescheduleTimer?.cancel();
    _cityController.dispose();
    AzanPlayer.instance.removeListener(_onPlaybackChanged);
    // Leaving a preview sounding after the screen that started it is gone
    // would be its own bug — the stop button is no longer reachable.
    unawaited(AzanPlayer.instance.stop());
    super.dispose();
  }

  void _onSettingsChanged() {
    if (!mounted) return;
    setState(() {});

    // Prayer times move by seconds between days, so re-arming after any
    // setting lands is cheap — but coalesce bursts (dragging the Hijri
    // slider fires on every tick) into one cancel/schedule pass.
    _rescheduleTimer?.cancel();
    _rescheduleTimer = Timer(const Duration(milliseconds: 500), _reschedule);
  }

  double get _effectiveLatitude =>
      _settings.customLatitude ?? widget.gpsLatitude ?? LocationService.fallbackAnchor.x;

  double get _effectiveLongitude =>
      _settings.customLongitude ?? widget.gpsLongitude ?? LocationService.fallbackAnchor.y;

  /// The always-on prayer card: the home-screen widget and the
  /// lock-screen card.
  ///
  /// Turning it off hides the card and nothing else - the prayer
  /// reminders, the Azaan and the favourite-masjid alerts keep
  /// working. The card that is already on screen goes away at once,
  /// and the app stops feeding it until the user brings it back.
  Future<void> _togglePrayerCard(bool on) async {
    _settings.setPrayerCardVisible(on);
    if (!mounted) return;
    setState(() {});
    if (on) {
      // Bring it straight back, rather than waiting for the next push.
      await _reschedule();
    } else {
      await PrayerWidget.clearCard();
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 5),
        content: Text(
          on
              ? 'The prayer card is back on your home and lock screen.'
              : 'The prayer card is off. Your reminders and the Azaan '
                  'keep working.',
        ),
      ),
    );
  }

  Future<void> _reschedule() async {
    if (!mounted) return;
    try {
      await NotificationService.scheduleAzan(
        latitude: _effectiveLatitude,
        longitude: _effectiveLongitude,
      );
      await NotificationService.scheduleFavouriteAlerts();
      // The home-screen widget quotes the same calculation this screen just
      // changed — feed it the new picture in the same pass.
      await PrayerWidget.push(
        latitude: _effectiveLatitude,
        longitude: _effectiveLongitude,
        areaName: _settings.hasCustomLocation
            ? _settings.customCity
            : (widget.locality ?? 'Prayer times'),
      );
    } catch (error) {
      debugPrint('Noor ▸ reschedule failed: $error');
    }
  }

  Future<void> _searchCity(String query) async {
    final String q = query.trim();
    if (q.length < 2) {
      setState(() => _cityResults = <MasjidSearchResult>[]);
      return;
    }

    final int token = ++_cityToken;
    setState(() => _cityLoading = true);
    final List<MasjidSearchResult> found = await searchCity(q);
    if (!mounted || token != _cityToken) return;
    setState(() {
      _cityResults = found;
      _cityLoading = false;
    });
  }

  Future<void> _showPrivacy() async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: NoorColors.cream,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Text('Privacy Policy',
            style: GoogleFonts.outfit(fontSize: 16, fontWeight: FontWeight.w700)),
        content: SingleChildScrollView(
          child: Text(
            '• Your GPS position is used on this device only — to sort the '
                'nearby list, compute prayer times and measure “800m away” '
                'badges. It is never sent to a server.\n\n'
            '• Masjid names, times and photos you submit are written to '
                'Cloud Firestore so neighbours see the same board. Your display '
                'name and profile picture are stored with the update.\n\n'
            '• Photos are stored as a small compressed copy (under 450 KB) so '
                'they load without a separate image host.\n\n'
            '• Board photos are read on your device first. If a Gemini key is '
                'configured, the photo is also sent once to Google so the '
                'Jamaat column can be read; with no key configured the photo '
                'never leaves your phone.\n\n'
            '• Search uses OpenStreetMap’s Nominatim — free, no account, no '
                'tracking. Google Sign-In shares only your name, email and '
                'avatar.\n\n'
            '• Azan reminders, favourites and settings live in local storage on '
                'your phone and are removed when you uninstall the app.',
            style: GoogleFonts.outfit(fontSize: 12.5, height: 1.6),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Close',
                style: GoogleFonts.outfit(
                    fontWeight: FontWeight.w700, color: NoorColors.ink)),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- widgets

  static const String _appName = 'Noor • Masjid Time';

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          text,
          style: GoogleFonts.outfit(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: NoorColors.onGlass,
          ),
        ),
      );

  /// The sentence under "When will the Azaan play?".
  ///
  /// The row below offers all four modes and each one reads a different
  /// clock, so this has to describe the mode that is actually live rather
  /// than repeat the answer for whichever row the reader is about to leave —
  /// otherwise "Only at Awwal time" still tells them the masjid's Jamaat
  /// time is what will sound.
  String get _azaanTimingHint {
    switch (_settings.azaanTiming) {
      case kAzaanTimingAwwalOnly:
        return 'The Azaan plays at the calculated Awwal time — the earliest '
            'waqt each prayer begins.';
      case kAzaanTimingBoth:
        return 'The Azaan plays twice for each prayer: once at the '
            'calculated Awwal time, then again at your favourite masjid’s '
            'own Jamaat time.';
      case kAzaanTimingNone:
        return 'No Azaan will sound for any prayer. The prohibited-time '
            '(zawal) banner is unaffected.';
      case kAzaanTimingJamaatOnly:
      default:
        return _settings.hasPrePrayerReminder
            ? 'A pre-prayer reminder is on, so the Azaan plays at your favourite masjid’s Jamaat time.'
            : 'The Azaan plays once per prayer, at your favourite masjid’s own Jamaat time.';
    }
  }

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
          text,
          style: GoogleFonts.outfit(fontSize: 11.5, color: NoorColors.onGlassMuted, height: 1.5),
        ),
      );

  /// One of a set of mutually exclusive options, laid out edge to edge.
  Widget _option({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? NoorColors.emerald : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? NoorColors.emerald : NoorColors.gold.withValues(alpha: 0.6),
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

  Widget _optionRow(List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(children: children),
      );

  /// The offset chips for [prayer]: the offered set, with this profile's own
  /// offset folded in first whenever it is not one of them.
  ///
  /// A config document can name an offset the chips have never heard of, and
  /// a chip that is not drawn cannot show that it is the one in force — so
  /// the live value joins the row rather than the row going blank.
  List<int> _offsetChoices(String prayer) {
    final int current = _settings.notifyOffsetFor(prayer);
    return <int>[
      if (!kNotifyOffsets.contains(current)) current,
      ...kNotifyOffsets,
    ];
  }

  @override
  Widget build(BuildContext context) {
    return NoorScaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 32),
        children: <Widget>[
          // ================================================== 1. CALCULATION
          const SectionHeader(title: 'Prayer calculation'),
          GoldCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _label('Calculation method'),
                Text(
                  _settings.method.hint,
                  style: GoogleFonts.outfit(
                      fontSize: 11.5, color: NoorColors.onGlassMuted, height: 1.5),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _settings.methodKey,
                  isExpanded: true,
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: NoorColors.cardGreen,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(13),
                      borderSide: BorderSide(color: NoorColors.gold.withValues(alpha: 0.6)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(13),
                      borderSide: BorderSide(color: NoorColors.gold.withValues(alpha: 0.6)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(13),
                      borderSide: const BorderSide(color: NoorColors.emerald, width: 1.4),
                    ),
                  ),
                  items: kCalcMethods
                      .map((CalcMethod m) => DropdownMenuItem<String>(
                            value: m.key,
                            child: Text(m.label,
                                maxLines: 2,
                                style: GoogleFonts.outfit(fontSize: 13)),
                          ))
                      .toList(),
                  onChanged: (String? key) {
                    if (key == null) return;
                    _settings.setMethod(key);
                  },
                ),
                const SizedBox(height: 18),
                _label('Madhab (Asr)'),
                _hint('Hanafi reads Asr at full shadow — roughly an hour later '
                    'than Shafi. Most masjids in Mumbai and Pakistan follow '
                    'Hanafi.'),
                _optionRow(<Widget>[
                  _option(
                    label: 'Shafi  ·  shadow 1×',
                    selected: !_settings.isHanafi,
                    onTap: () => _settings.setMadhab('shafi'),
                  ),
                  const SizedBox(width: 8),
                  _option(
                    label: 'Hanafi  ·  shadow 2×',
                    selected: _settings.isHanafi,
                    onTap: () => _settings.setMadhab('hanafi'),
                  ),
                ]),
                _label('Time format'),
                _optionRow(<Widget>[
                  _option(
                    label: '12 hour  ·  05:30 AM',
                    selected: _settings.timeFormat != '24',
                    onTap: () => _settings.setTimeFormat('12'),
                  ),
                  const SizedBox(width: 8),
                  _option(
                    label: '24 hour  ·  05:30',
                    selected: _settings.timeFormat == '24',
                    onTap: () => _settings.setTimeFormat('24'),
                  ),
                ]),
              ],
            ),
          ),

          // ==================================================== 2. LOCATION
          const SectionHeader(title: 'Location'),
          GoldCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(
                      _settings.hasCustomLocation ? Icons.push_pin : Icons.my_location,
                      size: 18,
                      color: NoorColors.onGlassGold,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            _settings.hasCustomLocation
                                ? 'Pinned city · ${_settings.customCity}'
                                : (widget.locality == null ||
                                        widget.locality!.trim().isEmpty
                                    ? 'Auto-detect (Current GPS)'
                                    : 'Auto-detect (Current GPS - '
                                        '${widget.locality} '
                                        '${_effectiveLatitude.toStringAsFixed(3)}, '
                                        '${_effectiveLongitude.toStringAsFixed(3)})'),
                            style: GoogleFonts.outfit(
                                fontSize: 13, fontWeight: FontWeight.w700, color: NoorColors.onGlass),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _settings.hasCustomLocation
                                ? '${_effectiveLatitude.toStringAsFixed(3)}, '
                                    '${_effectiveLongitude.toStringAsFixed(3)} · prayer times use this point'
                                : '${_effectiveLatitude.toStringAsFixed(3)}, '
                                    '${_effectiveLongitude.toStringAsFixed(3)} · from this device’s GPS',
                            style:
                                GoogleFonts.outfit(fontSize: 11.5, color: NoorColors.onGlassMuted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (_settings.hasCustomLocation) ...<Widget>[
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: () => _settings.setCustomLocation(null, null, ''),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: NoorColors.onGlassGold,
                      side: const BorderSide(color: NoorColors.onGlassGold),
                      visualDensity: VisualDensity.compact,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.gps_fixed, size: 15),
                    label: Text('Use my GPS location again',
                        style:
                            GoogleFonts.outfit(fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
                ],
                const SizedBox(height: 16),
                _label('Change city manually'),
                _hint('Search any city in India to preview its prayer times '
                    'instead of your own — useful before travelling.'),
                TextField(
                  controller: _cityController,
                  textInputAction: TextInputAction.search,
                  onChanged: (String v) {
                    if (v.trim().length >= 2) {
                      _searchCity(v);
                    } else if (_cityResults.isNotEmpty) {
                      setState(() => _cityResults = <MasjidSearchResult>[]);
                    }
                  },
                  onSubmitted: _searchCity,
                  decoration: InputDecoration(
                    hintText: 'e.g. Thane, Bhopal, Hyderabad…',
                    prefixIcon: const Icon(Icons.search_outlined, color: NoorColors.muted),
                    suffixIcon: _cityLoading
                        ? const Padding(
                            padding: EdgeInsets.all(13),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : null,
                    filled: true,
                    fillColor: NoorColors.cardGreen,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                if (_cityResults.isNotEmpty)
                  // The colour sits on the Material, not on a decorated box
                  // wrapped around it. ListTile paints its background and its
                  // ink on the nearest Material ancestor, so a coloured box
                  // between the two paints *over* what it draws — which is
                  // the very thing Flutter's debug check reports, and the
                  // reason a tap here used to leave no splash at all.
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Material(
                      color: NoorColors.onGlassChip,
                      borderRadius: BorderRadius.circular(14),
                      clipBehavior: Clip.antiAlias,
                      child: Container(
                        constraints: const BoxConstraints(maxHeight: 220),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                              color: NoorColors.gold.withValues(alpha: 0.6)),
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: _cityResults.length,
                          separatorBuilder: (_, _) =>
                              Divider(height: 1, color: NoorColors.gold.withValues(alpha: 0.3)),
                          itemBuilder: (BuildContext context, int i) {
                            final MasjidSearchResult r = _cityResults[i];
                            return ListTile(
                              dense: true,
                              leading: const Icon(Icons.location_city_outlined,
                                  size: 18, color: NoorColors.onGlassGold),
                              title: Text(r.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.outfit(
                                      fontSize: 13, fontWeight: FontWeight.w600, color: NoorColors.onGlass)),
                              subtitle: Text(r.address,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style:
                                      GoogleFonts.outfit(fontSize: 11, color: NoorColors.onGlassMuted)),
                              onTap: () {
                                FocusScope.of(context).unfocus();
                                setState(() => _cityResults = <MasjidSearchResult>[]);
                                _cityController.clear();
                                _settings.setCustomLocation(
                                    r.latitude, r.longitude, r.name);
                              },
                            );
                          },
                        ),
                      ),
                    ),
                  )
                else if (_cityController.text.trim().length >= 2 && !_cityLoading)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      'No city found — check the spelling or use the full name.',
                      style: GoogleFonts.outfit(fontSize: 11.5, color: NoorColors.onGlassMuted),
                    ),
                  ),
              ],
            ),
          ),

          // ================================================= NOTIFICATIONS
          const SectionHeader(title: 'Azan notifications'),
          GoldCard(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SwitchListTile(
                  value: _settings.notificationsEnabled,
                  onChanged: (bool v) => _settings.setNotificationsEnabled(v),
                  activeThumbColor: NoorColors.emerald,
                  title: Text('Enable Azan notifications',
                      style: GoogleFonts.outfit(
                          fontSize: 13.5, fontWeight: FontWeight.w700, color: NoorColors.onGlass)),
                  subtitle: Text(
                    _settings.notificationsEnabled
                        ? 'A reminder at each of the five prayers, using today’s '
                            'calculated times.'
                        : 'Off — no prayer reminders will be scheduled.',
                    style:
                        GoogleFonts.outfit(fontSize: 11.5, color: NoorColors.onGlassMuted, height: 1.45),
                  ),
                ),
                _hint(
                  'Silence is the default now: nothing is scheduled until a '
                  'reader asks for the Azaan — from the Home bell’s dialog or '
                  'this screen.',
                ),
                if (_settings.notificationsEnabled) ...<Widget>[
                  Divider(height: 1, color: NoorColors.gold.withValues(alpha: 0.3)),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        _label('When will the Azaan play?'),
                        _hint(_azaanTimingHint),
                        DropdownButtonFormField<String>(
                          // The stored value is part of the key, not just the
                          // option list: `initialValue` only ever seeds the
                          // field once, so a value arriving from a profile
                          // switch or the admin config would otherwise leave
                          // a stale row lit. With four modes offered, a row
                          // that disagrees with what is on disk is a setting
                          // the reader cannot see, let alone undo.
                          key: ValueKey(
                              '${_settings.azaanTiming}|${_settings.azaanTimingOptions.join('|')}'),
                          initialValue: _settings.azaanTimingOptions
                                  .contains(_settings.azaanTiming)
                              ? _settings.azaanTiming
                              : _settings.azaanTimingOptions.first,
                          isExpanded: true,
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: NoorColors.cardGreen,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(13),
                              borderSide:
                                  BorderSide(color: NoorColors.gold.withValues(alpha: 0.6)),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(13),
                              borderSide:
                                  BorderSide(color: NoorColors.gold.withValues(alpha: 0.6)),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(13),
                              borderSide: const BorderSide(
                                  color: NoorColors.emerald, width: 1.4),
                            ),
                          ),
                          items: _settings.azaanTimingOptions
                              .map((String key) => DropdownMenuItem<String>(
                                    value: key,
                                    child: Text(azaanTimingLabel(key),
                                        style:
                                            GoogleFonts.outfit(fontSize: 13)),
                                  ))
                              .toList(),
                          onChanged: (String? key) {
                            if (key == null) return;
                            _settings.setAzaanTiming(key);
                          },
                        ),
                      ],
                    ),
                  ),
                  for (final String key in kNotifiablePrayers) ...<Widget>[
                    Divider(height: 1, color: NoorColors.gold.withValues(alpha: 0.3)),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                      child: Row(
                        children: <Widget>[
                          Icon(prayerByKey(key).icon, size: 17, color: NoorColors.onGlassGold),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(prayerByKey(key).label,
                                style: GoogleFonts.outfit(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                    color: NoorColors.onGlass)),
                          ),
                          Switch(
                            value: _settings.notifyOnFor(key),
                            activeThumbColor: NoorColors.emerald,
                            onChanged: (bool v) => _settings.setNotifyOn(key, v),
                          ),
                        ],
                      ),
                    ),
                    // One row per prayer, matching the "When will the Azaan
                    // play?" mode above it - the two rows the Settings used
                    // to show together read as two disconnected switches,
                    // and in the default "Only at Jamaat time" mode the
                    // Awwal row could light up while changing nothing.
                    //
                    //  * "Only at Jamaat time": the SAME five chips, where
                    //    "At time" means the favourite masjid's Jamaat
                    //    moment and "N min" means N minutes before it.
                    //  * "Only at Awwal time": just the Awwal chips.
                    //  * "At both times" / "Off": both rows, each with its
                    //    own controls, so every source stays configurable.
                    if (_settings.notifyOnFor(key) &&
                        _settings.azaanTiming != kAzaanTimingJamaatOnly)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(39, 4, 12, 10),
                        child: Row(
                          children: <Widget>[
                            // The live offset comes first when it is not one
                            // of the offered choices, so a value the owner's
                            // config set (or an older build wrote) still
                            // shows itself as selected instead of leaving the
                            // row with nothing lit.
                            for (final MapEntry<int, int> choice
                                in _offsetChoices(key).asMap().entries) ...<Widget>[
                              if (choice.key > 0) const SizedBox(width: 6),
                              _option(
                                label: notifyOffsetChipLabel(choice.value),
                                selected: _settings.notifyOffsetFor(key) ==
                                    choice.value,
                                onTap: () =>
                                    _settings.setNotifyOffset(key, choice.value),
                              ),
                            ],
                          ],
                        ),
                      ),
                    // Jamaat-only: the single row. "At time" = the Jamaat
                    // moment itself; "N min" stores the offset and moves the
                    // prayer onto the Jamaat source. The second source's own
                    // caption row stays for the modes that still show both.
                    if (_settings.notifyOnFor(key) &&
                        _settings.azaanTiming != kAzaanTimingAwwalOnly)
                      if (_settings.azaanTiming == kAzaanTimingJamaatOnly)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(39, 4, 12, 14),
                          child: Row(
                            children: <Widget>[
                              for (final MapEntry<int, int> choice
                                  in _offsetChoices(key).asMap().entries) ...<Widget>[
                                if (choice.key > 0) const SizedBox(width: 6),
                                _option(
                                  label: notifyOffsetChipLabel(choice.value),
                                  selected: choice.value < 0
                                      ? _settings.favModeFor(key) == kFavModeAt ||
                                          _settings.notifyOffsetFor(key) < 0
                                      : _settings.favModeFor(key) ==
                                              kFavModeOffset &&
                                          _settings.notifyOffsetFor(key) ==
                                              choice.value,
                                  onTap: () {
                                    if (choice.value < 0) {
                                      _settings.setFavMode(key, kFavModeAt);
                                    } else {
                                      _settings.setNotifyOffset(
                                          key, choice.value);
                                      _settings.setFavMode(
                                          key, kFavModeOffset);
                                    }
                                  },
                                ),
                              ],
                            ],
                          ),
                        )
                      else
                        // Same prayer, second source: a starred masjid's own
                        // Jamaat column instead of the calculated time above.
                        Padding(
                          padding: const EdgeInsets.fromLTRB(39, 0, 12, 14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                'At my favourite masjid',
                                style: GoogleFonts.outfit(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: NoorColors.onGlassMuted,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: <Widget>[
                                  _option(
                                    label: 'At Jamaat time',
                                    selected:
                                        _settings.favModeFor(key) == kFavModeAt,
                                    onTap: () =>
                                        _settings.setFavMode(key, kFavModeAt),
                                  ),
                                  const SizedBox(width: 6),
                                  _option(
                                    label: notifyOffsetLabel(
                                        _settings.notifyOffsetFor(key)),
                                    selected: _settings.favModeFor(key) ==
                                        kFavModeOffset,
                                    onTap: () =>
                                        _settings.setFavMode(key, kFavModeOffset),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                  ],
                ],
                if (!_settings.notificationsEnabled)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Text(
                      'Grant the Android notification permission too if the '
                      'reminder still does not appear.',
                      style: GoogleFonts.outfit(
                        fontSize: 11,
                        color: NoorColors.muted,
                        height: 1.5,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // ============================= 3a-2. LOCK-SCREEN CARD VISIBILITY
          // The card posts perfectly on every phone; what decides whether a
          // locked phone *shows* it is the user's own toggle in the system
          // settings — one Android keeps away from apps. So the row reads
          // both switches, names whichever is off, and opens the page that
          // holds it: "works unlocked, vanishes locked" is otherwise
          // indistinguishable from a broken app.
          const SectionHeader(title: 'Prayer times on lock screen'),
          GoldCard(
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 10),
            child: ListTile(
              onTap: () => unawaited(AzaanAlarm.openNotificationSettings()),
              leading: Icon(
                _lockScreenStatus?.notificationsEnabled ?? true
                    ? Icons.lock_outline
                    : Icons.notifications_off_outlined,
                color: NoorColors.onGlassGold,
              ),
              trailing: Icon(
                _lockScreenOk == null
                    ? Icons.chevron_right
                    : _lockScreenOk!
                        ? Icons.check_circle_outline
                        : Icons.warning_amber_rounded,
                color: _lockScreenOk == null
                    ? NoorColors.onGlassGold
                    : _lockScreenOk!
                        ? NoorColors.emeraldDeep
                        : NoorColors.danger,
                size: 20,
              ),
              title: Text(
                'Lock screen visibility',
                style: GoogleFonts.outfit(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: NoorColors.onGlass),
              ),
              subtitle: Text(
                _lockScreenStatus == null
                    ? 'Checking this phone…'
                    : !_lockScreenStatus!.notificationsEnabled
                        ? 'Notifications are off for this app, so nothing '
                            'shows anywhere. Tap to open this phone’s '
                            'settings and allow them.'
                        : !_lockScreenStatus!.onLockScreen
                            ? 'This phone hides notifications on the lock '
                                'screen — the times appear only after '
                                'unlocking. Tap to open this app’s '
                                'notification settings and turn on “On the '
                                'lock screen”.'
                            : 'Visible — today’s times stay on the lock '
                                'screen while the phone is locked.',
                style: GoogleFonts.outfit(
                    fontSize: 11.5,
                    color: NoorColors.onGlassMuted,
                    height: 1.45),
              ),
            ),
          ),

          // =============================== 3a. PRAYER CARD
          const SectionHeader(title: 'Prayer card'),
          GoldCard(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SwitchListTile(
                  value: _settings.prayerCardVisible,
                  onChanged: _togglePrayerCard,
                  activeThumbColor: NoorColors.emerald,
                  title: Text('Home & lock-screen card',
                      style: GoogleFonts.outfit(
                          fontSize: 13.5, fontWeight: FontWeight.w700, color: NoorColors.onGlass)),
                  subtitle: Text(
                    _settings.prayerCardVisible
                        ? 'On — the next prayer and today’s times sit on '
                            'your home screen and your lock screen.'
                        : 'Off — the card is hidden for good. Your reminders, '
                            'the Azaan and masjid alerts keep working.',
                    style:
                        GoogleFonts.outfit(fontSize: 11.5, color: NoorColors.onGlassMuted, height: 1.45),
                  ),
                ),
              ],
            ),
          ),

          // =============================== 3b. FAVOURITE MASJID ALERTS
          const SectionHeader(title: 'Favourite masjid alerts'),
          GoldCard(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Reminders at the Jamaat times of the masjids you have starred. '
                  'The same switches live on each masjid’s own page.',
                  style: GoogleFonts.outfit(
                      fontSize: 11.5, color: NoorColors.onGlassMuted, height: 1.5),
                ),
                if (!_favLoaded)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text('Loading your favourites…',
                        style: GoogleFonts.outfit(fontSize: 12, color: NoorColors.onGlassMuted)),
                  )
                else if (_favMasjids.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12, bottom: 6),
                    child: Text(
                      'No favourites yet — tap the star on a masjid to follow '
                      'its board and get its Jamaat alerts.',
                      style: GoogleFonts.outfit(fontSize: 12, color: NoorColors.onGlassMuted, height: 1.5),
                    ),
                  )
                else
                  for (final Masjid masjid in _favMasjids) ...<Widget>[
                    Divider(height: 1, color: NoorColors.gold.withValues(alpha: 0.3)),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: _settings.favAlertFor(masjid.id),
                      activeThumbColor: NoorColors.emerald,
                      title: Text(
                        masjid.name.isEmpty ? 'Masjid' : masjid.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.outfit(
                            fontSize: 13, fontWeight: FontWeight.w600, color: NoorColors.onGlass),
                      ),
                      subtitle: Text(
                        _settings.favAlertFor(masjid.id)
                            ? 'Alerts on — ${_prayerSummary(masjid)}'
                            : 'Alerts off for this masjid',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.outfit(
                            fontSize: 11, color: NoorColors.onGlassMuted, height: 1.4),
                      ),
                      onChanged: (bool enabled) async {
                        _settings.setFavAlert(masjid.id, enabled);
                        await NotificationService.scheduleFavouriteAlerts();
                      },
                    ),
                  ],
              ],
            ),
          ),

          // ================================================ 4. AZAN SOUND
          const SectionHeader(title: 'Azan sound'),
          GoldCard(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            child: Column(
              children: kAzanSounds.map((AzanSound sound) {
                final bool selected = _settings.azanSound == sound.key;
                final bool playing = AzanPlayer.instance.playingKey == sound.key;
                return InkWell(
                  onTap: () async {
                    final bool changed = _settings.azanSound != sound.key;
                    _settings.setAzanSound(sound.key);
                    // Android freezes a channel's sound the instant the
                    // channel is created, so a new pick only lands once the
                    // old channel has been dropped and rebuilt around it.
                    if (changed) await NotificationService.applyAzanChannel();
                    if (!mounted) return;
                    final bool started =
                        await AzanPlayer.instance.preview(sound.key);
                    // A row that selected a clip and then made no noise is
                    // only trustworthy if it says which of the two it did.
                    if (!started) _explainSilenced();
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          selected
                              ? Icons.radio_button_checked
                              : Icons.radio_button_off,
                          size: 19,
                          color: selected ? NoorColors.onGlassGold : NoorColors.onGlassMuted,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            sound.label,
                            style: GoogleFonts.outfit(
                              fontSize: 13,
                              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                              color: selected ? NoorColors.onGlass : NoorColors.onGlassMuted,
                            ),
                          ),
                        ),
                        Icon(
                          playing ? Icons.stop_circle_outlined : Icons.play_circle_outline,
                          size: 22,
                          color: playing ? NoorColors.onGlassGold : NoorColors.gold,
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: GradientButton(
              label: _testPlaying ? 'Stop Azaan' : 'Test Azaan',
              icon: _testPlaying ? Icons.stop_circle_outlined : Icons.volume_up_outlined,
              onPressed: () async {
                // "None (silent)" has no clip to test, so the button plays the
                // built-in one instead of answering nothing at all — but a
                // reader who hears an Azan and does not know why would read
                // that as the reminder coming on. Say which is which.
                if (_settings.azanSound == 'silent') {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      duration: const Duration(seconds: 6),
                      content: Text(
                        '“None (silent)” is selected, so your reminders stay '
                        'silent — this is the built-in Azaan. Tap a clip above '
                        'to make it the one that rings.',
                      ),
                    ),
                  );
                }
                // On a phone this reader has silenced, not even the built-in
                // clip is going to sound, and a button that explains nothing
                // is how this row first came to look broken. Say so.
                final bool started =
                    await AzanPlayer.instance.preview(_settings.azanSound);
                if (!started) _explainSilenced();
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
            child: Text(
              'Each Azaan above ships inside the app, so the reminder plays the '
              'full recitation instead of the phone’s default tone — with the '
              'app closed, and at your own ring volume. Silence is still yours: on '
              'silent or vibrate the reminder stays quiet rather than '
              'overriding the choice, and “Test Azaan” says so instead of '
              'ringing anyway. With the ringer up, “Test Azaan” plays exactly '
              'that file at exactly that volume, and either volume key stops '
              'it while it runs. Choosing “None” leaves the reminder as a '
              'silent vibration, and “Test Azaan” then plays the built-in one '
              'so the path can still be checked.',
              style: GoogleFonts.outfit(
                fontSize: 11,
                color: NoorColors.muted,
                height: 1.55,
              ),
            ),
          ),

          // =============================== 4b. TEST THE REMINDER PATH
          // "Test Azaan" only proves the clip plays while the app is open.
          // This one also arms a copy for a minute later so the closed-app
          // case — the only one a prayer time ever really faces — can be
          // checked on demand instead of at Fajr.
          //
          // Every account gets it, and that is the point: the question this
          // answers — "will my phone actually wake for Fajr?" — belongs to
          // whoever set a reminder, not only to the person who wrote the app.
          // Restricting it to the owner meant a user with a broken setup had
          // no way to find out until the prayer itself was missed.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: GradientButton(
              label: 'Send test reminder',
              icon: Icons.notifications_active_outlined,
              onPressed: () async {
                final ScaffoldMessengerState messenger =
                    ScaffoldMessenger.of(context);
                await NotificationService.testReminder();
                if (!mounted) return;
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Test sent. It rings now, and again in a minute with '
                      'the app closed.',
                    ),
                  ),
                );
              },
            ),
          ),

          // The panel behind this is the owner's: permissions, the live alarm
          // ledger, and the controls that reach the whole app. Hidden rather
          // than gated — the client cannot keep anyone out of its own code —
          // so that a screen full of device diagnostics stays out of a normal
          // user's way.
          if (AdminAccess.isAdmin) ...<Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: GradientButton(
                label: 'Admin controls',
                icon: Icons.admin_panel_settings_outlined,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const AdminPanelScreen(),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: Text(
                'Permissions, the alarm ledger and the controls that reach '
                'the whole app — the account that owns this app.',
                style: GoogleFonts.outfit(
                  fontSize: 11,
                  color: NoorColors.muted,
                  height: 1.55,
                ),
              ),
            ),
          ],

          // ================================================== 5. OTHER
          const SectionHeader(title: 'Other'),
          GoldCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Icon(Icons.brightness_3_outlined,
                        size: 17, color: NoorColors.onGlassGold),
                    const SizedBox(width: 8),
                    Text('Hijri date adjustment',
                        style: GoogleFonts.outfit(
                            fontSize: 13, fontWeight: FontWeight.w700, color: NoorColors.onGlass)),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                      decoration: BoxDecoration(
                        color: NoorColors.onGlassChip,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: NoorColors.gold.withValues(alpha: 0.7)),
                      ),
                      child: Text(
                        _settings.hijriAdjustment == 0
                            ? '±0 days'
                            : (_settings.hijriAdjustment > 0
                                ? '+${_settings.hijriAdjustment} day${_settings.hijriAdjustment == 1 ? '' : 's'}'
                                : '${_settings.hijriAdjustment} days'),
                        style: GoogleFonts.outfit(
                            fontSize: 11.5, fontWeight: FontWeight.w700, color: NoorColors.onGlassGold),
                      ),
                    ),
                  ],
                ),
                Text(
                  'Nudge the Islamic date forward or back to match the moon '
                      'sighting announced in your area.',
                  style:
                      GoogleFonts.outfit(fontSize: 11.5, color: NoorColors.onGlassMuted, height: 1.5),
                ),
                Slider(
                  value: _settings.hijriAdjustment.toDouble(),
                  min: -2,
                  max: 2,
                  divisions: 4,
                  activeColor: NoorColors.emerald,
                  onChanged: (double v) => _settings.setHijriAdjustment(v.round()),
                ),
                const Divider(height: 26),
                FutureBuilder<PackageInfo>(
                  future: PackageInfo.fromPlatform(),
                  builder:
                      (BuildContext context, AsyncSnapshot<PackageInfo> snap) {
                    final String version = snap.hasData
                        ? '${snap.data!.version} (${snap.data!.buildNumber})'
                        : '—';
                    return _infoRow(Icons.info_outline, 'App version', version);
                  },
                ),
                const SizedBox(height: 6),
                InkWell(
                  onTap: _showPrivacy,
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: _infoRow(Icons.shield_outlined, 'Privacy Policy', 'Read'),
                  ),
                ),
                const SizedBox(height: 6),
                _infoRow(Icons.apps_outlined, 'App', _appName),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Row(
      children: <Widget>[
        Icon(icon, size: 17, color: NoorColors.onGlassGold),
        const SizedBox(width: 10),
        Expanded(
          child: Text(label,
              style: GoogleFonts.outfit(fontSize: 13, color: NoorColors.onGlass)),
        ),
        Text(value,
            style: GoogleFonts.outfit(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: NoorColors.onGlassMuted)),
      ],
    );
  }
}
