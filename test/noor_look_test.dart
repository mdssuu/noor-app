import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:noor_masjid_time/app_look.dart';
import 'package:noor_masjid_time/main.dart' show NoorColors;

// ===========================================================================
//  THE WALLPAPER AND THE FURNITURE
//
//  The sky is the app's wallpaper: it changes six times a day. These tests
//  pin the two promises that come with that:
//
//   1. the wallpaper keeps changing — six skies, six turning hours, a clock
//      that says exactly when "with it" is;
//   2. the furniture does *not* move with it. The re-skin pinned the cards
//      to one constant white material, so every hour — 3 a.m. included —
//      reads as warm daylight, and a sky change cannot rebuild a screen
//      that would look identical afterwards.
// ===========================================================================

/// Every sky the app can be wearing.
const List<NoorSky> skies = <NoorSky>[
  NoorSky.night,
  NoorSky.dawn,
  NoorSky.morning,
  NoorSky.afternoon,
  NoorSky.evening,
  NoorSky.dusk,
];

double _linear(double channel) => channel <= 0.04045
    ? channel / 12.92
    : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();

double _luminance(double r, double g, double b) =>
    0.2126 * _linear(r) + 0.7152 * _linear(g) + 0.0722 * _linear(b);

/// How well [type] reads on [look]'s card laid over [backdrop] — the real
/// situation, since a card over a sky is only as solid as its wash lets it
/// be. (The re-skin made the wash opaque, so the backdrop should turn out
/// not to matter; the loop below keeps it honest anyway.)
double contrastOn(NoorLook look, Color type, Color backdrop) {
  final double alpha = look.fill.a;
  final double r = look.fill.r * alpha + backdrop.r * (1 - alpha);
  final double g = look.fill.g * alpha + backdrop.g * (1 - alpha);
  final double b = look.fill.b * alpha + backdrop.b * (1 - alpha);
  final double card = _luminance(r, g, b);
  final double ink =
      _luminance(type.r, type.g, type.b);
  return (math.max(card, ink) + 0.05) / (math.min(card, ink) + 0.05);
}

void main() {
  group('NoorSky — when the wallpaper changes', () {
    test('the six change hours are the only hours the sky turns over', () {
      final DateTime day = DateTime(2026, 10, 8);

      final List<int> turning = <int>[
        for (int hour = 0; hour < 24; hour++)
          if (NoorSky.of(day.add(Duration(hours: hour))) !=
              NoorSky.of(day.add(Duration(hours: hour - 1))))
            hour,
      ];

      expect(turning, NoorSky.changeHours);
    });

    test('the next change is always ahead, and always a different sky', () {
      for (final int hour in NoorSky.changeHours) {
        final DateTime at = DateTime(2026, 10, 8, hour);
        final DateTime next = NoorSky.nextChange(at);

        expect(next.isAfter(at), isTrue,
            reason: 'a timer armed for $hour must not arm itself again');
        expect(NoorSky.of(next), isNot(NoorSky.of(at)),
            reason: 'waking up at $next has to be worth something');
      }
    });

    test('after the last change of the day it waits for tomorrow morning', () {
      expect(
        NoorSky.nextChange(DateTime(2026, 10, 8, 23, 30)),
        DateTime(2026, 10, 9, 4),
      );
      // Strictly after: 4:00 has already happened at 4:00:00.000.
      expect(NoorSky.nextChange(DateTime(2026, 10, 8, 4)), DateTime(2026, 10, 8, 6));
      expect(NoorSky.nextChange(DateTime(2026, 10, 8, 7, 15)), DateTime(2026, 10, 8, 11));
    });
  });

  group('NoorLook — what the cards are cut from', () {
    test('every sky resolves to the same material', () {
      final List<NoorLook> looks = skies.map(NoorLook.from).toList();

      for (int i = 0; i < looks.length; i++) {
        for (int j = i + 1; j < looks.length; j++) {
          expect(looks[i], looks[j],
              reason: 'the re-skin pinned the furniture: an hour must not '
                  'change what the cards are made of');
        }
      }
      expect(looks.toSet(), hasLength(1));
    });

    test('the material is a value — the look is just its fields', () {
      expect(NoorLook.from(NoorSky.morning), NoorLook.from(NoorSky.morning));
      expect(
        NoorLook.from(NoorSky.morning).hashCode,
        NoorLook.from(NoorSky.morning).hashCode,
      );
      expect(
        const NoorLook(
          base: NoorColors.ink,
          fill: NoorColors.ink,
          border: Color(0x1A3A2E22),
          shadowColor: Color(0x1F3A2E22),
          glow: LinearGradient(
            colors: <Color>[Color(0x14E39A6B), Color(0x00E39A6B)],
            stops: <double>[0, 0.55],
          ),
        ),
        isNot(NoorLook.from(NoorSky.night)),
      );
    });

    test('the card is opaque white — the sky cannot bleed through it', () {
      for (final NoorSky sky in skies) {
        final NoorLook look = NoorLook.from(sky);

        expect(look.fill.a, 1.0,
            reason: 'sky ${sky.mid} shows through a translucent card, and '
                'the re-skin promised warm daylight at every hour');
        expect(look.fill, NoorColors.white);
        expect(look.base, NoorColors.white);
      }
    });

    test('ink type reads on every card, over its own sky', () {
      for (final NoorSky sky in skies) {
        final NoorLook look = NoorLook.from(sky);

        for (final Color backdrop in <Color>[sky.top, sky.mid, sky.bottom]) {
          expect(contrastOn(look, NoorColors.ink, backdrop),
              greaterThanOrEqualTo(4.5),
              reason: 'ink type on a card over $backdrop at ${sky.mid} '
                  'falls apart');
        }
      }
    });

    test('the edge is warm paper, not cold glass', () {
      final NoorLook look = NoorLook.from(NoorSky.afternoon);

      // The hairline carries more red than blue: the edge of paper, not of
      // glass — and never a grey that reads cold on the cream page.
      expect(look.border.r, greaterThan(look.border.b));
      // The shadow is cut from the same warm ink the type is, not black.
      expect(look.shadowColor.r, greaterThan(look.shadowColor.b));
      expect(look.shadow, hasLength(1));
      expect(look.shadow.first.blurRadius, greaterThan(0));
    });

    test('the light at the top edge is the peach wash', () {
      final LinearGradient glow =
          NoorLook.from(NoorSky.night).glow as LinearGradient;

      expect(glow.colors.first, const Color(0x14E39A6B),
          reason: 'the accent catching the light down the top edge');
      expect(glow.colors.last, const Color(0x00E39A6B),
          reason: '…and gone by the middle of the card');
      expect(glow.stops, <double>[0, 0.55]);
    });
  });

  group('NoorGlassScope — how the cards hear about it', () {
    testWidgets('a screen\'s cards are cut from the material it asks for',
        (WidgetTester tester) async {
      Widget screen(NoorSky sky) => MaterialApp(
            home: NoorScaffold(
              sky: sky,
              body: Builder(
                builder: (BuildContext context) => Text(
                  'card-${NoorGlass.of(context).fill}',
                  textDirection: TextDirection.ltr,
                ),
              ),
            ),
          );

      await tester.pumpWidget(screen(NoorSky.night));
      expect(find.text('card-${NoorLook.from(NoorSky.night).fill}'),
          findsOneWidget);

      // Swap the wallpaper: the card on screen still answers with the
      // material of the sky now wearing — same constant, same frame.
      await tester.pumpWidget(screen(NoorSky.afternoon));
      expect(find.text('card-${NoorLook.from(NoorSky.afternoon).fill}'),
          findsOneWidget);
    });

    testWidgets('outside a screen the fallback is the sky right now',
        (WidgetTester tester) async {
      late NoorLook seen;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) {
              seen = NoorGlass.of(context);
              return const SizedBox();
            },
          ),
        ),
      );

      expect(seen, NoorLook.from(NoorSky.of()));
    });

    test('a sky that changed nothing does not announce a rebuild', () {
      // The whole point of pinning the material: the six-sky timer still
      // fires, but the screen it would repaint now looks identical, so the
      // scope stays quiet.
      final NoorGlassScope before = NoorGlassScope(
        look: NoorLook.from(NoorSky.night),
        child: const SizedBox(),
      );
      final NoorGlassScope after = NoorGlassScope(
        look: NoorLook.from(NoorSky.afternoon),
        child: const SizedBox(),
      );
      expect(before.updateShouldNotify(after), isFalse,
          reason: 'a wallpaper change that alters no card must not rebuild '
              'the screen beneath it');

      // A genuinely different material — e.g. a future theme override —
      // still gets through.
      final NoorGlassScope different = NoorGlassScope(
        look: const NoorLook(
          base: NoorColors.ink,
          fill: NoorColors.ink,
          border: Color(0x1A3A2E22),
          shadowColor: Color(0x1F3A2E22),
          glow: LinearGradient(
            colors: <Color>[Color(0x14E39A6B), Color(0x00E39A6B)],
            stops: <double>[0, 0.55],
          ),
        ),
        child: const SizedBox(),
      );
      expect(before.updateShouldNotify(different), isTrue);
    });
  });
}
