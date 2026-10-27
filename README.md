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
  `android/app/src/main/res/raw/` and played by a native player on the
  reader's own **ring volume**, so the reminder recites with the app closed at
  the loudness their slider says, instead of falling back to the system tone.
  The notification channel itself is deliberately silent, which is what keeps
  the sound to exactly one source and makes it endable with one keypress.
  Silent or vibrate is respected: the recitation declines rather than
  overriding the choice. **"When will the Azaan play?"** picks the clock —
  the masjid's own Jamaat column (the default), the calculated Awwal waqt,
  both, or off — so a reader following a printed board and a reader praying
  at home are not handed the same answer. A **Test Azaan** button and the
  exact-alarm + battery-optimisation prompts are raised once on first open.
  Silence is the default now — nothing is scheduled until the reader answers
  the Home bell dialog (Azaan / Mute / Band) or this screen, and a reader who
  did answer keeps their choice.
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
- **Manual add & edit** — no board to photograph? Search a place (Nominatim +
  Overpass, free, no key), set the pin on an OpenStreetMap screen, correct a
  wrong one later with **Fix location** (old coordinates kept, so the mistake
  stays recoverable), edit any time field and save. The same 200 m de-dup
  applies, so a scan and a manual entry can never become two masjids.
- **Qibla** — a real compass: the magnetometer with the accelerometer undoing
  the tilt, so a phone held up in the mosque reads the same as one flat on a
  table. The bearing is the great-circle one, computed from wherever the app
  already thinks you are — pinned city first, last GPS fix otherwise — the
  same location rule Home's prayer times follow.
- **Tasbeeh** — one button, one thumb: the count, the round of thirty-three
  (or ninety-nine), a buzz when a round closes, and a total that survives
  leaving the screen, closing the app and a reboot, because it is written per
  bead rather than per visit.
- **Tracker** — the salah log: a month of dots, a streak and today's five in
  one row, **entirely on the device** — no account, no network, scoped to the
  signed-in profile. A log of a person's prayers is theirs.
- **Ramadan banner** — during Ramadan only: which fast of the month, the end
  of Sehri and the Iftar time, all read off the same Umm al-Qura table as the
  Hijri date above it, so they can never disagree by a day.
- **Home-screen widget** — `NoorWidgetProvider.kt` puts the next two days of
  prayer times on the launcher, so the app does not have to be opened at all.
- **Share today's times** — the share sheet (`share_plus`) sends today's five
  to WhatsApp or anywhere else, with the masjid's own Jamaat times in them.
- **About & Privacy** — the real version and build number from
  `package_info_plus`, the developer's mailto, the licenses, a Play Store
  link, and the **Privacy Policy read in an in-app browser**
  (`flutter_inappwebview`) from its public URL
  ([`docs/privacy.md`](docs/privacy.md)) — one document, never a copy that
  drifted inside the binary — with the full text kept as an offline fallback
  and an "open in browser" action for the same link.
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

### Private files (repo me nahi hain)

Ye files **jaan bujh kar** git se bahar hain. Agar ye repo me hoti to koi bhi
`git clone` karke aapki tarah signed APK bana sakta tha aur `.env` ki key APK
se nikal li jaati:

| File | CI me kahan se aati hai | Laptop par |
| --- | --- | --- |
| `android/key.properties` | Actions secret `NOOR_KEY_PROPERTIES` | isi path par rakhi hai |
| `android/app/noor-release.p12` | Actions secret `NOOR_KEY_P12_B64` (base64) | isi path par rakhi hai |
| `android/app/google-services.json` | Actions secret `NOOR_GMS_JSON_B64` (base64) | isi path par rakhi hai |
| `.env` (Gemini key) | nahi aati - repo me placeholder `GEMINI_API_KEY=` hai | asli key `.env` me (skip-worktree) + `.env.local` backup |

`release.yml` ka **Reveal private build files** step inhe build se pehle
likhta hai. Secret na mile to release workflow wahin ruk jaati hai (galat key
se sign hone se pehle), aur debug build ka CI chalta rehta hai.

Secrets dobara set karne ho to:

```bash
gh auth login
gh secret set NOOR_KEY_PROPERTIES --repo mdssuu/noor-app < android/key.properties
base64 -w0 android/app/noor-release.p12     | gh secret set NOOR_KEY_P12_B64  --repo mdssuu/noor-app
base64 -w0 android/app/google-services.json | gh secret set NOOR_GMS_JSON_B64 --repo mdssuu/noor-app
```

PowerShell wale ye likh sakte hain:

```powershell
Get-Content android\key.properties -Raw | gh secret set NOOR_KEY_PROPERTIES --repo mdssuu/noor-app
[Convert]::ToBase64String([IO.File]::ReadAllBytes("android\app\noor-release.p12"))        | gh secret set NOOR_KEY_P12_B64  --repo mdssuu/noor-app
[Convert]::ToBase64String([IO.File]::ReadAllBytes("android\app\google-services.json"))    | gh secret set NOOR_GMS_JSON_B64 --repo mdssuu/noor-app
```

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

1. Open `github.com/mdssuu/noor-app` in Chrome on your phone.
2. Tap **Code** → **Codespaces** tab → **Create codespace on master**.
3. The container installs the current Flutter stable and runs `flutter pub get`
   by itself (`.devcontainer/postCreate.sh`). Wait for "Done."
4. Chrome will offer to switch to the desktop site - accept it. The editor
   needs it.

**Everyday edits:**

1. Open a file, edit it, tap the tick to commit.
2. Push from the terminal tab: `git push`
3. CI (`.github/workflows/ci.yml`) then runs `flutter analyze`, saare tests,
   aur ek debug APK artifact upload karta hai.

**Get an APK onto the phone:**

- **Automatic (recommended)** - har `master` push par
  `.github/workflows/release.yml` release APK banata hai aur GitHub ka
  **Latest APK (master)** release update kar deta hai. Seedha link:
  <https://github.com/mdssuu/noor-app/releases/download/latest/noor-masjid-time-latest.apk>
  (yahi link hamesha latest APK deta hai, kabhi nahi badalta).
- **Official version** - ek tag push karo, jaise `git tag v1.5.2 && git push origin v1.5.2`.
  Us tag ka proper GitHub Release banta hai (auto release notes + versioned
  APK file `noor-masjid-time-1.5.2+8.apk`).
- **Manual** - open **Actions** → **Release APK** → **Run workflow**. The APK
  is uploaded as an artifact instead.

> **Pehli baar install karte waqt:** phone par purani (pehle wali) app
> **ek baar uninstall** karo, phir nayi APK install karo. Signature badal
> chuka hai, isliye warna "signatures do not match" aayega. Uske baad har
> release seedha update hota rahega.
>
> **Key rotate ho chuki hai (25 Oct 2026).** Purani `noor-release.p12` +
> `key.properties` + `.env` public repo me pade the, yaani koi bhi aapki tarah
> signed APK bana sakta tha. Wo teeno ab git history se bhi nikal diye gaye
> hain aur repo me nahi aate (upar "Private files" section dekho). Nayi key
> parhelat se laptop aur CI dono par ek hi hai, isliye dono ki APK ek dusre ke
> upar install hoti hai.
>
> **Nayi key ka SHA-1 Firebase console me daalna zaroori hai** (warna Google
> Sign-In chalega hi nahi):
>
> ```
> SHA-1:    57:49:3B:88:E0:28:28:72:80:99:1A:86:9D:5D:BB:D9:C2:88:E0:50
> SHA-256:  AB:FB:F7:1C:A5:01:B4:9C:D4:3B:C0:A2:B8:AC:9E:85:32:46:52:62:B1:04:AE:E3:62:C2:43:DB:99:28:75:D4
> ```
>
> Project settings → Your apps → Android → Add fingerprint.

**Keep this laptop in the loop too:**

```powershell
.\scripts\sync.ps1   # pulls whatever you changed on GitHub back down here
```

---

## Shorebird (over-the-air updates)

`shorebird.yaml` (app_id `9983a193-6145-4bc2-8f31-ed8084125834`) repo me hai,
par ab tak kisi build me updater use nahi ho raha tha — Shorebird ke patches
us APK par lagte hain jo **Shorebird se bani ho**, aur har build plain
`flutter build apk` se banti thi. Dono workflows ab Shorebird chala sakti hain,
aur dono **opt-in** hain: jab tak secret nahi hai, bilkul wahi kaam hota hai jo
aaj hota hai.

### Ek baar setup (5 minute)

1. <https://console.shorebird.dev> par account banao aur repo ko **Import** karo
   (ya `shorebird login` → `shorebird init` chalao — `app_id` wahi rehna chahiye
   jo `shorebird.yaml` me hai, warna naya app ban jaayega).
2. Console me **Account → API Keys → Create** — key `sb_api_…` se shuru hoti hai
   aur **ek hi baar** dikhti hai.
3. GitHub par: repo **Settings → Secrets and variables → Actions → New secret**,
   naam `SHOREBIRD_TOKEN`, value wo key. (Repo me, `.env` me, kabhi bhi nahi.)

Bas. `release.yml` agla build Shorebird se karega; `shorebird releases list`
yahi releases dikhayega.

### Release vs patch — konsa kab

| Command | Kya karta hai | Kahan |
| --- | --- | --- |
| `shorebird release android` | Nayi installable baseline — usi build par aage ke patches lagte hain | `release.yml`, har `master` push par (secret hone par) |
| `shorebird patch android` | **OTA**: phone par lagi APK ko bina naye download ke update karta hai (sirf Dart) | `patch.yml`, haath se (**Actions → Shorebird OTA patch → Run workflow**) |

Release ka version **dobara upload nahi hota** (CLI “Please bump your version
number” bolta hai), isliye release har push par `--build-number <run number>`
leti hai — `pubspec.yaml` haath se badlane ki zaroorat nahi, aur versionCode
hamesha badhta rehta hai.

Patch chalane se pehle:

```bash
shorebird releases list          # kaunsa release kaunse version par hai
```

Phir **Actions → Shorebird OTA patch → Run workflow** me wo version daalo
(`1.6.1+42` — `+` ke baad wala number khud build number bana liya jaata hai).

**Dhyan:** Shorebird patches sirf **Dart** le jaate hain. `android/`, Gradle,
native plugins ya assets badalne wali push ke liye patch `--allow-native-diffs`
ke saath force mat karo — naya release chahiye (jo `release.yml` waise bhi har
push par bana deti hai). Rolling APK ka link waise bhi wahi rehta hai:
<https://github.com/mdssuu/noor-app/releases/download/latest/noor-masjid-time-latest.apk>

---

## CI status

| Workflow | Trigger | What it does |
| --- | --- | --- |
| `CI` | every push / PR to `master` | `flutter analyze` + `flutter test` + debug APK artifact |
| `Release APK` | every push to `master`, tag `v*`, or a manual run | release APK → GitHub Release (`releases/tag/latest` + versioned tags); `SHOREBIRD_TOKEN` hona to `shorebird release android` se |
| `Shorebird OTA patch` | manual run only | `shorebird patch android` → phone tak OTA update (Dart-only changes) |

> **Runner ki disk:** GitHub ke runner image me ~50 GB preinstalled tools hote
> hain (dotnet, ghc, swift, NDK). Bina hataye Flutter ka Gradle build
> *"No space left on device"* par fail hota tha. Is liye dono workflows me
> build se pehle **Free disk space** step hai, aur sirf `arm` + `arm64` ABIs
> build hoti hain (x86_64 emulator ke liye tha).
