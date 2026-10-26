import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Bridge to the native alarm-stream player in `MainActivity.kt`.
///
/// This is the **only** audible path a prayer reminder has. The reminder
/// notification posts to a channel with no sound — on `RINGER_MODE_SILENT` /
/// `VIBRATE` Android mutes every notification sound anyway, so a recitation
/// carried by the channel would never be heard. Routing the clip through
/// `AudioAttributes.USAGE_ALARM` puts it on the one stream a ringer key does
/// not mute, and that turns out to make the *app* the party that decides
/// whether a silenced reader hears anything: [ringerMode] reads the switch,
/// and `AzaanAudio.play` refuses when the answer is not `normal`. Because
/// exactly one thing makes the noise, a volume key during playback always
/// means "stop it" — [MainActivity]'s key handler in front, the playback
/// service's media session otherwise, and the "STOP AZAN" action on its
/// notification when the phone is locked.
///
/// The clip leaves at the instant the reader chose — the prayer time less
/// whatever the chips say, `0` when they say "At time". The chips are not a
/// note about the Azaan, they *are* when the Azaan happens, and scheduling the
/// recitation somewhere other than the moment the banner fires is what left a
/// reader who had asked for "5 min before" listening to the Azaan arrive on
/// the dot. One instant, one card: [AzaanAlarm] carries the card's own line
/// too, so the receiver can say what the banner would have said even when the
/// phone is silenced and no clip is allowed to sound.
class AzaanAlarm {
  AzaanAlarm._();

  static const MethodChannel _channel = MethodChannel('noor_masjid_time/azaan');

  /// Fired when a native playback run reaches the end of the clip, so the
  /// Settings row can stop showing itself as "playing".
  static void Function()? onPlaybackFinished;

  /// Fired when something *outside* this side asked the clip to stop — the
  /// volume key taken over by the platform side, or the recitation screen the
  /// alarm raises over the lock screen.
  ///
  /// It has to exist because playback has two homes: the native alarm-stream
  /// player this class drives, and the fallback player on the Dart side that
  /// runs where the native one does not. A stop has to reach both, or the
  /// fallback keeps sounding while the key that was pressed does nothing.
  static void Function()? onStopRequested;

  static bool _listening = false;

  /// Ids live in the same space as the `flutter_local_notifications` ids, so
  /// an alarm and its notification can be cancelled together.
  static const int azanIdFloor = 0;
  static const int azanIdCeiling = 1000000000;

  /// Every entry point is guarded: on iOS, desktop and web there is no Kotlin
  /// side, and a `MissingPluginException` must never break scheduling.
  static Future<Object?> _call(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<Object?>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      // Loud for the cases that hide a real failure: `bad-args` means the
      // two sides of this channel disagree on a key, and swallowing that is
      // what let `cancelRange` silently cancel nothing.
      debugPrint('Noor ▸ azaan alarm ▸ $method failed [${error.code}]: ${error.message}');
      return null;
    }
  }

  static void install() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      // This runs on the platform side's schedule, never on ours, and the
      // chain it starts ends in a `setState` on whatever screen is listening.
      // Deferring one frame means (a) no tree mutation from inside a channel
      // callback, and (b) if the screen went away while the clip was playing,
      // its `dispose` has already nulled the callback by the time this fires.
      if (call.method == 'stopRequested') {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          onStopRequested?.call();
        });
        return null;
      }
      if (call.method != 'playbackFinished') return null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onPlaybackFinished?.call();
      });
      return null;
    });
  }

  /// Arms one exact alarm at [at] that plays [raw] on the alarm stream.
  /// [title] only labels the foreground notification Android insists on while
  /// the recitation is running.
  ///
  /// [recurring] is what makes the Azaan outlive the process. The native side
  /// keeps a ledger of what it armed, and: the receiver puts tomorrow's copy
  /// in place as soon as today's has rung; boot, app-update, timezone and
  /// clock-change broadcasts re-derive every entry from its stored local time.
  /// Without it every alarm would die with the process — and a phone that is
  /// restarted on Sunday would recite only until Sunday's last prayer.
  ///
  /// The Settings "test reminder" probe passes `false`: a diagnostic that
  /// resurrects itself every morning would be a bug, not a feature.
  static Future<void> schedule({
    required int id,
    required DateTime at,
    required String raw,
    String? title,
    String? body,
    bool recurring = true,
  }) async {
    install();
    await _call('schedule', <String, Object?>{
      'id': id,
      'atMs': at.millisecondsSinceEpoch,
      'sound': raw,
      'title': title,
      'body': body,
      'recurring': recurring,
    });
  }

  static Future<void> cancel(int id) => _call('cancel', <String, Object?>{'id': id});

  /// Drops every alarm in `[from, to)`. The favourite-masjid block is
  /// re-armed wholesale on each pass, so it clears its own range rather than
  /// reaching into the 0..4 range the calculated reminders own.
  ///
  /// The wire keys are `from` / `to` — `MainActivity`'s `cancelRange` branch
  /// must read exactly those two names. It used to read `until`, answered
  /// `bad-args` on every call, and [_call] downgraded that to a debugPrint,
  /// which is how an un-starred masjid kept reciting.
  static Future<void> cancelRange(int from, int to) =>
      _call('cancelRange', <String, Object?>{'from': from, 'to': to});

  /// Plays [raw] right now on the alarm stream — the "Test Azaan" button and
  /// the in-app preview. Returns `false` when the platform has no native side,
  /// which is the caller's cue to fall back to the remote clip, and when the
  /// phone is silenced, which is not: [ringerMode] is asked before dialling
  /// precisely so that case never reaches the fallback.
  static Future<bool> playNow(String raw) async {
    install();
    return await _call('playNow', <String, Object?>{'sound': raw}) == true;
  }

  /// The phone's own ringer switch: `normal`, `vibrate` or `silent`.
  ///
  /// The one question worth asking before any noise is made. The alarm stream
  /// a recitation rides is deliberately the stream a ringer key does not
  /// mute — which means nothing downstream can be trusted to stay quiet on a
  /// phone somebody switched off, so the switching off is checked here
  /// instead. `normal` is also the answer where there is no Android side to
  /// ask (desktop, web, tests): a guard must never be able to block a
  /// platform that has nothing to guard.
  static Future<String> ringerMode() async {
    install();
    final Object? value = await _call('ringerMode');
    return value is String && value.isNotEmpty ? value : 'normal';
  }

  static Future<void> stop() => _call('stop');

  /// Points the launcher at one of the icon variants bundled with the build.
  ///
  /// An icon cannot be downloaded: Android resolves a launcher icon from the
  /// app's own resources, so the owner's "change the icon" is a choice
  /// between *prepared* icons rather than an arbitrary file. The platform
  /// side holds them as four `activity-alias` entries and enables exactly one,
  /// which is what makes the switch possible without shipping an update.
  ///
  /// [variant] is an index into that list; out-of-range values are clamped
  /// there so a hand-edited config document cannot leave the phone with no
  /// launcher entry at all. Failures are swallowed — a phone that refuses the
  /// switch keeps the icon it already has, which is a better outcome than a
  /// boot that reports an error for a cosmetic choice.
  static Future<void> setLauncherIcon(int variant) =>
      _call('setLauncherIcon', <String, Object?>{'variant': variant});

  /// Android 12+ can revoke `SCHEDULE_EXACT_ALARM`; without it the azaan
  /// drifts off the minute by up to 15 minutes in battery-saver mode.
  static Future<bool> canScheduleExact() async =>
      await _call('canScheduleExact') == true;

  /// What the native ledger actually holds — the alarms that would survive a
  /// reboot, in prayer order.
  ///
  /// The Dart side cannot answer this for itself: the ledger lives in
  /// SharedPreferences on the Kotlin side, written *before* each alarm is
  /// armed so a crash in between cannot orphan one. Reading it back is the
  /// only way to tell the user what is genuinely armed rather than what was
  /// asked for, which is what makes the admin diagnostics worth showing.
  static Future<List<Map<String, Object?>>> alarmLedger() async {
    final Object? raw = await _call('alarmLedger');
    if (raw is! List) return const <Map<String, Object?>>[];
    return raw.whereType<Map>().map((Map entry) =>
        entry.map((Object? key, Object? value) => MapEntry(key.toString(), value))).toList();
  }

  /// Whether Android is willing to show this app's notifications at all.
  ///
  /// The alarms and the recitation are unaffected by it — they run through
  /// AlarmManager and the alarm stream — so a denied notification permission
  /// produces the worst possible combination: the phone recites at the right
  /// minute with nothing on screen to explain why, and no banner to dismiss.
  /// The app asks instead of assuming.
  static Future<bool> notificationsEnabled() async =>
      await _call('areNotificationsEnabled') == true;

  /// The two switches that decide whether the lock-screen prayer card can be
  /// seen while the phone is locked: notifications at all, and the phone's
  /// own "on the lock screen" toggle.
  ///
  /// The second one Android keeps entirely with the user — a card posted as
  /// `VISIBILITY_PUBLIC` into a phone that has it off still shows only in the
  /// shade, which reads as the card being broken rather than hidden. The app
  /// cannot flip it, but it can name it: this is what the Settings row shows,
  /// and [openNotificationSettings] is the row's tap.
  static Future<({bool notificationsEnabled, bool onLockScreen})>
      lockScreenStatus() async {
    final Object? raw = await _call('lockScreenStatus');
    if (raw is! Map) {
      // No native side (iOS, desktop, web): nothing to report and nothing
      // broken — the card exists only on the Kotlin side anyway.
      return (notificationsEnabled: true, onLockScreen: true);
    }
    return (
      notificationsEnabled: raw['notificationsEnabled'] == true,
      onLockScreen: raw['lockScreenNotifications'] == true,
    );
  }

  /// Opens this app's notification settings page — where every phone keeps
  /// the lock-screen switch, under whatever name its maker gave it.
  static Future<void> openNotificationSettings() =>
      _call('openNotificationSettings');

  /// Opens the system "Alarms & reminders" screen for this app. Returns once
  /// the user comes back, so callers can re-check.
  static Future<void> requestExactAlarm() => _call('requestExactAlarm');

  /// Asks to be excluded from battery optimisation. Doze delays the
  /// notification and would otherwise let a 1-minute test silently miss.
  static Future<void> requestNoBatteryOptimisation() =>
      _call('requestNoBatteryOptimisation');

  /// Whether the playback notification may raise the recitation screen.
  ///
  /// That screen is the whole of the volume-key fix with the phone locked: a
  /// key event reaches the focused window and nothing else, so without it the
  /// rocker has nothing to land on and an Azaan on the alarm stream — the one
  /// stream Android refuses to silence — plays out unattended. Android 14
  /// made this a switch the user has to throw, so it is asked for like any
  /// other permission. `false` also means "not applicable" (pre-14), where
  /// declaring it in the manifest is enough.
  static Future<bool> canUseFullScreenIntent() async =>
      await _call('canUseFullScreenIntent') == true;

  /// Opens the system screen for that switch, so the caller can re-check when
  /// the user comes back.
  static Future<void> requestFullScreenIntent() => _call('requestFullScreenIntent');

  /// Whether this app may put a window up while it is in the background.
  ///
  /// The platform side asks **two** switches for this, and takes either:
  ///
  ///  * the AOSP overlay permission (`SYSTEM_ALERT_WINDOW`), which
  ///    `Settings.canDrawOverlays()` reads; and
  ///  * MIUI's private op 10021, which the Settings app labels *"Display
  ///    pop-up windows while running in the background"* — a separate toggle,
  ///    and the one the warning in `main.dart` actually names.
  ///
  /// They used to be read as one, with only the first consulted, which is how
  /// the warning stayed on for a user who had already allowed the setting it
  /// asked for: the message pointed at a switch the code never read. Either
  /// open is enough to let a background launch through on its own device, so
  /// either answer turns the warning off.
  static Future<bool> canDrawOverlays() async =>
      await _call('canDrawOverlays') == true;

  /// Opens the system screen holding that switch, so the caller can re-check
  /// when the user comes back. On MIUI that is SecurityCenter's own permission
  /// editor — where the pop-up toggle lives — and the AOSP overlay page
  /// everywhere else.
  static Future<void> requestOverlayPermission() => _call('requestOverlay');

  /// Whether this phone is one that refuses a background service *any* window
  /// unless that overlay permission is on.
  ///
  /// MIUI is the archetypal case — it rejects the request at the exact second
  /// an alarm fires, in `appops`, with the recitation already sounding and
  /// the app never told. Knowing it is a Xiaomi-family device is what lets the
  /// app name the setting instead of guessing.
  static Future<bool> needsOverlayPermission() async =>
      await _call('deviceNeedsOverlay') == true;
}
