import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app_look.dart';
import '../app_settings.dart';
import '../main.dart';
import '../manual_add_screen.dart';
import '../services/admin_access.dart';
import '../services/azaan_alarm.dart';
import '../services/app_config.dart';
import '../services/azan_player.dart';
import 'admin_config_screen.dart';
import 'admin_controls.dart';

/// Everything the account that owns this app can reach, on one screen.
///
/// Reached from Settings, and only when the signed-in account is the one in
/// [AdminAccess.adminEmail]. What sits here is everything the app itself can
/// do — the calculation settings, the azaan, the location, the masjid list,
/// the alarms, the permissions and the account — gathered so that running the
/// app does not mean walking through six screens to reach one switch.
///
/// It exists because these questions otherwise had to be answered with `adb`,
/// from a machine, by someone who already knew the answer. What a user needs
/// is the answer on the screen they are already looking at.
class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({super.key});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

/// One row of the permissions card: what the switch is, whether it is on, and
/// the system screen that turns it on.
class _PermissionRow {
  const _PermissionRow({
    required this.label,
    required this.hint,
    required this.read,
    required this.request,
  });

  final String label;
  final String hint;
  final Future<bool> Function() read;
  final Future<void> Function() request;
}

class _AdminPanelScreenState extends State<AdminPanelScreen> {
  final AppSettings _settings = AppSettings.instance;

  /// `null` while a row is still being read. Three-valued on purpose: "not
  /// asked yet" and "asked, and the answer is no" are different states, and
  /// collapsing them would show every permission as denied on first paint.
  final Map<String, bool?> _permissions = <String, bool?>{};

  List<Map<String, Object?>> _ledger = <Map<String, Object?>>[];
  bool _ledgerLoading = true;

  List<Masjid> _masjids = <Masjid>[];
  bool _masjidsLoading = true;

  bool _busy = false;

  late final List<_PermissionRow> _rows = <_PermissionRow>[
    _PermissionRow(
      label: 'Notifications',
      hint: 'Without this the phone still recites, with nothing on screen to '
          'explain why and no banner to dismiss.',
      read: AzaanAlarm.notificationsEnabled,
      request: () async {},
    ),
    _PermissionRow(
      label: 'Exact alarms',
      hint: 'Battery saver can drift a reminder off its minute by up to 15 '
          'without it.',
      read: AzaanAlarm.canScheduleExact,
      request: AzaanAlarm.requestExactAlarm,
    ),
    _PermissionRow(
      label: 'Display pop-up windows',
      hint: 'MIUI rejects a background window at the exact second an alarm '
          'fires without this. Optional elsewhere.',
      read: AzaanAlarm.canDrawOverlays,
      request: AzaanAlarm.requestOverlayPermission,
    ),
    _PermissionRow(
      label: 'Full-screen intent',
      hint: 'Android 14 made this a switch. Off means the recitation screen '
          'can never appear over the lock screen.',
      read: AzaanAlarm.canUseFullScreenIntent,
      request: AzaanAlarm.requestFullScreenIntent,
    ),
    _PermissionRow(
      label: 'Battery optimisation',
      hint: 'Doze delays the notification and can let a reminder miss its '
          'minute entirely.',
      read: () async => true,
      request: AzaanAlarm.requestNoBatteryOptimisation,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _settings.addListener(_onSettingsChanged);
    _refreshPermissions();
    _refreshLedger();
    _refreshMasjids();
  }

  @override
  void dispose() {
    _settings.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshPermissions() async {
    for (final _PermissionRow row in _rows) {
      final bool value = await _safe(row.read);
      if (!mounted) return;
      setState(() => _permissions[row.label] = value);
    }
  }

  Future<void> _refreshLedger() async {
    setState(() => _ledgerLoading = true);
    final List<Map<String, Object?>> ledger = await AzaanAlarm.alarmLedger();
    if (!mounted) return;
    setState(() {
      _ledger = ledger;
      _ledgerLoading = false;
    });
  }

  Future<void> _refreshMasjids() async {
    setState(() => _masjidsLoading = true);
    final List<Masjid> loaded = <Masjid>[];
    try {
      final QuerySnapshot<Map<String, dynamic>> snap =
          await FirebaseFirestore.instance.collection('masjids').get();
      for (final DocumentSnapshot<Map<String, dynamic>> doc in snap.docs) {
        try {
          loaded.add(Masjid.fromDoc(doc));
        } catch (_) {
          // One malformed board must not take the whole list down with it.
        }
      }
    } catch (error) {
      debugPrint('Noor ▸ admin masjid list failed: $error');
    }
    loaded.sort((Masjid a, Masjid b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (!mounted) return;
    setState(() {
      _masjids = loaded;
      _masjidsLoading = false;
    });
  }

  static Future<bool> _safe(Future<bool> Function() read) async {
    try {
      return await read();
    } catch (_) {
      return false;
    }
  }

  /// Re-derives every reminder from the settings as they now stand.
  ///
  /// Worth its own button because half the controls on this screen change what
  /// a reminder *is* — the method, the madhab, the sound, the timing, the
  /// place — and none of those changes are worth anything until the alarms are
  /// rebuilt from them.
  Future<void> _rearmAll() async {
    setState(() => _busy = true);
    try {
      NotificationService.invalidateTimeZone();
      await NotificationService.scheduleAzan(
        latitude: LocationService.anchorLatitude,
        longitude: LocationService.anchorLongitude,
      );
      await NotificationService.scheduleFavouriteAlerts();
      await _refreshLedger();
    } catch (error) {
      debugPrint('Noor ▸ admin re-arm failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendTest() async {
    setState(() => _busy = true);
    try {
      await NotificationService.testReminder();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editMasjid(Masjid? masjid) async {
    final bool? saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => ManualAddScreen(existing: masjid),
      ),
    );
    if (saved == true) _refreshMasjids();
  }

  Future<void> _deleteMasjid(Masjid masjid) async {
    final bool? proceed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('Delete ${masjid.name}?'),
        content: const Text(
          'Every user who follows this board loses it at once. This cannot be '
          'undone.',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete', style: TextStyle(color: NoorColors.danger)),
          ),
        ],
      ),
    );
    if (proceed != true) return;

    try {
      await FirebaseFirestore.instance.collection('masjids').doc(masjid.id).delete();
      // Take it out of this account's favourites too, cloud copy first —
      // otherwise the next sync would union the dead id straight back in.
      final List<String> ids = await FavouriteStore.cached();
      if (ids.remove(masjid.id)) {
        await FavouriteStore.cache(ids);
        final String? uid = FirebaseAuth.instance.currentUser?.uid;
        if (uid != null) {
          try {
            await FirebaseFirestore.instance
                .collection('users')
                .doc(uid)
                .collection('favourites')
                .doc(masjid.id)
                .delete();
          } catch (_) {}
        }
      }
      _toast('${masjid.name} deleted');
      _refreshMasjids();
    } catch (error) {
      _toast('Could not delete: $error');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// One line saying what is currently set for *everyone*, so the card is
  /// worth reading before it is opened — an owner checking "did my last edit
  /// land?" should not have to open the editor to find out.
  String _configSummary() {
    final AppConfigData config = AppConfig.instance.data;
    final List<String> parts = <String>[
      if (config.wallpaperUrl.isNotEmpty) 'Wallpaper',
      if (config.logoUrl.isNotEmpty) 'Logo',
      if (config.announcement.isNotEmpty) 'Notice',
      if (config.iconVariant != 0) kLauncherIconLabels[config.iconVariant],
      if (config.azanUrls.isNotEmpty)
        '${config.azanUrls.length} custom Azaan clip'
            '${config.azanUrls.length == 1 ? '' : 's'}',
    ];
    if (parts.isEmpty) {
      return 'Nothing set yet — the app is running on its own defaults. '
          'New profiles open on: ${config.defaults.describe()}';
    }
    return '${parts.join(' · ')} · new profiles open on: '
        '${config.defaults.describe()}';
  }

  @override
  Widget build(BuildContext context) {
    // Signed out while the panel is open: the controls stop belonging to
    // anyone, so they stop being shown rather than being left live.
    if (!AdminAccess.isAdmin) {
      return NoorScaffold(
        appBar: AppBar(title: const Text('Admin')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Text(
              'These controls are only shown to the account that owns this app.',
              textAlign: TextAlign.center,
              style: GoogleFonts.outfit(fontSize: 14, color: NoorColors.onGlassMuted),
            ),
          ),
        ),
      );
    }

    return NoorScaffold(
      appBar: AppBar(
        title: const Text('Admin'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Re-read everything',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _refreshPermissions();
              _refreshLedger();
              _refreshMasjids();
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 32),
        children: <Widget>[
          // ============================ A. ONE-TAP ACTIONS
          const SectionHeader(title: 'Actions'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GradientButton(
              label: _busy
                  ? 'Working…'
                  : AzanPlayer.instance.isPlaying
                      ? 'Stop Azaan'
                      : 'Re-arm every reminder',
              icon: AzanPlayer.instance.isPlaying
                  ? Icons.stop_circle_outlined
                  : Icons.alarm_on_outlined,
              busy: _busy,
              onPressed: AzanPlayer.instance.isPlaying
                  ? AzanPlayer.instance.stop
                  : _rearmAll,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: GradientButton(
              label: 'Send test reminder',
              icon: Icons.notifications_outlined,
              onPressed: _sendTest,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
            child: Text(
              'Re-arm rebuilds every reminder from the settings as they stand '
              'now — the thing to press after changing the method, the madhab, '
              'the sound, the timing or the place. The test arms one reminder '
              'now and a second a minute later; swipe Noor away first, since '
              'only the second one proves the phone will wake a closed app.',
              style: GoogleFonts.outfit(
                fontSize: 11,
                color: NoorColors.onGlassMuted,
                height: 1.55,
              ),
            ),
          ),

          // ============================ A2. THE OWNER'S CONFIG EDITOR
          //
          // Everything below this line changes *this phone*. Everything on
          // the other side of this entry changes every phone, which is why it
          // gets its own screen rather than a row among the diagnostics.
          const SectionHeader(title: 'App config · everyone'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GoldCard(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const AdminConfigScreen(),
                ),
              ),
              padding: const EdgeInsets.all(16),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: NoorColors.cardGreen,
                      borderRadius: BorderRadius.circular(13),
                      border: Border.all(
                        color: NoorColors.gold.withValues(alpha: 0.5),
                      ),
                    ),
                    child: const Icon(Icons.tune,
                        size: 20, color: NoorColors.onGlassGold),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Defaults, wallpaper, Azaan clips, icon',
                          style: GoogleFonts.outfit(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: NoorColors.onGlass,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _configSummary(),
                          style: GoogleFonts.outfit(
                            fontSize: 11,
                            color: NoorColors.onGlassMuted,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right,
                      size: 20, color: NoorColors.onGlassMuted),
                ],
              ),
            ),
          ),

          // ============================ B. PRAYER CALCULATION
          const SectionHeader(title: 'Prayer calculation'),
          GoldCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _label('Calculation method'),
                _dropdown<String>(
                  value: _settings.methodKey,
                  items: kCalcMethods
                      .map((CalcMethod m) => DropdownMenuItem<String>(
                            value: m.key,
                            child: Text(m.label, style: GoogleFonts.outfit(fontSize: 13)),
                          ))
                      .toList(),
                  onChanged: (String? key) {
                    if (key == null) return;
                    _settings.setMethod(key);
                  },
                ),
                Text(
                  _settings.method.hint,
                  style: GoogleFonts.outfit(
                    fontSize: 11,
                    color: NoorColors.onGlassMuted,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 16),
                _label('Madhab (Asr)'),
                _segmented<bool>(
                  value: _settings.isHanafi,
                  options: const <MapEntry<bool, String>>[
                    MapEntry<bool, String>(true, 'Hanafi'),
                    MapEntry<bool, String>(false, 'Shafi'),
                  ],
                  onChanged: (bool hanafi) => _settings.setMadhab(hanafi ? 'hanafi' : 'shafi'),
                ),
                const SizedBox(height: 16),
                _label('Hijri adjustment'),
                Row(
                  children: <Widget>[
                    _square(Icons.remove, () =>
                        _settings.setHijriAdjustment(_settings.hijriAdjustment - 1)),
                    const SizedBox(width: 12),
                    Text(
                      '${_settings.hijriAdjustment > 0 ? '+' : ''}${_settings.hijriAdjustment} day(s)',
                      style: GoogleFonts.outfit(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: NoorColors.onGlass,
                      ),
                    ),
                    const SizedBox(width: 12),
                    _square(Icons.add, () =>
                        _settings.setHijriAdjustment(_settings.hijriAdjustment + 1)),
                  ],
                ),
                const SizedBox(height: 16),
                _label('Time format'),
                _segmented<bool>(
                  value: _settings.use12Hour,
                  options: const <MapEntry<bool, String>>[
                    MapEntry<bool, String>(true, '12-hour'),
                    MapEntry<bool, String>(false, '24-hour'),
                  ],
                  onChanged: (bool twelve) =>
                      _settings.setTimeFormat(twelve ? '12' : '24'),
                ),
              ],
            ),
          ),

          // ============================ C. AZAN
          const SectionHeader(title: 'Azaan'),
          GoldCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _label('Sound'),
                const SizedBox(height: 6),
                ...kAzanSounds.map((AzanSound sound) {
                  final bool selected = _settings.azanSound == sound.key;
                  return InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      _settings.setAzanSound(sound.key);
                      if (sound.hasBundle) AzanPlayer.instance.preview(sound.key);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            selected ? Icons.radio_button_checked : Icons.radio_button_off,
                            size: 19,
                            color: selected ? NoorColors.onGlassGold : NoorColors.onGlassMuted,
                          ),
                          const SizedBox(width: 11),
                          Expanded(
                            child: Text(
                              sound.label,
                              style: GoogleFonts.outfit(
                                fontSize: 13.5,
                                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                                color: selected
                                    ? NoorColors.onGlass
                                    : NoorColors.onGlassMuted,
                              ),
                            ),
                          ),
                          Icon(
                            Icons.play_circle_outline,
                            size: 19,
                            color: sound.hasBundle
                                ? NoorColors.gold
                                : NoorColors.onGlassMuted.withValues(alpha: 0.35),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 10),
                _label('When the Azaan plays'),
                _dropdown<String>(
                  value: _settings.azaanTiming,
                  items: kAzaanTimingOptions
                      .map((String key) => DropdownMenuItem<String>(
                            value: key,
                            child: Text(
                              azaanTimingLabel(key),
                              style: GoogleFonts.outfit(fontSize: 13),
                            ),
                          ))
                      .toList(),
                  onChanged: (String? key) {
                    if (key == null) return;
                    _settings.setAzaanTiming(key);
                  },
                ),
                const SizedBox(height: 14),
                _switchRow(
                  'Prayer reminders',
                  'Master switch for every calculated reminder.',
                  _settings.notificationsEnabled,
                  (bool on) => _settings.setNotificationsEnabled(on),
                ),
              ],
            ),
          ),

          // ============================ D. LOCATION
          const SectionHeader(title: 'Location'),
          GoldCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _stat(
                  'GPS',
                  LocationService.lastPosition == null
                      ? 'Off — using the Mumbai fallback'
                      : 'On',
                  ok: LocationService.lastPosition != null,
                ),
                _stat(
                  'Custom override',
                  _settings.hasCustomLocation
                      ? _settings.customCity
                      : 'None — following GPS',
                  ok: !_settings.hasCustomLocation || _settings.customCity.isNotEmpty,
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: GradientButton(
                        label: 'Clear override',
                        icon: Icons.my_location,
                        expand: false,
                        onPressed: _settings.hasCustomLocation
                            ? () {
                                _settings.setCustomLocation(null, null, '');
                                _toast('Following GPS again');
                              }
                            : null,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // ============================ E. PERMISSIONS
          const SectionHeader(title: 'Permissions'),
          GoldCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Column(children: _rows.map(_permissionTile).toList()),
          ),

          // ============================ F. DIAGNOSTICS
          const SectionHeader(title: 'Diagnostics'),
          GoldCard(
            padding: const EdgeInsets.all(16),
            child: _ledgerLoading
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _stat(
                        'Armed alarms',
                        '${_ledger.length} in the ledger',
                        ok: _ledger.isNotEmpty,
                      ),
                      _stat(
                        'Recurring',
                        '${_ledger.where((Map<String, Object?> e) => e['recurring'] == true).length} '
                            'come back tomorrow',
                        ok: _ledger.any((Map<String, Object?> e) => e['recurring'] == true),
                      ),
                      const SizedBox(height: 10),
                      if (_ledger.isEmpty)
                        Text(
                          'Nothing is armed. A ledger with no entries means no '
                          'prayer reminder would survive a reboot.',
                          style: GoogleFonts.outfit(
                            fontSize: 12,
                            color: NoorColors.onGlassMuted,
                            height: 1.5,
                          ),
                        )
                      else
                        ..._ledger.map(_ledgerTile),
                    ],
                  ),
          ),

          // ============================ G. MASJIDS
          SectionHeader(
            title: 'Masjids (${_masjids.length})',
            action: IconButton(
              tooltip: 'Add a masjid',
              icon: const Icon(Icons.add_circle_outline),
              onPressed: () => _editMasjid(null),
            ),
          ),
          GoldCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: _masjidsLoading
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                : _masjids.isEmpty
                    ? Text(
                        'No masjids yet. Add the first board and every user who '
                        'stars it gets its Jamaat times.',
                        style: GoogleFonts.outfit(
                          fontSize: 12,
                          color: NoorColors.onGlassMuted,
                          height: 1.5,
                        ),
                      )
                    : Column(children: _masjids.map(_masjidTile).toList()),
          ),

          // ============================ H. ACCOUNT
          const SectionHeader(title: 'Account'),
          GoldCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _stat('Signed in as', AdminAccess.adminEmail, ok: true),
                _stat(
                  'User id',
                  (FirebaseAuth.instance.currentUser?.uid ?? '—'),
                  ok: FirebaseAuth.instance.currentUser != null,
                ),
                const SizedBox(height: 12),
                GradientButton(
                  label: 'Sign out',
                  icon: Icons.logout,
                  onPressed: () async {
                    // Captured before the await: once the account is gone the
                    // panel's own guard sends it back, and reaching for
                    // `context` afterwards is a widget tree that may no longer
                    // be there.
                    final NavigatorState navigator = Navigator.of(context);
                    await FirebaseAuth.instance.signOut();
                    if (!mounted) return;
                    navigator.pop();
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- widgets

  Widget _label(String text) => adminLabel(text);

  Widget _dropdown<T>({
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) =>
      adminDropdown<T>(value: value, items: items, onChanged: onChanged);

  /// A two-way choice — Hanafi/Shafi, 12/24 — drawn as one pill rather than a
  /// dropdown, because a dropdown with two entries is a menu pretending to be
  /// a decision.
  Widget _segmented<T>({
    required T value,
    required List<MapEntry<T, String>> options,
    required ValueChanged<T> onChanged,
  }) =>
      adminSegmented<T>(value: value, options: options, onChanged: onChanged);

  Widget _square(IconData icon, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(11),
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: NoorColors.cardGreen,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: NoorColors.gold.withValues(alpha: 0.5)),
        ),
        child: Icon(icon, size: 19, color: NoorColors.ink),
      ),
    );
  }

  Widget _switchRow(String title, String hint, bool value, ValueChanged<bool> onChanged) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: GoogleFonts.outfit(fontSize: 13.5, color: NoorColors.onGlass)),
              const SizedBox(height: 2),
              Text(
                hint,
                style: GoogleFonts.outfit(
                  fontSize: 11,
                  color: NoorColors.onGlassMuted,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: NoorColors.ink,
          activeTrackColor: NoorColors.emerald,
        ),
      ],
    );
  }

  Widget _permissionTile(_PermissionRow row) {
    final bool? value = _permissions[row.label];

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () async {
        await row.request();
        if (!mounted) return;
        // Re-read after the user comes back — the only moment it can change.
        final bool after = await _safe(row.read);
        if (!mounted) return;
        setState(() => _permissions[row.label] = after);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    row.label,
                    style: GoogleFonts.outfit(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: NoorColors.onGlass,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    row.hint,
                    style: GoogleFonts.outfit(
                      fontSize: 11,
                      color: NoorColors.onGlassMuted,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (value == null)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                value ? Icons.check_circle_outline : Icons.error_outline,
                size: 22,
                color: value ? NoorColors.onGlassGold : NoorColors.danger,
              ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, String value, {required bool ok}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            ok ? Icons.check_circle_outline : Icons.error_outline,
            size: 17,
            color: ok ? NoorColors.onGlassGold : NoorColors.danger,
          ),
          const SizedBox(width: 9),
          Text(label, style: GoogleFonts.outfit(fontSize: 13, color: NoorColors.onGlass)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: GoogleFonts.outfit(fontSize: 12, color: NoorColors.onGlassMuted),
            ),
          ),
        ],
      ),
    );
  }

  /// One armed alarm, in prayer order, as "06:05 — Fajr".
  Widget _ledgerTile(Map<String, Object?> entry) {
    final int hour = (entry['hour'] as num?)?.toInt() ?? 0;
    final int minute = (entry['minute'] as num?)?.toInt() ?? 0;
    final String? title = entry['title'] as String?;
    final String sound = (entry['sound'] as String?) ?? '';

    final String time =
        '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          Text(
            time,
            style: GoogleFonts.outfit(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: NoorColors.onGlassGold,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title ?? sound,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.outfit(fontSize: 13, color: NoorColors.onGlass),
            ),
          ),
          if (entry['recurring'] == true)
            Icon(Icons.loop, size: 15, color: NoorColors.onGlassMuted),
        ],
      ),
    );
  }

  Widget _masjidTile(Masjid masjid) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _editMasjid(masjid),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    masjid.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.outfit(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: NoorColors.onGlass,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Fajr ${masjid.fajr} · Dhuhr ${masjid.dhuhr} · '
                    'Asr ${masjid.asr} · Isha ${masjid.isha}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.outfit(fontSize: 11, color: NoorColors.onGlassMuted),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined, size: 19),
              color: NoorColors.gold,
              onPressed: () => _editMasjid(masjid),
            ),
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline, size: 19),
              color: NoorColors.danger,
              onPressed: () => _deleteMasjid(masjid),
            ),
          ],
        ),
      ),
    );
  }
}
