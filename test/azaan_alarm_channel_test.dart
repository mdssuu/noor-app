import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/main.dart' as app;
import 'package:noor_masjid_time/services/azaan_alarm.dart';

/// Guards the `noor_masjid_time/azaan` wire contract with `MainActivity.kt`.
///
/// `cancelRange` is the call that retires a whole id block: the favourite
/// masjids on every rebuild, and the calculated reminders on every
/// `cancelAzan()`. Its Kotlin side reads `from` and `to` — it once read
/// `until`, answered `bad-args` on every call, and `AzaanAlarm._call` turned
/// that into a debugPrint nobody reads. Nothing was ever cancelled, so a
/// masjid the user had already un-starred kept reciting from the alarm
/// stream while its notification was quietly gone.
///
/// Neither side can now drift alone: this pins the keys Dart sends, and the
/// comment in `MainActivity.kt` pins the ones Kotlin reads.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('noor_masjid_time/azaan');
  final List<MethodCall> calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('cancelRange sends the two names the native side reads', () async {
    // The favourite-masjid pass clears exactly this block on every rebuild.
    await AzaanAlarm.cancelRange(1000, 1000000000);

    expect(calls.single.method, 'cancelRange');
    expect(
      calls.single.arguments,
      <String, Object?>{'from': 1000, 'to': 1000000000},
      reason: 'Kotlin reads "from" and "to" — a third spelling cancels nothing',
    );
  });

  test('cancel names the id, which is how a single masjid retires', () async {
    await AzaanAlarm.cancel(1013);

    expect(calls.single.method, 'cancel');
    expect(calls.single.arguments, <String, Object?>{'id': 1013});
  });

  test('the test-reminder id sits outside the block a rebuild clears', () {
    // `_rebuildFavouriteAlerts` cancels `[1000, 1000000000)` wholesale on
    // every reschedule. The "Send test reminder" probe used to live at
    // 791900 — inside that range — so its second notification, the closed-app
    // one that is the whole point of the button, was armed and then cancelled
    // a moment later by an unrelated favourite rebuild. To the user that is
    // indistinguishable from an alarm that simply never fired.
    const int floor = 1000;
    const int ceiling = 1000000000;

    expect(
      app.NotificationService.testReminderId < floor ||
          app.NotificationService.testReminderId >= ceiling,
      isTrue,
      reason: 'ids inside [1000, 1000000000) are cancelled on every '
          'favourite rebuild, which silently kills the closed-app test',
    );

    expect(
      app.NotificationService.testReminderId,
      lessThan(DateTime.now().millisecondsSinceEpoch ~/ 1000),
      reason: '`show()` allocates epoch-second ids — the probe must stay '
          'clear of them too',
    );
  });

  test('a native error never escapes into the scheduler', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      throw PlatformException(code: 'bad-args', message: 'from and to are required');
    });

    // `_rebuildFavouriteAlerts` must keep scheduling whatever is still
    // starred even when the platform side rejects the clear-down.
    await expectLater(AzaanAlarm.cancelRange(1000, 1000000000), completes);
    await expectLater(AzaanAlarm.cancel(1013), completes);
  });

  test('the overlay warning reads both switches under one name', () async {
    // The recitation screen has two routes to a window and the platform side
    // folds both into a single answer: the AOSP overlay op AND MIUI's private
    // op 10021, which is the one the warning in main.dart actually names. It
    // used to read only the first, so the message stayed on for a user who had
    // already allowed the setting it asked for — and a renamed key anywhere in
    // this path hands back null, which reads as "denied", which is the exact
    // false warning this guards.
    await AzaanAlarm.canDrawOverlays();
    await AzaanAlarm.needsOverlayPermission();
    await AzaanAlarm.requestOverlayPermission();

    expect(
      calls.map((MethodCall call) => call.method).toList(),
      <String>['canDrawOverlays', 'deviceNeedsOverlay', 'requestOverlay'],
      reason: 'MainActivity.kt answers exactly these three keys',
    );
  });
}
