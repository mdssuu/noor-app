import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/main.dart';
import 'package:noor_masjid_time/manual_add_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Friday's clock on the one form that could not ask for it.
///
/// `Masjid`, Firestore, the OCR reader and the add screen in `main.dart` have
/// all carried a `juma` field for as long as the field has existed — the
/// manual form was the single writer left that could not set it, so a masjid
/// entered by hand kept an empty Friday cell however often anybody edited its
/// times afterwards. It also wrote that old value *back* on every save, so
/// even a reader who knew what they wanted could not have typed it in.
///
/// Both halves are pinned: the row the reader fills (six rows, not five), and
/// the payload line that carries it out (the form's own answer, and no second
/// line overwriting it).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.instance.load();
  });

  Future<void> pumpForm(WidgetTester tester, {Masjid? existing}) async {
    // The form is a long ListView: rows the window never reaches are never
    // built, and "the sixth row exists" over a window that lays out three
    // would be asserting on nothing. Give it the room a phone gives it.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: ManualAddScreen(existing: existing),
    ));
    await tester.pump();
  }

  Masjid boardWith({required String juma}) => Masjid(
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

  testWidgets('the form offers Juma beside the five waqt times',
      (WidgetTester tester) async {
    await pumpForm(tester);

    for (final String label
        in <String>['Fajr', 'Zuhr', 'Asr', 'Maghrib', 'Isha', 'Juma']) {
      expect(find.text(label), findsOneWidget, reason: '$label has a row');
    }
    // Six rows, six ways to set them — the sixth is the new one, and it is
    // unanswered on a masjid nobody has filled it in for.
    expect(find.text('Tap to set'), findsNWidgets(6));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('editing shows the stored Friday time instead of losing it',
      (WidgetTester tester) async {
    await pumpForm(tester, existing: boardWith(juma: '13:30'));

    expect(find.text('13:30'), findsOneWidget,
        reason: 'the stored Juma is on show, which is what makes it editable');
    expect(find.text('Tap to set'), findsNothing,
        reason: 'every clock on this board answers');

    await tester.pumpWidget(const SizedBox());
  });

  test('the payload carries the form’s own Juma, and nothing overwrites it',
      () {
    final String source =
        File('lib/manual_add_screen.dart').readAsStringSync();

    expect(source, contains("<String>['fajr', 'dhuhr', 'asr', 'maghrib', 'isha', 'juma']"),
        reason: 'the key list is what the rows, the pickers and the payload '
            'are all built from — Juma has to be in it, not beside it.');
    expect(source, contains("'juma': 'Juma'"),
        reason: 'a label for the row, or the picker opens over an unnamed '
            'field.');
    expect(source, contains('for (final String key in _keys) key:'),
        reason: 'one line writes every clock the reader can see — that is '
            'what puts the typed Juma on the document.');
    expect(source, isNot(contains('widget.existing?.juma')),
        reason: 'the old line wrote the *stored* value back on every save, '
            'which is how the field stayed empty even once it existed.');
  });
}
