import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/main.dart' as app;

/// One prayer must arrive as one notification — in every state the Home bell
/// can be left in, Mute included.
///
/// The Dart-side banner and the Kotlin-side card used to take turns at it,
/// and which one spoke depended on how far before the prayer the reader had
/// set the reminder: with an advance notice both were armed — "Maghrib in 5
/// minutes" behind the recitation's "Azaan playing" — and with no notice at
/// all only the recitation was, so a phone on vibrate declined the clip and
/// left nothing. Two cards, or none, out of one rule that was only ever
/// asking one question.
///
/// That question is now answered by where the phone is, not by what the bell
/// carries: on Android `AzaanAlarmReceiver` posts the card for every armed
/// bell, and the Dart banner stands down so there is exactly one owner. It
/// used to stand down only for a bell carrying a clip, which left **Mute**
/// as the one state routed through `flutter_local_notifications` and its
/// exact-alarm grant — the reader's words for which were "Mute switches the
/// whole thing off", on the same phone where an Azaan bell still arrived.
///
/// These tests pin both halves of that boundary.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final AzanSound silent = azanSoundByKey('silent');

  group('the receiver card is the notification on Android when…', () {
    test('the bell carries a clip — the recitation card', () {
      // The default: `_notifyOffsets` starts every prayer at -1 ("at the
      // prayer time") and the default sound is "Makkah Full Azaan". The
      // offset used to be part of this answer, which is what put two cards
      // in the shade for a reader who had set "5 min before": the banner
      // left at T−5 and the clip at T. The clip now leaves from `fire`
      // like the banner does, so there is only ever one moment to speak at
      // — and the receiver posts for it either way.
      expect(app.NotificationService.receiverOwnsTheCard(android: true), isTrue);
    });

    test('the bell is on Mute — the reported bug: a card, no sound', () {
      // Mute keeps the card and drops the recitation, and the card is now
      // the receiver's like every other armed bell: an alarm armed through
      // `setAlarmClock`, which no permission can be taken back from.
      //
      // `androidRaw` stays null for the silent sound, which is what keeps a
      // clip out of the alarm — the receiver posts the card and returns
      // before anything plays.
      expect(silent.androidRaw, isNull);
      expect(app.NotificationService.receiverOwnsTheCard(android: true), isTrue);
    });

    test('armed with the silent sentinel, the receiver plays nothing', () {
      // The word `AzaanAlarmReceiver` branches on is the key the silent
      // sound itself is stored under, so "muted bell" and "profile asked
      // for no sound" cannot drift apart into two answers.
      expect(silent.key, 'silent');
    });
  });

  group('the banner is still armed because…', () {
    test('off Android there is no Kotlin player to post a card', () {
      // iOS keeps the clip in the banner itself; the desktop has neither.
      expect(
        app.NotificationService.receiverOwnsTheCard(android: false),
        isFalse,
      );
    });
  });
}
