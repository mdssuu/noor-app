import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/today_prayer_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The row a reader actually reads — their words: "home 5 prayers ke text ko
/// halka bada kar bohot chota hai".
///
/// A prayer's name and its clock share one row down the card and are the
/// same fact printed twice — which prayer, what time — so they wear one
/// size. Both sat at 13.5, which read as fine print beside the hero above
/// the card; they move up to 15 together, and only together: bigger type on
/// one half of the line would leave it lopsided.
///
/// The two footnotes beneath the clock — the Awwal under a board's Jamaat,
/// and the official End under that — keep their small sizes on purpose.
/// They are the line's footnotes, and the card has to keep saying two more
/// things without the row turning into a paragraph.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const double lat = 19.0760;
  const double lng = 72.8777;

  testWidgets('a prayer’s name and the clock beside it wear the bigger type',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final AppSettings settings = AppSettings.instance;
    await settings.useProfile('row-type');
    settings.setTimeFormat('12');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TodayPrayerCard(
          latitude: lat,
          longitude: lng,
          areaName: 'Mumbai',
        ),
      ),
    ));
    await tester.pump();

    final Text name = tester.widget<Text>(find.text('Fajr'));
    expect(name.style?.fontSize, 15,
        reason: 'the prayer’s name is what the eye lands on first');
    expect(name.style?.fontWeight, FontWeight.w700);

    // The clock on the same row — unstarred, so it is the calculated time
    // printed exactly as the card prints it.
    final LocalPrayerTimes day =
        settings.compute(latitude: lat, longitude: lng);
    final Text clock =
        tester.widget<Text>(find.text(settings.format(day.times['fajr']!)));
    expect(clock.style?.fontSize, 15,
        reason: 'and the number it is read beside is the same fact — a '
            'smaller size there would leave the row lopsided');

    // The footnotes stay footnotes: the official End is still the smallest
    // line on the row, small enough to be quiet and large enough to read.
    final Text end = tester
        .widget<Text>(find.text('Ends ${settings.format(day.times['sunrise']!)}'));
    expect(end.style?.fontSize, 10);

    await tester.pumpWidget(const SizedBox());
  });
}
