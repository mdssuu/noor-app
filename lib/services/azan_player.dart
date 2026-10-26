import 'dart:async';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../app_settings.dart';
import 'azaan_alarm.dart';

/// Plays the Azan clip selected in Settings.
///
/// Two entry points:
///   * `preview(key)`  — tapping a ringtone row in Settings or the "Test
///     Azaan" button, stops on a second tap so the user can silence it.
///   * `playSelected()` — fired when the user taps an Azan reminder
///     notification while the app is in the foreground.
///
/// Playback goes through the **native alarm-stream player** first, so what the
/// preview plays is byte-for-byte what the reminder plays, at the same volume.
/// It does *not* play over a phone its reader has put on silent or vibrate —
/// the alarm stream would allow it, and declining anyway is the whole of what
/// "silent means silent" costs. `audioplayers` is only the fallback for
/// platforms with no native bundle (desktop, web, tests) — which is also why
/// each [AzanSound] still carries a remote [AzanSound.url].
class AzanPlayer {
  AzanPlayer._() {
    install();
  }

  static final AzanPlayer instance = AzanPlayer._();

  /// Puts this player's callbacks where a stop pressed *anywhere* can reach a
  /// clip this side holds — a volume key taken over by the platform side, or
  /// the recitation screen the alarm raises over the lock screen.
  ///
  /// Playback has two homes: the native alarm-stream player and this fallback
  /// one, which is what runs where the native player does not. A stop that
  /// reaches only the first leaves the second sounding, which is one way "the
  /// volume button does nothing" came about.
  void install() {
    AzaanAlarm.onPlaybackFinished = () => _setPlaying(null);
    AzaanAlarm.onStopRequested = () => unawaited(stop());
  }

  final AudioPlayer _player = AudioPlayer();
  String? _playingKey;

  /// Lets a listening screen re-render when a clip starts or ends — the row
  /// highlight and the "Test Azaan" button both depend on it.
  ///
  /// A *set* of listeners, not a single slot. Screens used to overwrite each
  /// other's callback, so whichever opened second simply stopped repainting:
  /// its row would keep showing a clip as playing long after it had ended,
  /// and its stop button would do nothing visible.
  final Set<VoidCallback> _listeners = <VoidCallback>{};

  void addListener(VoidCallback listener) => _listeners.add(listener);

  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void _setPlaying(String? key) {
    if (_playingKey == key) return;
    _playingKey = key;
    for (final VoidCallback listener in _listeners.toList()) {
      listener();
    }
  }

  bool get isPlaying => _playingKey != null;

  /// Which row is currently audibly previewing, or `null`.
  String? get playingKey => _playingKey;

  static AzanSound? _sound(String key) {
    for (final AzanSound s in kAzanSounds) {
      if (s.key == key) return s;
    }
    return null;
  }

  /// Tapping the row that is already playing stops it; anything else stops
  /// the current clip and starts the new one.
  ///
  /// A preview always has something to play — except when the phone is
  /// silenced, and then it has nothing to play *and says so*. That is what
  /// the `bool` is for: `false` means "declined, not broken", so the button
  /// that used to look wired to nothing can explain itself instead of
  /// staying quiet without a word.
  ///
  /// The rest of the promise stands. "None (silent)" is the one row with no
  /// clip of its own, and answering "nothing" to every question a reader
  /// asks of it — the row's play icon, the "Test Azaan" button — is what
  /// made that button look broken: it did not fail, it *declined*. So the
  /// built-in clip stands in here, the same substitution [_bellSound]
  /// makes for a bell left on azan under a silent profile. What the reminder
  /// itself does with that profile is a separate question, answered by
  /// [playSelected] and by the scheduler — not by a button whose whole job is
  /// to be heard.
  Future<bool> preview(String key) async {
    if (_playingKey == key) {
      await stop();
      return true;
    }
    await stop();
    return _start(key, builtInFallback: true);
  }

  /// Replays the clip behind a reminder the reader tapped.
  ///
  /// Never with the built-in stand-in: a banner tapped on a silent profile is
  /// a reminder that deliberately recited nothing, and answering it with an
  /// Azan would invent noise the reader asked not to have. Silence is the
  /// honest reply there — it is only the *test* that owes an answer.
  Future<bool> playSelected() =>
      _start(AppSettings.instance.azanSound, builtInFallback: false);

  Future<bool> _start(String key, {required bool builtInFallback}) async {
    final AzanSound? chosen = _sound(key);
    if (chosen == null) return false;

    // Silence is the reader's, and it is asked before a single byte is
    // fetched. The native player asks the same question and would answer
    // `false`, but `false` is the wrong answer *here*: step 1 falls through
    // to step 2, the remote copy would be downloaded, and the row would light
    // up over a clip this phone is never going to let anyone hear. Asking
    // first is also what gives [preview] a reason it can show.
    final String ringer = await AzaanAlarm.ringerMode();
    if (ringer != 'normal') {
      debugPrint('Noor ▸ azan "$key" declined — ringer mode is $ringer');
      _setPlaying(null);
      return false;
    }

    if (key == 'silent' && !builtInFallback) return false;
    final AzanSound sound =
        key == 'silent' ? (_sound('makkah') ?? chosen) : chosen;

    // 1. The bundled clip on the alarm stream — the same file the notification
    //    channel carries, so a preview is an honest test of the reminder.
    if (sound.androidRaw != null && await AzaanAlarm.playNow(sound.androidRaw!)) {
      _setPlaying(key);
      return true;
    }

    // 2. No native player on this platform — or a native player that has just
    //    said it has nothing: remote clip, or a synthesised beep that needs
    //    neither a bundle nor a network.
    try {
      if (sound.url != null) {
        // A remote clip is the *second* chance, not the listener: a dead or
        // unreachable link must not leave "Test Azaan" spinning for thirty
        // seconds with nothing to show for it. Eight seconds is longer than
        // any honest start and short enough that the row still feels alive.
        await _player
            .play(UrlSource(sound.url!), volume: 1.0)
            .timeout(const Duration(seconds: 8));
      } else if (!sound.hasBundle) {
        await _player.play(BytesSource(_beepWav()), volume: 1.0);
      } else {
        debugPrint('Noor ▸ azan preview unavailable on this platform: $key');
        return false;
      }
    } catch (error) {
      debugPrint('Noor ▸ azan preview failed: $error');
      if (!builtInFallback) {
        _setPlaying(null);
        return false;
      }
      // The test owes an answer even when both clips are out of reach: the
      // beep is not the Azaan, but it is proof the button is wired to
      // something — silence is what made this row look broken in the first
      // place.
      debugPrint('Noor ▸ azan preview standing in with the beep for $key');
      try {
        await _player.play(BytesSource(_beepWav()), volume: 1.0);
      } catch (beepError) {
        debugPrint('Noor ▸ azan preview beep failed: $beepError');
        _setPlaying(null);
        return false;
      }
    }
    _setPlaying(key);
    _player.onPlayerComplete.first.then((_) {
      if (_playingKey == key) _setPlaying(null);
    });
    return true;
  }

  Future<void> stop() async {
    _setPlaying(null);
    await AzaanAlarm.stop();
    try {
      await _player.stop();
    } catch (_) {}
  }

  /// 16-bit mono 8 kHz WAV: two short 880 Hz beeps with a fade, ~0.5 s.
  /// Only reached where there is no native player at all.
  static Uint8List _beepWav() {
    const int sampleRate = 8000;
    const double seconds = 0.55;
    final int samples = (sampleRate * seconds).round();
    const double frequency = 880;
    const int amplitude = 12000;

    final ByteData bytes = ByteData(44 + samples * 2);

    void ascii(int offset, String value) {
      for (int i = 0; i < value.length; i++) {
        bytes.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    bytes.setUint32(4, 36 + samples * 2, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little); // PCM
    bytes.setUint16(22, 1, Endian.little); // mono
    bytes.setUint32(24, sampleRate, Endian.little);
    bytes.setUint32(28, sampleRate * 2, Endian.little);
    bytes.setUint16(32, 2, Endian.little);
    bytes.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    bytes.setUint32(40, samples * 2, Endian.little);

    for (int i = 0; i < samples; i++) {
      final double t = i / sampleRate;
      // Two beeps separated by a 120 ms gap.
      final bool on = (t < 0.2) || (t > 0.32 && t < 0.52);
      final double envelope = on ? math.min(1.0, (t % 0.32) * 20) : 0.0;
      final int value =
          (math.sin(2 * math.pi * frequency * t) * amplitude * envelope).round();
      bytes.setInt16(44 + i * 2, value, Endian.little);
    }

    return bytes.buffer.asUint8List();
  }
}
