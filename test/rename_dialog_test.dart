import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/main.dart';

/// Regression for the red screen hit when editing a masjid name:
///
///   'package:flutter/src/widgets/framework.dart': Failed assertion: line 6281
///   pos 12: '_dependents.isEmpty': is not true.
///
/// That assertion was never the bug — it was the last of three cascading
/// exceptions. The first was "A TextEditingController was used after being
/// disposed", thrown from an `AnimatedState.didUpdateWidget` on the dialog's
/// own TextField.
///
/// `showDialog`'s future resolves in the microtask drained between the
/// begin-frame and draw-frame callbacks. The route's elements are only torn
/// down in the draw phase, so disposing the controller at that point left a
/// still-mounted TextField whose next update registered a listener on a dead
/// ChangeNotifier. On a device the rebuild comes from the keyboard sliding
/// away — a viewport-metrics change — and that is what a surface resize
/// stands in for here, so no real input injection is needed.
void main() {
  Masjid masjid() => Masjid(
        id: 'masjid-x',
        name: 'Aqsa Masjid Road',
        fajr: '05:15',
        dhuhr: '13:20',
        asr: '16:40',
        maghrib: '18:45',
        isha: '20:10',
        juma: '13:30',
        latitude: 19.0760,
        longitude: 72.8777,
        address: 'Kurla, Mumbai',
        photoProofPath: '',
        photoProofBase64: '',
        lastUpdated: Timestamp.fromMillisecondsSinceEpoch(1700000000000),
        updatedBy: 'Ayesha',
        updatedByUid: 'uid-editor',
        area: 'Kurla',
        createdByUid: 'uid-owner',
      );

  Future<void> openDialog(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => Center(
            child: TextButton(
              onPressed: () => showRenameDialog(context, masjid()),
              child: const Text('Edit'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Suggest correct name'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  }

  testWidgets('the controller outlives the route being torn down', (WidgetTester tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await openDialog(tester);

    // Put text in the field, so its AnimatedBuilder is subscribed to the
    // controller — the exact subscription the old code invalidated.
    await tester.enterText(find.byType(TextField), 'Noor Masjid');
    await tester.pump();

    // Dismiss, and change the viewport before the fade-out has run its
    // course: the keyboard going away while the route is still in the tree.
    await tester.tap(find.text('Cancel'));
    await tester.binding.setSurfaceSize(const Size(700, 1100));

    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsNothing);

    // Anything still to come out of the teardown has to be inert by now.
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a tap that changes nothing closes without writing', (WidgetTester tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await openDialog(tester);

    // Save with the text untouched: `showRenameDialog` must pop before it
    // reaches Firestore, so this never leaves the device.
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Suggest correct name'), findsNothing);
  });
}
