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
/// preview plays is byte-for-byte what the reminder plays, at the same volume,
/// and it is audible with the ringer off. `audioplayers` is only the fallback
/// for platforms with no native bundle (desktop, web, tests) — which is also
/// why each [AzanSound] still carries a remote [AzanSound.url].
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
  Future<void> preview(String key) async {
    if (_playingKey == key) {
      await stop();
      return;
    }
    await stop();
    await _start(key);
  }

  Future<void> playSelected() => _start(AppSettings.instance.azanSound);

  Future<void> _start(String key) async {
    final AzanSound? sound = _sound(key);
    if (sound == null || key == 'silent') return;

    // 1. The bundled clip on the alarm stream — the same file the notification
    //    channel carries, so a preview is an honest test of the reminder.
    if (sound.androidRaw != null && await AzaanAlarm.playNow(sound.androidRaw!)) {
      _setPlaying(key);
      return;
    }

    // 2. No native player on this platform: remote clip, or a synthesised beep
    //    that needs neither a bundle nor a network.
    try {
      if (sound.url != null) {
        await _player.play(UrlSource(sound.url!), volume: 1.0);
      } else if (!sound.hasBundle) {
        await _player.play(BytesSource(_beepWav()), volume: 1.0);
      } else {
        debugPrint('Noor ▸ azan preview unavailable on this platform: $key');
        return;
      }
      _setPlaying(key);
      _player.onPlayerComplete.first.then((_) {
        if (_playingKey == key) _setPlaying(null);
      });
    } catch (error) {
      debugPrint('Noor ▸ azan preview failed: $error');
      _setPlaying(null);
    }
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
