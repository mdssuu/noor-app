import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_look.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/screens/home_extras.dart';
import 'package:noor_masjid_time/screens/onboarding_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Home's nafl card, the three doors under the hero, and the four pages a
/// new profile walks once.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.instance.load();
  });

  testWidgets('the nafl card says all four times and the rule behind each',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: <Widget>[
              NaflTimingsCard(latitude: 19.0760, longitude: 72.8777),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Ishraq'), findsOneWidget);
    expect(find.text('Chasht'), findsOneWidget);
    expect(find.text('Zawal begins'), findsOneWidget);
    expect(find.text('Tahajjud'), findsOneWidget);
    // The rules are printed, not implied — this is fiqh, not decoration.
    expect(find.textContaining('quarter of the way'), findsOneWidget);
    expect(find.textContaining('last third of the night'), findsOneWidget);
  });

  testWidgets('the hero’s row offers the three doors',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NextPrayerHero(
            latitude: 19.0760,
            longitude: 72.8777,
            areaName: 'Kurla',
          ),
        ),
      ),
    );

    for (final String label in <String>['Qibla', 'Tasbeeh', 'Tracker']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    // Two doors moved: calendar is out of the app entirely, and share now
    // sits on the very card that prints the five times.
    expect(find.text('Calendar'), findsNothing, reason: 'no calendar door');
    expect(find.text('Share times'), findsNothing,
        reason: 'share lives on the times card');

    // The hero reads a clock every second — unmount it instead of waiting
    // for a ticker that never settles.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the wizard walks four pages and finishes',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: OnboardingScreen()));
    await tester.pumpAndSettle();

    // Page 1 — welcome.
    expect(find.text('Noor'), findsWidgets);
    expect(find.text('Next'), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);
    expect(AppSettings.instance.onboarded, isFalse);

    // Page 2 — location, and the city search that hides behind its option.
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Where are you praying?'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('Pin a city'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    // Page 3 — calculation; picking Hanafi writes through immediately.
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('How should the times be calculated?'), findsOneWidget);
    expect(AppSettings.instance.isHanafi, isFalse);
    await tester.tap(find.text('Hanafi'));
    await tester.pumpAndSettle();
    expect(AppSettings.instance.isHanafi, isTrue,
        reason: "a choice isn't collected until it is stored");

    // Page 4 — the Azaan, then Finish closes the wizard for good.
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('What should the Azaan sound like?'), findsOneWidget);

    await tester.tap(find.text('Finish'));
    await tester.pumpAndSettle();

    expect(AppSettings.instance.onboarded, isTrue);
    expect(find.byType(OnboardingScreen), findsNothing,
        reason: 'the wizard must not sit between the user and Home');
  });

  testWidgets('Skip closes the wizard without collecting anything',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: OnboardingScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    expect(AppSettings.instance.onboarded, isTrue,
        reason: 'quitting must not resurrect the wizard tomorrow');
    expect(find.byType(OnboardingScreen), findsNothing);
  });
}
