import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/main.dart' show NoorColors, buildNoorTheme;
import 'package:noor_masjid_time/screens/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Noor paints its own sky — the phone's mood must not repaint one widget.
///
/// The whole app resolves the same light palette whether the system is on
/// light or dark (`forceDarkAllowed="false"` in the manifest keeps the OS
/// out of it too). These tests pin the two halves of that promise: the
/// theme stays light under a dark platform brightness, and every control
/// the system would otherwise colour itself — switch, radio, cursor —
/// carries the app's own colours instead.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.instance.load();
  });

  testWidgets('Settings keeps its light palette on a phone in dark mode',
      (WidgetTester tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    // A tall phone, so the lazy list builds every section at once and the
    // assertions can look at the whole screen rather than the fold.
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildNoorTheme(),
        darkTheme: buildNoorTheme(),
        home: const SettingsScreen(),
      ),
    );
    await tester.pumpAndSettle();

    final BuildContext ctx = tester.element(find.text('Prayer calculation'));

    // The system is honest about night…
    expect(MediaQuery.platformBrightnessOf(ctx), Brightness.dark);
    // …and Noor answers with the same palette it always paints with.
    expect(Theme.of(ctx).brightness, Brightness.light,
        reason: 'the dark slot must resolve to the same light theme');
    expect(Theme.of(ctx).textTheme.bodyMedium?.color, NoorColors.ink,
        reason: 'every unstyled label on the cards reads ink-on-glass');

    // The widgets the user reported losing text on: the dropdowns, the
    // search field, the switches — all built on the pinned palette.
    expect(find.byType(DropdownButtonFormField<String>), findsWidgets);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(Switch), findsWidgets);

    final EditableText field =
        tester.widget<EditableText>(find.byType(EditableText).first);
    expect(field.style.color, NoorColors.ink,
        reason: 'typed text on the search field must read against its fill');

    // Unmount so the scaffold's sky timer is cancelled before the test
    // framework counts what is still armed.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('every system-coloured control carries the app palette',
      (WidgetTester tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearAllTestValues);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildNoorTheme(),
        darkTheme: buildNoorTheme(),
        home: const SizedBox.shrink(key: Key('probe')),
      ),
    );
    final ThemeData theme = Theme.of(tester.element(find.byKey(const Key('probe'))));

    const Set<WidgetState> off = <WidgetState>{};
    const Set<WidgetState> on = <WidgetState>{WidgetState.selected};

    expect(theme.brightness, Brightness.light);
    expect(theme.switchTheme.thumbColor?.resolve(off), NoorColors.white);
    expect(theme.switchTheme.thumbColor?.resolve(on), NoorColors.ink);
    expect(theme.switchTheme.trackColor?.resolve(on), NoorColors.emerald);
    expect(theme.radioTheme.fillColor?.resolve(on), NoorColors.emerald);
    expect(theme.checkboxTheme.checkColor?.resolve(on), NoorColors.white);
    expect(theme.textSelectionTheme.cursorColor, NoorColors.emerald);
    expect(theme.progressIndicatorTheme.color, NoorColors.emerald);
  });
}
