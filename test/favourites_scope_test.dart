import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression for: "save a masjid in one account and it shows as saved in
/// another account too."
///
/// Firestore was always `users/{uid}/favourites`. The leak came from the
/// local cache, which used a single device-wide key — so every account on the
/// phone read and re-wrote the same list.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('favourite cache key is scoped per account', () {
    test('two signed-in accounts never share a key', () {
      final String a = FavouriteStore.cacheKeyFor('uid-a');
      final String b = FavouriteStore.cacheKeyFor('uid-b');
      final String anon = FavouriteStore.cacheKeyFor(null);

      expect(a, isNot(b));
      expect(a, isNot(anon));
      expect(b, isNot(anon));
    });

    test('no account reuses the old shared key', () {
      expect(FavouriteStore.cacheKeyFor('uid-a'), isNot(FavouriteStore.legacyCacheKey));
      expect(FavouriteStore.cacheKeyFor(null), isNot(FavouriteStore.legacyCacheKey));
      expect(FavouriteStore.cacheKeyFor('uid-a'), startsWith('noor_favourite_ids::'));
    });

    test('legacy shared list is set aside, never handed to a signed-in account', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        FavouriteStore.legacyCacheKey: <String>['masjid-x'],
      });
      final SharedPreferences prefs = await SharedPreferences.getInstance();

      await FavouriteStore.retireLegacyCacheKey(prefs);

      expect(prefs.containsKey(FavouriteStore.legacyCacheKey), isFalse,
          reason: 'the ambiguous key must stop existing so it cannot leak again');
      expect(prefs.getStringList(FavouriteStore.cacheKeyFor(null)), <String>['masjid-x'],
          reason: 'nothing is thrown away — it stays with the signed-out profile');
      expect(prefs.getStringList(FavouriteStore.cacheKeyFor('uid-a')), isNull,
          reason: 'account A must not inherit it');
      expect(prefs.getStringList(FavouriteStore.cacheKeyFor('uid-b')), isNull,
          reason: 'account B must not inherit it');
    });

    test('legacy ids merge into the signed-out list rather than replacing it', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        FavouriteStore.legacyCacheKey: <String>['masjid-x'],
        FavouriteStore.cacheKeyFor(null): <String>['masjid-y'],
      });
      final SharedPreferences prefs = await SharedPreferences.getInstance();

      await FavouriteStore.retireLegacyCacheKey(prefs);

      expect(prefs.getStringList(FavouriteStore.cacheKeyFor(null)),
          <String>['masjid-y', 'masjid-x']);
    });

    test('migrating twice is a no-op', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        FavouriteStore.legacyCacheKey: <String>['a', 'b'],
      });
      final SharedPreferences prefs = await SharedPreferences.getInstance();

      await FavouriteStore.retireLegacyCacheKey(prefs);
      await FavouriteStore.retireLegacyCacheKey(prefs);

      expect(prefs.getStringList(FavouriteStore.cacheKeyFor(null)), <String>['a', 'b']);
      expect(prefs.containsKey(FavouriteStore.legacyCacheKey), isFalse);
    });

    test('a clean install has nothing to migrate', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SharedPreferences prefs = await SharedPreferences.getInstance();

      await FavouriteStore.retireLegacyCacheKey(prefs);

      expect(prefs.getStringList(FavouriteStore.cacheKeyFor('uid-a')), isNull);
      expect(prefs.getStringList(FavouriteStore.cacheKeyFor(null)), isNull);
    });
  });
}
