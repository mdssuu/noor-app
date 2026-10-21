import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_settings.dart';
import 'azaan_alarm.dart';

/// The launcher icons the owner can pick between, by index.
///
/// Android resolves a launcher icon from the app's own resources, so "change
/// the icon for everyone" cannot mean "download any image" — it means choosing
/// among the variants baked into the build. The names here are what the admin
/// panel shows; the matching resources live in `res/mipmap` and the matching
/// `activity-alias` entries in the manifest, and [LauncherIconIndex] must stay
/// in step with both.
const List<String> kLauncherIconLabels = <String>[
  'Gold mosque (original)',
  'Crescent night',
  'Eight-point star',
  'Emerald minaret',
];

/// One screenful of everything the app's owner controls remotely.
///
/// This is the *content* of `app_config/general`, deliberately free of any
/// Firestore type so it can be parsed, compared, tested and cached to disk
/// without a Firebase in the room. [AppConfigData.fromMap] is the only way in
/// and [toMap] the only way out, which is what keeps a hand-edited document
/// from becoming a state the app cannot render.
@immutable
class AppConfigData {
  const AppConfigData({
    this.defaults = const NewUserDefaults(),
    this.wallpaperUrl = '',
    this.logoUrl = '',
    this.announcement = '',
    this.iconVariant = 0,
    this.azanUrls = const <String, String>{},
  });

  /// Reads the Firestore document — tolerantly.
  ///
  /// Every field is optional and every field is validated: the doc may not
  /// exist yet (nobody has opened the panel), may hold a value of the wrong
  /// type (hand-edited in the console), or may name something the app no
  /// longer offers (a sound key removed in a later build). None of those may
  /// reach the UI as an unrenderable state, so each falls back to what the
  /// app would have had anyway.
  factory AppConfigData.fromMap(Map<String, dynamic>? raw) {
    if (raw == null) return const AppConfigData();

    final Map<String, dynamic>? branding = _asMap(raw['branding']);

    // Remote clips are keyed by the *sound* key the Settings screen shows,
    // and only the slots that exist in this build are kept: a key the app
    // cannot play would otherwise sit in the panel looking like a live choice.
    final Map<String, dynamic>? azan = _asMap(raw['azanUrls']);
    final Map<String, String> clips = <String, String>{};
    if (azan != null) {
      for (final AzanSound sound in kAzanSounds) {
        if (sound.androidRaw == null) continue;
        final String url = _asUrl(azan[sound.key]);
        if (url.isNotEmpty) clips[sound.key] = url;
      }
    }

    return AppConfigData(
      defaults: NewUserDefaults.fromMap(_asMap(raw['defaults'])),
      wallpaperUrl: _asUrl(branding?['wallpaperUrl']),
      logoUrl: _asUrl(branding?['logoUrl']),
      announcement: _asText(branding?['announcement'], max: 400),
      iconVariant: _asVariant(branding?['iconVariant']),
      azanUrls: clips,
    );
  }

  /// The exact document shape [AppConfigData.fromMap] reads, so saving a
  /// panel edit and reading it back is a round trip that loses nothing —
  /// including a URL the owner has *cleared*, which has to actually clear.
  Map<String, Object?> toMap() => <String, Object?>{
        'defaults': defaults.toMap(),
        'branding': <String, Object?>{
          'wallpaperUrl': wallpaperUrl,
          'logoUrl': logoUrl,
          'announcement': announcement,
          'iconVariant': iconVariant,
        },
        'azanUrls': <String, Object?>{...azanUrls},
      };

  /// The defaults a brand-new profile opens on.
  final NewUserDefaults defaults;

  /// A photograph to stand behind every screen, or `''` for the drawn sky.
  final String wallpaperUrl;

  /// The mark shown in place of the built-in badge, or `''` for the badge.
  final String logoUrl;

  /// A notice shown at the top of Home, or `''` for none.
  final String announcement;

  /// Which bundled launcher icon is in force — an index into
  /// [kLauncherIconLabels].
  final int iconVariant;

  /// Sound key → direct URL of the clip that replaces the bundled one.
  ///
  /// Only the four slots that have a bundled counterpart are ever present;
  /// an empty map means "every Azaan plays what shipped with the app".
  final Map<String, String> azanUrls;

  AppConfigData copyWith({
    NewUserDefaults? defaults,
    String? wallpaperUrl,
    String? logoUrl,
    String? announcement,
    int? iconVariant,
    Map<String, String>? azanUrls,
  }) =>
      AppConfigData(
        defaults: defaults ?? this.defaults,
        wallpaperUrl: wallpaperUrl ?? this.wallpaperUrl,
        logoUrl: logoUrl ?? this.logoUrl,
        announcement: announcement ?? this.announcement,
        iconVariant: iconVariant ?? this.iconVariant,
        azanUrls: azanUrls ?? this.azanUrls,
      );

  static Map<String, dynamic>? _asMap(Object? value) => value is Map
      ? value.map((Object? key, Object? item) =>
          MapEntry<String, dynamic>(key.toString(), item))
      : null;

  static String _asText(Object? value, {required int max}) {
    if (value is! String) return '';
    final String text = value.trim();
    return text.length <= max ? text : text.substring(0, max);
  }

  /// A URL is only a URL if it is one the app can actually fetch over the
  /// network; anything else reads as "unset" rather than as a broken image
  /// on every user's screen.
  static String _asUrl(Object? value) {
    if (value is! String) return '';
    final String url = value.trim();
    final Uri? parsed = Uri.tryParse(url);
    if (parsed == null) return '';
    if (parsed.scheme != 'http' && parsed.scheme != 'https') return '';
    if (parsed.host.isEmpty) return '';
    return url;
  }

  static int _asVariant(Object? value) => value is num
      ? value.toInt().clamp(0, kLauncherIconLabels.length - 1).toInt()
      : 0;

  @override
  bool operator ==(Object other) =>
      other is AppConfigData &&
      other.defaults == defaults &&
      other.wallpaperUrl == wallpaperUrl &&
      other.logoUrl == logoUrl &&
      other.announcement == announcement &&
      other.iconVariant == iconVariant &&
      _sameClips(other.azanUrls, azanUrls);

  @override
  int get hashCode {
    // Sorted, because a hash that depends on insertion order would give two
    // configs holding the same clips two different hashes — and == above
    // says they are the same document.
    final List<MapEntry<String, String>> entries = azanUrls.entries.toList()
      ..sort((MapEntry<String, String> a, MapEntry<String, String> b) =>
          a.key.compareTo(b.key));
    return Object.hash(
      defaults,
      wallpaperUrl,
      logoUrl,
      announcement,
      iconVariant,
      Object.hashAll(entries
          .map((MapEntry<String, String> e) => '${e.key}=${e.value}')),
    );
  }

  static bool _sameClips(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length &&
      a.entries.every((MapEntry<String, String> e) => b[e.key] == e.value);
}

/// The owner's control document: one Firestore doc, one screen, no rebuilds.
///
/// Everything the app can be changed *to* — the defaults a new profile opens
/// on, the wallpaper behind every screen, the notice at the top of Home, the
/// launcher icon, the Azaan clips — is read from `app_config/general` and
/// mirrored into SharedPreferences, so the first frame of a cold start is
/// already dressed in the current config and a phone with no network still
/// opens looking right.
///
/// Two things are deliberately *not* here:
///
///  * **seeding** asks [AppSettings] rather than writing preferences itself,
///    because only that class knows which profile is in force and which has
///    never spoken for itself;
///  * **enforcement** lives in `firestore.rules`, where an email claim can
///    actually be checked. Everything in this file is a convenience: a client
///    cannot keep a determined person out of its own code, and pretending
///    otherwise would be worse than saying so.
class AppConfig extends ChangeNotifier {
  AppConfig._();

  static final AppConfig instance = AppConfig._();

  /// The document every build reads. One doc rather than a collection, so a
  /// fetch is one round trip and there is never a question of *which* config
  /// a phone picked up.
  static const String collectionName = 'app_config';
  static const String documentId = 'general';

  // Where the last known config is kept on disk. Written on every change so
  // the very first frame of the next launch has it, before any network call.
  static const String _kCache = 'app_config_cache_v1';

  /// Per-file marker of which URL a cached download belongs to, so a changed
  /// URL is re-fetched and a cleared one stops being served.
  static const String _kSourcePrefix = 'app_config_src::';

  AppConfigData _data = const AppConfigData();
  AppConfigData get data => _data;

  bool _loaded = false;
  bool get isLoaded => _loaded;

  ImageProvider? _wallpaper;

  /// The wallpaper as a provider, or `null` while there is none to show.
  ///
  /// Null means "paint the drawn sky" — the state both a config without a
  /// wallpaper and a download that has not landed yet want, so the screen
  /// never shows a broken image where a sky used to be.
  ImageProvider? get wallpaperImage => _wallpaper;

  Future<void>? _pendingLoad;
  Future<void>? _pendingMedia;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _subscription;

  DocumentReference<Map<String, dynamic>> get _doc => FirebaseFirestore
      .instance
      .collection(collectionName)
      .doc(documentId);

  /// Brings the config up to date: disk first, network second, live from then
  /// on. Idempotent, because `RootGate` and `_bootstrap` both ask.
  Future<void> load() {
    if (_pendingLoad != null) return _pendingLoad!;
    final Future<void> work = _load().whenComplete(() => _pendingLoad = null);
    _pendingLoad = work;
    return work;
  }

  Future<void> _load() async {
    await _readCache();
    _loaded = true;
    await _pull();
    _subscribe();
  }

  /// The last config this phone saw, applied before any network is attempted.
  Future<void> _readCache() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? cached = prefs.getString(_kCache);
      if (cached == null || cached.isEmpty) return;
      final Object? decoded = jsonDecode(cached);
      if (decoded is! Map) return;
      _adopt(AppConfigData.fromMap(_stringKeyed(decoded)), persist: false);
    } catch (error) {
      debugPrint('Noor ▸ app config cache unreadable: $error');
    }
  }

  /// One server read, for the phone that has just come online.
  Future<void> _pull() async {
    try {
      final DocumentSnapshot<Map<String, dynamic>> snap = await _doc.get();
      if (!snap.exists) return;
      _adopt(AppConfigData.fromMap(snap.data()), persist: true);
    } catch (error) {
      // Offline, signed out or rules denying the read — the cache is already
      // showing, so this is a note rather than a failure the user sees.
      debugPrint('Noor ▸ app config fetch failed: $error');
    }
  }

  /// Follows the document so an owner's edit reaches open phones without
  /// waiting for the next launch — which is the whole point of a control
  /// document instead of a build-time constant.
  void _subscribe() {
    _subscription ??= _doc.snapshots().listen(
      (DocumentSnapshot<Map<String, dynamic>> snap) {
        if (!snap.exists) return;
        _adopt(AppConfigData.fromMap(snap.data()), persist: true);
      },
      onError: (Object error) =>
          debugPrint('Noor ▸ app config watch failed: $error'),
    );
  }

  /// Swaps in [next], wakes everything that depends on it, and mirrors it to
  /// disk so the next cold start opens on it too.
  void _adopt(AppConfigData next, {required bool persist}) {
    if (next == _data) return;
    _data = next;
    if (persist) _writeCache();
    notifyListeners();

    // The wallpaper, the clips and the launcher icon all live outside this
    // document's own storage: they are files and components that have to be
    // brought into line with what the document now says.
    unawaited(prepareMedia());
    unawaited(AzaanAlarm.setLauncherIcon(next.iconVariant));
  }

  Future<void> _writeCache() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCache, jsonEncode(_data.toMap()));
    } catch (error) {
      debugPrint('Noor ▸ app config cache write failed: $error');
    }
  }

  /// What the owner saved from the panel, applied at once and written to
  /// Firestore. The local state moves first so the panel reflects the tap
  /// even on a slow link; the server write's failure is passed back to the
  /// caller, which is the only one showing a "saved?" answer.
  Future<void> save(AppConfigData next) async {
    _adopt(next, persist: true);
    try {
      await _doc.set(
        <String, Object?>{
          ...next.toMap(),
          'updatedAt': FieldValue.serverTimestamp(),
        },
        // A field mask, not a bare merge: a nested map under merge semantics
        // is merged key by key, so clearing a URL the owner has emptied would
        // leave the old one behind. A mask replaces each named field outright,
        // which is the meaning of "I have cleared this". Only these four are
        // named, so anything else the document may carry is left alone.
        SetOptions(mergeFields: <String>[
          'defaults',
          'branding',
          'azanUrls',
          'updatedAt',
        ]),
      );
    } catch (error) {
      debugPrint('Noor ▸ app config save failed: $error');
      rethrow;
    }
  }

  /// Gives the owner's chosen defaults to a profile that has never stored a
  /// setting — and to no other profile, ever.
  ///
  /// This runs once per account, right after the profile has been read from
  /// disk and before the user has had a chance to open Settings, so a fresh
  /// install opens on the madhab, the method, the offsets and the clip the
  /// owner decided it should. Everyone else keeps what they chose: the check
  /// is [AppSettings.isVirginProfile], which is false the moment a profile
  /// has any preference of its own.
  void seedNewProfile() {
    final AppSettings settings = AppSettings.instance;
    if (!settings.isVirginProfile) return;
    settings.seedWith(_data.defaults);
    debugPrint('Noor ▸ new profile seeded with the owner\'s defaults');
  }

  /// The clip URL the owner has assigned to [key], or `''` for the bundled one.
  String azanUrlFor(String key) => _data.azanUrls[key] ?? '';

  /// Whether [key] is currently overridden by a remote clip.
  bool hasCustomAzan(String key) => azanUrlFor(key).isNotEmpty;

  /// Brings every downloaded artefact in line with the config as it stands.
  ///
  /// Runs on every adoption, which is cheap: each file records the URL it
  /// came from, so nothing is re-fetched while the config has not moved. A
  /// URL that has been cleared has its file *deleted*, because the bundled
  /// clip has to take the slot back rather than the old download playing on.
  Future<void> prepareMedia() {
    if (_pendingMedia != null) return _pendingMedia!;
    final Future<void> work = Future.wait<void>(<Future<void>>[
      _prepareWallpaper(),
      _prepareAzanClips(),
    ]).whenComplete(() => _pendingMedia = null);
    _pendingMedia = work;
    return work;
  }

  Future<void> _prepareWallpaper() async {
    final String url = _data.wallpaperUrl;
    if (url.isEmpty) {
      if (_wallpaper != null) {
        _wallpaper = null;
        notifyListeners();
      }
      return _removeFile('wallpaper.img');
    }

    final File? file = await _download(url, 'wallpaper.img');
    // A file we can own, or the network itself while the first download is
    // still in flight — never a stale file from a previous URL.
    final ImageProvider next = file != null ? FileImage(file) : NetworkImage(url);
    if (next == _wallpaper) return;
    _wallpaper = next;
    notifyListeners();
  }

  Future<void> _prepareAzanClips() async {
    for (final AzanSound sound in kAzanSounds) {
      final String? raw = sound.androidRaw;
      if (raw == null) continue;
      final String fileName = 'azaan_$raw.clip';
      final String url = _data.azanUrls[sound.key] ?? '';
      if (url.isEmpty) {
        await _removeFile(fileName);
        continue;
      }
      await _download(url, fileName);
    }
  }

  /// Downloads [url] to the app's private files directory as [fileName],
  /// where the Kotlin side can open it by path with the app not running.
  ///
  /// Returns null when there is no usable file: no network, an answer that
  /// is not a 200, or a body with nothing in it. Callers fall back to what
  /// the app ships with, which is the point — a broken link costs an owner
  /// their custom clip, never a user's Azaan.
  Future<File?> _download(String url, String fileName) async {
    try {
      final Directory dir = await getApplicationSupportDirectory();
      final File file = File('${dir.path}${Platform.pathSeparator}$fileName');
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String sourceKey = '$_kSourcePrefix$fileName';

      if (await file.exists() && prefs.getString(sourceKey) == url) {
        return file;
      }

      final http.Response response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 45));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        debugPrint('Noor ▸ app config: $url answered ${response.statusCode}');
        return null;
      }

      await file.writeAsBytes(response.bodyBytes, flush: true);
      await prefs.setString(sourceKey, url);
      return file;
    } catch (error) {
      debugPrint('Noor ▸ app config download failed for $url: $error');
      return null;
    }
  }

  Future<void> _removeFile(String fileName) async {
    try {
      final Directory dir = await getApplicationSupportDirectory();
      final File file = File('${dir.path}${Platform.pathSeparator}$fileName');
      if (await file.exists()) await file.delete();
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_kSourcePrefix$fileName');
    } catch (_) {
      // A file that will not go away is the bundled clip losing one round;
      // it is not worth telling anyone about.
    }
  }

  static Map<String, dynamic> _stringKeyed(Map<Object?, Object?> map) =>
      map.map((Object? key, Object? value) =>
          MapEntry<String, dynamic>(key.toString(), value));

  /// Stops following the document — tests and a signed-out app.
  @override
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    super.dispose();
  }
}
