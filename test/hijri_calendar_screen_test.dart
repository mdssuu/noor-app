import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hijri/hijri_calendar.dart';
import 'package:intl/intl.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/screens/hijri_calendar_screen.dart';
import 'package:noor_masjid_time/services/islamic_calendar.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Hijri calendar is a screen that was promised on the onboarding page
/// and never built, while the whole month grid sat in `services/` unused.
///
/// What the screen must hold to:
///
///  * the month on screen is a *whole* Hijri month, with both calendars on
///    every cell;
///  * "next month" lands on the 1st of the month after, not 29 days on;
///  * tapping a day prints that day's times, calculated for the reader's
///    own place.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.instance.load();
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: HijriCalendarScreen(latitude: 19.0760, longitude: 72.8777),
      ),
    );
    await tester.pump();
  }

  testWidgets('the screen shows the month, whole, with both calendars', (
    WidgetTester tester,
  ) async {
    await pumpScreen(tester);

    final HijriCalendar h = NoorHijri.hijriOf(DateTime.now());
    final int length = h.getDaysInMonth(h.hYear, h.hMonth);

    expect(find.text('Hijri calendar'), findsOneWidget);
    expect(find.textContaining(h.getLongMonthName()), findsWidgets);
    expect(find.textContaining('${h.hYear} AH'), findsWidgets);

    // Every day of the month is on the grid — the 1st and the last, and
    // the days either side of them.
    expect(find.byKey(const ValueKey('hijri-day-1')), findsOneWidget);
    expect(find.byKey(ValueKey('hijri-day-$length')), findsOneWidget);
    expect(find.byKey(ValueKey('hijri-day-${length - 1}')), findsOneWidget);
  });

  testWidgets('next month lands on the first of the month after', (
    WidgetTester tester,
  ) async {
    await pumpScreen(tester);

    final HijriCalendar h = NoorHijri.hijriOf(DateTime.now());
    final DateTime nextStart = NoorHijri.monthStartBy(
      DateTime.now(),
      1,
      adjustment: AppSettings.instance.hijriAdjustment,
    );
    final HijriCalendar next = NoorHijri.hijriOf(nextStart);

    expect(next.hMonth, (h.hMonth % 12) + 1);

    await tester.tap(find.byTooltip('Next month'));
    await tester.pump();

    // The whole month changed, and it changed to the *first* of the next
    // one — the 1st is on the grid again, not a day in the middle.
    expect(find.textContaining(next.getLongMonthName()), findsWidgets);
    expect(find.textContaining('${next.hYear} AH'), findsWidgets);
    expect(find.byKey(const ValueKey('hijri-day-1')), findsOneWidget);
  });

  testWidgets('tapping a day prints that day and its times', (
    WidgetTester tester,
  ) async {
    await pumpScreen(tester);

    final HijriCalendar h = NoorHijri.hijriOf(DateTime.now());
    final DateTime first = NoorHijri.gregorianOf(
      h.hYear,
      h.hMonth,
      1,
      adjustment: AppSettings.instance.hijriAdjustment,
    );

    await tester.tap(find.byKey(const ValueKey('hijri-day-1')));
    await tester.pump();

    // The day under the grid is the one that was tapped.
    await tester.scrollUntilVisible(
      find.text(DateFormat('EEEE, d MMMM yyyy').format(first)),
      200,
    );
    expect(
      find.text(DateFormat('EEEE, d MMMM yyyy').format(first)),
      findsOneWidget,
    );

    // And its times — the five prayers, the sunrise, the sunset.
    expect(find.text('Fajr'), findsOneWidget);
    expect(find.text('Sunrise'), findsOneWidget);
    expect(find.text('Sunset'), findsOneWidget);
  });

  testWidgets('the occasions of the month are listed with their dates', (
    WidgetTester tester,
  ) async {
    await pumpScreen(tester);

    await tester.scrollUntilVisible(find.text('Occasions this month'), 200);
    expect(find.text('Occasions this month'), findsOneWidget);

    // The fixed occasions are always there — either the ones of this month,
    // or the line that says there are none.
    final HijriCalendar h = NoorHijri.hijriOf(DateTime.now());
    final List<IslamicEvent> events = kIslamicEvents
        .where((IslamicEvent e) => e.month == h.hMonth)
        .toList();
    if (events.isEmpty) {
      expect(find.textContaining('No fixed occasion'), findsOneWidget);
    } else {
      expect(find.text(events.first.title), findsOneWidget);
    }
  });
}
