package com.sunesra_app

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.IBinder
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

    /** True once this instance has actually entered the foreground. */
    private var foregrounded = false

    /** Set the moment the card is handed back, so no path posts it twice. */
    private var retired = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val sound = intent?.getStringExtra(EXTRA_SOUND)
        val stopping = intent?.action == ACTION_STOP

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

        // Foreground first: the receiver started this with
        // startForegroundService(), which must be answered within five
        // seconds whether or not the clip then plays.
        //
        // The card it posts is [PrayerCard]'s, under the *prayer's* own id —
        // the same number the reminder would have used. That is what makes
        // this one card rather than two: whichever posts last replaces the
        // other, and the Dart side does not post at all while a clip is
        // armed, so there is only ever this one.
        try {
            val notification =
                PrayerCard.build(this, cardId, cardTitle, cardBody, playing = true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    cardId,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
                )
            } else {
                @Suppress("DEPRECATION")
                startForeground(cardId, notification)
            }
            foregrounded = true
        } catch (error: Exception) {
            // Not fatal: the clip matters more than the foreground status.
            Log.w(TAG, "could not enter foreground: ${error.message}")
        }

        // The service outlives the clip: either the decoder hands back
        // control when the recitation ends, or it never started at all.
        startSession()
        val playing = AzaanAudio.play(this, sound) { finish() }
        if (!playing) {
            finish()
            return START_NOT_STICKY
        }

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
        releaseSession()
        if (!retired) {
            retired = true
            if (foregrounded) {
                @Suppress("DEPRECATION")
                stopForeground(false)
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
        const val EXTRA_SOUND = "sound"
        const val EXTRA_TITLE = "title"

        /** The reminder's own line, so the card can say what the banner did. */
        const val EXTRA_BODY = "body"

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
