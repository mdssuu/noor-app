package com.sunesra_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
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
 * for that span is what keeps it alive; the notification it must post is
 * deliberately silent and low-priority, because the recitation is the only
 * sound this app makes and nothing is allowed to compete with it.
 */
class AzaanPlaybackService : Service() {

    /** Set while a clip runs, so the lock screen and a headset can stop it. */
    private var session: MediaSession? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val sound = intent?.getStringExtra(EXTRA_SOUND)
        val stopping = intent?.action == ACTION_STOP

        if (stopping) {
            // The notification's "STOP AZAN" button lands here, from the lock
            // screen. Silence first — waiting for onDestroy() would leave a
            // beat of recitation after the tap — then retire the foreground
            // notification with it.
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

        val title = intent.getStringExtra(EXTRA_TITLE)
            ?.takeIf { it.isNotBlank() }
            ?: "Azaan"

        // Foreground first: the receiver started this with
        // startForegroundService(), which must be answered within five
        // seconds whether or not the clip then plays. The notification it
        // posts carries the full-screen intent — see buildNotification.
        try {
            val notification = buildNotification(title)
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

        // No window is raised, and that is deliberate.
        //
        // A recitation screen is what a volume key would need in order to be
        // *intercepted* — but on this device the system refuses that launch
        // outright (`Abort background activity starts`), and a popup the user
        // has to dismiss is not what an Azaan should ask of anyone anyway. The
        // rocker needs no window of ours at all: it lowers whichever stream is
        // currently sounding, and this service plays on the ringtone stream
        // precisely so that the stream it adjusts is the one the Azaan is on.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        up = false
        AzaanAudio.stop()
        releaseSession()
        super.onDestroy()
    }

    private fun finish() {
        releaseSession()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    /** The volume rocker is the mute the user reaches for; hand it to them. */
    private fun stopFromKey() {
        AzaanAudio.stop()
        finish()
    }

    /**
     * Gives the lock screen and any connected headset a way to stop the
     * recitation.
     *
     * The framework's media session carries transport controls, not volume:
     * the rocker adjusts whichever *stream* is sounding, and the Azaan plays
     * on the alarm stream on purpose — that is the one position Android
     * refuses to silence. So a volume key reaches the recitation only through
     * [MainActivity.onKeyDown], with the app in front. This session covers
     * the rest: a stop control wherever the system renders playing media, and
     * the media buttons of a headset. The "STOP AZAN" action on the
     * notification is the same handle, spelled as a notification.
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
                    override fun onMediaButtonEvent(intent: Intent): Boolean {
                        val key = keyEventFrom(intent) ?: return false
                        if (key.keyCode != KeyEvent.KEYCODE_MEDIA_STOP &&
                            key.keyCode != KeyEvent.KEYCODE_MEDIA_PAUSE &&
                            key.keyCode != KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
                        ) {
                            return false
                        }
                        stopFromKey()
                        return true
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

    private fun buildNotification(title: String): Notification {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Azaan playback",
                    // HIGH, and deliberately so. A full-screen intent is only
                    // honoured on an alerting channel: on LOW the system posts
                    // the notification quietly and *drops the full-screen part
                    // on the floor*, with no error and no log line anywhere.
                    // That is precisely how the recitation screen failed to
                    // appear over the lock screen while every other part of
                    // the pipeline reported success — the one launch no
                    // background restriction can refuse was being refused by
                    // our own channel importance. It stays silent (`setSound`
                    // below), so HIGH costs no second copy of the Azaan; what
                    // it buys is a window the volume keys can land on.
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "Present only while an Azaan is actually playing"
                    setSound(null, null)
                    enableVibration(false)
                    setShowBadge(false)
                    // Shown on the lock screen in full, however the user has
                    // configured notification privacy there. This is the stop
                    // handle that needs no window at all: the "STOP AZAN"
                    // button below stays tappable while the phone is locked,
                    // so the recitation can be ended on any device without the
                    // recitation screen ever having appeared.
                    setLockscreenVisibility(Notification.VISIBILITY_PUBLIC)
                },
            )
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        // No full-screen intent, and no popup behind it either.
        //
        // A recitation screen is what a volume key would need in order to be
        // *intercepted*, but it is also a window the user has to dismiss —
        // and on this device the system refuses to launch it at all
        // (`Abort background activity starts`). The rocker does not need one:
        // it lowers whichever stream is sounding, and the Azaan sounds on the
        // ringtone stream for exactly that reason. What is left here is a
        // quiet record that the Azaan is playing, and the one button below it.
        return builder
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(title)
            .setContentText("Azaan playing")
            .setOngoing(true)
            .setShowWhen(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            // An alarm, not a message: the system treats it as one — shown on
            // the lock screen, counted with the alarms, and offered the same
            // dismissal behaviour every alarm app gets.
            .setCategory(Notification.CATEGORY_ALARM)
            .addAction(stopAzanAction())
            .build()
    }

    /**
     * "STOP AZAN" on the playback notification — the only handle that reaches
     * the recitation when the phone is locked or the app is nowhere on screen.
     *
     * The intent is deliberately a plain service start rather than
     * `startForegroundService()`: this notification only exists while the
     * service is already in the foreground, so the background-start
     * restrictions do not apply, and the ACTION_STOP branch never has to
     * satisfy the "call startForeground() within five seconds" contract.
     */
    private fun stopAzanAction(): Notification.Action {
        val stop = Intent(this, AzaanPlaybackService::class.java).setAction(ACTION_STOP)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        val pending = PendingIntent.getService(this, NOTIFICATION_ID, stop, flags)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Notification.Action.Builder(
                Icon.createWithResource(this, android.R.drawable.ic_menu_close_clear_cancel),
                "STOP AZAN",
                pending,
            ).build()
        } else {
            // Pre-M has no Icon overload of the builder; the resource id is
            // the only spelling that works there.
            @Suppress("DEPRECATION")
            Notification.Action.Builder(
                android.R.drawable.ic_menu_close_clear_cancel,
                "STOP AZAN",
                pending,
            ).build()
        }
    }

    companion object {
        const val ACTION_PLAY = "com.sunesra_app.action.PLAY_AZAAN_SERVICE"
        const val ACTION_STOP = "com.sunesra_app.action.STOP_AZAAN_SERVICE"
        const val EXTRA_SOUND = "sound"
        const val EXTRA_TITLE = "title"

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
         * Silence first, then retire the service so its "STOP AZAN"
         * notification goes with it. The service is asked to stand down with a
         * plain `startService()`, never `startForegroundService()`: the
         * ACTION_STOP branch never enters the foreground, and the latter would
         * have the process killed for not doing so within five seconds.
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
         * A new id, not a new setting on the old one.
         *
         * A channel's importance is set once and then belongs to the system:
         * on this device `azaan_playback` has stayed at `mImportance=2` no
         * matter that the app later asked for HIGH — the dumpsys output says
         * `mUserLockedFields=0`, so no user did it, and yet the value would
         * not move. Every attempt to upgrade it in place was being ignored,
         * which is how a full-screen intent kept being dropped on a channel
         * the code believed was alerting. An id the system has never seen is
         * the one thing it cannot have an old opinion about.
         */
        private const val CHANNEL_ID = "azaan_playback_v2"
        private const val NOTIFICATION_ID = 900001
    }
}
