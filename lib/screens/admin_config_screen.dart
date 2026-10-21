import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app_look.dart';
import '../app_settings.dart';
import '../main.dart';
import '../prayer_readings.dart';
import '../services/admin_access.dart';
import '../services/app_config.dart';
import '../services/azan_player.dart';
import 'admin_controls.dart';

/// The owner's editor for `app_config/general` — the document that decides
/// what every phone running Noor looks and sounds like.
///
/// Reached from the admin panel, and only from an account the panel has
/// already accepted. Everything on this screen writes to *one* Firestore
/// document; nothing here changes this phone's own preferences, and nothing
/// it writes ever reaches a profile that has already made choices of its own.
/// That split is the whole design:
///
///  * **Defaults for new users** — applied once, at first launch, to a
///    profile with no stored settings. Existing users keep their settings.
///  * **Look and clips** — everyone's, because a masjid's wallpaper and its
///    Azaan are not a preference, they are the app.
///
/// The editor holds its own copy of the document ([_draft]) rather than
/// writing on every keystroke: it is one save, visibly dirty, with the
/// changes not applied to anyone until that save goes through. Firestore
/// rules are what actually decide *who* may write — this screen is only
/// where the owner does it.
class AdminConfigScreen extends StatefulWidget {
  const AdminConfigScreen({super.key});

  @override
  State<AdminConfigScreen> createState() => _AdminConfigScreenState();
}

class _AdminConfigScreenState extends State<AdminConfigScreen> {
  /// The document as this screen would leave it.
  ///
  /// The four text fields are deliberately *not* mirrored here — they live in
  /// their controllers and are read back by [_collect] at save time, so a
  /// half-typed URL is never part of the state being compared for dirt.
  late AppConfigData _draft;

  /// Whether any control on this screen has been touched. While untouched, a
  /// change arriving from the other direction (this document is also watched)
  /// is pulled in rather than being overwritten by a stale form.
  bool _pristine = true;

  late final TextEditingController _wallpaper;
  late final TextEditingController _logo;
  late final TextEditingController _announcement;
  final Map<String, TextEditingController> _clipControllers =
      <String, TextEditingController>{};

  bool _busy = false;

  /// The sound slots that have a bundled clip to be replaced.
  late final List<AzanSound> _clippable = kAzanSounds
      .where((AzanSound sound) => sound.androidRaw != null)
      .toList(growable: false);

  @override
  void initState() {
    super.initState();
    // Every controller first: [_apply] writes straight into all of them, and
    // a `late final` field left unassigned takes the whole screen down with
    // a LateInitializationError the moment the document is poured in.
    _wallpaper = TextEditingController();
    _logo = TextEditingController();
    _announcement = TextEditingController();
    for (final AzanSound sound in _clippable) {
      _clipControllers[sound.key] = TextEditingController();
    }
    _apply(AppConfig.instance.data);
    AppConfig.instance.addListener(_configChanged);
  }

  @override
  void dispose() {
    AppConfig.instance.removeListener(_configChanged);
    _wallpaper.dispose();
    _logo.dispose();
    _announcement.dispose();
    for (final TextEditingController c in _clipControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _configChanged() {
    // Only while the form is still an untouched mirror of the document: the
    // owner typing is a reason for this screen to *not* follow.
    if (!_pristine || !mounted) return;
    setState(() => _apply(AppConfig.instance.data));
  }

  void _apply(AppConfigData data) {
    _draft = data;
    _wallpaper.text = data.wallpaperUrl;
    _logo.text = data.logoUrl;
    _announcement.text = data.announcement;
    for (final AzanSound sound in _clippable) {
      _clipControllers[sound.key]!.text = data.azanUrls[sound.key] ?? '';
    }
  }

  /// Moves the draft to [next] and marks the form as spoken for.
  void _set(AppConfigData next) {
    setState(() {
      _pristine = false;
      _draft = next;
    });
  }

  // ------------------------------------------------------------------ saving

  /// The document as this screen leaves it: the draft, with the text fields
  /// read back in. A URL that is not a URL reads as empty rather than being
  /// written for every phone to choke on — [AppConfigData.fromMap] would drop
  /// it on the way back out anyway, and doing it here keeps the two honest.
  AppConfigData _collect() {
    final Map<String, String> clips = <String, String>{
      ..._draft.azanUrls,
    };
    for (final AzanSound sound in _clippable) {
      clips[sound.key] = _cleanUrl(_clipControllers[sound.key]!.text);
    }
    clips.removeWhere((String key, String url) => url.isEmpty);

    return _draft.copyWith(
      wallpaperUrl: _cleanUrl(_wallpaper.text),
      logoUrl: _cleanUrl(_logo.text),
      announcement: _announcement.text.trim(),
      azanUrls: clips,
    );
  }

  bool get _dirty => _collect() != AppConfig.instance.data;

  static String _cleanUrl(String raw) {
    final String text = raw.trim();
    if (text.isEmpty) return '';
    final Uri? uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) return '';
    if (uri.scheme != 'http' && uri.scheme != 'https') return '';
    return text;
  }

  /// True when the field holds something that cannot be fetched: shown as a
  /// red border rather than discovered by every user when it fails.
  bool _looksBroken(String raw) {
    final String text = raw.trim();
    return text.isNotEmpty && _cleanUrl(text).isEmpty;
  }

  Future<void> _save({bool announce = true}) async {
    setState(() => _busy = true);
    try {
      final AppConfigData next = _collect();
      await AppConfig.instance.save(next);
      // Saving is not the same as having: the wallpaper, the logo and the
      // clips still have to be *downloaded* before anyone can see or hear
      // them, so the save waits for that before claiming success.
      await AppConfig.instance.prepareMedia();
      _draft = next;
      _pristine = false;
      if (mounted) setState(() {});
      if (announce) {
        _toast('Saved — it reaches every phone on its next sync.');
      }
    } catch (error) {
      _toast('Not saved: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Save, then let the owner hear the clip they just pointed at.
  ///
  /// In that order on purpose: the preview plays the *file on this phone*,
  /// which only becomes the new clip once it has been fetched — so a play
  /// pressed before saving would audition the clip that is already in force.
  Future<void> _saveAndPlay(String key) async {
    await _save(announce: false);
    await AzanPlayer.instance.preview(key);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    // Signed out while the editor is open: the write would be refused by the
    // rules anyway, and a form that pretends otherwise is worse than none.
    if (!AdminAccess.isAdmin) {
      return NoorScaffold(
        appBar: AppBar(title: const Text('App config')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Text(
              'These controls are only shown to the account that owns this app.',
              textAlign: TextAlign.center,
              style:
                  GoogleFonts.outfit(fontSize: 14, color: NoorColors.onGlassMuted),
            ),
          ),
        ),
      );
    }

    final bool dirty = _dirty;

    return NoorScaffold(
      appBar: AppBar(title: const Text('App config')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 32),
        children: <Widget>[
          // ------------------------------- what this is
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GoldCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'One document, every phone',
                    style: GoogleFonts.outfit(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: NoorColors.onGlass,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Everything below is written to app_config/general and '
                    'picked up by every installed copy the next time it syncs — '
                    'no update, no code, no reinstall. Defaults apply to a user '
                    'who has never opened Settings; look and clips apply to '
                    'everyone, always.',
                    style: GoogleFonts.outfit(
                      fontSize: 12,
                      color: NoorColors.onGlassMuted,
                      height: 1.55,
                    ),
                  ),
                  const SizedBox(height: 14),
                  GradientButton(
                    label: _busy
                        ? 'Saving…'
                        : dirty
                            ? 'Save changes'
                            : 'Everything is saved',
                    icon: dirty ? Icons.cloud_upload_outlined : Icons.check,
                    busy: _busy,
                    onPressed: dirty ? _save : null,
                  ),
                ],
              ),
            ),
          ),

          // ============================ A. DEFAULTS FOR NEW USERS
          const SectionHeader(title: 'Defaults for new users'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GoldCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Given once, to a brand-new user — the first time the app '
                    'opens on an account that has never stored a setting. '
                    'Everyone who is already using Noor keeps exactly what they '
                    'chose; these numbers never reach them.',
                    style: GoogleFonts.outfit(
                      fontSize: 11.5,
                      color: NoorColors.onGlassMuted,
                      height: 1.55,
                    ),
                  ),
                  const SizedBox(height: 16),

                  adminLabel('Calculation method'),
                  adminDropdown<String>(
                    value: _draft.defaults.method,
                    items: kCalcMethods
                        .map((CalcMethod m) => DropdownMenuItem<String>(
                              value: m.key,
                              child: Text(m.label,
                                  style: GoogleFonts.outfit(fontSize: 13)),
                            ))
                        .toList(),
                    onChanged: (String? key) {
                      if (key == null) return;
                      _set(_draft.copyWith(
                          defaults: _draft.defaults.copyWith(method: key)));
                    },
                  ),

                  const SizedBox(height: 16),
                  adminLabel('Madhab (Asr)'),
                  adminSegmented<bool>(
                    value: _draft.defaults.madhab == 'hanafi',
                    options: const <MapEntry<bool, String>>[
                      MapEntry<bool, String>(true, 'Hanafi'),
                      MapEntry<bool, String>(false, 'Shafi'),
                    ],
                    onChanged: (bool hanafi) => _set(_draft.copyWith(
                        defaults:
                            _draft.defaults.copyWith(madhab: hanafi ? 'hanafi' : 'shafi'))),
                  ),

                  const SizedBox(height: 16),
                  adminLabel('Reminder, minutes before each prayer'),
                  adminDropdown<int>(
                    value: _offsetValue(_draft.defaults.minutesBefore),
                    items: kNotifyOffsets
                        .map((int m) => DropdownMenuItem<int>(
                              value: m,
                              child: Text(notifyOffsetLabel(m),
                                  style: GoogleFonts.outfit(fontSize: 13)),
                            ))
                        .toList(),
                    onChanged: (int? minutes) {
                      if (minutes == null) return;
                      _set(_draft.copyWith(
                          defaults: _draft.defaults
                              .copyWith(minutesBefore: minutes)));
                    },
                  ),

                  const SizedBox(height: 16),
                  adminLabel('When the Azaan plays'),
                  adminDropdown<String>(
                    value: kAzaanTimingOptions.contains(_draft.defaults.azaanTiming)
                        ? _draft.defaults.azaanTiming
                        : kAzaanTimingDefault,
                    items: kAzaanTimingOptions
                        .map((String key) => DropdownMenuItem<String>(
                              value: key,
                              child: Text(azaanTimingLabel(key),
                                  style: GoogleFonts.outfit(fontSize: 13)),
                            ))
                        .toList(),
                    onChanged: (String? key) {
                      if (key == null) return;
                      _set(_draft.copyWith(
                          defaults: _draft.defaults.copyWith(azaanTiming: key)));
                    },
                  ),

                  const SizedBox(height: 16),
                  adminLabel('Azaan clip'),
                  adminDropdown<String>(
                    value: azanSoundByKey(_draft.defaults.azanSound).key,
                    items: kAzanSounds
                        .map((AzanSound s) => DropdownMenuItem<String>(
                              value: s.key,
                              child: Text(s.label,
                                  style: GoogleFonts.outfit(fontSize: 13)),
                            ))
                        .toList(),
                    onChanged: (String? key) {
                      if (key == null) return;
                      _set(_draft.copyWith(
                          defaults: _draft.defaults.copyWith(azanSound: key)));
                    },
                  ),

                  const SizedBox(height: 16),
                  adminLabel('Time format'),
                  adminSegmented<String>(
                    value: _draft.defaults.timeFormat == '24' ? '24' : '12',
                    options: const <MapEntry<String, String>>[
                      MapEntry<String, String>('12', '12 hour'),
                      MapEntry<String, String>('24', '24 hour'),
                    ],
                    onChanged: (String format) => _set(_draft.copyWith(
                        defaults: _draft.defaults.copyWith(timeFormat: format))),
                  ),

                  const SizedBox(height: 16),
                  adminLabel('Hijri date adjustment'),
                  adminDropdown<int>(
                    value: _draft.defaults.hijriAdjustment,
                    items: <int>[-3, -2, -1, 0, 1, 2, 3]
                        .map((int d) => DropdownMenuItem<int>(
                              value: d,
                              child: Text(_hijriLabel(d),
                                  style: GoogleFonts.outfit(fontSize: 13)),
                            ))
                        .toList(),
                    onChanged: (int? days) {
                      if (days == null) return;
                      _set(_draft.copyWith(
                          defaults:
                              _draft.defaults.copyWith(hijriAdjustment: days)));
                    },
                  ),

                  const SizedBox(height: 16),
                  adminLabel('Language of the reading cards'),
                  adminDropdown<String>(
                    value: kReadingLanguageKeys
                            .contains(_draft.defaults.readingLanguage)
                        ? _draft.defaults.readingLanguage
                        : kReadingLanguageUrdu,
                    items: kReadingLanguageKeys
                        .map((String key) => DropdownMenuItem<String>(
                              value: key,
                              child: Text(kReadingLanguageLabels[key] ?? key,
                                  style: GoogleFonts.outfit(fontSize: 13)),
                            ))
                        .toList(),
                    onChanged: (String? key) {
                      if (key == null) return;
                      _set(_draft.copyWith(
                          defaults:
                              _draft.defaults.copyWith(readingLanguage: key)));
                    },
                  ),

                  const SizedBox(height: 14),
                  _switchRow(
                    title: 'Azan reminders on',
                    hint: 'Whether a fresh install starts with the reminder '
                        'switches on. Each prayer can still be switched off '
                        'by the user afterwards.',
                    value: _draft.defaults.notificationsEnabled,
                    onChanged: (bool on) => _set(_draft.copyWith(
                        defaults:
                            _draft.defaults.copyWith(notificationsEnabled: on))),
                  ),

                  const SizedBox(height: 14),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => _set(_draft.copyWith(
                          defaults: const NewUserDefaults())),
                      icon: const Icon(Icons.restart_alt, size: 16),
                      label: Text(
                        'Back to the app’s own defaults',
                        style: GoogleFonts.outfit(fontSize: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ============================ B. LOOK — FOR EVERYONE
          const SectionHeader(title: 'Look — for everyone'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GoldCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  adminLabel('Wallpaper (direct image link)'),
                  _urlField(
                    controller: _wallpaper,
                    hint: 'https://…/masjid.jpg',
                  ),
                  if (_wallpaper.text.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SizedBox(
                        height: 110,
                        width: double.infinity,
                        child: Image(
                          image: NetworkImage(_wallpaper.text.trim()),
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            color: NoorColors.cardGreen,
                            alignment: Alignment.center,
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              'This link does not open as an image. Use a '
                              'direct http/https link that ends in a picture.',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.outfit(
                                fontSize: 11,
                                color: NoorColors.onGlassMuted,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                  _hint('Stands behind every screen; the skyline and the glass '
                      'cards stay in front of it. Empty means the drawn sky.'),

                  const SizedBox(height: 16),
                  adminLabel('App logo (direct image link)'),
                  _urlField(controller: _logo, hint: 'https://…/logo.png'),
                  if (_logo.text.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 10),
                    ClipOval(
                      child: Container(
                        width: 72,
                        height: 72,
                        color: NoorColors.cardGreen,
                        child: Image(
                          image: NetworkImage(_logo.text.trim()),
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const Icon(
                              Icons.broken_image_outlined,
                              color: NoorColors.onGlassMuted),
                        ),
                      ),
                    ),
                  ],
                  _hint('Takes the place of the نور badge wherever it appears — '
                      'splash and profile. Empty means the built-in mark.'),

                  const SizedBox(height: 16),
                  adminLabel('Notice shown at the top of Home'),
                  _urlField(
                    controller: _announcement,
                    hint: 'e.g. Jumu’ah Salah at 13:30 this week',
                    maxLines: 3,
                    broken: false,
                    maxLength: 400,
                  ),
                  _hint('Shown until the reader dismisses it; a new sentence '
                      'brings it back. Empty means nothing is announced.'),

                  const SizedBox(height: 16),
                  adminLabel('Launcher icon'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (int i = 0; i < kLauncherIconLabels.length; i++)
                        _iconChoice(i),
                    ],
                  ),
                  _hint('Android draws the launcher icon from the app’s own '
                      'resources, so it can be switched between the four '
                      'prepared here but not replaced by any file. A change '
                      'can take a moment to appear while the launcher '
                      'refreshes.'),
                ],
              ),
            ),
          ),

          // ============================ C. AZAAN CLIPS
          const SectionHeader(title: 'Azaan clips'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GoldCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'A direct link to an audio file replaces the clip the app '
                    'ships with. The app downloads it once and keeps it on the '
                    'phone, so it plays with no network and with the app '
                    'closed — and if the link ever dies, the bundled clip '
                    'takes the slot back instead of the Azaan going silent.',
                    style: GoogleFonts.outfit(
                      fontSize: 11.5,
                      color: NoorColors.onGlassMuted,
                      height: 1.55,
                    ),
                  ),
                  for (final AzanSound sound in _clippable) ...<Widget>[
                    const SizedBox(height: 16),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: adminLabel(sound.label),
                        ),
                        Text(
                          (_clipControllers[sound.key]!.text.isEmpty)
                              ? 'bundled'
                              : 'custom',
                          style: GoogleFonts.outfit(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.6,
                            color: _clipControllers[sound.key]!.text.isEmpty
                                ? NoorColors.onGlassMuted
                                : NoorColors.onGlassGold,
                          ),
                        ),
                      ],
                    ),
                    _urlField(
                      controller: _clipControllers[sound.key]!,
                      hint: 'https://…/azaan.mp3',
                      onChanged: (_) => setState(() {}),
                    ),
                    Row(
                      children: <Widget>[
                        TextButton.icon(
                          onPressed: () => _saveAndPlay(sound.key),
                          icon: const Icon(Icons.play_arrow, size: 17),
                          label: Text(
                            'Save & play',
                            style: GoogleFonts.outfit(fontSize: 12),
                          ),
                        ),
                        if (_clipControllers[sound.key]!.text.isNotEmpty)
                          TextButton.icon(
                            onPressed: () {
                              _clipControllers[sound.key]!.clear();
                              setState(() {});
                            },
                            icon: const Icon(Icons.delete_outline, size: 16),
                            label: Text(
                              'Use the bundled clip',
                              style: GoogleFonts.outfit(fontSize: 12),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),

          // ------------------------------- save, again, at the end
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: GradientButton(
              label: _busy
                  ? 'Saving…'
                  : dirty
                      ? 'Save changes'
                      : 'Everything is saved',
              icon: dirty ? Icons.cloud_upload_outlined : Icons.check,
              busy: _busy,
              onPressed: dirty ? _save : null,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- widgets

  /// A stored offset that is not one of the offered choices still needs a
  /// value the dropdown accepts — the menu itself cannot invent one.
  int _offsetValue(int minutes) =>
      kNotifyOffsets.contains(minutes) ? minutes : kNotifyOffsets.first;

  static String _hijriLabel(int days) {
    if (days == 0) return 'No change';
    final String plural = days == 1 || days == -1 ? 'day' : 'days';
    return '${days > 0 ? '+' : ''}$days $plural';
  }

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.only(top: 7),
        child: Text(
          text,
          style: GoogleFonts.outfit(
            fontSize: 11,
            color: NoorColors.onGlassMuted,
            height: 1.5,
          ),
        ),
      );

  Widget _urlField({
    required TextEditingController controller,
    required String hint,
    ValueChanged<String>? onChanged,
    int maxLines = 1,
    int? maxLength,
    bool broken = true,
  }) {
    final bool invalid = broken && _looksBroken(controller.text);
    return TextField(
      controller: controller,
      maxLines: maxLines,
      maxLength: maxLength,
      keyboardType: maxLines > 1 ? TextInputType.multiline : TextInputType.url,
      style: GoogleFonts.outfit(fontSize: 13, color: NoorColors.onGlass),
      onChanged: (String value) {
        if (onChanged != null) {
          onChanged(value);
        } else {
          // The preview and the dirty flag both hang off the text.
          setState(() {});
        }
      },
      decoration: InputDecoration(
        counterText: '',
        hintText: hint,
        hintStyle: GoogleFonts.outfit(
            fontSize: 13, color: NoorColors.onGlassMuted.withValues(alpha: 0.7)),
        errorText: invalid ? 'Needs a full http:// or https:// link' : null,
        filled: true,
        fillColor: NoorColors.cardGreen,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: BorderSide(
              color: (invalid
                      ? NoorColors.muted
                      : NoorColors.gold.withValues(alpha: 0.6))),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: BorderSide(
              color: (invalid
                      ? NoorColors.muted
                      : NoorColors.gold.withValues(alpha: 0.6))),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: const BorderSide(color: NoorColors.emerald, width: 1.4),
        ),
      ),
    );
  }

  Widget _switchRow({
    required String title,
    required String hint,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title,
                  style:
                      GoogleFonts.outfit(fontSize: 13.5, color: NoorColors.onGlass)),
              const SizedBox(height: 2),
              Text(hint,
                  style: GoogleFonts.outfit(
                      fontSize: 11,
                      color: NoorColors.onGlassMuted,
                      height: 1.45)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Switch(
          value: value,
          activeThumbColor: NoorColors.emerald,
          onChanged: onChanged,
        ),
      ],
    );
  }

  /// One of the four prepared launcher icons, drawn as a choice rather than
  /// named — an owner picking an icon should be looking at icons.
  Widget _iconChoice(int index) {
    final bool selected = _draft.iconVariant == index;
    return InkWell(
      borderRadius: BorderRadius.circular(13),
      onTap: () => _set(_draft.copyWith(iconVariant: index)),
      child: Container(
        width: 76,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        decoration: BoxDecoration(
          color: selected ? NoorColors.emerald : NoorColors.cardGreen,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: selected
                ? NoorColors.emerald
                : NoorColors.gold.withValues(alpha: 0.5),
          ),
        ),
        child: Column(
          children: <Widget>[
            Icon(
              _iconGlyph(index),
              size: 22,
              color: selected ? NoorColors.ink : NoorColors.onGlassGold,
            ),
            const SizedBox(height: 6),
            Text(
              kLauncherIconLabels[index],
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.outfit(
                fontSize: 9.5,
                height: 1.25,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? NoorColors.ink : NoorColors.onGlassMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// What each prepared icon looks like, for the picker.
  ///
  /// The real art lives in `res/mipmap`; this is its shadow on the panel —
  /// enough to tell the four apart, never pretending to be the launcher's
  /// rendering of them.
  static IconData _iconGlyph(int index) {
    switch (index) {
      case 1:
        return Icons.nightlight_round;
      case 2:
        return Icons.star_outline;
      case 3:
        return Icons.location_city_outlined;
      case 0:
      default:
        return Icons.mosque_outlined;
    }
  }
}
