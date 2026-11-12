package com.sunesra_app

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import android.view.KeyEvent

/**
 * Holds the Azaan while it plays with no activity on screen.
 *
 * A recitation lasts minutes, and a process that only answered a broadcast is
 * a prime candidate for being trimmed mid-way through. Being in the foreground
 * for that span is what keeps it alive; the notification it must post is the
 * prayer's own card — [PrayerCard], one per prayer, never two — and it is
 * silent, because the recitation is the only sound this app makes and nothing
 * is allowed to compete with it.
 */
class AzaanPlaybackService : Service() {

    /** Set while a clip runs, so the lock screen and a headset can stop it. */
    private var session: MediaSession? = null

    /**
     * The prayer this run speaks for, carried so the card can be handed back
     * when the clip ends.
     *
     * The id is the prayer's own — the number [PrayerCard] and the Dart side
     * both use — because the foreground notification *is* the prayer's card,
     * not a second one the service brings of its own. `NOTIFICATION_ID` is
     * only the fallback for a start that arrived with no id to be had.
     */
    private var cardId: Int = NOTIFICATION_ID
    private var cardTitle: String? = null
    private var cardBody: String? = null

    /**
     * Minutes the phone stays on vibrate once this recitation ends — the
     * reader's "Silence after Azaan" choice, carried by the alarm that
     * started this service.
     *
     * 0 (never) until a PLAY intent says otherwise. A STOP that follows
     * carries no such extra and must not clear the window the clip it
     * stopped asked for, which is why the value is only taken when present.
     */
    private var silentMinutes: Int = 0

    /**
     * True once a clip actually sounded under this instance.
     *
     * The quiet window belongs to a recitation that *happened*: a service
     * retired before the player took the field — no card, no clip, a ringer
     * that said no — must leave the phone's ringer exactly as it found it.
     */
    private var recited = false

    /** True once this instance has actually entered the foreground. */
    private var foregrounded = false

    /** True once this instance has taken a prayer under its care. */
    private var started = false

    /** False once the card was dismissed by the reader, who wants no card. */
    private var keepCard = true

    /** Set the moment the card is handed back, so no path posts it twice. */
    private var retired = false

    /**
     * Watches the card the recitation is standing behind.
     *
     * A clip with no notification is a clip nobody can stop, so the two are
     * kept together for their whole life, not just at the start: if the card
     * is taken out of the shade — by the reader, by a reschedule, by an OEM
     * clearing the tray — the sound goes with it. That is the plain read of
     * "until a notification with a stop button is there, the Azaan must not
     * play", and it is also the only state in which the `STOP AZAN` button
     * and the lock screen's own window can be reached.
     */
    private val cardWatch = object : Runnable {
        override fun run() {
            if (!PrayerCard.isLive(this@AzaanPlaybackService, cardId)) {
                Log.i(TAG, "card $cardId is gone — stopping the recitation")
                stopFromKey()
                return
            }
            guard.postDelayed(this, CARD_WATCH_MS)
        }
    }

    private val guard = Handler(Looper.getMainLooper())

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val sound = intent?.getStringExtra(EXTRA_SOUND)
        val stopping = intent?.action == ACTION_STOP
        val dismissing = intent?.action == ACTION_DISMISS

        if (dismissing) {
            // The reader swiped the card away. That is the same request as
            // STOP AZAN, with one difference: the card is already gone, so
            // handing it back afterwards would put a reminder on screen the
            // reader has just dismissed.
            keepCard = false
            AzaanAudio.stop()
            finish()
            return START_NOT_STICKY
        }

        if (stopping) {
            // The notification's "STOP AZAN" button lands here, from the lock
            // screen. Silence first — waiting for onDestroy() would leave a
            // beat of recitation after the tap — then hand the card back to
            // its resting state.
            AzaanAudio.stop()
            finish()
            return START_NOT_STICKY
        }

        if (sound.isNullOrEmpty() || sound == "silent") {
            finish()
            return START_NOT_STICKY
        }

        // From here on the service exists to hold a recitation, so a stop
        // request is worth sending to it.
        up = true

        cardTitle = intent?.getStringExtra(EXTRA_TITLE)?.takeIf { it.isNotBlank() } ?: "Azaan"
        cardBody = intent?.getStringExtra(EXTRA_BODY)
        (intent?.getIntExtra(EXTRA_ID, -1) ?: -1).let { id -> if (id >= 0) cardId = id }
        // Present only on the PLAY intent that asked for a window; a STOP
        // arriving mid-clip must not zero out the one the clip asked for.
        (intent?.getIntExtra(EXTRA_SILENT, -1) ?: -1).let { silent ->
            if (silent >= 0) silentMinutes = silent
        }

        // Foreground first: the receiver started this with
        // startForegroundService(), which must be answered within five
        // seconds whether or not the clip then plays.
        //
        // The card it posts is [PrayerCard]'s, under the *prayer's* own id —
        // the same number the reminder would have used. That is what makes
        // this one card rather than two: whichever posts last replaces the
        // other, and the Dart side does not post at all while a clip is
        // armed, so there is only ever this one.
        //
        // The foreground notification is deliberately **not** the prayer's
        // card, and that is the fix behind "the Azaan plays but the
        // notification is not there". A foreground-service notification is a
        // thing the *system* manages: it is cancelled the instant the service
        // is told to stand down, and on some OEM builds it is cancelled on its
        // own within the same second (`Cancel FGS notification … Id:3`). While
        // both were one object, that cancellation took the card — and with it
        // the only STOP button — down, leaving the recitation sounding with
        // nothing on screen. Two objects, one job each: this one keeps the
        // process alive and comes and goes with it, the card is posted by the
        // receiver and belongs to the prayer.
        try {
            val notification = foregroundNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
                )
            } else {
                @Suppress("DEPRECATION")
                startForeground(NOTIFICATION_ID, notification)
            }
            foregrounded = true
            started = true
            Log.i(
                TAG,
                "foreground up for $cardId (live: " +
                    (getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager)
                        .activeNotifications.joinToString(",") { "${it.id}" } +
                    ")",
            )
        } catch (error: Exception) {
            // Not fatal: the clip matters more than the foreground status.
            Log.w(TAG, "could not enter foreground: ${error.message}")
        }

        // No card, no clip. `startForeground` can be refused outright — a
        // revoked grant, an OEM rule — and the receiver's own post can be
        // cancelled before this service is up. Either way the recitation would
        // run with nothing to press, so it does not run at all.
        if (!PrayerCard.canShow(this)) {
            Log.w(TAG, "notifications are off — no card, so no recitation")
            finish()
            return START_NOT_STICKY
        }

        // The service outlives the clip: either the decoder hands back
        // control when the recitation ends, or it never started at all.
        startSession()
        val playing = AzaanAudio.play(this, sound) { finish() }
        if (!playing) {
            finish()
            return START_NOT_STICKY
        }
        // The player took the field: from here on, this instance owns a
        // recitation — and the quiet window that follows one.
        recited = true

        // The card and the clip now live and die together — but only where
        // the phone can answer the question. `getActiveNotifications()`
        // answers `empty` on some OEM builds even for a card that is up, and
        // a watcher that believed that would stop every Azaan a second after
        // it began. So it is armed only if the first answer was the honest
        // one; everywhere else the foreground service (which the system cannot
        // dismiss) is the guarantee instead.
        if (PrayerCard.isLive(this, cardId)) {
            guard.postDelayed(cardWatch, CARD_WATCH_MS)
        } else {
            Log.i(TAG, "this phone cannot report its own cards — card watcher off")
        }

        raiseScreen()

        // A window *is* raised, and that is the point.
        //
        // Android hands a key event to the focused window and to nothing
        // else, so with the keyguard up there is no window of ours to catch a
        // rocker press — which is exactly why an "unstoppable" Azaan was
        // never a playback problem, it was a focus problem. The card's
        // full-screen intent is what puts [AzaanActivity] over the lock
        // screen; there it owns both volume keys, offers a STOP AZAN button,
        // and closes itself the moment the clip does. An earlier version
        // raised it with a plain `startActivity` and the system refused it
        // outright (`Abort background activity starts`); a full-screen intent
        // is the one launch Android still makes itself.
        //
        // For the phone that is unlocked with some other app in front — a
        // full-screen intent does not reach that one — [AzaanAudio] watches
        // every stream a key could move and reads any change as the press.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        up = false
        AzaanAudio.stop()
        // A service killed from under the clip never reaches finish() by the
        // usual road, so the card is handed back from here too — guarded, so
        // the normal exit does not post it a second time.
        finish()
        super.onDestroy()
    }

    /**
     * The pinned "an Azaan is running" line, owned by the service alone.
     *
     * Silent, because the recitation is the only sound this app makes, and
     * deliberately separate from [PrayerCard]'s id so a system that cancels a
     * foreground notification cannot cancel the prayer with it.
     */
    private fun foregroundNotification(): android.app.Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            android.app.Notification.Builder(this, PrayerCard.CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            android.app.Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.drawable.ic_lock_moon)
            .setContentTitle(cardTitle ?: "Azaan")
            .setContentText("Azaan playing")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(android.app.Notification.CATEGORY_SERVICE)
            .build()
    }

    /**
     * Hands the prayer's card back and retires the service.
     *
     * **Detach**, never remove. The card belongs to the prayer and has to
     * outlive the clip that stood in for it — the reader asked to be told at
     * Maghrib, and a recitation that ended must not take the telling with it.
     * What changes is the one thing that was temporary about it: the
     * `STOP AZAN` action goes with the playback, and the resting card carries
     * no action at all.
     *
     * Nothing is posted at all when this instance never entered the
     * foreground: a stop that arrived before a clip existed would otherwise
     * conjure a card for a prayer nothing has happened to.
     */
    private fun finish() {
        Log.i(TAG, "retiring (foregrounded=$foregrounded, retired=$retired)")
        guard.removeCallbacks(cardWatch)
        releaseSession()
        if (!retired) {
            retired = true
            // The recitation is over — hand the phone its quiet window, if
            // this prayer asked for one. Guarded by `recited`: a service
            // that never heard a clip must not silence a ringer nobody
            // rang, and `retired` keeps the window to exactly one start
            // however many roads reach this method.
            if (recited && silentMinutes > 0) {
                RingerSilence.engage(this, silentMinutes)
            }
            if (foregrounded) {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            // The prayer's card outlives the clip — that is the promise a
            // reminder makes — unless the reader took it away themselves.
            if (started && keepCard) {
                PrayerCard.show(
                    applicationContext,
                    cardId,
                    cardTitle,
                    cardBody,
                    playing = false,
                )
            }
        }
        stopSelf()
        up = false
    }

    /**
     * Puts [AzaanActivity] up, from here rather than from the card.
     *
     * The card used to carry the launch as a full-screen intent, and on a
     * phone that also has its own pop-up switch that was actively harmful:
     * MIUI reads a full-screen intent as a request for a pop-up it may not
     * have granted, and answers by removing the notification outright — the
     * Azaan then played with no card and no window, which is precisely the
     * complaint. Where [PopUpWindows] says a window may be raised (the
     * overlay grant, or MIUI's own switch), it is raised here instead, and the
     * card stays a plain notification nobody has any reason to take down.
     *
     * A launch that is refused is logged and survivable: the card is still in
     * the shade with its `STOP AZAN` button, and the rocker is watched one
     * layer down, so only the on-screen button is lost — not the control.
     */
    private fun raiseScreen() {
        if (!PopUpWindows.allowed(this)) return
        try {
            startActivity(AzaanActivity.launch(this, cardTitle))
            Log.i(TAG, "recitation screen raised directly")
        } catch (error: Exception) {
            Log.w(TAG, "could not raise the recitation screen: ${error.message}")
        }
    }

    /** The volume rocker is the mute the user reaches for; hand it to them. */
    private fun stopFromKey() {
        AzaanAudio.stop()
        finish()
    }

    /**
     * Gives a headset, the lock screen's transport controls and the media
     * button of anything else that is playing a part a way to stop the
     * recitation.
     *
     * It is deliberately **not** where the volume rocker is answered. The
     * framework's `MediaSession` offers two flags and neither of them is
     * volume: `FLAG_HANDLES_MEDIA_VOLUME` is a `MediaSessionCompat` idea that
     * this class cannot use, and there is no `onAdjustVolume` to override. So
     * the rocker has two roads of its own, both outside this session:
     *
     *  * [AzaanActivity], raised by the card's full-screen intent, is the
     *    focused window a key event actually goes to — that is the road that
     *    answers *strictly*, because it catches the press even when the key
     *    would otherwise change nothing at all;
     *  * [AzaanAudio.watchStreamVolume], for the unlocked phone in front of
     *    some other app, reads every stream a key could move and treats any
     *    movement as the press.
     *
     * This session covers the rest — pause, stop, and the transport controls
     * a connected headset or a lock-screen widget renders.
     */
    private fun startSession() {
        releaseSession()
        try {
            val media = MediaSession(this, "NoorAzaan").apply {
                setFlags(
                    MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or
                        MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS,
                )
                setCallback(object : MediaSession.Callback() {
                    override fun onPause() = stopFromKey()

                    override fun onStop() = stopFromKey()

                    // Some builds dispatch a key press here rather than to
                    // the transport methods; stop is what was asked for.
                    //
                    // The volume keys belong here too, and that is the whole
                    // of the "the rocker dies with the screen off" report.
                    // With the display *on*, a focused window of ours
                    // ([AzaanActivity], or [MainActivity] for a preview) gets
                    // the key first and answers it. The instant the screen
                    // goes fully off, no window of any app holds input focus
                    // — so `onKeyDown` never runs — and because this session
                    // handles media buttons, the system hands the press here
                    // instead, as a media-button event. Left returning `false`
                    // it went unanswered *and* never touched a stream, which
                    // is why [AzaanAudio.watchStreamVolume] saw nothing
                    // either: two roads, both silent, and the recitation was
                    // left running over a locked phone. The rocker is the
                    // mute the reader reaches for; it is off, strictly.
                    override fun onMediaButtonEvent(intent: Intent): Boolean {
                        val key = keyEventFrom(intent) ?: return false
                        when (key.keyCode) {
                            KeyEvent.KEYCODE_MEDIA_STOP,
                            KeyEvent.KEYCODE_MEDIA_PAUSE,
                            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
                            KeyEvent.KEYCODE_VOLUME_DOWN,
                            KeyEvent.KEYCODE_VOLUME_UP,
                            -> {
                                stopFromKey()
                                return true
                            }
                            else -> return false
                        }
                    }

                    private fun keyEventFrom(intent: Intent): KeyEvent? =
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT, KeyEvent::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
                        }
                })
                setPlaybackState(
                    PlaybackState.Builder()
                        .setActions(PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_STOP)
                        .setState(PlaybackState.STATE_PLAYING, 0, 1f)
                        .build(),
                )
                isActive = true
            }
            session = media
        } catch (error: Exception) {
            // The notification's stop action still covers this case.
            Log.w(TAG, "no media session for the recitation: ${error.message}")
        }
    }

    private fun releaseSession() {
        val held = session
        session = null
        if (held == null) return
        try {
            held.isActive = false
        } catch (_: Exception) {
        }
        try {
            held.release()
        } catch (_: Exception) {
        }
    }

    // The notification is no longer built here.
    //
    // It used to be: this service owned a card of its own ("Azaan playing",
    // id 900001, channel `azaan_playback_v2`) while the reminder belonged to
    // the Dart side — two cards for one prayer whenever an advance notice was
    // set, and, when the recitation was declined for a silenced phone,
    // neither. [PrayerCard] is the single owner now and this service only
    // hands it a state: `playing` while the clip runs, resting the moment it
    // ends.

    companion object {
        const val ACTION_PLAY = "com.sunesra_app.action.PLAY_AZAAN_SERVICE"
        const val ACTION_STOP = "com.sunesra_app.action.STOP_AZAAN_SERVICE"

        /** The card was swiped away: stop, and do not put it back. */
        const val ACTION_DISMISS = "com.sunesra_app.action.DISMISS_AZAAN_SERVICE"
        const val EXTRA_SOUND = "sound"
        const val EXTRA_TITLE = "title"

        /** The reminder's own line, so the card can say what the banner did. */
        const val EXTRA_BODY = "body"

        /**
         * Minutes the phone stays on vibrate once this recitation ends —
         * the reader's "Silence after Azaan" choice, handed over by
         * [AzaanAlarmReceiver] and spent by [RingerSilence.engage] in
         * [finish]. Absent on STOP/DISMISS intents, which must not clear
         * the window the clip they stopped asked for.
         */
        const val EXTRA_SILENT = "silentMinutes"

        /**
         * The prayer this run is for — the id the card is posted under.
         *
         * It arrives from the alarm, which took it from the Dart side, which
         * allocates the same numbers to `flutter_local_notifications`. One
         * number, one prayer, one card.
         */
        const val EXTRA_ID = "id"

        /**
         * Set while an instance is actually up holding a recitation.
         *
         * It exists to keep a stop from being *dispatched* when there is
         * nothing to stop. `startService(ACTION_STOP)` on a service that is
         * not running does not stop anything: it creates one, and that fresh
         * instance's first act is `AzaanAudio.stop()` — arriving a beat after
         * it was asked for, on whatever has started playing in between. The
         * Settings preview's own stop went through here, which is how a clip
         * could be started and then torn down 20 ms later, every single time.
         */
        @Volatile
        private var up = false

        /**
         * Brings the recitation down wherever it is sounding, from any
         * context — the recitation screen, the activity's volume key handler,
         * the playback notification.
         *
         * Silence first, then retire the service. The prayer's card stays
         * behind it in its resting form — what goes is the `STOP AZAN`
         * action, which belonged to a clip that is no longer running.
         * The service is asked to stand down with a plain `startService()`,
         * never `startForegroundService()`: the ACTION_STOP branch never
         * enters the foreground, and the latter would have the process killed
         * for not doing so within five seconds.
         */
        fun stopFromAnywhere(context: Context) {
            if (!up) return
            AzaanAudio.stop()
            val app = context.applicationContext
            val intent = Intent(app, AzaanPlaybackService::class.java).setAction(ACTION_STOP)
            try {
                app.startService(intent)
            } catch (_: Exception) {
                // Android refuses a service start once the app is backgrounded;
                // stopService() still brings the player down through onDestroy().
                try {
                    app.stopService(Intent(app, AzaanPlaybackService::class.java))
                } catch (_: Exception) {
                }
            }
        }

        private const val TAG = "Noor/AzanService"

        /** How often the card behind the clip is looked for. */
        private const val CARD_WATCH_MS = 1_000L

        /**
         * The fallback card id, for a start that arrived with no prayer to
         * name.
         *
         * Every path that matters carries [EXTRA_ID]; this is only so a
         * foreground service can never be entered with an id of -1, which the
         * system would not accept.
         */
        private const val NOTIFICATION_ID = 900001
    }
}
