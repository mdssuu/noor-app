import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/main.dart' as app;

/// One prayer must arrive as one notification.
///
/// The Dart-side banner and the Kotlin-side card used to take turns at it,
/// and which one spoke depended on how far before the prayer the reader had
/// set the reminder: with an advance notice both were armed — "Maghrib in 5
/// minutes" behind the recitation's "Azaan playing" — and with no notice at
/// all only the recitation was, so a phone on vibrate declined the clip and
/// left nothing. Two cards, or none, out of one rule that was only ever
/// asking one question.
///
/// The question is answered once now: does this prayer's bell carry a clip?
/// If it does, `AzaanAlarmReceiver` owns the card — it posts it when the
/// alarm fires whether or not the recitation is allowed to sound, and posts
/// it again when the clip ends. If it does not, the banner is the only voice
/// there is and it must speak.
///
/// These tests pin both halves of that boundary.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final AzanSound clip = azanSoundByKey('makkah');
  final AzanSound silent = azanSoundByKey('silent');

  group('the recitation card is the notification when…', () {
    test('the bell carries a clip — the reported bug', () {
      // The default: `_notifyOffsets` starts every prayer at -1 ("at the
      // prayer time") and the default sound is "Makkah Full Azaan". The
      // offset used to be part of this answer, which is what put two cards
      // in the shade for a reader who had set "5 min before": the banner
      // left at T−5 and the clip at T. The clip now leaves from `fire`
      // like the banner does, so there is only ever one moment to speak at
      // — and the receiver posts for it either way.
      expect(app.NotificationService.recitationIsTheCard(clip, android: true), isTrue);
    });
  });

  group('the banner is still armed because…', () {
    test('a bell on "None (silent)" has no card to speak for it', () {
      // No `androidRaw` means no recitation arms at all — the banner is
      // the only thing that will ever appear, so it must.
      expect(silent.androidRaw, isNull);
      expect(
        app.NotificationService.recitationIsTheCard(silent, android: true),
        isFalse,
      );
    });

    test('off Android there is no Kotlin player to post a card', () {
      // iOS keeps the clip in the banner itself; the desktop has neither.
      expect(
        app.NotificationService.recitationIsTheCard(clip, android: false),
        isFalse,
      );
    });
  });
}
