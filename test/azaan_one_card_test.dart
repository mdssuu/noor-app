import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/main.dart' as app;

/// One prayer must arrive as one notification.
///
/// With no advance notice the reminder banner lands on the prayer time
/// itself — the same minute the alarm-stream player rises with its
/// "Azaan playing" card — and the reader saw two cards for one prayer:
/// "It is time for Fajr" and, behind it, the recitation. Both cannot stay:
/// the playback card is not optional (a foreground service may not run
/// without one, and it carries the only STOP AZAN handle a locked phone
/// has), so the banner is what stands down, and only where the card is
/// genuinely going to speak.
///
/// These tests pin that boundary — when the banner is held back, and the
/// three cases where it must still be armed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final AzanSound clip = azanSoundByKey('makkah');
  final AzanSound silent = azanSoundByKey('silent');

  group('the recitation card is the notification when…', () {
    test('the bell carries a clip and has no notice to give — the reported bug', () {
      // The default: `_notifyOffsets` starts every prayer at -1 ("at the
      // prayer time"), and the default sound is "Makkah Full Azaan".
      expect(app.NotificationService.recitationIsTheCard(clip, -1, android: true), isTrue);
      expect(app.NotificationService.recitationIsTheCard(clip, 0, android: true), isTrue);
    });

    test('the reader opted the prayer in with no notice set', () {
      // Favourite-masjid alerts arrive with `minutesBefore == 0` unless the
      // reader picked an offset — same instant, same single card.
      expect(app.NotificationService.recitationIsTheCard(clip, 0, android: true), isTrue);
    });
  });

  group('the banner is still armed because…', () {
    test('an advance notice is its own event, minutes before the clip', () {
      // "Fajr in 10 minutes" fires at T−10 and the recitation at T: two
      // instants, so the two never collide into a duplicate.
      expect(
        app.NotificationService.recitationIsTheCard(clip, 10, android: true),
        isFalse,
      );
    });

    test('a bell on "None (silent)" has no card to speak for it', () {
      // No `androidRaw` means no recitation arms at all — the banner is
      // the only thing that will ever appear, so it must.
      expect(silent.androidRaw, isNull);
      expect(
        app.NotificationService.recitationIsTheCard(silent, 0, android: true),
        isFalse,
      );
    });

    test('off Android there is no Kotlin player to post a card', () {
      // iOS keeps the clip in the banner itself; the desktop has neither.
      expect(
        app.NotificationService.recitationIsTheCard(clip, 0, android: false),
        isFalse,
      );
    });
  });
}
