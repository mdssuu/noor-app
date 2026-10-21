import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app_look.dart';
import '../app_settings.dart';
import '../main.dart';
import '../services/azan_player.dart';
import '../services/places_service.dart';

/// Four pages, once per profile: where the times come from, how they are
/// calculated, and what the Azan should sound like.
///
/// The wizard is deliberately *short* — it collects the three answers that
/// change the very first screen, and everything else stays in Settings.
/// Every choice writes through [AppSettings] the moment it is made, so a
/// wizard abandoned on page two leaves behind a half-configured profile
/// that is still coherent (and still shows no wizard next time only if it
/// was actually finished — quitting is not consenting).
///
/// Seeding has already run by the time this opens (the owner's defaults
/// arrive first, in `_bootstrap`), so the choices here are a *user*
/// overwriting defaults — never the wizard racing the owner's config.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final AppSettings _settings = AppSettings.instance;
  final PageController _pages = PageController();

  int _page = 0;

  // ------------------------------------------------------------- location
  /// `gps` while no city is pinned; flipping to `city` reveals the search.
  late String _locationMode =
      _settings.hasCustomLocation ? 'city' : 'gps';

  final TextEditingController _cityQuery = TextEditingController();
  Timer? _cityDebounce;
  List<MasjidSearchResult> _cityResults = <MasjidSearchResult>[];
  bool _cityBusy = false;

  // ----------------------------------------------------------------- azan
  bool _previewPlaying = false;

  @override
  void initState() {
    super.initState();
    AzanPlayer.instance.addListener(_playbackChanged);
    _previewPlaying = AzanPlayer.instance.playingKey == _settings.azanSound;
  }

  void _playbackChanged() {
    if (!mounted) return;
    setState(() {
      _previewPlaying =
          AzanPlayer.instance.playingKey == _settings.azanSound;
    });
  }

  @override
  void dispose() {
    AzanPlayer.instance.removeListener(_playbackChanged);
    _cityDebounce?.cancel();
    _cityQuery.dispose();
    _pages.dispose();
    // A preview sounding after the screen that started it is gone would be
    // its own bug — the stop button is no longer reachable.
    unawaited(AzanPlayer.instance.stop());
    super.dispose();
  }

  // ------------------------------------------------------------- actions

  void _go(int page) {
    if (page < 0 || page > 3) return;
    setState(() => _page = page);
    _pages.animateToPage(
      page,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  /// Closes the wizard — and nothing else.
  ///
  /// Every choice it collected has already gone through [AppSettings] on the
  /// spot it was made, so there is nothing left to commit here but the flag.
  /// Re-arming the schedule is Home's job the moment this route pops (its
  /// `then` in `_bootstrap`): pulling it in here would stall the very frame
  /// that closes the wizard, because the first time-zone parse on a debug
  /// VM is synchronous and slow — the user would watch a closing animation
  /// freeze, and every future reading of this screen would inherit the wait.
  void _finish() {
    _settings.markOnboarded();
    Navigator.of(context).pop<bool>(true);
  }

  // ---------------------------------------------------------------- city

  void _searchCities(String raw) {
    final String query = raw.trim();
    _cityDebounce?.cancel();
    if (query.length < 2) {
      setState(() => _cityResults = <MasjidSearchResult>[]);
      return;
    }
    _cityDebounce = Timer(const Duration(milliseconds: 420), () async {
      final int token = ++_cityToken;
      setState(() => _cityBusy = true);
      try {
        final List<MasjidSearchResult> found =
            await searchCity(query, limit: 6);
        if (!mounted || token != _cityToken) return;
        setState(() => _cityResults = found);
      } catch (_) {
        if (!mounted || token != _cityToken) return;
        setState(() => _cityResults = <MasjidSearchResult>[]);
      } finally {
        if (mounted && token == _cityToken) setState(() => _cityBusy = false);
      }
    });
  }

  int _cityToken = 0;

  // --------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return NoorScaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            // Skip is always there: a wizard that cannot be escaped is a
            // trap, and everything it offers is in Settings anyway.
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _finish,
                child: Text(
                  'Skip',
                  style: GoogleFonts.outfit(
                    fontSize: 13,
                    color: NoorColors.onGlassMuted,
                  ),
                ),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pages,
                physics: const NeverScrollableScrollPhysics(),
                children: <Widget>[
                  _welcomePage(),
                  _locationPage(),
                  _calculationPage(),
                  _azaanPage(),
                ],
              ),
            ),
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _footer() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
      child: Row(
        children: <Widget>[
          if (_page > 0)
            TextButton(
              onPressed: () => _go(_page - 1),
              child: Text(
                'Back',
                style: GoogleFonts.outfit(
                  fontSize: 13.5,
                  color: NoorColors.onGlassMuted,
                ),
              ),
            )
          else
            const SizedBox(width: 72),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                for (int i = 0; i < 4; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _page ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                      color: i == _page
                          ? NoorColors.gold
                          : NoorColors.onGlassMuted.withValues(alpha: 0.45),
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(
            width: 96,
            child: GradientButton(
              label: _page == 3 ? 'Finish' : 'Next',
              expand: false,
              onPressed: _page == 3 ? _finish : () => _go(_page + 1),
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- pages

  Widget _welcomePage() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 30, 24, 10),
      children: <Widget> [
        Icon(Icons.mosque_outlined, size: 56, color: NoorColors.gold),
        const SizedBox(height: 16),
        Text(
          'Noor',
          textAlign: TextAlign.center,
          style: GoogleFonts.outfit(
            fontSize: 34,
            fontWeight: FontWeight.w800,
            color: NoorColors.onGlass,
          ),
        ),
        Text(
          'Masjid Time — real masjid, real time',
          textAlign: TextAlign.center,
          style: GoogleFonts.outfit(
            fontSize: 13,
            color: NoorColors.onGlassMuted,
          ),
        ),
        const SizedBox(height: 26),
        GoldCard(
          child: Column(
            children: <Widget>[
              _bullet(Icons.campaign_outlined,
                  'The Azaan rings at your masjid\'s own Jamaat time — and can sound even on a silent phone.'),
              const SizedBox(height: 12),
              _bullet(Icons.explore_outlined,
                  'Qibla, tasbeeh, the Hijri calendar and a salah streak — all one tap from Home.'),
              const SizedBox(height: 12),
              _bullet(Icons.widgets_outlined,
                  'A home-screen widget with today\'s times, before you even open the app.'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _bullet(IconData icon, String text) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 19, color: NoorColors.gold),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.outfit(
                fontSize: 12.5,
                height: 1.5,
                color: NoorColors.onGlass,
              ),
            ),
          ),
        ],
      );

  Widget _locationPage() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      children: <Widget>[
        _heading('Where are you praying?', 'The times on Home come from here.'),
        const SizedBox(height: 12),
        _optionCard(
          selected: _locationMode == 'gps',
          icon: Icons.my_location_outlined,
          title: 'Use my location',
          subtitle: 'Best for travelling — follows your GPS.',
          onTap: () {
            setState(() => _locationMode = 'gps');
            _settings.setCustomLocation(null, null, '');
          },
        ),
        const SizedBox(height: 10),
        _optionCard(
          selected: _locationMode == 'city',
          icon: Icons.location_city_outlined,
          title: 'Pin a city',
          subtitle: _settings.hasCustomLocation
              ? 'Times fixed to ${_settings.customCity}.'
              : 'No GPS needed — a home or a hometown.',
          onTap: () => setState(() => _locationMode = 'city'),
        ),
        if (_locationMode == 'city') ...<Widget>[
          const SizedBox(height: 10),
          GoldCard(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Column(
              children: <Widget>[
                TextField(
                  controller: _cityQuery,
                  onChanged: _searchCities,
                  style: GoogleFonts.outfit(
                      fontSize: 13.5, color: NoorColors.onGlass),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Search a city — Mumbai, Delhi, Hyderabad…',
                    hintStyle: GoogleFonts.outfit(
                        fontSize: 13, color: NoorColors.onGlassMuted),
                    prefixIcon: Icon(Icons.search,
                        size: 18, color: NoorColors.onGlassMuted),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                          color: NoorColors.onGlassMuted
                              .withValues(alpha: 0.4)),
                    ),
                  ),
                ),
                if (_cityBusy)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: LinearProgressIndicator(
                      minHeight: 2,
                      color: NoorColors.gold,
                      backgroundColor: NoorColors.onGlassChip,
                    ),
                  ),
                for (final MasjidSearchResult r in _cityResults)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.pin_drop_outlined,
                        size: 17, color: NoorColors.gold),
                    title: Text(
                      r.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.outfit(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: NoorColors.onGlass),
                    ),
                    subtitle: Text(
                      r.address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.outfit(
                          fontSize: 10.5, color: NoorColors.onGlassMuted),
                    ),
                    onTap: () {
                      _settings.setCustomLocation(
                          r.latitude, r.longitude, r.name);
                      _cityQuery.clear();
                      setState(() => _cityResults = <MasjidSearchResult>[]);
                      FocusScope.of(context).unfocus();
                    },
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 14),
        Text(
          'You can change this any time in Settings → Location.',
          textAlign: TextAlign.center,
          style: GoogleFonts.outfit(
            fontSize: 11,
            color: NoorColors.onGlassMuted,
          ),
        ),
      ],
    );
  }

  Widget _calculationPage() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      children: <Widget>[
        _heading('How should the times be calculated?',
            'Both can be changed later — your masjid\'s board wins anyway when you star it.'),
        const SizedBox(height: 14),
        GoldCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Calculation method',
                style: GoogleFonts.outfit(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: NoorColors.onGlassMuted,
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _settings.methodKey,
                isExpanded: true,
                dropdownColor: NoorColors.white,
                style: GoogleFonts.outfit(
                    fontSize: 13.5, color: NoorColors.ink),
                icon: Icon(Icons.keyboard_arrow_down,
                    color: NoorColors.gold, size: 20),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 11),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(11),
                    borderSide: BorderSide(
                        color: NoorColors.gold.withValues(alpha: 0.5)),
                  ),
                ),
                items: <DropdownMenuItem<String>>[
                  for (final CalcMethod m in kCalcMethods)
                    DropdownMenuItem<String>(
                      value: m.key,
                      child: Text(m.label, maxLines: 2),
                    ),
                ],
                onChanged: (String? key) {
                  if (key != null) _settings.setMethod(key);
                  setState(() {});
                },
              ),
              const SizedBox(height: 6),
              Text(
                kCalcMethods
                    .firstWhere((CalcMethod m) => m.key == _settings.methodKey,
                        orElse: () => kCalcMethods.first)
                    .hint,
                style: GoogleFonts.outfit(
                  fontSize: 11,
                  height: 1.4,
                  color: NoorColors.onGlassMuted,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GoldCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Asr — which school?',
                style: GoogleFonts.outfit(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: NoorColors.onGlassMuted,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _madhabTile(
                      key: 'hanafi',
                      title: 'Hanafi',
                      note: 'Later Asr — the standard across India',
                      selected: _settings.isHanafi,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _madhabTile(
                      key: 'shafi',
                      title: 'Shafi / Maliki / Hanbali',
                      note: 'Earlier Asr',
                      selected: !_settings.isHanafi,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _madhabTile(
          {required String key,
          required String title,
          required String note,
          required bool selected}) =>
      InkWell(
        onTap: () {
          _settings.setMadhab(key);
          setState(() {});
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: selected
                ? NoorColors.gold.withValues(alpha: 0.20)
                : NoorColors.onGlassChip,
            border: Border.all(
              color: selected
                  ? NoorColors.gold
                  : NoorColors.onGlassMuted.withValues(alpha: 0.35),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: GoogleFonts.outfit(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: selected ? NoorColors.gold : NoorColors.onGlass,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                note,
                style: GoogleFonts.outfit(
                  fontSize: 10.5,
                  height: 1.35,
                  color: NoorColors.onGlassMuted,
                ),
              ),
            ],
          ),
        ),
      );

  Widget _azaanPage() {
    final int offset = _settings.notifyOffsetFor('fajr');
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      children: <Widget>[
        _heading('What should the Azaan sound like?',
            'It rings through the alarm volume — the one your silent mode cannot mute.'),
        const SizedBox(height: 14),
        GoldCard(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Azan reminders',
                      style: GoogleFonts.outfit(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: NoorColors.onGlass,
                      ),
                    ),
                  ),
                  Switch(
                    value: _settings.notificationsEnabled,
                    activeThumbColor: NoorColors.ink,
                    activeTrackColor: NoorColors.gold,
                    onChanged: (bool on) {
                      _settings.setNotificationsEnabled(on);
                      setState(() {});
                    },
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: <Widget>[
                  for (final AzanSound sound in kAzanSounds)
                    ChoiceChip(
                      selected: sound.key == _settings.azanSound,
                      onSelected: (bool _) {
                        _settings.setAzanSound(sound.key);
                        setState(() {});
                      },
                      label: Text(
                        sound.label,
                        style: GoogleFonts.outfit(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: sound.key == _settings.azanSound
                              ? NoorColors.ink
                              : NoorColors.onGlass,
                        ),
                      ),
                      selectedColor: NoorColors.gold,
                      backgroundColor: NoorColors.onGlassChip,
                      side: BorderSide(
                        color: sound.key == _settings.azanSound
                            ? NoorColors.gold
                            : NoorColors.onGlassMuted
                                .withValues(alpha: 0.35),
                      ),
                      showCheckmark: false,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _settings.azanSound == 'silent'
                      ? null
                      : () {
                          if (_previewPlaying) {
                            unawaited(AzanPlayer.instance.stop());
                          } else {
                            unawaited(AzanPlayer.instance.playSelected());
                          }
                        },
                  icon: Icon(
                    _previewPlaying ? Icons.stop : Icons.play_arrow,
                    size: 18,
                    color: NoorColors.gold,
                  ),
                  label: Text(
                    _previewPlaying ? 'Stop' : 'Listen',
                    style: GoogleFonts.outfit(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: NoorColors.gold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GoldCard(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Remind me…',
                style: GoogleFonts.outfit(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: NoorColors.onGlassMuted,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: <Widget>[
                  for (final int minutes in kNotifyOffsets)
                    ChoiceChip(
                      selected: offset == minutes,
                      onSelected: (bool _) {
                        // One answer for all five prayers — the per-prayer
                        // rows live in Settings for anyone who wants them.
                        for (final String key in kNotifiablePrayers) {
                          _settings.setNotifyOffset(key, minutes);
                        }
                        setState(() {});
                      },
                      label: Text(
                        notifyOffsetChipLabel(minutes),
                        style: GoogleFonts.outfit(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: offset == minutes
                              ? NoorColors.ink
                              : NoorColors.onGlass,
                        ),
                      ),
                      selectedColor: NoorColors.gold,
                      backgroundColor: NoorColors.onGlassChip,
                      side: BorderSide(
                        color: offset == minutes
                            ? NoorColors.gold
                            : NoorColors.onGlassMuted
                                .withValues(alpha: 0.35),
                      ),
                      showCheckmark: false,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Applied to all five prayers; tune each one separately in Settings.',
                style: GoogleFonts.outfit(
                  fontSize: 10.5,
                  color: NoorColors.onGlassMuted,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ----------------------------------------------------------- fragments

  Widget _heading(String title, String subtitle) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: GoogleFonts.outfit(
              fontSize: 21,
              fontWeight: FontWeight.w800,
              color: NoorColors.onGlass,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: GoogleFonts.outfit(
              fontSize: 12.5,
              height: 1.45,
              color: NoorColors.onGlassMuted,
            ),
          ),
        ],
      );

  Widget _optionCard({
    required bool selected,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: selected
              ? NoorColors.gold.withValues(alpha: 0.18)
              : NoorColors.onGlassChip,
          border: Border.all(
            color: selected
                ? NoorColors.gold
                : NoorColors.onGlassMuted.withValues(alpha: 0.35),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: <Widget>[
            Icon(icon,
                size: 24,
                color: selected ? NoorColors.gold : NoorColors.onGlassMuted),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: GoogleFonts.outfit(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: selected
                          ? NoorColors.gold
                          : NoorColors.onGlass,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: GoogleFonts.outfit(
                      fontSize: 11.5,
                      height: 1.4,
                      color: NoorColors.onGlassMuted,
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              Icon(Icons.check_circle, size: 20, color: NoorColors.gold),
          ],
        ),
      ),
    );
  }
}
