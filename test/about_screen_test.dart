import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/screens/about_screen.dart';

/// The About page is the one screen the device run cannot reach — the
/// install has no `input tap` — so it is pinned here instead: the page
/// builds, carries the developer's details, and offers the help rows.
void main() {
  testWidgets('About screen shows the developer and the help rows',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AboutScreen(),
      ),
    );
    await tester.pump();

    expect(find.text('About Noor'), findsOneWidget);
    expect(find.text('Noor • Masjid Time'), findsOneWidget);
    expect(find.text('Mohammad Siddique Sunesra'), findsOneWidget);
    expect(find.text('Email the developer'), findsOneWidget);
    expect(find.text(AboutScreen.supportEmail), findsOneWidget);
    expect(find.text('Download / update the app'), findsOneWidget);
    expect(find.text('Open-source licenses'), findsOneWidget);
  });
}
