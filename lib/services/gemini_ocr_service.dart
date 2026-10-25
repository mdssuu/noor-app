import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:http/http.dart' as http;

/// ===========================================================================
///  Gemini Vision — Jamaat times from a photographed board
/// ===========================================================================
///
/// SECURITY NOTE — read before shipping anything but a personal build.
///
/// The key lives in `.env` on the machine that builds, and is read with
/// `flutter_dotenv`, so it never appears in a Dart source file. The `.env`
/// **committed to this repo is a placeholder with an empty key** — CI, clones
/// and Codespaces therefore build with no Gemini key and fall straight back
/// to on-device ML Kit. The key is still **not secret on a device** if a build
/// does carry it.
///
/// `flutter_dotenv` ships `.env` as a bundled asset, and assets are plain
/// files inside the APK:
///
///     unzip -p app.apk assets/flutter_dotenv/assets/.env
///
/// so anyone who has the APK has the key. Two things close that gap:
///
///   1. Restrict the key in Google Cloud to this app's Android package name
///      (`com.sunesra_app`) plus its signing SHA-1, so a stolen key
///      cannot be replayed from curl or another app.
///   2. Move the call behind a backend proxy — see [_usesProxy] below. Set
///      `GEMINI_PROXY_URL` in `.env` and the key stops shipping entirely;
///      this file then only needs [GeminiOcrService.extractJamaatTimes].
///
/// Until then, treat this key as public and put a spending cap on it.
/// ===========================================================================

/// What Gemini managed to read off the board.
class GeminiOcrResult {
  const GeminiOcrResult({
    required this.times,
    required this.rawText,
    this.masjidName,
    this.outOfOrder = false,
  });

  /// prayer key (`fajr`, `dhuhr`, `asr`, `maghrib`, `isha`, `juma`) -> `HH:MM`
  /// in 24-hour form, ready for the review screen's fields.
  final Map<String, String> times;

  /// The model's raw JSON, kept so the review screen can show what came back.
  final String rawText;

  final String? masjidName;

  /// True when the readings still do not rise through the day after
  /// normalisation — almost always a Start/Jamaat column mix-up.
  final bool outOfOrder;
}

class GeminiOcrService {
  GeminiOcrService._();

  /// Pinned model, overridable with `GEMINI_MODEL` in `.env`.
  ///
  /// Not hard-coded to a single name because that is exactly how this broke
  /// once already: the original `gemini-1.5-flash` now returns
  /// "is not found for API version v1beta", which would have quietly dropped
  /// every scan back to on-device OCR with nothing in the log but a 404.
  /// Both `gemini-2.5-flash` and `gemini-3.8-flash` were verified against a
  /// real two-column board before this default was chosen.
  static const String _defaultModel = 'gemini-2.5-flash';

  static String get _model {
    final String configured = _read('GEMINI_MODEL').trim();
    return configured.isEmpty ? _defaultModel : configured;
  }

  /// Refuse to send anything for a placeholder or empty key rather than
  /// spending a round trip guaranteed to get a 400 back.
  static const String _placeholder = 'PASTE_YOUR_NEW_KEY_HERE';

  static bool get _usesProxy => _read('GEMINI_PROXY_URL').isNotEmpty;

  static String get _apiKey => _read('GEMINI_API_KEY');

  static String _read(String name) {
    // `dotenv.env` throws NotInitializedError before `load()` has run, and a
    // missing .env must degrade to "no Gemini" instead of crashing at boot.
    if (!dotenv.isInitialized) return '';
    return dotenv.env[name] ?? '';
  }

  /// True when OCR could go to the cloud — used to log intent, never to gate
  /// the UI, because the on-device reader always remains available.
  static bool get isConfigured =>
      _usesProxy || (_apiKey.isNotEmpty && _apiKey != _placeholder);

  /// Why the most recent [extractJamaatTimes] came back `null`.
  ///
  /// The scan path must never show an error dialog — the on-device reader is
  /// always behind it — but a *silent* fallback is what makes the feature look
  /// flaky: the AI fails once for a reason nobody can see, the on-device
  /// result is used instead, and that result is often wrong. The review screen
  /// reads this to say out loud that AI was skipped, and to offer a retry.
  static String? lastFailureReason;

  /// Transient failures seen in the wild: Google answers `503 UNAVAILABLE —
  /// high demand` under load, 429 when the key's quota is spent, and a
  /// thinking model can outlast the deadline on a slow mobile connection. Any
  /// of those once meant the scan silently dropped to on-device OCR.
  static const int _maxAttempts = 3;

  /// Per attempt. The old 25 s deadline was tight enough that a slow-but-
  /// perfectly good response looked identical to an outage.
  static const Duration _attemptTimeout = Duration(seconds: 40);

  static const List<Duration> _retryDelay = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 3),
  ];

  /// Asks Gemini to read the board. Returns `null` — never throws — whenever
  /// the caller should fall back to on-device OCR.
  ///
  /// Transient failures are retried up to [_maxAttempts] times; permanent ones
  /// (bad key, retired model, unsupported location) fall through at once
  /// because retrying them only delays the fallback.
  static Future<GeminiOcrResult?> extractJamaatTimes(
    Uint8List jpeg, {
    String? hint,
  }) async {
    if (!dotenv.isInitialized) {
      lastFailureReason = 'the .env file is not loaded';
      debugPrint('Gemini ▸ .env not loaded — using on-device OCR');
      return null;
    }
    if (!_usesProxy && !isConfigured) {
      lastFailureReason = 'no API key is configured in .env';
      debugPrint('Gemini ▸ GEMINI_API_KEY missing in .env — using on-device OCR');
      return null;
    }

    final Stopwatch clock = Stopwatch()..start();
    for (int attempt = 1; attempt <= _maxAttempts; attempt++) {
      try {
        final String raw =
            await _generate(jpeg, hint: hint).timeout(_attemptTimeout);
        clock.stop();

        if (raw.trim().isEmpty) {
          lastFailureReason = 'the model returned an empty response';
          debugPrint('Gemini ▸ empty response in ${clock.elapsedMilliseconds}ms — '
              'using on-device OCR');
          return null;
        }

        final GeminiOcrResult? result = _parse(raw);
        if (result == null) {
          lastFailureReason = 'the model replied with something that was not a board';
          debugPrint('Gemini ▸ unparseable response in ${clock.elapsedMilliseconds}ms');
          return null;
        }

        lastFailureReason = null;
        debugPrint('Gemini ▸ ${result.times.length} Jamaat time(s) in '
            '${clock.elapsedMilliseconds}ms ${result.times}'
            '${result.outOfOrder ? ' OUT OF ORDER' : ''}'
            '${attempt > 1 ? ' (attempt $attempt)' : ''}');
        return result;
      } on GenerativeAIException catch (error) {
        if (!_isTransient(error) || attempt == _maxAttempts) {
          lastFailureReason = _describe(error);
          debugPrint('Gemini ▸ refused ($error) — using on-device OCR');
          return null;
        }
        debugPrint('Gemini ▸ attempt $attempt failed ($error) — retrying');
      } catch (error) {
        // TimeoutException, socket resets, TLS hiccups: worth another go. A
        // malformed-request failure is not, and the same test says so here.
        if (!_isTransient(error) || attempt == _maxAttempts) {
          lastFailureReason = _describe(error);
          debugPrint('Gemini ▸ failed after ${clock.elapsedMilliseconds}ms '
              '($error) — using on-device OCR');
          return null;
        }
        debugPrint('Gemini ▸ attempt $attempt failed ($error) — retrying');
      }
      await Future<void>.delayed(_retryDelay[attempt - 1]);
    }
    return null;
  }

  /// Whether another attempt could plausibly succeed.
  ///
  /// Everything is assumed transient unless it is one of the failures that
  /// are decided by the request itself rather than by load: an invalid key, a
  /// retired model name, a refused location, or a malformed request.
  static bool _isTransient(Object error) {
    final String message = error.toString();
    const List<String> permanent = <String>[
      'API key not valid',
      'API_KEY_INVALID',
      'PERMISSION_DENIED',
      'is not found for API version',
      'User location is not supported',
      'INVALID_ARGUMENT',
      'problem with the Google Generative AI SDK',
    ];
    return !permanent.any(message.contains);
  }

  /// A one-line explanation the review screen can show next to the fields.
  static String _describe(Object error) {
    final String message = error.toString().trim();
    return message.isEmpty ? error.runtimeType.toString() : message;
  }

  // =========================================================================
  //  Transport — exactly one method to replace when a proxy arrives
  // =========================================================================

  /// Everything that talks to the network lives here. Swapping to a backend
  /// proxy means replacing this body with a `POST` of the same JSON; every
  /// caller stays untouched.
  ///
  /// No `.timeout` here on purpose: the deadline belongs to the retry loop in
  /// [extractJamaatTimes], which needs to know whether a failure was slow
  /// rather than have one of the two nested timers fire first.
  static Future<String> _generate(Uint8List jpeg, {String? hint}) async {
    final String endpoint = _read('GEMINI_PROXY_URL');
    if (endpoint.isNotEmpty) {
      return _generateViaProxy(endpoint, jpeg, hint: hint);
    }

    final String apiKey = _apiKey;
    if (apiKey.isEmpty || apiKey == _placeholder) {
      throw GenerativeAIException('GEMINI_API_KEY is not set');
    }

    final GenerativeModel model = GenerativeModel(
      model: _model,
      apiKey: apiKey,
      // JSON mode removes the "here's your result:\n```json ...```" wrapper
      // and the occasional stray sentence that used to break the decoder.
      generationConfig: GenerationConfig(
        responseMimeType: 'application/json',
        temperature: 0,
      ),
      systemInstruction: Content.system(_systemPrompt),
    );

    final GenerateContentResponse response = await model.generateContent(
      <Content>[
        Content.multi(<Part>[
          TextPart(_userPrompt(hint: hint)),
          DataPart('image/jpeg', jpeg),
        ]),
      ],
    );

    return response.text ?? '';
  }

  /// Stand-in for a future backend. POSTs the image, expects the same JSON
  /// the model returns directly, so switching over needs no parser changes.
  static Future<String> _generateViaProxy(
    String endpoint,
    Uint8List jpeg, {
    String? hint,
  }) async {
    final http.Response response = await http.post(
      Uri.parse(endpoint),
      headers: const <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, Object?>{
        'model': _model,
        'hint': hint,
        'image': base64Encode(jpeg),
      }),
    );
    if (response.statusCode != 200) {
      throw GenerativeAIException('proxy HTTP ${response.statusCode}');
    }
    return response.body;
  }

  // =========================================================================
  //  Prompt
  // =========================================================================

  static const String _systemPrompt = '''
You transcribe photographs of masjid (mosque) prayer-time boards.

Reply with STRICT JSON only. No prose, no markdown fences, no commentary.

Every board showing two times per prayer means two different things:
  * the START time — also called azan, aazaan, begins, begins prayer,
    start, or the time the prayer itself opens; and
  * the JAMAAT time — also called iqamah, jamat, congregation, stands,
    or jamat starts.

ALWAYS return the JAMAAT time. NEVER the start/azan time. If only one time
is printed, treat it as the jamaat time.

Use a 24-hour clock. Fajr is a morning prayer, so 05:50 stays 05:50. Dhuhr,
Asr, Maghrib and Isha are afternoon/evening prayers: if the board prints them
in 12-hour form without AM/PM, read them as PM — 1:15 becomes 13:15.

Omit any key the board does not show. Do not invent a value.

Schema:
{"name":"string","fajr":"HH:MM","dhuhr":"HH:MM","asr":"HH:MM","maghrib":"HH:MM","isha":"HH:MM","juma":"HH:MM"}''';

  static String _userPrompt({String? hint}) {
    final String extra =
        (hint == null || hint.trim().isEmpty) ? '' : ' The board may be labelled: ${hint.trim()}.';
    return 'Read the Jamaat times from this board.$extra';
  }

  // =========================================================================
  //  Parsing
  // =========================================================================

  static const Map<String, List<String>> _aliases = <String, List<String>>{
    'fajr': <String>['fajr', 'fajar', 'subuh', 'fajr_jamat'],
    'dhuhr': <String>['dhuhr', 'zohar', 'zuhr', 'zohr', 'dhuhur', 'dhuhr_jamat'],
    'asr': <String>['asr', 'asar'],
    'maghrib': <String>['maghrib', 'magrib', 'maghreb'],
    'isha': <String>['isha', 'ishaa', 'esha'],
    'juma': <String>['juma', 'jumuah', 'friday'],
  };

  static const List<String> _dayOrder = <String>['fajr', 'dhuhr', 'asr', 'maghrib', 'isha'];

  /// Parses a model response into times. Public so the Start-vs-Jamaat and
  /// 12-hour rules can be pinned by a test without a key or a network call.
  static GeminiOcrResult? parseResponse(String raw) => _parse(raw);

  static GeminiOcrResult? _parse(String raw) {
    final Map<String, dynamic>? json = _decodeObject(raw);
    if (json == null) return null;

    final Map<String, String> times = <String, String>{};
    json.forEach((String key, dynamic value) {
      if (value is! String) return;
      final String? prayer = _matchPrayer(key);
      if (prayer == null) return;
      final String? hhmm = _to24(prayer, value);
      if (hhmm != null) times[prayer] = hhmm;
    });

    if (times.isEmpty) return null;

    _repairOrder(times);

    final String name = _stringOf(json['name']);
    return GeminiOcrResult(
      times: times,
      rawText: raw.trim(),
      masjidName: name.isEmpty ? null : name,
      outOfOrder: _isOutOfOrder(times),
    );
  }

  /// Tolerates JSON mode being ignored: strips fences and grabs the outermost
  /// `{ ... }` whatever the model wrapped it in.
  static Map<String, dynamic>? _decodeObject(String raw) {
    String text = raw.trim();
    text = text.replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '');
    text = text.replaceFirst(RegExp(r'\s*```$'), '');

    final int start = text.indexOf('{');
    final int end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return null;

    try {
      final Object? decoded = jsonDecode(text.substring(start, end + 1));
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (error) {
      debugPrint('Gemini ▸ JSON decode failed: $error');
      return null;
    }
  }

  static String? _matchPrayer(String key) {
    final String normalised = key.trim().toLowerCase().replaceAll(RegExp(r'[\s\-]+'), '_');
    for (final MapEntry<String, List<String>> entry in _aliases.entries) {
      if (entry.value.contains(normalised)) return entry.key;
    }
    return null;
  }

  static String _stringOf(dynamic value) =>
      value is String ? value.trim() : (value == null ? '' : value.toString().trim());

  /// `5:50`, `05.50`, `5 : 50` and the odd board that drops the colon
  /// (`0550`) all land as a canonical `HH:MM`, or `null` if unusable.
  static String? _to24(String prayer, String value) {
    RegExpMatch? match = RegExp(r'(\d{1,2})\s*[:.]\s*(\d{2})').firstMatch(value);
    int? hour;
    int? minute;

    if (match != null) {
      hour = int.tryParse(match.group(1)!);
      minute = int.tryParse(match.group(2)!);
    } else {
      final String digits = value.replaceAll(RegExp(r'\D'), '');
      if (digits.length == 3 || digits.length == 4) {
        hour = int.tryParse(digits.substring(0, digits.length - 2));
        minute = int.tryParse(digits.substring(digits.length - 2));
      }
    }

    if (hour == null || minute == null) return null;
    if (hour > 23 || minute > 59) return null;
    if (prayer.isEmpty) return null;

    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }

  /// Fajr 05:50 then Dhuhr 01:15 only makes sense if the board is printing
  /// afternoon prayers in 12-hour form. Rather than blanket-add 12 (which
  /// would break a board that genuinely says `11:45`), try the readings as
  /// transcribed first and only lift them if they do not rise through the day.
  static void _repairOrder(Map<String, String> times) {
    if (!_isOutOfOrder(times)) return;

    final Map<String, String> lifted = Map<String, String>.from(times);
    for (final String key in _dayOrder) {
      if (key == 'fajr') continue;
      final String? value = lifted[key];
      if (value == null) continue;
      final int? hour = int.tryParse(value.split(':').first);
      if (hour == null || hour >= 12) continue;
      lifted[key] = '${(hour + 12).toString().padLeft(2, '0')}:${value.split(':').last}';
    }

    if (!_isOutOfOrder(lifted)) {
      times
        ..clear()
        ..addAll(lifted);
    }
  }

  static bool _isOutOfOrder(Map<String, String> times) {
    int? previous;
    for (final String key in _dayOrder) {
      final String? value = times[key];
      if (value == null) continue;
      final int? hour = int.tryParse(value.split(':').first);
      final int? minute = int.tryParse(value.split(':').last);
      if (hour == null || minute == null) continue;
      final int minutes = hour * 60 + minute;
      if (previous != null && minutes < previous) return true;
      previous = minutes;
    }
    return false;
  }
}
