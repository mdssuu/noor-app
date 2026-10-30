import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/main.dart' show buildNoorTheme;
import 'package:noor_masjid_time/screens/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One answer per question — the reader's own words: "settings se wo cheeze
/// hata de jo home me already hai kyu ke double double hojata hai".
///
/// The per-prayer rows this screen used to carry — a switch and two rows of
/// chips for each of the five — answered exactly what the bell at the end of
/// every prayer's row on Home answers: Azaan, Mute or Band, and how many
/// minutes before. Two doors to one choice is the "double" that was named,
/// so the rows are gone.
///
/// What stays is what Home does *not* ask: the master gate, the mode that
/// says which clock (Awwal, the masjid's Jamaat, both) may ring at all, and
/// the clip list under "Azan sound" — the bell dialog itself points there,
/// because the clip is one voice for every prayer and a per-prayer door for
/// it would promise a choice no per-prayer alarm can keep.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpSettings(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: buildNoorTheme(),
      home: const SettingsScreen(),
    ));
    await tester.pump();
  }

  testWidgets('the per-prayer rows are gone, and the screen says where '
      'they went', (WidgetTester tester) async {
    await pumpSettings(tester);

    // Both halves of the old block, absent: the switch row, and the
    // "second source" chips whose every tap landed where the bell dialog's
    // own chips land.
    expect(find.text('At my favourite masjid'), findsNothing,
        reason: 'the source rows moved into the bell dialog, where the '
            'prayer they configure is already named on the title');
    expect(find.text('At Jamaat time'), findsNothing,
        reason: 'and its chips with it');

    // What stays is every prayer's own answer — the gate and the mode.
    expect(find.text('Enable Azan notifications'), findsOneWidget);
    expect(find.text('When will the Azaan play?'), findsOneWidget,
        reason: 'no bell on Home can say which *source* may ring — that '
            'question is the same for every prayer, which is this '
            'screen’s own business');

    // And the screen points at the door that took the rows' place, or a
    // removed control with no forwarding address is a reader hunting for
    // a switch that no longer exists.
    expect(
      find.textContaining('bell at the end of each prayer'),
      findsOneWidget,
      reason: 'the forwarding address, in the section the rows left',
    );

    await tester.pumpWidget(const SizedBox());
  });
}
