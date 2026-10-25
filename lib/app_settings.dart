import 'package:adhan_dart/adhan_dart.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'prayer_readings.dart';

/// The calculation methods offered in Settings, in the order they appear.
class CalcMethod {
  const CalcMethod(this.key, this.label, this.hint);

  final String key;

  /// Exactly the wording the user sees in the dropdown.
  final String label;

  /// One-line explanation under the dropdown.
  final String hint;

  CalculationParameters build() {
    switch (key) {
      case 'ummAlQura':
        return CalculationMethodParameters.ummAlQura();
      case 'egyptian':
        return CalculationMethodParameters.egyptian();
      case 'karachi':
        return CalculationMethodParameters.karachi();
      case 'dubai':
        return CalculationMethodParameters.dubai();
      case 'moonsighting':
        return CalculationMethodParameters.moonsightingCommittee();
      case 'awwal':
        // "Awwal Waqt" — take the earliest permissible Fajr (18°).
        return CalculationParameters(
          method: CalculationMethod.other,
          fajrAngle: 18,
          ishaAngle: 17,
        );
      case 'muslimWorldLeague':
      default:
        return CalculationMethodParameters.muslimWorldLeague();
    }
  }
}

const List<CalcMethod> kCalcMethods = <CalcMethod>[
  CalcMethod('muslimWorldLeague', 'Muslim World League',
      '18° Fajr · 17° Isha — the default used across India.'),
  CalcMethod('ummAlQura', 'Umm Al-Qura', '18.5° Fajr · Isha 90 min after Maghrib.'),
  CalcMethod('egyptian', 'Egyptian General Authority', '19.5° Fajr · 17.5° Isha.'),
  CalcMethod('karachi', 'University of Islamic Sciences, Karachi',
      '18° Fajr · 18° Isha — common on Indian boards.'),
  CalcMethod('dubai', 'Dubai', '18.2° Fajr · 18.2° Isha.'),
  CalcMethod('moonsighting', 'Moonsighting Committee',
      '18° Fajr · 18° Isha, local moon-sighting offsets.'),
  CalcMethod('awwal', 'Custom · Awwal Waqt (18°)',
      'Earliest permissible time — used by many desi masjids.'),
];

/// The Azan ringtones offered in Settings.
///
/// Every entry names the audio file *bundled with the app* first: an Azan that
/// only exists as a URL cannot be attached to an Android notification channel,
/// which is why the reminder used to fall back to the system "ding". [url] is
/// kept purely as a preview fallback on the platforms that have no native
/// bundle (desktop/web) or when the platform channel is unavailable.
class AzanSound {
  const AzanSound(
    this.key,
    this.label, {
    this.url,
    this.androidRaw,
    this.iosSound,
  });

  final String key;
  final String label;

  /// Remote clip used for the in-app preview when the native bundle cannot be
  /// played. `null` needs no network: `silent` plays nothing at all.
  final String? url;

  /// File name (without extension) in `android/app/src/main/res/raw/`.
  ///
  /// This is what the notification channel plays with the app closed, and what
  /// the alarm-stream fallback plays when the phone is on silent.
  final String? androidRaw;

  /// File name (with extension) inside the iOS app bundle. iOS cannot play a
  /// sound that is not in the bundle, so `null` means "default system sound".
  final String? iosSound;

  /// Android must never be left without a sound resource, otherwise the
  /// channel silently degrades to the default tone.
  bool get hasBundle => androidRaw != null || iosSound != null;
}

const List<AzanSound> kAzanSounds = <AzanSound>[
  AzanSound(
    'makkah',
    'Azaan 1 (Makkah)',
    url: 'https://www.islamcan.com/audio/adhan/azan2.mp3',
    androidRaw: 'azaan1',
    iosSound: 'azaan1.mp3',
  ),
  AzanSound(
    'madina',
    'Azaan 2 (Madinah)',
    url: 'https://www.islamcan.com/audio/adhan/azan3.mp3',
    androidRaw: 'azaan2',
    iosSound: 'azaan2.mp3',
  ),
  AzanSound(
    'mishary',
    'Azaan 3 (Mishary Rashid Alafasy)',
    url: 'https://www.islamcan.com/audio/adhan/azan4.mp3',
    androidRaw: 'azaan3',
    iosSound: 'azaan3.mp3',
  ),
  AzanSound('beep', 'Simple Beep', androidRaw: 'beep', iosSound: 'beep.wav'),
  AzanSound('silent', 'None (silent)'),
];

/// Looks a sound up by its stored key; unknown keys fall back to the default
/// so a stale preference can never leave the notification channel unsounded.
AzanSound azanSoundByKey(String key) {
  for (final AzanSound sound in kAzanSounds) {
    if (sound.key == key) return sound;
  }
  return kAzanSounds.first;
}

/// Prayer keys that can carry their own reminder offset.
const List<String> kNotifiablePrayers = <String>['fajr', 'dhuhr', 'asr', 'maghrib', 'isha'];

/// The three states a Home bell walks through, one tap at a time:
///
/// * `azan` — the banner *and* the recitation, the full reminder.
/// * `silent` — the banner only, with no sound of any kind: the phone
///   still tells you, it just does not say the azan out loud.
/// * `off` — nothing at all, not even the banner.
const String kBellAzan = 'azan';
const String kBellSilent = 'silent';
const String kBellOff = 'off';

/// The ring the Home bell cycles in — `azan → silent → off → azan` — so a
/// reader who lands on any state always knows what the next tap gives.
const List<String> kBellCycle = <String>[kBellAzan, kBellSilent, kBellOff];

/// How many minutes before a prayer the Azan reminder fires.
/// `-1` means "at the time of the prayer".
///
/// These are the *choices* offered, not the values the app can store: an
/// offset written by the owner's config is honoured whatever it is, and the
/// row shows it even when it is not one of these — see the settings screen,
/// which folds the live value into the row rather than drawing no selection.
const List<int> kNotifyOffsets = <int>[-1, 5, 10, 15, 30];

String notifyOffsetLabel(int minutes) =>
    minutes < 0 ? 'At time' : '$minutes min before';

/// The same choice as [notifyOffsetLabel], in the words a chip has room for.
///
/// The row sets every option to an equal width, and "30 min before" does not
/// fit one of five of them — "30 min" does, and the full sentence is still
/// there for anyone reading the row underneath.
String notifyOffsetChipLabel(int minutes) =>
    minutes < 0 ? 'At time' : '$minutes min';

/// When a favourite masjid's own Jamaat time should alert.
///
/// A board's Jamaat column is what the user actually follows, so the default
/// is to fire exactly on it; `offset` reuses the "minutes before" picked for
/// the calculated reminder instead.
const String kFavModeAt = 'at';
const String kFavModeOffset = 'offset';

/// Preference prefix for the per-masjid alert switch. The masjid id sits
/// between this and the `::<uid>` scope suffix `AppSettings._key` appends.
const String kFavAlertKeyPrefix = 'favalert::';

/// When the Azaan itself is allowed to sound.
///
/// One prayer can be announced twice: once at the *calculated* time (the
/// Awwal / earliest permissible waqt, from `NotificationService.scheduleAzan`)
/// and again at a favourite masjid's own Jamaat column (from
/// `scheduleFavouriteAlerts`). Both used to be armed, which is the "do baar
/// azaan" bug — this preference picks which of the two survives.
const String kAzaanTimingJamaatOnly = 'jamaat_only';
const String kAzaanTimingAwwalOnly = 'awwal_only';
const String kAzaanTimingBoth = 'both';
const String kAzaanTimingNone = 'none';

/// The stored value used when nothing has been picked yet.
const String kAzaanTimingDefault = kAzaanTimingJamaatOnly;

/// Dropdown order, exactly as the Settings rows appear.
/// Only one Azaan option is offered in Settings.
const List<String> kAzaanTimingOptions = <String>[
  kAzaanTimingJamaatOnly,
];

/// The wording the user sees in the "When will the Azaan play?" dropdown.
String azaanTimingLabel(String key) {
  switch (key) {
    case kAzaanTimingJamaatOnly:
    default:
      return 'Only at Jamaat time';
  }
}

/// What a profile that has never stored a setting of its own starts with.
///
/// This is the admin panel's answer to "what should a new user get?" — the
/// madhab, the calculation method, how many minutes before the prayer the
/// reminder fires, the Azaan clip, and the rest. It is *defaults*, not
/// policy: [AppSettings.seedWith] writes it exactly once, on a profile with
/// no settings of its own, and every one of these can then be changed in
/// Settings like any other preference. Nothing here ever touches a profile
/// that has already spoken for itself.
///
/// Every value is validated on the way out of Firestore in [fromMap] — a
/// document edited by hand, a stale key or a value of the wrong type falls
/// back to the app's own built-in default rather than becoming a setting the
/// Settings screen cannot render.
@immutable
class NewUserDefaults {
  const NewUserDefaults({
    this.method = 'muslimWorldLeague',
    this.madhab = 'shafi',
    this.timeFormat = '12',
    this.hijriAdjustment = 0,
    this.azanSound = 'makkah',
    this.azaanTiming = kAzaanTimingDefault,
    this.minutesBefore = -1,
    this.readingLanguage = kReadingLanguageUrdu,
    this.notificationsEnabled = true,
  });

  /// Reads a Firestore map, discarding anything the app cannot honestly use.
  ///
  /// [raw] is `null`-tolerated: a document that has not been written yet is
  /// the same as the app's own defaults, which is what an untouched install
  /// would have had anyway.
  factory NewUserDefaults.fromMap(Map<String, dynamic>? raw) {
    final NewUserDefaults builtin = const NewUserDefaults();
    if (raw == null) return builtin;

    final String method = raw['method'] is String &&
            kCalcMethods.any((CalcMethod m) => m.key == raw['method'])
        ? raw['method'] as String
        : builtin.method;

    final String madhab =
        raw['madhab'] == 'hanafi' || raw['madhab'] == 'shafi'
            ? raw['madhab'] as String
            : builtin.madhab;

    final String timeFormat =
        raw['timeFormat'] == '24' ? '24' : builtin.timeFormat;

    final int hijri = raw['hijriAdjustment'] is num
        ? (raw['hijriAdjustment'] as num).toInt().clamp(-7, 7).toInt()
        : builtin.hijriAdjustment;

    final String azanSound = raw['azanSound'] is String &&
            kAzanSounds.any((AzanSound s) => s.key == raw['azanSound'])
        ? raw['azanSound'] as String
        : builtin.azanSound;

    final String timing = raw['azaanTiming'] is String &&
            raw['azaanTiming'] == kAzaanTimingJamaatOnly
        ? raw['azaanTiming'] as String
        : builtin.azaanTiming;

    // Minutes before the prayer. Negative is the one value the app has a
    // word for ("at time"), so anything below zero folds onto it instead of
    // becoming "3 hours before" — and anything past an hour is a typo.
    final int minutes = raw['minutesBefore'] is num
        ? (raw['minutesBefore'] as num).toInt()
        : builtin.minutesBefore;
    final int minutesBefore =
        minutes < 0 ? -1 : minutes.clamp(0, 120).toInt();

    final String reading = raw['readingLanguage'] is String &&
            kReadingLanguageKeys.contains(raw['readingLanguage'])
        ? raw['readingLanguage'] as String
        : builtin.readingLanguage;

    return NewUserDefaults(
      method: method,
      madhab: madhab,
      timeFormat: timeFormat,
      hijriAdjustment: hijri,
      azanSound: azanSound,
      azaanTiming: timing,
      minutesBefore: minutesBefore,
      readingLanguage: reading,
      notificationsEnabled:
          raw['notificationsEnabled'] is bool ? raw['notificationsEnabled'] as bool : builtin.notificationsEnabled,
    );
  }

  /// The exact shape [NewUserDefaults.fromMap] reads back, so the admin
  /// screen round-trips through Firestore without losing a field.
  Map<String, Object?> toMap() => <String, Object?>{
        'method': method,
        'madhab': madhab,
        'timeFormat': timeFormat,
        'hijriAdjustment': hijriAdjustment,
        'azanSound': azanSound,
        'azaanTiming': azaanTiming,
        'minutesBefore': minutesBefore,
        'readingLanguage': readingLanguage,
        'notificationsEnabled': notificationsEnabled,
      };

  final String method;
  final String madhab;
  final String timeFormat;
  final int hijriAdjustment;
  final String azanSound;
  final String azaanTiming;

  /// Minutes before each prayer the reminder fires; `-1` is at the time.
  final int minutesBefore;
  final String readingLanguage;
  final bool notificationsEnabled;

  /// A copy with some of the fields moved — how the panel edits one setting
  /// without having to restate the rest of the document around it.
  NewUserDefaults copyWith({
    String? method,
    String? madhab,
    String? timeFormat,
    int? hijriAdjustment,
    String? azanSound,
    String? azaanTiming,
    int? minutesBefore,
    String? readingLanguage,
    bool? notificationsEnabled,
  }) =>
      NewUserDefaults(
        method: method ?? this.method,
        madhab: madhab ?? this.madhab,
        timeFormat: timeFormat ?? this.timeFormat,
        hijriAdjustment: hijriAdjustment ?? this.hijriAdjustment,
        azanSound: azanSound ?? this.azanSound,
        azaanTiming: azaanTiming ?? this.azaanTiming,
        minutesBefore: minutesBefore ?? this.minutesBefore,
        readingLanguage: readingLanguage ?? this.readingLanguage,
        notificationsEnabled:
            notificationsEnabled ?? this.notificationsEnabled,
      );

  /// One row of the admin panel's preview: what a fresh profile will open on.
  String describe() {
    final CalcMethod m = kCalcMethods.firstWhere(
      (CalcMethod c) => c.key == method,
      orElse: () => kCalcMethods.first,
    );
    return '${madhab == 'hanafi' ? 'Hanafi' : 'Shafi'} Asr · ${m.label} · '
        '${minutesBefore < 0 ? 'Azaan at time' : '$minutesBefore min before'} · '
        '${azanSoundByKey(azanSound).label} · ${azaanTimingLabel(azaanTiming)}';
  }

  @override
  bool operator ==(Object other) =>
      other is NewUserDefaults &&
      other.method == method &&
      other.madhab == madhab &&
      other.timeFormat == timeFormat &&
      other.hijriAdjustment == hijriAdjustment &&
      other.azanSound == azanSound &&
      other.azaanTiming == azaanTiming &&
      other.minutesBefore == minutesBefore &&
      other.readingLanguage == readingLanguage &&
      other.notificationsEnabled == notificationsEnabled;

  @override
  int get hashCode => Object.hash(method, madhab, timeFormat, hijriAdjustment,
      azanSound, azaanTiming, minutesBefore, readingLanguage, notificationsEnabled);
}

/// A day of prayer times, already converted to the device's local wall clock
/// on the *correct calendar day*.
class LocalPrayerTimes {
  const LocalPrayerTimes({
    required this.times,
    required this.fajrTomorrow,
  });

  /// `fajr`, `sunrise`, `dhuhr`, `asr`, `maghrib`, `isha`, `sunset` → local
  /// `DateTime`.
  ///
  /// `sunset` is the sun's own going-down, not a prayer: Maghrib is the
  /// prayer that opens at it, and this is the marker the Home's day-strip
  /// prints beside the sunrise.
  final Map<String, DateTime> times;

  /// Next day's Fajr, for the "past Isha" countdown rollover.
  final DateTime fajrTomorrow;

  DateTime? operator [](String key) => times[key];

  /// The official end of [key]'s prayer time — the *calculated* start of
  /// whatever the day puts next, never a board's Jamaat reading.
  ///
  /// A masjid quoting "Fajr 6:05" does not move the moment Fajr's waqt ends
  /// (sunrise) nor Isha's (tomorrow's Fajr): those belong to the official
  /// clock. Sunrise itself is not a prayer and ends nothing, so it — and
  /// any unknown key — answers null.
  DateTime? officialEnd(String key) => switch (key) {
        'fajr' => times['sunrise'],
        'dhuhr' => times['asr'],
        'asr' => times['maghrib'],
        'maghrib' => times['isha'],
        'isha' => fajrTomorrow,
        _ => null,
      };

  /// Today's makruh (Zawal) window: the sun's half hour at the zenith,
  /// ending the moment Dhuhr begins.
  ///
  /// Printed Mumbai timetables say it the same way — "Zawal lasts 30
  /// minutes; Dhuhr starts right after it ends" — so the reader meets the
  /// window they already know from the masjid's board.
  ({DateTime start, DateTime end})? get makruhWindow {
    final DateTime? dhuhr = times['dhuhr'];
    if (dhuhr == null) return null;
    return (start: dhuhr.subtract(const Duration(minutes: 30)), end: dhuhr);
  }
}

/// adhan_dart builds every prayer time with `DateTime.utc(y, m, d, hh, mm)`
/// from *astronomical* hours, i.e. the event's UTC wall clock. Reading
/// `.hour` straight off that gives 23:47 for a 05:17 IST Fajr — that is the
/// bug where Fajr showed as 23:47.
///
/// Worse, for any positive UTC offset the late-evening UTC reading rolls the
/// local date forward by a day, so Fajr looked like it was *tomorrow* and the
/// "Next prayer" countdown picked the wrong row. This folds both back onto
/// the requested calendar day while keeping the correct local wall clock.
DateTime localisePrayerTime(DateTime rawUtc, DateTime day) {
  final DateTime local = rawUtc.toLocal();
  final DateTime dayStart = DateTime(day.year, day.month, day.day);
  final DateTime localDay = DateTime(local.year, local.month, local.day);

  int shift = 0;
  if (localDay.isAfter(dayStart)) {
    shift = -1;
  } else if (localDay.isBefore(dayStart)) {
    shift = 1;
  }

  final DateTime onDay = shift == 0
      ? local
      : (shift < 0
          ? local.subtract(Duration(days: 1))
          : local.add(Duration(days: 1)));

  return DateTime(day.year, day.month, day.day, onDay.hour, onDay.minute);
}

/// App-wide preferences, persisted in SharedPreferences and applied to the
/// Today card the instant anything changes.
class AppSettings extends ChangeNotifier {
  AppSettings._();

  static final AppSettings instance = AppSettings._();

  static const String _kMethod = 'calcMethod';
  static const String _kMadhab = 'madhab';
  static const String _kTimeFormat = 'timeFormat';
  static const String _kHijri = 'hijriAdjustment';
  static const String _kCustomLat = 'customLat';
  static const String _kCustomLng = 'customLng';
  static const String _kCustomCity = 'customCity';
  static const String _kNotifMaster = 'azanNotifications';

  /// Whether the always-on prayer card may be shown on the home
  /// screen and the lock screen.
  ///
  /// This is the one setting the user can leave off for good: it hides
  /// the card and nothing else - the prayer reminders, the Azaan and the
  /// favourite-masjid alerts keep working exactly as they did.
  static const String _kPrayerCard = 'prayerCardVisible';

  static const String _kAzan = 'azanSound';

  /// "When will the Azaan play?" — which of the two announcements for a prayer may
  /// sound. Read back by the scheduler as `jamaat_only` when absent.
  static const String _kAzaanTiming = 'azaan_timing_pref';

  /// Whose Jamaat column the Today card quotes, by masjid id.
  ///
  /// Empty is the normal answer — "whichever starred masjid is nearest" — and
  /// it is also what the card falls back to when the masjid named here has
  /// since been unstarred or deleted, so a stale id can never point the card
  /// at a masjid this account no longer follows.
  static const String _kTodayBoard = 'today_board_pref';

  /// Which language the Home card prints its daily ayah/hadith translation in.
  ///
  /// The Arabic above it never changes — only the rendering underneath, and
  /// that choice is the reader's to keep rather than reset every launch.
  static const String _kReadingLang = 'readingLanguage';

  /// Locally edited display name, shown instead of Firebase's `displayName`
  /// when set. Scoped like every other preference so two accounts on one
  /// phone do not overwrite each other's names.
  static const String _kProfileName = 'profileDisplayName';

  /// Path to the photo the user picked from their gallery, stored on disk.
  /// Firebase's `photoURL` is a network address we cannot write to, so a
  /// locally chosen portrait lives here instead.
  static const String _kProfilePhoto = 'profilePhotoPath';

  /// Which profile the previous run ended on.
  ///
  /// Firebase has not resolved `currentUser` by the time `main()` reads these
  /// preferences, so without this hint the first frame would render against
  /// the signed-out defaults and then visibly flip once auth lands.
  static const String _kActiveProfile = 'activeProfile';

  /// Set once when a profile finishes the first-run setup wizard — and
  /// never cleared: the wizard is a greeting, not a lock, and every choice
  /// it collects stays an ordinary setting afterwards.
  static const String _kOnboarded = 'onboarded_v1';

  /// Every setting, under the bare name it had before profiles existed.
  ///
  /// These used to be written straight to [base] — one set of preferences for
  /// the whole phone — so signing in as a second account inherited the first
  /// account's calculation method, madhab and Azan reminder offsets.
  static final List<String> _allBases = <String>[
    _kMethod,
    _kMadhab,
    _kTimeFormat,
    _kHijri,
    _kCustomLat,
    _kCustomLng,
    _kCustomCity,
    _kNotifMaster,
    _kAzan,
    _kAzaanTiming,
    _kTodayBoard,
    _kReadingLang,
    _kProfileName,
    _kProfilePhoto,
    for (final String prayer in kNotifiablePrayers) 'notify_$prayer',
    for (final String prayer in kNotifiablePrayers) 'notifyon_$prayer',
    for (final String prayer in kNotifiablePrayers) 'favmode_$prayer',
    for (final String prayer in kNotifiablePrayers) 'bellmode_$prayer',
  ];

  /// The profile these preferences belong to; `anon` while signed out.
  String _scope = 'anon';

  /// Which profile the preferences are scoped to right now, for services
  /// that keep their *own* keys (the tasbeeh bead count, the prayer log)
  /// and must not let two accounts on one phone share each other's beads.
  String get activeProfileScope => _scope;

  /// A profile switch that has not finished reading from disk yet, so a
  /// second request for the same account joins it instead of racing it.
  Future<void>? _pendingSwitch;

  /// Which profile [_pendingSwitch] is loading, so a request for a *different*
  /// account chains behind it instead of being swallowed. Signing out while a
  /// switch is in flight would otherwise leave the old account's values live.
  String? _pendingScope;

  /// Set once the bare keys have been handed over, so it happens exactly once
  /// per run even when `useProfile('anon')` would otherwise be a no-op.
  bool _retired = false;

  SharedPreferences? _prefs;
  bool _loaded = false;

  bool get isLoaded => _loaded;

  /// The stored name for [base] belonging to [uid] (`anon` when signed out).
  @visibleForTesting
  static String scopedKeyFor(String base, String? uid) => '$base::${uid ?? 'anon'}';

  String _key(String base) => '$base::$_scope';

  // ---------------------------------------------------------------- stored
  String _method = 'muslimWorldLeague';
  String _madhab = 'shafi';
  String _timeFormat = '12';
  int _hijriAdjustment = 0;
  double? _customLat;
  double? _customLng;
  String _customCity = '';
  bool _notificationsEnabled = true;
  bool _prayerCardVisible = true;
  bool _onboarded = false;
  String _azanSound = 'makkah';

  /// "When will the Azaan play?" — see [kAzaanTimingJamaatOnly] and friends. The
  /// default is one recitation per prayer, at the Jamaat the user follows.
  String _azaanTiming = kAzaanTimingDefault;

  /// Starred masjid id the Today card quotes; `''` = nearest starred.
  String _todayBoard = '';

  /// Language the daily reading's translation is printed in — see
  /// [kReadingLanguageKeys]. Urdu by default, because it is the language the
  /// reader asked in, and it is the one script the card ships a typeface for.
  String _readingLang = kReadingLanguageUrdu;

  /// Locally chosen display name; `''` means "fall back to Firebase".
  String _profileName = '';

  /// Path to the locally chosen portrait file; `''` means "use Firebase's".
  String _profilePhoto = '';

  /// prayer key → minutes before the prayer (`-1` = at time).
  final Map<String, int> _notifyOffsets = <String, int>{
    for (final String key in kNotifiablePrayers) key: -1,
  };

  /// prayer key → whether its reminder is switched on at all.
  final Map<String, bool> _notifyOn = <String, bool>{
    for (final String key in kNotifiablePrayers) key: true,
  };

  /// prayer key → when a *favourite masjid's* alert for that prayer fires.
  final Map<String, String> _favModes = <String, String>{
    for (final String key in kNotifiablePrayers) key: kFavModeAt,
  };

  /// prayer key → its Home bell's own mode ([kBellAzan]/[kBellSilent]/[kBellOff]).
  ///
  /// No default entries on purpose: a bell never pressed *derives* its
  /// state (see [bellModeFor]) so today's readers keep exactly what they
  /// see, and only a real tap writes a mode of its own.
  final Map<String, String> _bellModes = <String, String>{};

  /// masjid id → whether this account wants alerts from that masjid.
  ///
  /// Absent means **on**: a masjid you starred is one you asked to hear from,
  /// so the switch that exists on its page and in Settings is there to opt
  /// out rather than in.
  final Map<String, bool> _favAlerts = <String, bool>{};

  // ------------------------------------------------------------ accessors
  CalcMethod get method => kCalcMethods.firstWhere(
        (CalcMethod m) => m.key == _method,
        orElse: () => kCalcMethods.first,
      );

  String get methodKey => _method;
  bool get isHanafi => _madhab == 'hanafi';
  String get madhabKey => _madhab;
  String get timeFormat => _timeFormat;
  int get hijriAdjustment => _hijriAdjustment;
  bool get notificationsEnabled => _notificationsEnabled;

  /// Whether the always-on prayer card (home screen + lock screen) may
  /// show.
  ///
  /// Off is permanent: the setting is written to disk, it survives a
  /// restart, and nothing in the app turns it back on by itself.
  bool get prayerCardVisible => _prayerCardVisible;

  /// Whether this profile has already walked through the setup wizard.
  /// Reads false before [load] — an unloaded profile has never *said* no,
  /// and pushing the wizard on top of a cold start that has not yet decided
  /// anything would race the very answers it collects.
  bool get onboarded => _loaded && _onboarded;
  String get azanSound => _azanSound;

  /// Starred masjid the Today card quotes by name, or `''` for the automatic
  /// answer (whichever starred masjid is nearest).
  String get todayBoardId => _todayBoard;

  /// Which rendering of the daily reading is on show: `urdu`, `english` or
  /// `roman`. The Arabic is above it whichever this says.
  String get readingLanguage => _readingLang;

  /// Locally chosen display name; `''` means "use Firebase's".
  String get profileDisplayName => _profileName;

  /// Path to the locally chosen portrait; `''` means "use Firebase's".
  String get profilePhotoPath => _profilePhoto;

  /// The raw stored choice for "When will the Azaan play?".
  String get azaanTiming => _azaanTiming;

  /// True when any prayer uses a "N min before" reminder - i.e. the user
  /// tapped the "N min before" chip under "At my favourite masjid".
  ///
  /// A pre-prayer reminder already warns the user ahead of the calculated
  /// (Awwal) time, so the Azaan itself is left to the favourite masjid's
  /// Jamaat time - otherwise the user hears two Azaans for the same prayer.
  bool get hasPrePrayerReminder => kNotifiablePrayers.any(
        (String prayer) =>
            _favModes[prayer] == kFavModeOffset && (_notifyOffsets[prayer] ?? -1) > 0,
      );

  /// The Azaan timings the user is allowed to pick.
  ///
  /// Only one choice is offered: the Azaan plays once per prayer, at the
  /// favourite masjid's Jamaat time. A pre-prayer reminder (At time, N min)
  /// does not hide this option anymore.
  List<String> get azaanTimingOptions => const <String>[kAzaanTimingJamaatOnly];

  /// Whether the calculated (Awwal) reminders may be armed. With `none`
  /// selected both of these read false and every Azaan alarm is cancelled.
  bool get schedulesAwwal =>
      _azaanTiming == kAzaanTimingAwwalOnly || _azaanTiming == kAzaanTimingBoth;

  /// Whether a favourite masjid's own Jamaat-time alerts may be armed.
  bool get schedulesJamaat =>
      _azaanTiming == kAzaanTimingJamaatOnly || _azaanTiming == kAzaanTimingBoth;

  bool get hasCustomLocation => _customLat != null && _customLng != null;
  double? get customLatitude => _customLat;
  double? get customLongitude => _customLng;
  String get customCity => _customCity;

  int notifyOffsetFor(String prayer) => _notifyOffsets[prayer] ?? -1;
  bool notifyOnFor(String prayer) => _notifyOn[prayer] ?? true;
  String favModeFor(String prayer) => _favModes[prayer] ?? kFavModeAt;
  bool favAlertFor(String masjidId) => _favAlerts[masjidId] ?? true;

  /// The Home bell's current state for [prayer].
  ///
  /// A prayer switched off is always [kBellOff] — that switch is the same
  /// "no banner at all" the scheduler gates on, so the bell cannot claim
  /// otherwise. Otherwise an explicitly tapped mode wins and survives the
  /// Settings screen switching reminders off and back on (the reader gets
  /// their `azan`/`silent` choice back). A bell never pressed has stored
  /// nothing and derives from what the profile already said: a global
  /// `silent` sound means a quiet app, so its plain bells start on
  /// [kBellSilent]; any other sound starts on [kBellAzan].
  String bellModeFor(String prayer) {
    if (!notifyOnFor(prayer)) return kBellOff;
    final String stored = _bellModes[prayer] ?? '';
    if (stored == kBellAzan || stored == kBellSilent) return stored;
    return azanSound == 'silent' ? kBellSilent : kBellAzan;
  }

  /// Puts [prayer]'s bell on [mode] and files the choice under the profile.
  ///
  /// The two switches move together: `off` means no banner either, so it
  /// clears `notifyon_` (the Settings screen's own gate, the scheduler's
  /// gate), while `azan`/`silent` restore it — which is also how a bell
  /// left `off` comes back to life under the same master switch.
  void setBellMode(String prayer, String mode) {
    if (!kBellCycle.contains(mode)) return;
    _bellModes[prayer] = mode;
    final bool on = mode != kBellOff;
    final bool wasOn = notifyOnFor(prayer);
    if (wasOn != on) {
      _notifyOn[prayer] = on;
      _put((SharedPreferences p) => p.setBool(_key('notifyon_$prayer'), on));
    }
    notifyListeners();
    _put((SharedPreferences p) => p.setString(_key('bellmode_$prayer'), mode));
  }

  /// One tap on the Home bell: [kBellAzan] → [kBellSilent] → [kBellOff] →
  /// around again. Returns what the bell now shows.
  String cycleBellMode(String prayer) {
    final String next =
        kBellCycle[(kBellCycle.indexOf(bellModeFor(prayer)) + 1) % kBellCycle.length];
    setBellMode(prayer, next);
    return next;
  }

  /// Every masjid this profile has ever been switched on or off for. The
  /// scheduler needs the "off" ones too so it can take down alarms it armed
  /// earlier — a toggle that merely stopped scheduling would leak them.
  Set<String> favAlertMasjidIds() => _favAlerts.keys.toSet();

  /// Whether this profile has never stored a setting of its own.
  ///
  /// The whole of "a new user" is defined by this one answer: a profile with
  /// not a single preference under its scope suffix has never opened the
  /// Settings screen, never picked a madhab, never moved a reminder — so the
  /// owner's chosen defaults can stand in for choices nobody has made yet.
  ///
  /// It reads false before [load] has run, deliberately: an unloaded profile
  /// looks empty for the same reason a blank screen looks unprinted, and
  /// seeding against that guess would overwrite the settings it is supposed
  /// to leave alone.
  bool get isVirginProfile {
    final SharedPreferences? prefs = _prefs;
    if (!_loaded || prefs == null) return false;
    final String suffix = '::$_scope';
    return !prefs.getKeys().any((String key) => key.endsWith(suffix));
  }

  /// Null when the user has not pinned a city — callers fall back to GPS.
  Coordinates? get customCoordinates =>
      hasCustomLocation ? Coordinates(_customLat!, _customLng!) : null;

  // ------------------------------------------------------------------ load
  /// Point every preference at [uid]'s profile — or the signed-out profile
  /// when `null` — and reload them from disk.
  ///
  /// Idempotent and safe to fire from a widget build: a repeat call for the
  /// profile that is already active does nothing, and a repeat call while a
  /// switch is in flight returns the same future. `RootGate` and
  /// `_bootstrap` both ask, so this has to tolerate being called twice.
  Future<void> useProfile(String? uid) {
    final String scope = uid ?? 'anon';

    final Future<void>? pending = _pendingSwitch;
    if (pending != null) {
      if (_pendingScope == scope) return pending;
      // A different account is asking while this one is still loading — run
      // it behind rather than swallow it. `whenComplete` has cleared the
      // marker by the time this continuation runs, so this terminates.
      return pending.then<void>((_) => useProfile(uid));
    }
    if (scope == _scope && _loaded && _retired) return Future<void>.value();

    final Future<void> work = _switchTo(scope).whenComplete(() {
      _pendingSwitch = null;
      _pendingScope = null;
    });
    _pendingSwitch = work;
    _pendingScope = scope;
    return work;
  }

  Future<void> _switchTo(String scope) async {
    // Close the gate first so no *new* write can join the drain below, then
    // let every write already in flight finish while `_scope` still names
    // the profile it was issued under — its remaining keys are computed as
    // it goes, and after the switch they would name the incoming account.
    _loaded = false;
    final List<Future<void>> inFlight = List<Future<void>>.of(_writes);
    if (inFlight.isNotEmpty) await Future.wait(inFlight);

    _scope = scope;
    // No write may land until the destination profile is on disk, otherwise
    // the outgoing account's in-memory values would be saved under the
    // incoming account's keys.
    final SharedPreferences prefs = _prefs = await SharedPreferences.getInstance();
    // Written before load() so the next cold start skips this whole dance.
    await prefs.setString(_kActiveProfile, scope);
    if (!_retired) {
      await retireLegacyKeys(prefs, scope == 'anon' ? null : scope);
      _retired = true;
    }
    await load();
  }

  /// One-time hand-over of the bare, device-wide keys written before settings
  /// were scoped to an account.
  ///
  /// Unlike favourites these are not stored in the cloud, so there is no
  /// per-account copy to restore from — the values go to whichever profile
  /// opens this build first, and are then removed from the bare keys so no
  /// later profile can inherit them. A profile that already has its own value
  /// for a setting is left alone.
  @visibleForTesting
  static Future<void> retireLegacyKeys(SharedPreferences prefs, String? uid) async {
    final String scope = uid ?? 'anon';
    bool moved = false;

    for (final String base in _allBases) {
      if (!prefs.containsKey(base)) continue;
      final String scoped = scopedKeyFor(base, uid);
      if (!prefs.containsKey(scoped)) await _copyValue(prefs, base, scoped);
      await prefs.remove(base);
      moved = true;
    }

    if (moved) debugPrint('Noor ▸ settings re-scoped to profile "$scope"');
  }

  /// `SharedPreferences.get` hands back `Object?`, so the type has to be
  /// recovered rather than cast — a wrong cast silently drops the value.
  static Future<void> _copyValue(SharedPreferences prefs, String from, String to) async {
    final Object? value = prefs.get(from);
    if (value is String) {
      await prefs.setString(to, value);
    } else if (value is bool) {
      await prefs.setBool(to, value);
    } else if (value is int) {
      await prefs.setInt(to, value);
    } else if (value is double) {
      await prefs.setDouble(to, value);
    } else if (value is List<String>) {
      await prefs.setStringList(to, value);
    }
  }

  Future<void> load() async {
    try {
      final SharedPreferences prefs =
          _prefs = await SharedPreferences.getInstance();
      // Cold start: take up the profile the last run finished on, because
      // FirebaseAuth has not resolved `currentUser` this early.
      _scope = prefs.getString(_kActiveProfile) ?? _scope;
      _method = prefs.getString(_key(_kMethod)) ?? 'muslimWorldLeague';
      _madhab = prefs.getString(_key(_kMadhab)) ?? 'shafi';
      _timeFormat = prefs.getString(_key(_kTimeFormat)) ?? '12';
      _hijriAdjustment = prefs.getInt(_key(_kHijri)) ?? 0;
      _customLat = prefs.getDouble(_key(_kCustomLat));
      _customLng = prefs.getDouble(_key(_kCustomLng));
      _customCity = prefs.getString(_key(_kCustomCity)) ?? '';
      _notificationsEnabled = prefs.getBool(_key(_kNotifMaster)) ?? true;
      _prayerCardVisible = prefs.getBool(_key(_kPrayerCard)) ?? true;
      _onboarded = prefs.getBool(_key(_kOnboarded)) ?? false;
      _azanSound = prefs.getString(_key(_kAzan)) ?? 'makkah';
      // An unknown stored value would otherwise read as "no source at all",
      // which is how a typo could silently mute every reminder.
      // Only one option is offered now, so only that one is accepted.
      final String timing = prefs.getString(_key(_kAzaanTiming)) ?? kAzaanTimingDefault;
      _azaanTiming = timing == kAzaanTimingJamaatOnly ? timing : kAzaanTimingDefault;
      // Kept verbatim on purpose: the home screen only honours an id that is
      // still starred, so a masjid that has since been unstarred simply
      // costs one fallback rather than a key that silently lies.
      _todayBoard = prefs.getString(_key(_kTodayBoard)) ?? '';
      // An unknown stored key would render an empty translation, so it is
      // rejected here rather than trusted by the card.
      final String reading = prefs.getString(_key(_kReadingLang)) ?? kReadingLanguageUrdu;
      _readingLang = kReadingLanguageKeys.contains(reading)
          ? reading
          : kReadingLanguageUrdu;
      _profileName = prefs.getString(_key(_kProfileName)) ?? '';
      _profilePhoto = prefs.getString(_key(_kProfilePhoto)) ?? '';
      for (final String key in kNotifiablePrayers) {
        _notifyOffsets[key] = prefs.getInt(_key('notify_$key')) ?? -1;
        _notifyOn[key] = prefs.getBool(_key('notifyon_$key')) ?? true;
        _favModes[key] = prefs.getString(_key('favmode_$key')) ?? kFavModeAt;
        // A stored mode only counts if it is one of the three; anything
        // else — stale, or a profile being left behind — clears the slot
        // so [bellModeFor] derives again instead of trusting garbage.
        final String mode = prefs.getString(_key('bellmode_$key')) ?? '';
        if (kBellCycle.contains(mode)) {
          _bellModes[key] = mode;
        } else {
          _bellModes.remove(key);
        }
      }
      _loadFavAlerts(prefs);
      _loaded = true;
    } catch (error) {
      debugPrint('Noor ▸ settings load failed: $error');
      _loaded = true;
    }
    notifyListeners();
  }

  /// Picks this profile's per-masjid switches out of the raw key set.
  ///
  /// These keys are open-ended (one per masjid) rather than a fixed list like
  /// the rest of [_allBases], so they cannot go through `retireLegacyKeys` —
  /// they are matched by prefix and by the scope suffix instead.
  void _loadFavAlerts(SharedPreferences prefs) {
    _favAlerts.clear();
    final String suffix = '::$_scope';
    for (final String stored in prefs.getKeys()) {
      if (!stored.startsWith(kFavAlertKeyPrefix) || !stored.endsWith(suffix)) continue;
      final int end = stored.length - suffix.length;
      if (end <= kFavAlertKeyPrefix.length) continue;
      _favAlerts[stored.substring(kFavAlertKeyPrefix.length, end)] =
          prefs.getBool(stored) ?? true;
    }
  }

  // --------------------------------------------------------------- setters

  /// Every [_put] still in flight.
  ///
  /// A write computes its keys *as it runs*, so a multi-statement one —
  /// [seedWith] above all — depends on `_scope` still naming the profile it
  /// was issued under until it finishes. [_switchTo] drains this list first,
  /// which is what stops the tail of an outgoing account's write from being
  /// filed under the incoming account's keys.
  final List<Future<void>> _writes = <Future<void>>[];

  Future<void> _put(Future<void> Function(SharedPreferences p) write) {
    final Future<void> task = _doPut(write);
    _writes.add(task);
    // `_doPut` swallows its own errors, so this cannot complete with one.
    task.whenComplete(() => _writes.remove(task));
    return task;
  }

  Future<void> _doPut(Future<void> Function(SharedPreferences p) write) async {
    final SharedPreferences? prefs = _prefs;
    // A profile switch has not landed yet — dropping the write beats filing it
    // under the wrong account.
    if (prefs == null || !_loaded) return;
    try {
      await write(prefs);
    } catch (error) {
      debugPrint('Noor ▸ settings save failed: $error');
    }
  }

  void setMethod(String key) {
    _method = key;
    notifyListeners();
    _put((SharedPreferences p) => p.setString(_key(_kMethod), key));
  }

  void setMadhab(String key) {
    _madhab = key;
    notifyListeners();
    _put((SharedPreferences p) => p.setString(_key(_kMadhab), key));
  }

  void setTimeFormat(String format) {
    _timeFormat = format;
    notifyListeners();
    _put((SharedPreferences p) => p.setString(_key(_kTimeFormat), format));
  }

  /// Chooses whose board the Today card quotes; `''` hands it back to the
  /// automatic answer, whichever starred masjid is nearest.
  void setTodayBoard(String masjidId) {
    _todayBoard = masjidId;
    notifyListeners();
    _put((SharedPreferences p) => p.setString(_key(_kTodayBoard), masjidId));
  }

  /// Puts the daily reading's translation into [key] (`urdu`, `english` or
  /// `roman`); anything else is ignored so a stray tap can never blank the
  /// card by pointing it at a language that does not exist.
  void setReadingLanguage(String key) {
    if (!kReadingLanguageKeys.contains(key)) return;
    if (_readingLang == key) return;
    _readingLang = key;
    notifyListeners();
    _put((SharedPreferences p) => p.setString(_key(_kReadingLang), key));
  }

  /// Stores the name the user typed on the Profile screen. An empty [name]
  /// clears the override so Firebase's `displayName` shows again.
  void setProfileName(String name) {
    _profileName = name.trim();
    notifyListeners();
    _put((SharedPreferences p) async {
      if (_profileName.isEmpty) {
        await p.remove(_key(_kProfileName));
      } else {
        await p.setString(_key(_kProfileName), _profileName);
      }
    });
  }

  /// Stores the path of the portrait the user picked. An empty [path] clears
  /// it so the Firebase photo (or the default glyph) shows again.
  void setProfilePhoto(String path) {
    _profilePhoto = path.trim();
    notifyListeners();
    _put((SharedPreferences p) async {
      if (_profilePhoto.isEmpty) {
        await p.remove(_key(_kProfilePhoto));
      } else {
        await p.setString(_key(_kProfilePhoto), _profilePhoto);
      }
    });
  }

  void setHijriAdjustment(int days) {
    _hijriAdjustment = days.clamp(-2, 2);
    notifyListeners();
    _put((SharedPreferences p) => p.setInt(_key(_kHijri), _hijriAdjustment));
  }

  void setCustomLocation(double? lat, double? lng, String city) {
    _customLat = lat;
    _customLng = lng;
    _customCity = city;
    notifyListeners();
    _put((SharedPreferences p) async {
      if (lat == null || lng == null) {
        await p.remove(_key(_kCustomLat));
        await p.remove(_key(_kCustomLng));
        await p.remove(_key(_kCustomCity));
      } else {
        await p.setDouble(_key(_kCustomLat), lat);
        await p.setDouble(_key(_kCustomLng), lng);
        await p.setString(_key(_kCustomCity), city);
      }
    });
  }

  /// Shows or hides the always-on prayer card.
  ///
  /// Nothing else is touched: the prayer reminders, the Azaan and the
  /// favourite-masjid alerts keep working exactly as they did.
  void setPrayerCardVisible(bool visible) {
    if (_prayerCardVisible == visible) return;
    _prayerCardVisible = visible;
    notifyListeners();
    _put((SharedPreferences p) => p.setBool(_key(_kPrayerCard), visible));
  }

  void setNotificationsEnabled(bool enabled) {
    _notificationsEnabled = enabled;
    notifyListeners();
    _put((SharedPreferences p) => p.setBool(_key(_kNotifMaster), enabled));
  }

  /// Closes the setup wizard for this profile. Idempotent — the wizard's
  /// Done button can be pressed twice on a double-tap, and the second press
  /// must not write a second time against a scope that is mid-switch.
  void markOnboarded() {
    if (_onboarded) return;
    _onboarded = true;
    notifyListeners();
    _put((SharedPreferences p) => p.setBool(_key(_kOnboarded), true));
  }

  void setNotifyOffset(String prayer, int minutes) {
    _notifyOffsets[prayer] = minutes;
    notifyListeners();
    _put((SharedPreferences p) => p.setInt(_key('notify_$prayer'), minutes));
  }

  void setNotifyOn(String prayer, bool on) {
    _notifyOn[prayer] = on;
    notifyListeners();
    _put((SharedPreferences p) => p.setBool(_key('notifyon_$prayer'), on));
  }

  void setFavMode(String prayer, String mode) {
    if (mode != kFavModeAt && mode != kFavModeOffset) return;
    _favModes[prayer] = mode;
    notifyListeners();
    _put((SharedPreferences p) => p.setString(_key('favmode_$prayer'), mode));
  }

  /// Turns one masjid's alerts on or off for this account. Written even when
  /// `on` is the default, so the switch's state survives a profile reload.
  void setFavAlert(String masjidId, bool on) {
    _favAlerts[masjidId] = on;
    notifyListeners();
    _put((SharedPreferences p) => p.setBool(_key('$kFavAlertKeyPrefix$masjidId'), on));
  }

  void setAzanSound(String key) {
    _azanSound = key;
    notifyListeners();
    _put((SharedPreferences p) => p.setString(_key(_kAzan), key));
  }

  /// "When will the Azaan play?" — persisted as `azaan_timing_pref`, and pushed to the
  /// listeners so the Settings screen re-arms the alarms on the next frame.
  void setAzaanTiming(String key) {
    // Only one option is offered now, so any other value falls back to it.
    _azaanTiming = kAzaanTimingJamaatOnly;
    notifyListeners();
    _put((SharedPreferences p) => p.setString(_key(_kAzaanTiming), kAzaanTimingJamaatOnly));
  }

  /// Takes [defaults] as this profile's starting point, in one write —
  /// unless this profile has already spoken for itself, in which case it
  /// does nothing at all.
  ///
  /// This is the app's owner answering "what should a brand-new user open
  /// on?", applied exactly once per profile and never again: a user who
  /// later changes the madhab is *changing* it, not being re-seeded, and the
  /// act of writing any preference ends the [isVirginProfile] this checks.
  ///
  /// The check lives here rather than only in the caller
  /// ([AppConfig.seedNewProfile] makes it too) because "never re-seed" is
  /// not a preference but a property of the whole feature: one caller
  /// forgetting it would silently overwrite every existing user's settings
  /// with the owner's, which is precisely what this feature exists to avoid
  /// doing.
  ///
  /// Everything lands in a single [_put] with one `notifyListeners`: ten
  /// separate setters would repaint the screen ten times over a boot that has
  /// only just started, and could half-apply if a profile switch raced them.
  void seedWith(NewUserDefaults defaults) {
    if (!isVirginProfile) return;

    _method = defaults.method;
    _madhab = defaults.madhab;
    _timeFormat = defaults.timeFormat;
    _hijriAdjustment = defaults.hijriAdjustment;
    _azanSound = defaults.azanSound;
    _azaanTiming = defaults.azaanTiming;
    _readingLang = defaults.readingLanguage;
    _notificationsEnabled = defaults.notificationsEnabled;
    for (final String prayer in kNotifiablePrayers) {
      _notifyOffsets[prayer] = defaults.minutesBefore;
      _notifyOn[prayer] = true;
      _favModes[prayer] = kFavModeAt;
    }

    notifyListeners();
    _put((SharedPreferences p) async {
      await p.setString(_key(_kMethod), _method);
      await p.setString(_key(_kMadhab), _madhab);
      await p.setString(_key(_kTimeFormat), _timeFormat);
      await p.setInt(_key(_kHijri), _hijriAdjustment);
      await p.setString(_key(_kAzan), _azanSound);
      await p.setString(_key(_kAzaanTiming), _azaanTiming);
      await p.setString(_key(_kReadingLang), _readingLang);
      await p.setBool(_key(_kNotifMaster), _notificationsEnabled);
      for (final String prayer in kNotifiablePrayers) {
        await p.setInt(_key('notify_$prayer'), _notifyOffsets[prayer]!);
        await p.setBool(_key('notifyon_$prayer'), _notifyOn[prayer]!);
        await p.setString(_key('favmode_$prayer'), _favModes[prayer]!);
      }
    });
  }

  // ------------------------------------------------------- time computation
  CalculationParameters buildParameters() {
    final CalculationParameters params = method.build();
    params.madhab = isHanafi ? Madhab.hanafi : Madhab.shafi;
    return params;
  }

  /// Memoised last result, keyed by everything that can change it.
  ///
  /// The hero on Home recomputes once a second to drive its countdown, and
  /// the reading cards every thirty seconds — three full prayer-time
  /// calculations per second, each one followed by a `debugPrint`, which is
  /// where the once-per-second "GPS: … -> Fajr: …" line in logcat came from.
  /// A day's times cannot move under a fixed coordinate, method, madhab and
  /// calendar date, so they are computed once and handed out until one of
  /// those four does.
  LocalPrayerTimes? _computed;
  String? _computedKey;

  /// Computes one day of prayer times and folds every value onto [day]'s
  /// calendar date in the device's own timezone.
  LocalPrayerTimes compute({
    required double latitude,
    required double longitude,
    DateTime? day,
  }) {
    final DateTime date = day ?? DateTime.now();
    // Not only out-of-range values: a `double.nan` slips past every `>` test
    // there ever was, and one NaN coordinate makes the library run its
    // iteration to the limit handing back times for a place that does not
    // exist. A last-known city beats an unrepresentable answer.
    final double lat = (latitude.isFinite && latitude.abs() <= 90) ? latitude : 19.0760;
    final double lng = (longitude.isFinite && longitude.abs() <= 180) ? longitude : 72.8777;

    final String key = '$lat|$lng|${date.year}-${date.month}-${date.day}|'
        '${method.key}|$isHanafi';
    final LocalPrayerTimes? hit = _computed;
    if (hit != null && _computedKey == key) return hit;

    final PrayerTimes raw = PrayerTimes(
      date: date,
      coordinates: Coordinates(lat, lng),
      calculationParameters: buildParameters(),
    );

    final Map<String, DateTime> times = <String, DateTime>{
      'fajr': localisePrayerTime(raw.fajr, date),
      'sunrise': localisePrayerTime(raw.sunrise, date),
      'dhuhr': localisePrayerTime(raw.dhuhr, date),
      'asr': localisePrayerTime(raw.asr, date),
      'maghrib': localisePrayerTime(raw.maghrib, date),
      'isha': localisePrayerTime(raw.isha, date),
      // The sun's own going-down, which the boards print under the five as
      // "Sunset" and which the Home's day-strip shows beside the sunrise.
      // It is *not* a prayer — Maghrib is the prayer that opens at it.
      'sunset': localisePrayerTime(raw.sunset, date),
    };

    final DateTime tomorrow = DateTime(date.year, date.month, date.day + 1);
    final DateTime fajrTomorrow = localisePrayerTime(raw.fajrAfter, tomorrow);

    // Shared between every widget that asks from here on, so the map is
    // frozen at the door rather than left as one reader's to corrupt.
    final LocalPrayerTimes result = LocalPrayerTimes(
      times: Map<String, DateTime>.unmodifiable(times),
      fajrTomorrow: fajrTomorrow,
    );
    _computed = result;
    _computedKey = key;

    // Once a second, forever, from three widgets at once — this line is the
    // spam, and it says nothing a developer cannot read off the UI. Kept for
    // debug builds, where it is what tells you *which* coordinate produced
    // the times on screen.
    if (!kReleaseMode) {
      debugPrint('GPS: $lat,$lng -> Fajr: ${times['fajr']} '
          '[${method.label} / ${isHanafi ? 'Hanafi' : 'Shafi'}]');
    }
    return result;
  }

  // -------------------------------------------------------------- formatting
  bool get use12Hour => _timeFormat != '24';

  /// `05:30 AM` when the 12-hour setting is on, `05:30` when it is not.
  String format(DateTime local) {
    if (use12Hour) {
      return DateFormat('hh:mm a').format(local).toUpperCase();
    }
    return DateFormat('HH:mm').format(local);
  }

  /// Compact variant for the horizontal chips (`5:30pm` / `17:30`) — the same
  /// trade-off [formatClockShort] makes for a board's own time: the digits
  /// first, the suffix squeezed on without a space.
  String formatShort(DateTime local) {
    if (use12Hour) {
      final String s = DateFormat('h:mm').format(local);
      final String suffix = DateFormat('a').format(local).toLowerCase();
      return '$s$suffix';
    }
    return DateFormat('HH:mm').format(local);
  }

  /// The same clock as [format], for a time that arrives as *stored text*.
  ///
  /// A masjid's Jamaat column is written to Firestore as strict `HH:MM`
  /// (`13:20`), so `Masjid.timeFor` hands the screen a number that knows
  /// nothing about the reader's preference — this is what turns it into
  /// `01:20 PM` for anyone who asked for the twelve-hour clock.
  ///
  /// Nothing else may change: `--:--` (a prayer the board never answered),
  /// an empty field and `13:60` (a typo somebody typed) pass through exactly
  /// as written. A missing time must never come back as a plausible one.
  String formatClock(String hhmm) {
    final (int, int)? clock = _parseClock(hhmm);
    if (clock == null) return hhmm;

    final int hour = clock.$1;
    final String mm = clock.$2.toString().padLeft(2, '0');
    if (!use12Hour) return '${hour.toString().padLeft(2, '0')}:$mm';

    // Zero-padded like `format`'s `hh`, so the column keeps lining up —
    // `05:15 AM` sits above `01:20 PM`.
    return '${_hour12(hour).toString().padLeft(2, '0')}:$mm ${hour < 12 ? 'AM' : 'PM'}';
  }

  /// Compact variant for the five chips on a card (`1:45pm` / `13:45`).
  ///
  /// A chip has about forty pixels of text width, so the space [formatClock]
  /// can afford after the digits goes on the suffix instead of on a gap.
  String formatClockShort(String hhmm) {
    final (int, int)? clock = _parseClock(hhmm);
    if (clock == null) return hhmm;

    final int hour = clock.$1;
    final String mm = clock.$2.toString().padLeft(2, '0');
    if (!use12Hour) return '${hour.toString().padLeft(2, '0')}:$mm';

    return '${_hour12(hour)}:$mm${hour < 12 ? 'am' : 'pm'}';
  }

  /// The two hours the twelve-hour clock names differently: 0 → 12, 13 → 1.
  static int _hour12(int hour) => hour % 12 == 0 ? 12 : hour % 12;

  static final RegExp _clockPattern = RegExp(r'^(\d{1,2}):(\d{2})$');

  /// `13:20` → `(13, 20)`, or `null` when [value] is not a wall clock.
  static (int, int)? _parseClock(String value) {
    final Match? match = _clockPattern.firstMatch(value.trim());
    if (match == null) return null;

    final int hour = int.parse(match.group(1)!);
    final int minute = int.parse(match.group(2)!);
    if (hour > 23 || minute > 59) return null;
    return (hour, minute);
  }
}
