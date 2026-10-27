# Privacy Policy — Noor • Masjid Time

**Effective date: 26 October 2026**
**Developer: Mohammad Siddique Sunesra — mdsunesra@gmail.com**

This policy is the same text the app shows, kept here as the public, permanent copy:
<https://github.com/mdssuu/noor-app/blob/master/docs/privacy.md>

Noor • Masjid Time (the “app”) is a community prayer-time app. It has **no advertising
SDK, no analytics SDK, no tracking pixel and no account database of its own** beyond the
one described below. Everything the app does with your data is listed here.

---

## 1. Location (GPS)

Your position is read **on this device only**, and only to:

- sort the *Nearby Masjids* list nearest-first,
- compute the prayer times for where you are,
- measure the distance badge (“800m away”).

Your coordinates are **never sent to a server**. Distance to each masjid is computed
locally with the haversine formula.

## 2. What is written to the shared database

Masjid data is stored in **Cloud Firestore** so that everyone nearby sees the same board:

| Field | Why |
|---|---|
| Masjid name | shown in the list to everyone nearby |
| The five prayer times + Juma | the whole point of the app |
| Location (lat/lng) of the masjid | distance, map pin, prayer times |
| Board photo (small compressed copy, under 450 KB) | proof that the times were read off a real board |
| Your **display name** and **profile picture** | attributed to the update you submitted |

Nothing else about you is written to Firestore. Your email, your password (there is none —
you sign in with Google), your device id and your contacts are never stored there.

If you edit a masjid's name, the **original spelling is kept** in the document
(`originalName`) together with who edited it and when, so a bad edit can be reverted.

## 3. Camera and the board photo

The photo you take is used to read the prayer times. **It is read on your device first**
with Google's ML Kit text recognition, which runs offline and sends nothing anywhere.

If — and only if — a Gemini API key has been configured by the app owner, the photo is
also sent **once** to Google so the Juma column can be read more reliably. With no key
configured (the default, and what every public download of the app ships with) the photo
**never leaves your phone**.

The compressed copy stored in Firestore is under 450 KB precisely so no separate image
host is needed.

## 4. Search

Finding a city or a place uses **OpenStreetMap's Nominatim and Overpass** — free,
accountless, and used according to their fair-use policy. No identifier is attached to
those requests beyond the query itself.

## 5. Sign-in

Sign-in is **Google Sign-In** (`firebase_auth` + `google_sign_in`). Google shares only
your name, your email address and your avatar with the app. The app never sees your
Google password, and Firebase issues an anonymous sign-in for readers who prefer not to
use Google at all.

## 6. Notifications and reminders

Azan reminders, the favourite-masjid alerts, the snoozes and every setting behind them
live in **local storage on your phone** (SharedPreferences + the Android alarm ledger).
They are not synced anywhere, and they are removed when you uninstall the app.

The app posts a local notification. It does not register with FCM for push messages, so
there is no push token leaving the device.

## 7. Permissions the app asks for

- **Location** — for the nearby list and prayer times (see §1).
- **Camera** — to photograph the board (see §3).
- **Notifications** — to show the prayer reminder (Android 13+ asks explicitly).
- **Exact alarm** — so the reminder fires at the exact second you chose. It is used for
  your own reminders only.
- **Internet** — for Firestore, OSM search and (only if configured) Gemini.
- **Vibrate / full-screen intent / battery-optimisation exemption** — so the recitation
  can sound over the lock screen the way an alarm does.

## 8. What the app does *not* do

- No advertising, no ad network, no fingerprinting.
- No analytics or crash-reporting SDK.
- No selling, renting or sharing of personal data with third parties.
- No reading of your contacts, SMS, files or other apps' data.

## 9. Children

The app is suitable for general audiences and collects no data from children knowingly.
A guardian can use it without signing in at all — anonymous sign-in works fully.

## 10. Your choices

- You can sign out from the Profile tab; your favourites and settings for that profile
  stay on your device.
- You can deny location permission and still use the app with a searched city.
- You can deny notifications and the app still shows every time on screen.
- Uninstalling the app removes all local data.

## 11. Changes

Any change to this policy is committed to
[`docs/privacy.md`](https://github.com/mdssuu/noor-app/blob/master/docs/privacy.md)
in the app's public repository, with the date of the change. The copy inside the app is
loaded from that same file.

## 12. Contact

Questions, or a request to delete your submission:
**mdsunesra@gmail.com** — or open an issue at
<https://github.com/mdssuu/noor-app/issues>.
