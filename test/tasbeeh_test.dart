import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/services/tasbeeh.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<Tasbeeh> fresh() async {
    final Tasbeeh t = Tasbeeh.test();
    await t.load();
    return t;
  }

  group('counting', () {
    test('a bead lands on today and on the lifetime total', () async {
      final Tasbeeh t = await fresh();
      expect(t.tap(), isFalse); // not a round yet
      expect(t.todayOf('subhanallah'), 1);
      expect(t.totalOf('subhanallah'), 1);
    });

    test('the thirty-third bead completes a round', () async {
      final Tasbeeh t = await fresh();
      bool buzzed = false;
      for (int i = 0; i < 33; i++) {
        buzzed = t.tap();
      }
      expect(buzzed, isTrue, reason: 'the 33rd bead is the round');
      expect(t.roundsToday, 1);
      expect(t.inRound, 0, reason: 'the next round starts fresh');

      expect(t.tap(), isFalse);
      expect(t.inRound, 1);
      expect(t.roundsToday, 1);
    });

    test('a dhikr without a 33-round counts toward ninety-nine', () async {
      final Tasbeeh t = await fresh();
      t.select('istighfar');
      expect(t.roundOf, 99);
      for (int i = 0; i < 99; i++) {
        expect(t.tap(), i == 98, reason: 'only the 99th completes');
      }
    });

    test('switching dhikr keeps each count its own', () async {
      final Tasbeeh t = await fresh();
      t.tap();
      t.tap();
      t.select('alhamdulillah');
      expect(t.todayOf('alhamdulillah'), 0);
      t.tap();
      expect(t.totalOf('subhanallah'), 2);
      expect(t.totalOf('alhamdulillah'), 1);
      expect(t.selectedKey, 'alhamdulillah');
    });

    test('an unknown dhikr is ignored rather than selected', () async {
      final Tasbeeh t = await fresh();
      t.select('bismillah-not-in-the-list');
      expect(t.selectedKey, 'subhanallah');
    });
  });

  group('reset', () {
    test('clears today and spares the lifetime', () async {
      final Tasbeeh t = await fresh();
      for (int i = 0; i < 40; i++) {
        t.tap();
      }
      t.reset();
      expect(t.todayOf('subhanallah'), 0);
      expect(t.inRound, 0);
      expect(t.totalOf('subhanallah'), 40, reason: 'every bead ever counted');
    });
  });

  group('memory', () {
    test('totals survive a reload, today included', () async {
      final Tasbeeh t = await fresh();
      for (int i = 0; i < 35; i++) {
        t.tap();
      }
      t.select('istighfar');
      t.tap();

      // Wait for the fire-and-forget writes to settle: `tap` persists
      // without awaiting, which is right on a bead counter (no tap should
      // wait on disk) and needs one quiet moment here.
      await Future<void>.delayed(Duration.zero);

      final Tasbeeh reloaded = await fresh();
      expect(reloaded.totalOf('subhanallah'), 35);
      expect(reloaded.todayOf('subhanallah'), 35);
      expect(reloaded.selectedKey, 'istighfar');
      expect(reloaded.totalOf('istighfar'), 1);
    });
  });

  group('the offered set', () {
    test('carries the classic three and their order', () {
      expect(kDhikr.first.key, 'subhanallah');
      expect(kDhikr.map((Dhikr d) => d.key),
          containsAll(<String>['alhamdulillah', 'allahuakbar']));
      expect(dhikrByKey('allahuakbar').label, 'Allahu Akbar');
      expect(dhikrByKey('unknown').key, kDhikr.first.key);
    });
  });
}
