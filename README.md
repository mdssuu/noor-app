# Noor • Masjid Time

> **Real Masjid, Real Time** — a community prayer-time app with a single superpower:
> walk into any masjid, photograph the physical prayer-time board, let **on-device AI**
> read the times, confirm them, and every user nearby is updated instantly.

Everything lives in one file: [`lib/main.dart`](lib/main.dart).

---

## Why it is free to run (no billing, no API keys)

| Concern | Implementation | Cost |
|---|---|---|
| Backend | **Cloud Firestore** only — no custom REST API, no Node server | Spark plan |
| OCR / AI | **`google_mlkit_text_recognition`** — 100 % on device | Free |
| Maps | **`flutter_map`** + OpenStreetMap tiles | Free, no key |
| Distance | **`Geolocator.distanceBetween`** — local haversine | Free |
| Auth | **`firebase_auth` + `google_sign_in`** real credential flow | Free |
| Notifications | **`flutter_local_notifications`** (local, on-device) | Free |

`google_maps_flutter` and the Google Maps SDK are **not** used anywhere.

---

## Features

- **Google Login** → real `GoogleSignIn().signIn()` → `GoogleAuthProvider.credential()` → `signInWithCredential()`.
- **Scan Masjid Clock (big FAB)** → `image_picker` camera → ML Kit text recognition → Dart parsing engine
  (FAJR / FAJAR, ZUHR / ZOHAR / DHUHR / ZOHR, ASAR / ASR, MAGHRIB / MAGRIB, ISHA / ESHA, JUMA / JUMMA …)
  with `05:15`, `5.15`, `5:15 AM`, `18:45` normalised to strict `HH:MM` 24-hour.
- **Verification screen** — scanned photo preview, six editable time fields, required
  *“Masjid ka naam kya hai? e.g. Masjid Al-Falah”* field when the name could not be read,
  `Scan Again` + `Save & Confirm for All`.
- **De-duplication** — if a masjid with the same name already exists within **200 m**, that
  document is updated instead of creating a new one.
- **Proof** — the board photo is stored as base64 (plus its local path) and can be zoomed.
- **Home** — search, `Nearby Masjids` sorted by distance (nearest first), live
  `StreamBuilder` on `masjids`, distance badge, five time chips with prayer icons,
  “Last updated 2 min ago”, favourite heart.
- **Detail** — full times, **OpenStreetMap** pin via `flutter_map`, full photo proof,
  `Update Time` to re-scan.
- **Suggest correct name** — an ✏️ **Edit** next to the masjid's name opens
  “Suggest correct name”; saving writes `masjidName` plus `nameEditedBy`,
  `nameEditedAt` and `originalName` (the *first* spelling, kept so any edit can
  be reverted) and the list repaints immediately from the same snapshot stream.
  `lastUpdated` is deliberately untouched — a rename is not a prayer-time
  verification. No approval queue yet; the three audit fields are what make one
  cheap to add later.
- **Favourites + notifications** — ids in `users/{uid}/favourites` (mirrored to
  SharedPreferences). A listener on each favourite fires
  *“Masjid Al-Falah ka Maghrib time update hua: 18:20”* through
  `flutter_local_notifications`, with the Android 13+ permission requested.
- **Azaan sound that actually plays** — the clip is bundled in
  `android/app/src/main/res/raw/` and attached to the notification channel, so
  the reminder recites with the app closed instead of falling back to the
  system tone (channel sound is frozen at creation, hence the delete +
  recreate on every change). A second exact alarm plays the same file with
  `USAGE_ALARM` **only when the phone is on silent/vibrate**, which is the one
  case the channel cannot be heard — so never twice, never not at all.
  Settings offers the selector, a **Test Azaan** button, and the exact-alarm +
  battery-optimisation prompts are raised once on first open.
- **The day at a glance** — the sun's own path across the day drawn as a
  curve from **sunrise to sunset**, with the four times the boards print
  under the five (Ishraq, Chasht, Zawal, Tahajjud) pinned on it, the
  daylight length in the corner, and a dot showing where the clock stands
  right now. Sunset used to be computed every day and thrown away; it is
  now printed where the reader can see it.
- **Hijri calendar** — a whole Hijri month as a grid with **both**
  calendars on every cell, the fixed occasions (Ashura, Shab-e-Barat, the
  two Eids…) marked and dated, the next occasion counted down, and the
  prayer times of **any** day the reader taps — calculated for the same
  place the Home card uses. Tap the date under the greeting, or the
  **Hijri calendar** row on the Profile tab. The month is navigated by
  month, so “next” always lands on the 1st.
- **Owner's remote config** — one Firestore document (`app_config/general`)
  decides what every phone opens on and looks like: new-user defaults (method,
  madhab, minutes-before, clip, time format, Hijri offset, language), the
  wallpaper behind every screen, the profile logo, the notice on Home, the
  launcher icon, and a replacement Azaan clip per sound. Changed from the
  **Admin → App config** screen; reaches every installed copy on its next
  sync, with no update and no code. Defaults are given **once per profile**
  (only to a profile that has never stored a setting); look and clips apply
  to everyone. See “The owner's remote config” below.

---

## The owner's remote config

`app_config/general` is the whole feature. It is read by every phone and
written by one account, and the split in what it controls is deliberate:

| Section | Applies to | Why |
| --- | --- | --- |
| `defaults` | **New profiles only** — the first time an account opens the app with no stored setting | A default is a stand-in for a choice nobody has made yet. Once a user touches Settings they have made choices, and the owner's defaults never reach them again (`AppSettings.isVirginProfile`, then a single-write `AppSettings.seedWith`). |
| `branding` (wallpaper, logo, notice, launcher icon) | **Everyone, always** | A masjid's wallpaper and its mark are not a preference — they are the app. |
| `azanUrls` | **Everyone, always** | The Azaan the owner chose is the Azaan the masjid hears. A clip that fails to fetch falls back to the bundled one, so a dead link costs the owner their clip, never a user's Azaan. |

What each URL does on the phone: the clip is fetched once and kept in the
app's private `filesDir` (`azaan_<sound>.clip`) — reachable by path, which is
what the alarm path needs, since it plays with the app closed. The wallpaper
and logo are cached the same way and drawn by `MosqueScape`/`NoorBadge`
behind the existing skyline and glass.

**The launcher icon is the honest limitation.** Android draws that icon from
the app's own resources, so it cannot be replaced by a download — only
*chosen* between prepared variants. Four ship in the build as
`activity-alias` entries over `MainActivity` (`Launcher0`…`Launcher3`, in the
order of `kLauncherIconLabels`), and enabling one and disabling the rest is
the switch (`LauncherIcons.kt`). The choice is remembered in SharedPreferences
and re-applied on launch, because an app update clears component states back
to the manifest's default. MIUI and some launchers cache the old icon for a
while; that is the launcher's doing, not the app's.

Enforcement lives in `firestore.rules`: read for any signed-in account, write
only for the owner's. The panel hides the controls from everyone else as a
courtesy — a client cannot keep anyone out of its own code, so the rule is
where the door actually is.

---

## Setup

```bash
# 1. Dependencies
flutter pub get

# 2. Connect the project to Firebase (writes google-services.json + lib/firebase_options.dart)
dart pub global activate flutterfire_cli
flutterfire configure
```

`flutterfire configure` detects the already-wrapped `com.google.gms.google-services`
plugin in `android/` (the `START/END: FlutterFire Configuration` markers) and only
adds `android/app/google-services.json`.

### Firebase console

1. **Build → Authentication → Sign-in method → Google → Enable** (add a support email).
2. **Project settings → Your apps → Android** — package name `com.sunesra_app`,
   and add the **SHA-1** (`cd android && ./gradlew signingReport`). Without it Google
   Sign-In fails on a physical device.
3. **Firestore → Start collection** and publish these rules:

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /masjids/{doc} {
      allow read: if request.auth != null;
      allow create, update: if request.auth != null
        && request.resource.data.keys().hasAll([
             'masjidName','fajr','dhuhr','asr','maghrib','isha','juma',
             'latitude','longitude','address','lastUpdated','updatedByUid'])
        && request.resource.data.updatedByUid == request.auth.uid;
      allow delete: if false;
    }
    match /users/{uid}/favourites/{doc} {
      allow read, write: if request.auth != null && request.auth.uid == uid;
    }
  }
}
```

### Run

```bash
flutter run
```

---

## Android permissions

`android/app/src/main/AndroidManifest.xml` declares `CAMERA`, `ACCESS_FINE_LOCATION`,
`ACCESS_COARSE_LOCATION`, `INTERNET`, `ACCESS_NETWORK_STATE`, `POST_NOTIFICATIONS`.
All runtime permissions (camera, location, notifications) are requested in Dart.

The Azaan screen needs two special-access permissions, neither of which is a
runtime prompt — both are granted from a system screen the app opens for you:

- `USE_FULL_SCREEN_INTENT` — the route to the **lock screen**: the playback
  notification carries the recitation card there, where the volume keys can
  reach it. Android 14+ makes this a switch (Admin → Permissions → Full-screen
  intent).
- `SYSTEM_ALERT_WINDOW` — the route to an **unlocked** phone, which no
  full-screen intent reaches. On MIUI the toggle the app names is a separate
  one, *"Display pop-up windows while running in the background"* (op 10021),
  so `PopUpWindows.kt` reads both and opens whichever screen holds the real
  switch. This must be declared in the manifest or the app never appears on
  that screen at all.

`android/app/build.gradle.kts` enables **core library desugaring**
(`com.android.tools:desugar_jdk_libs:2.1.4`), which `flutter_local_notifications` requires.

---

## Tests

```bash
flutter test     # unit tests for the OCR → prayer-time parsing engine
flutter analyze  # zero issues
```

---

## Work from your phone (GitHub Codespaces)

You do not need this laptop switched on. The whole Flutter environment lives in
a cloud container defined by `.devcontainer/`.

**First time, about 5 minutes:**

1. Open `github.com/mdssuu/privatecode` in Chrome on your phone.
2. Tap **Code** → **Codespaces** tab → **Create codespace on master**.
3. The container installs the current Flutter stable and runs `flutter pub get`
   by itself (`.devcontainer/postCreate.sh`). Wait for "Done."
4. Chrome will offer to switch to the desktop site - accept it. The editor
   needs it.

**Everyday edits:**

1. Open a file, edit it, tap the tick to commit.
2. Push from the terminal tab: `git push`
3. CI (`.github/workflows/ci.yml`) then runs `flutter analyze`, all 273 tests,
   and uploads a debug APK as an artifact.

**Get an APK onto the phone:**

- **Automatic** - push a tag such as `v1.5.2`. `.github/workflows/release.yml`
  builds a release APK and attaches it to a GitHub Release, downloadable
  straight from the Releases page.
- **Manual** - open **Actions** → **Release APK** → **Run workflow**. The APK
  is uploaded as an artifact instead.

Release builds are signed with the debug key (see `android/app/build.gradle.kts`),
so this APK installs over your existing app as long as the version in
`pubspec.yaml` keeps going up.

**Keep this laptop in the loop too:**

```powershell
.\scripts\sync.ps1   # pulls whatever you changed on GitHub back down here
```

---

## CI status

| Workflow | Trigger | What it does |
| --- | --- | --- |
| `CI` | every push / PR to `master` | `flutter analyze` + `flutter test` + debug APK artifact |
| `Release APK` | tag `v*`, or a manual run | release APK attached to a GitHub Release |
