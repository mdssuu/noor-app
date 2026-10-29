import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Friday's clock on the card the reader actually looks at.
///
/// A board has always stored a `juma` column and Home never printed it: the
/// card's row of chips is the five *waqts*, and Juma — the time the whole
/// Friday turns on — was the one clock on the document the card did not show.
///
/// It gets the full width rather than a sixth of that row. Five chips already
/// leave each column little more than 40 logical pixels, and "1:30pm" set that
/// narrow is a clock clipped by its own box; a line across the card fits it
/// with room to spare. A cell nobody has filled reads `--:--` like every other
/// clock the board never answered, because a blank looks like the card broke.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Masjid board({String juma = '13:30'}) => Masjid(
        id: 'masjid-juma',
        name: 'Aqsa Masjid',
        fajr: '05:15',
        dhuhr: '13:20',
        asr: '16:40',
        maghrib: '18:45',
        isha: '20:10',
        juma: juma,
        latitude: 19.076,
        longitude: 72.8777,
        address: 'Kurla, Mumbai',
        photoProofPath: '',
        photoProofBase64: '',
        lastUpdated: Timestamp.fromMillisecondsSinceEpoch(1700000000000),
        updatedBy: 'Ayesha',
        updatedByUid: 'uid-editor',
      );

  Future<AppSettings> settingsWith(String format) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final AppSettings settings = AppSettings.instance;
    await settings.useProfile('masjid-card-juma-$format');
    settings.setTimeFormat(format);
    return settings;
  }

  Future<void> pumpCard(WidgetTester tester, Masjid masjid) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MasjidCard(
          masjid: masjid,
          metres: 120,
          isFavourite: false,
          onFavourite: () {},
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('the card prints the board’s Juma time', (WidgetTester tester) async {
    await settingsWith('12');
    await pumpCard(tester, board());

    expect(find.text('Juma · Friday'), findsOneWidget);
    expect(find.text('1:30pm'), findsOneWidget,
        reason: 'the board’s own clock, in the reader’s twelve-hour format');

    // The five waqts keep their row above it, untouched.
    for (final String label in <String>['Fajr', 'Dhuhr', 'Asr', 'Maghrib', 'Isha']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reads the Juma column as stored on the twenty-four-hour clock',
      (WidgetTester tester) async {
    await settingsWith('24');
    await pumpCard(tester, board());

    expect(find.text('13:30'), findsOneWidget);
    expect(find.text('1:30pm'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an unanswered Friday reads as unanswered, not blank',
      (WidgetTester tester) async {
    await settingsWith('12');
    await pumpCard(tester, board(juma: ''));

    expect(find.text('Juma · Friday'), findsOneWidget,
        reason: 'the row exists whatever the board answered — the field is '
            'real either way');
    expect(find.text('--:--'), findsOneWidget,
        reason: 'the same “the board never answered” the rest of the card '
            'speaks, rather than a gap that reads as a bug');

    await tester.pumpWidget(const SizedBox());
  });

  test('the strip is a full-width line, not a sixth chip in the row', () {
    final String source = File('lib/main.dart').readAsStringSync();
    expect(source, contains('kPrayers.take(5)'),
        reason: 'the waqt row stays five abreast — a sixth column is what '
            'would clip the clock it was added to show.');
    expect(source, contains('inline: true'),
        reason: 'and Juma takes the line beneath it instead.');
  });
}
