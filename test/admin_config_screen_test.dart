import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/main.dart' show GradientButton;
import 'package:noor_masjid_time/screens/admin_config_screen.dart';
import 'package:noor_masjid_time/services/admin_access.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The owner's editor, pumped the way the owner reaches it — through the
/// admin check and onto a real build.
///
/// This exists because of a bug it would have caught: `initState` used to
/// pour the document into three `late final` controllers that had never been
/// constructed, so the first person to open the screen (the owner, on a real
/// phone) hit a `LateInitializationError` before seeing anything. The data
/// layer was unit-tested to the hilt and the screen nobody built was not —
/// hence a test that *builds the screen*.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AdminAccess.isAdminOverride = true;
  });

  tearDown(() => AdminAccess.isAdminOverride = null);

  Future<void> pumpConfig(WidgetTester tester) async {
    // The form is one long ListView, and Flutter only builds what is on
    // screen — a phone-sized window would never lay out the icon picker or
    // the clip rows at all, so every assertion on them would be a test of
    // the viewport rather than of the screen.
    tester.view.physicalSize = const Size(1200, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: AdminConfigScreen()));
    await tester.pumpAndSettle();
  }

  testWidgets('the editor builds and shows every section', (WidgetTester tester) async {
    await pumpConfig(tester);

    expect(find.text('App config'), findsOneWidget);
    expect(find.text('Defaults for new users'), findsOneWidget);
    expect(find.text('Look — for everyone'), findsOneWidget);
    expect(find.text('Azaan clips'), findsOneWidget);

    // The four replaceable clips, each with its status word. Their labels
    // also sit in the defaults dropdown above, hence loose counts here.
    expect(find.text('Azaan 1 (Makkah)'), findsWidgets);
    expect(find.text('Azaan 2 (Madinah)'), findsWidgets);
    expect(find.text('Azaan 3 (Mishary Rashid Alafasy)'), findsWidgets);
    expect(find.text('Simple Beep'), findsWidgets);
    expect(find.text('bundled'), findsNWidgets(4));
    expect(find.text('Save & play'), findsNWidgets(4));

    // Nothing typed yet: the document on disk is what the form holds, so
    // there is nothing to save.
    final GradientButton save = tester.widget<GradientButton>(
      find.byType(GradientButton).first,
    );
    expect(save.onPressed, isNull);
    expect(find.text('Everything is saved'), findsWidgets);
  });

  testWidgets('a wallpaper link turns the screen dirty and shows its preview',
      (WidgetTester tester) async {
    await pumpConfig(tester);

    final Finder wallpaper = find.byType(TextField).first;
    await tester.enterText(wallpaper, 'https://example.com/wall.jpg');
    await tester.pump();

    expect(find.text('Save changes'), findsWidgets);
    final GradientButton save = tester.widget<GradientButton>(
      find.byType(GradientButton).first,
    );
    expect(save.onPressed, isNotNull);
    // The preview is the same picture the phone would stand the screen on.
    expect(find.byType(Image), findsWidgets);

    // A link that cannot be fetched is said so at once rather than saved.
    await tester.enterText(wallpaper, 'file:///etc/passwd');
    await tester.pump();
    expect(find.text('Needs a full http:// or https:// link'), findsOneWidget);
  });

  testWidgets('the notice and the launcher icon are reachable',
      (WidgetTester tester) async {
    await pumpConfig(tester);

    // Four icon variants, drawn rather than named — a picker for icons.
    expect(find.text('Crescent night'), findsOneWidget);
    expect(find.text('Eight-point star'), findsOneWidget);
    expect(find.text('Emerald minaret'), findsOneWidget);

    // The notice field is the third text field — wallpaper, logo, notice —
    // the four clip links come after it.
    final TextField notice =
        tester.widgetList<TextField>(find.byType(TextField)).elementAt(2);
    await tester.enterText(find.byWidget(notice), 'Jumu’ah Salah at 13:30');
    await tester.pump();
    expect(find.text('Save changes'), findsWidgets);
  });

  testWidgets('signed out, the screen keeps its controls to itself',
      (WidgetTester tester) async {
    AdminAccess.isAdminOverride = false;
    await pumpConfig(tester);

    expect(find.text('Defaults for new users'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(
      find.text(
        'These controls are only shown to the account that owns this app.',
      ),
      findsOneWidget,
    );
  });
}
