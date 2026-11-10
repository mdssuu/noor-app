import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The widget's native half — the layout, the provider that fills it, and
/// the font the readings are set in.
///
/// None of this can run in a Flutter test: RemoteViews and AppWidgetManager
/// are Android classes. So the contract between the three files is pinned
/// where it lives — a rename on either side has to break here first, not
/// on somebody's home screen.
void main() {
  test('the layout carries a block for every prayer, in provider order', () {
    final String xml =
        File('android/app/src/main/res/layout/noor_widget.xml')
            .readAsStringSync();

    for (int i = 0; i < 5; i++) {
      expect(xml, contains('widget_p${i}_name'),
          reason: 'block $i needs its prayer name');
      expect(xml, contains('widget_p${i}_time'),
          reason: 'block $i needs its clock');
      expect(xml, contains('widget_p${i}_quote'),
          reason: 'block $i needs its reading in the plain face');
      expect(xml, contains('widget_p${i}_quote_urdu'),
          reason: 'block $i needs its reading in the Nastaliq face');
      expect(xml, contains('widget_block_$i'),
          reason: 'block $i must be hideable as a whole');
    }

    // The two faces exist as two views because RemoteViews cannot switch a
    // typeface at draw time; the provider shows exactly one.
    expect(xml, contains('@font/noto_nastaliq_urdu'),
        reason: 'the Urdu face must be a real resource, or the Nastaliq '
            'line falls back to the system font');
    final File font =
        File('android/app/src/main/res/font/noto_nastaliq_urdu.ttf');
    expect(font.existsSync(), isTrue, reason: 'the face must be bundled');
    expect(font.lengthSync(), greaterThan(100000),
        reason: 'a font file this small is an error page, not a typeface');

    // The empty state: a header over nothing reads as a broken widget.
    expect(xml, contains('widget_hint'),
        reason: 'before the first picture the widget must say what to do');
    expect(xml, contains('widget_sunrise'),
        reason: 'sunrise keeps its slim line between Fajr and Dhuhr');
  });

  test('the provider reads exactly the fields the layout and Dart name', () {
    final String kotlin = File(
            'android/app/src/main/kotlin/com/sunesra_app/NoorWidgetProvider.kt')
        .readAsStringSync();

    expect(kotlin, contains('readingLang'),
        reason: 'the face shown must follow the reader’s language');
    expect(kotlin, contains('tomorrowQuote'),
        reason: 'after midnight the widget must have a reading to show');
    expect(kotlin, contains('dayEndMs'),
        reason: 'something must tell it when tomorrow begins');
    expect(kotlin, contains('internal fun pick('),
        reason: 'the lock-screen card picks by the same rule, or the two '
            'surfaces disagree about every clock after midnight');

    final String lock = File(
            'android/app/src/main/kotlin/com/sunesra_app/LockScreenNotifier.kt')
        .readAsStringSync();
    expect(lock, contains('NoorWidgetProvider.pick('),
        reason: 'the card must share the widget’s rule, not keep its own');

    // Every id the Kotlin side names must exist in the layout above.
    final String xml =
        File('android/app/src/main/res/layout/noor_widget.xml')
            .readAsStringSync();
    final RegExp ids = RegExp(r'R\.id\.(widget_\w+)');
    final Set<String> used =
        ids.allMatches(kotlin).map((Match m) => m.group(1)!).toSet();
    expect(used, isNotEmpty);
    for (final String id in used) {
      expect(xml, contains('android:id="@+id/$id"'),
          reason: 'Kotlin fills `$id`, which the layout does not declare — '
              'the widget would crash rendering');
    }
  });

  test('the widget is registered and told how much room it wants', () {
    final String manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('.NoorWidgetProvider'),
        reason: 'an unregistered receiver means the launcher never finds '
            'the widget at all');

    final String info =
        File('android/app/src/main/res/xml/noor_widget_info.xml')
            .readAsStringSync();
    // Five prayers with their readings want about three cells of height;
    // a host that grants less clips the last lines.
    expect(info, contains('android:minHeight="270dp"'));
    expect(info, contains('android:resizeMode="horizontal|vertical"'));
  });
}
