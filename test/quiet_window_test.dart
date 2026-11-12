import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';

/// Two answers the reader gave separately, and the two things that went
/// wrong with them.
///
///  * **"I stopped the Azaan with the volume button and the phone never went
///    quiet."** Every road that ends a recitation has to reach the playback
///    service's `finish()`, because that is the only place that knows a
///    recitation is over — and only there may the ringer be switched. The
///    volume watcher used to tear the player down and stop there: no
///    retirement, no card handed back, and no quiet window.
///  * **"I turned the Azaan off but left the silence on — my phone should
///    still go quiet at my masjid's Jamaat time."** Silence is a choice
///    about the *ringer*, asked separately from the reminder, so it arms
///    even when `notificationsEnabled` says no: a quiet-only alarm that
///    opens the window and posts nothing.
///
/// Home and Settings cannot be pumped here (Firebase, platform channels), so
/// the wiring is pinned where it lives — the same rule every test in this
/// folder follows.
void main() {
  const String kotlin = 'android/app/src/main/kotlin/com/sunesra_app/';
  TestWidgetsFlutterBinding.ensureInitialized();

  final String audio = File('${kotlin}AzaanAudio.kt').readAsStringSync();
  final String service =
      File('${kotlin}AzaanPlaybackService.kt').readAsStringSync();
  final String receiver =
      File('${kotlin}AzaanAlarmReceiver.kt').readAsStringSync();
  final String mainDart = File('lib/main.dart').readAsStringSync();
  final String screen =
      File('lib/screens/settings_screen.dart').readAsStringSync();

  group('a stop is an end too', () {
    test('the player hands its end to whoever asked for it', () {
      expect(
        audio,
        contains('private var endOfRun: (() -> Unit)? = null'),
        reason: 'without a field the stop path has nowhere to put the '
            'callback the service passed to play()',
      );
      expect(
        audio,
        contains('fun stop() = stopLocked(notifyEnd = true)'),
        reason: 'the reader pressing a volume key is asking for the end of '
            'the run, not just for silence',
      );
      expect(
        audio,
        contains('stopLocked(notifyEnd = false)'),
        reason: 'and play() replacing an earlier clip must not announce that '
            'end — it would retire the service about to take the new one',
      );
      expect(
        audio.indexOf('endOfRun = onStopped'),
        lessThan(audio.indexOf('mp.start()')),
        reason: 'the callback has to be filed while the run is still '
            'knowable, before the clip can end under it',
      );
    });

    test('the teardown announces the end, once, after the player is down', () {
      final int stop = audio.indexOf('private fun stopLocked(notifyEnd: Boolean)');
      expect(stop, greaterThan(-1));
      final String body = audio.substring(stop, audio.indexOf('\n    }', stop));

      expect(body, contains('ended?.invoke()'),
          reason: 'this is the whole fix: a stop that never told the service '
              'left the quiet window unopened');
      expect(body, contains('notifyEnded()'),
          reason: 'and the recitation screen closes on the same stop');
      expect(
        body.indexOf('ended?.invoke()'),
        greaterThan(body.indexOf('recitation stopped (player torn down)')),
        reason: 'the window belongs to a clip that was actually on the '
            'field — announce it only after the player is down',
      );
      expect(
        body,
        contains('if (!notifyEnd || old == null) return'),
        reason: 'a stop against silence must not retire a service that '
            'never recited',
      );
    });

    test('the natural end takes the same callback, so it cannot fire twice', () {
      final int completions = 'val ended = takeEndOfRun()'.allMatches(audio).length;
      expect(completions, 2,
          reason: 'the completion listener and the error listener are both '
              'ends — each takes the callback rather than reading it');
      expect(
        audio,
        contains('private fun takeEndOfRun(): (() -> Unit)?'),
        reason: 'taken, not read: one end, one window',
      );
    });

    test('the service behind that callback is the one that opens the window', () {
      expect(
        service,
        contains('val playing = AzaanAudio.play(this, sound) { finish() }'),
        reason: 'the stop path lands on exactly the finish() that guards '
            'with `recited` and opens the quiet window',
      );
      expect(service, contains('if (recited && silentMinutes > 0)'));
    });
  });

  group('silence while the Azaan is off', () {
    test('a word of its own for an alarm that wants only the window', () {
      expect(
        mainDart,
        contains("static const String _quietRaw = 'quiet';"),
        reason: 'the receiver must be able to tell "post the card, play '
            'nothing" (silent) from "post nothing at all" (quiet)',
      );
      expect(
        receiver,
        contains('const val SOUND_QUIET = "quiet"'),
        reason: 'and both ends must spell it the same way — a different '
            'string is read as a file name and falls through to a recitation',
      );
      expect(
        receiver.indexOf('if (sound == SOUND_QUIET)'),
        lessThan(receiver.indexOf('if (sound == "silent")')),
        reason: 'asked before the muted-bell branch, which is a different '
            'promise: that one still wants its card',
      );
      expect(
        receiver,
        contains('if (silentMinutes > 0 && AzaanAudio.ringerAllowsRecitation(context))'),
        reason: 'a phone already on vibrate has nothing to take away, and '
            'filing it as the mode to restore would hand back a mode the '
            'reader never had',
      );
      expect(
        receiver.indexOf('RingerSilence.engage(context, silentMinutes)'),
        greaterThan(receiver.indexOf('if (sound == SOUND_QUIET)')),
        reason: 'the quiet branch is the one road that silences with no '
            'recitation behind it — it must reach engage itself',
      );
      // Nothing at all is posted on that road.
      final int quiet = receiver.indexOf('if (sound == SOUND_QUIET)');
      final int after = receiver.indexOf('return', quiet);
      final String branch = receiver.substring(quiet, after);
      expect(branch, isNot(contains('PrayerCard.show')),
          reason: 'the master switch is off — a posted reminder would '
              'contradict the setting that armed this instead');
    });

    test('the favourite pass arms a window even with the Azaan off', () {
      expect(
        mainDart,
        contains('final bool armsQuiet ='),
        reason: 'the pass has to know it is arming silence rather than a '
            'recitation',
      );
      expect(
        mainDart,
        contains('!settings.notificationsEnabled && settings.autoSilentMinutes > 0'),
        reason: 'both halves are the reader\'s own: the Azaan off and the '
            'silence on — either alone arms nothing',
      );
      expect(
        mainDart,
        contains('if (!armsJamaat && !armsQuiet) return;'),
        reason: 'returning on !armsJamaat alone cleared the range and '
            'scheduled nothing, which is the whole of the complaint',
      );
      expect(
        mainDart,
        contains('chosenRings = (armsJamaat || armsQuiet) &&'),
        reason: 'the chosen masjid has to be resolved for the quiet pass '
            'too, or there is no board to read a Jamaat time from',
      );
      expect(
        mainDart,
        contains('raw: armsJamaat ? _bellRaw(key, entry.masjidId) : _quietRaw,'),
        reason: 'the Azaan on keeps its clip; the Azaan off gets the quiet '
            'word — one loop, two promises',
      );
      expect(
        mainDart,
        contains('if (armsJamaat && !settings.schedulesJamaatFor(key)) continue;'),
        reason: '"When will the Azaan play?" is one of the azaan settings '
            'this window is meant to outlive — the default of "Only at '
            'Awwal time" must not silence the masjid\'s own instant',
      );
      expect(
        mainDart,
        isNot(contains('if (!armsJamaat) return;')),
        reason: 'the old gate, on its own, is the bug',
      );
    });

    test('the quiet pass posts no banner of its own', () {
      expect(
        mainDart,
        contains('if (armsJamaat && receiverOwnsTheCard())'),
        reason: 'the card rule is unchanged where there is a card to speak '
            'for — and does not run at all where there is not',
      );
      expect(
        mainDart,
        contains('} else if (armsJamaat) {'),
        reason: 'the banner branch is behind the same guard, so a reader '
            'who switched the Azaan off is not handed a reminder instead',
      );
    });

    test('the row that sets it is visible with the Azaan off', () {
      expect(
        screen,
        isNot(contains('if (_settings.notificationsEnabled) ...<Widget>[')),
        reason: 'the silence row used to live inside the Azaan guard, so a '
            'reader who turned the Azaan off could neither see nor change '
            'the answer they had already given',
      );
      expect(
        screen,
        contains('_hint(_settings.notificationsEnabled'),
        reason: 'the row explains itself either way — and says plainly what '
            'happens when there is no Azaan to follow',
      );
      expect(
        screen,
        contains('With the Azaan off, your phone still goes on vibrate'),
      );
      for (final int minutes in kAutoSilentOptions) {
        final String call = minutes == kAutoSilentOff
            ? '_silentOption(kAutoSilentOff)'
            : '_silentOption($minutes)';
        expect(screen, contains(call));
      }
    });

    test('turning the switch off re-arms the favourites, not just the Azaan',
        () {
      final int reschedule = screen.indexOf('Future<void> _reschedule() async {');
      expect(reschedule, greaterThan(-1));
      final String body = screen.substring(reschedule, reschedule + 700);

      expect(body, contains('NotificationService.scheduleAzan('));
      expect(body, contains('NotificationService.scheduleFavouriteAlerts()'),
          reason: 'the quiet window lives on the favourite pass — a '
              '_reschedule that only re-armed the Azaan would leave the '
              'setting doing nothing');
      expect(
        screen,
        contains('Timer(const Duration(milliseconds: 500), _reschedule)'),
        reason: 'and it has to be reached: the debounce is what carries the '
            'switch the reader just flipped',
      );
    });
  });
}
