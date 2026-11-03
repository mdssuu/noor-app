package com.sunesra_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.media.AudioAttributes
import android.os.Build
import android.provider.Settings
import android.util.Log

/**
 * The one notification a prayer is allowed to have.
 *
 * A prayer can be due twice over — the recitation and the reminder — and for
 * a while it was. When an advance notice was set, the banner landed on the
 * notice and the recitation card landed on the prayer time, so the shade
 * carried two cards for one namaz; and when the phone was on vibrate the
 * recitation was declined at the receiver and *neither* appeared, because the
 * banner had already been held back on the assumption that the recitation
 * would speak for it. One prayer, two cards, or none: all three answers were
 * wrong in different weather.
 *
 * This object is the single poster, and it decides nothing — it only renders
 * whichever state it is handed:
 *
 *  * **playing** — the recitation's own card, with `STOP AZAN` as its first
 *    action, the button a locked phone can reach without any window of ours;
 *  * **resting** — the reminder that stays after the clip ends, or stands in
 *    its place when the phone is silenced. It carries no action of its own:
 *    a card that only ever repeats what the bell already decided has
 *    nothing left to press, and the second button it used to carry was the
 *    reader's own complaint.
 *
 * Either way it is the *same* id as the `flutter_local_notifications` banner
 * for that prayer, which is what makes the two interchangeable: whichever
 * posts last replaces the other rather than joining it. The Dart side stops
 * posting altogether whenever this receiver is armed (see
 * `NotificationService.receiverOwnsTheCard`), so on a phone with a bell set
 * there is exactly one owner and no race to break the promise. The bell's
 * own state decides what the alarm carries, not who posts: a muted bell
 * arms the same alarm with the silent sentinel, and the receiver hands it
 * straight here without a byte of sound.
 *
 * The channel is the Dart side's own, `azan_reminders_v2`, and the settings
 * below mirror `_azanChannel()` exactly. Two channels would mean two entries
 * in the phone's notification settings for what is visibly one thing; a
 * mismatched creation order would be worse, because Android freezes a
 * channel's sound at the moment it is first created and the Dart side would
 * find the id already taken and leave ours in place.
 */
object PrayerCard {

    private const val TAG = "Noor/PrayerCard"

    /** `NotificationService._azanChannelId` — the reminder's own channel. */
    const val CHANNEL_ID = "azan_reminders_v2"
    private const val CHANNEL_NAME = "Azan Reminders"
    private const val CHANNEL_DESCRIPTION =
        "A reminder at each of the five daily prayer times"

    /**
     * The channel a **muted bell** posts on: the phone's own notification
     * sound, and nothing else.
     *
     * A bell on Mute asks for a reminder without a recitation, and "without a
     * recitation" must not mean "without a sound": a prayer nothing announces
     * is a prayer the reader misses. So this channel carries whatever the
     * phone already uses for its notifications — the reader's own answer to
     * "what does an alert sound like" — while the Azaan's channel stays
     * silent, because there the recitation is the sound.
     *
     * It exists as a separate id rather than as a per-notification sound
     * because Android freezes a channel's sound at creation: one channel
     * cannot be both the system sound and silence, and re-creating it would
     * be ignored on every phone that already has it.
     */
    private const val MUTED_CHANNEL_ID = "azan_muted_bell_v1"
    private const val MUTED_CHANNEL_NAME = "Azan Reminders (bell muted)"
    private const val MUTED_CHANNEL_DESCRIPTION =
        "A reminder at a prayer time whose bell is on Mute"

    private const val ACCENT = 0xFF0A4D3C.toInt()

    /**
     * Posts the prayer's card under [id], replacing whatever was there.
     *
     * Failures are logged and swallowed: a phone that refuses a notification
     * has already lost the prayer's banner, and turning that into a crash on
     * top would cost more than the card was worth.
     */
    fun show(
        context: Context,
        id: Int,
        title: String?,
        body: String?,
        playing: Boolean,
        ring: Boolean = false,
    ) {
        try {
            val manager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(id, build(context, id, title, body, playing, ring))
            // Proof the card was handed to the system, and in which state —
            // "no notification came" was otherwise indistinguishable between
            // a card that was never posted and one posted and then taken
            // down a moment later by a reschedule.
            Log.i(TAG, "card $id posted (playing=$playing)")
        } catch (error: Exception) {
            Log.w(TAG, "could not post the prayer card: ${error.message}")
        }
    }

    /**
     * The card itself, built rather than posted so the foreground service can
     * hand the very same object to `startForeground` — a service that posted
     * one thing and foregrounded another would put two cards back.
     */
    fun build(
        context: Context,
        id: Int,
        title: String?,
        body: String?,
        playing: Boolean,
        ring: Boolean = false,
    ): Notification {
        if (ring) ensureMutedChannel(context) else ensureChannel(context)

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, if (ring) MUTED_CHANNEL_ID else CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }

        return builder
            // A plain drawable, never the launcher mipmap.
            //
            // The adaptive launcher icon is not a status-bar icon: a build fan
            // answers `notify()` for it and then shows nothing at all — no
            // card, no error, no log line — which is exactly how "the Azaan
            // rings and no notification comes" survived every previous fix.
            // The lock-screen card next door has always used this drawable and
            // has always appeared; one icon, one answer.
            .setSmallIcon(R.drawable.ic_lock_moon)
            .setContentTitle(title?.takeIf { it.isNotBlank() } ?: "Prayer reminder")
            .setContentText(
                if (playing) "Azaan playing" else (body?.takeIf { it.isNotBlank() } ?: "It is time.")
            )
            .setColor(ACCENT)
            .setWhen(System.currentTimeMillis())
            .setShowWhen(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setCategory(Notification.CATEGORY_ALARM)
            .setContentIntent(tapIntent(context, id))
            // While the clip sounds the card is the record of something still
            // happening, so it is not swipeable; the moment it ends it becomes
            // a reminder again and goes with a flick like any other.
            .setOngoing(playing)
            .setAutoCancel(!playing)
            // A fresh reminder may sound once; a card that only changed its
            // wording (the clip ending, the same prayer re-posted) must not.
            .setOnlyAlertOnce(!ring)
            .apply {
                if (playing) {
                    // The screen, and then the button.
                    //
                    // A key event goes to the focused window and to nothing
                    // else. With the phone locked that window belongs to the
                    // keyguard, so an "unstoppable" Azaan was never a
                    // playback problem — it was a focus problem, and this is
                    // the part of the card that fixes it: a full-screen
                    // intent is the one launch the system still makes itself
                    // while the device is locked, and `AzaanActivity` is the
                    // window that then owns both volume keys. The permission
                    // is declared in the manifest, and Settings already
                    // offers the Android 14+ toggle for it.
                    //
                    // Without it the card still works — the rocker is
                    // watched four streams wide one layer down — but a key
                    // that moves nothing would have nothing to catch it.
                    //
                    // **But only when this app has no other way to raise
                    // that window.** A notification carrying a full-screen
                    // intent is a special object on MIUI, and a phone whose
                    // pop-up switch is off does not merely refuse the launch
                    // — it drops the *whole notification*, silently, within
                    // a hundred milliseconds of it being posted. That is the
                    // exact shape of the report this fixes: the Azaan sounds
                    // and there is no card and no popup, because the card was
                    // never allowed to exist. Where [PopUpWindows] says the
                    // window can be raised directly, the recitation service
                    // does exactly that and the card stays an ordinary card.
                    if (!PopUpWindows.allowed(context)) {
                        setFullScreenIntent(screenIntent(context, id, title), true)
                    }
                    addAction(stopAction(context))
                    // "The moment the notification goes, the Azaan goes." A
                    // swipe is the other way a reader can take the card away,
                    // and it must mean the same thing the STOP button does —
                    // otherwise the clip would keep sounding with nothing left
                    // on screen to stop it.
                    setDeleteIntent(dismissAction(context))
                }
            }
            .build()
    }

    /** Opens the app — the same thing the Dart-side tap did, minus its clip. */
    private fun tapIntent(context: Context, id: Int): PendingIntent {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: Intent(context, MainActivity::class.java).setAction(Intent.ACTION_MAIN)
        // No data on this one, deliberately. A launcher intent's filter
        // declares no `<data>`, and an intent carrying a scheme would no
        // longer match it — the card would open nothing at all. What tells
        // one prayer's tap from another's is the request code, which is part
        // of what makes two PendingIntents different objects; here every tap
        // does the same thing anyway, so the id only has to keep them apart.
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getActivity(context, id, launch, flags)
    }

    private fun stopAction(context: Context): Notification.Action {
        val stop = Intent(context, AzaanPlaybackService::class.java)
            .setAction(AzaanPlaybackService.ACTION_STOP)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        val pending = PendingIntent.getService(context, 0, stop, flags)
        return action(
            context,
            android.R.drawable.ic_menu_close_clear_cancel,
            "STOP AZAN",
            pending,
        )
    }

    /** A swipe: the same stop, minus putting the card back afterwards. */
    private fun dismissAction(context: Context): PendingIntent {
        val dismiss = Intent(context, AzaanPlaybackService::class.java)
            .setAction(AzaanPlaybackService.ACTION_DISMISS)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getService(context, 1, dismiss, flags)
    }

    /** The recitation screen — the window the volume keys are given. */
    private fun screenIntent(context: Context, id: Int, title: String?): PendingIntent {
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getActivity(context, id, AzaanActivity.launch(context, title), flags)
    }

    private fun action(
        context: Context,
        icon: Int,
        label: String,
        pending: PendingIntent,
    ): Notification.Action =
        // The resource-id spelling, on every API level. It is deprecated —
        // `Icon` took over — but it is the one overload that does not depend
        // on which package this build happens to file `Icon` under, and an
        // action is a button, not a badge: nobody has ever needed it to be
        // anything else than a drawable.
        @Suppress("DEPRECATION")
        Notification.Action.Builder(icon, label, pending).build()

    /**
     * Whether this app is allowed to show the prayer card at all.
     *
     * This is the question the recitation may be gated on: no notifications
     * enabled, or the reminder channel switched off, means the card the
     * reader needs in order to stop the clip can never appear — and a clip
     * nobody can stop is what the gate exists to prevent.
     *
     * It is deliberately *not* [isLive]. `getActiveNotifications()` answers
     * `empty` on some OEM builds (measured here: the card is live during
     * `startForeground` and the very next call, a millisecond later, reports
     * nothing), so gating a prayer on it would silently mute the app on those
     * phones. The permission answer is one the system gives honestly.
     */
    fun canShow(context: Context): Boolean = try {
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!manager.areNotificationsEnabled()) {
            false
        } else {
            val channel = manager.getNotificationChannel(CHANNEL_ID)
            channel == null || channel.importance != NotificationManager.IMPORTANCE_NONE
        }
    } catch (error: Exception) {
        Log.w(TAG, "could not read the notification switch: ${error.message}")
        true
    }

    /**
     * Whether the card for [id] is actually up in the shade right now.
     *
     * The recitation is only allowed to sound behind a card that carries the
     * `STOP AZAN` button — that is the reader's one handle on a clip that can
     * run for minutes, and an Azaan that plays with nothing to press is the
     * exact complaint this answers: "if the notification is gone, the Azaan
     * must not play at all".
     *
     * So the two questions are asked of the system rather than assumed from
     * having called `notify()`: a blocked channel, a revoked permission or a
     * reschedule that cancelled the card all answer `false` here, and all of
     * them used to leave a clip sounding with no way to stop it. Anything that
     * cannot be read answers `true` — an unreadable answer must not be the one
     * that takes a prayer away (and on API < 23 there is nothing to read).
     */
    fun isLive(context: Context, id: Int): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return try {
            val manager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val live = manager.activeNotifications
            val answer = live.any { it.id == id }
            if (!answer) {
                Log.i(
                    TAG,
                    "card $id is not up (active: ${live.joinToString(",") { "${it.id}" }})",
                )
            }
            answer
        } catch (error: Exception) {
            Log.w(TAG, "could not read the active cards: ${error.message}")
            true
        }
    }

    /**
     * The muted-bell channel: the phone's own notification sound, once.
     *
     * `IMPORTANCE_HIGH` so the reminder arrives the way a reminder should —
     * heads-up where the reader allows it — and the default notification uri
     * so it sounds like every other app on the phone rather than like this
     * one. No vibration is added on top: the sound is the announcement.
     */
    private fun ensureMutedChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(MUTED_CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                MUTED_CHANNEL_ID,
                MUTED_CHANNEL_NAME,
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = MUTED_CHANNEL_DESCRIPTION
                setSound(
                    Settings.System.DEFAULT_NOTIFICATION_URI,
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                enableVibration(false)
                setShowBadge(false)
            },
        )
        Log.i(TAG, "created the muted-bell channel $MUTED_CHANNEL_ID")
    }

    /**
     * Creates the reminder channel if nothing has yet.
     *
     * `createNotificationChannel` on an id already in place keeps the existing
     * record, so this cannot overwrite the Dart side's creation — it only
     * means the first card of the day does not depend on the app having been
     * opened since the last reboot. The settings below are `_azanChannel()`
     * spelled in Kotlin for the case where ours is the creation that counts.
     */
    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = CHANNEL_DESCRIPTION
                // Never a sound of its own: the recitation is the only thing
                // this app is allowed to make a noise with, and a second copy
                // of it arriving on the notification stream is the bug the
                // whole pipeline was rebuilt to avoid.
                setSound(null, null)
                enableVibration(true)
                enableLights(true)
                lightColor = Color.parseColor("#0A4D3C")
                setShowBadge(false)
            },
        )
        Log.i(TAG, "created the reminder channel $CHANNEL_ID")
    }
}
