package com.sunesra_app

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import java.io.File
import java.util.concurrent.CopyOnWriteArraySet

/**
 * Plays the Azaan clip, on the **ringtone** stream.
 *
 * The clip comes from one of two places, and the choice is made here so that
 * every caller keeps asking the same question:
 *
 *  * a file in the app's private files directory — `azaan_<sound>.clip`,
 *    downloaded from the URL the app's owner set in the admin panel. The
 *    alarm path needs exactly this: it plays with the app closed, so the
 *    clip has to be reachable by path, with no Dart isolate to ask.
 *  * the bundled `res/raw` clip of the same name, which takes the slot back
 *    the moment there is no file — a broken link costs the owner their
 *    custom clip, never a user's Azaan.
 *
 * The reminder notification itself posts with no sound; the recitation is the
 * only sound this app makes. One player also means one thing to stop —
 * [AzaanPlaybackService] wraps this in a foreground service and a media
 * session, and both the volume keys and the notification's stop action come
 * down to [stop].
 *
 * The stream is the whole feature, and it is the ringtone one deliberately.
 * See [watchStreamVolume] for why the alarm stream could never be silenced.
 */
object AzaanAudio {

    private const val TAG = "Noor/AzaanAudio"

    /** `filesDir/azaan_<sound>.clip`, where a downloaded clip is kept. */
    fun cachedClip(context: Context, sound: String): File =
        File(context.applicationContext.filesDir, "azaan_$sound.clip")

    /**
     * How often the alarm volume is asked about while a recitation sounds.
     *
     * Slow enough to be free next to a recitation that already holds a wake
     * lock, fast enough that a keypress feels answered the moment the finger
     * lets go.
     */
    private const val POLL_INTERVAL_MS = 1_000L

    private var player: MediaPlayer? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var volumePoll: Runnable? = null

    /** Set by MainActivity so a preview can drop its "playing" highlight. */
    @Volatile
    var onFinished: (() -> Unit)? = null

    /** Anything that must close when the clip ends — the recitation screen. */
    val endListeners: CopyOnWriteArraySet<() -> Unit> = CopyOnWriteArraySet()

    /** The run is over, however it ended. */
    private fun notifyEnded() {
        onFinished?.invoke()
        for (listener in endListeners) listener()
    }

    /** True while a clip is actually sounding, so two runs never overlap. */
    @Synchronized
    fun isPlaying(): Boolean = try {
        player?.isPlaying == true
    } catch (_: Exception) {
        false
    }

    /**
     * Starts [sound] at the ringtone volume — the one volume the rocker can
     * actually reach. Returns false when the resource is missing or the
     * decoder refuses it, so callers can fall back rather than report success
     * for silence. [onStopped] fires when the clip finishes or errors out —
     * the foreground service uses it to retire itself.
     */
    @Synchronized
    fun play(context: Context, sound: String, onStopped: (() -> Unit)? = null): Boolean {
        val app = context.applicationContext

        // The owner's clip first. A file sitting in filesDir *is* the answer
        // to "what should sound", and unlike a Dart-side player it is
        // reachable with the app not running — which is the whole case for
        // an alarm. A missing, empty or undecodable file falls through to the
        // bundled resource rather than to silence.
        val cached = cachedClip(app, sound)
        val downloaded = cached.isFile && cached.length() > 0L
        val resId = if (downloaded) {
            0
        } else {
            app.resources.getIdentifier(sound, "raw", app.packageName)
        }
        if (!downloaded && resId == 0) {
            Log.w(TAG, "no downloaded clip for $sound and no res/raw/$sound — nothing to play")
            notifyEnded()
            return false
        }

        stopLocked()

        val mp = MediaPlayer()
        try {
            mp.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            if (downloaded) {
                mp.setDataSource(cached.absolutePath)
            } else {
                val descriptor = app.resources.openRawResourceFd(resId)
                    ?: throw IllegalStateException("no seekable descriptor for $sound")
                mp.setDataSource(descriptor.fileDescriptor, descriptor.startOffset, descriptor.length)
                descriptor.close()
            }
            mp.prepare()
        } catch (error: Exception) {
            Log.e(TAG, "cannot play $sound: $error")
            try {
                mp.release()
            } catch (_: Exception) {
            }
            notifyEnded()
            return false
        }

        // A recitation runs for minutes and the screen will be off; the CPU
        // must not be allowed to sleep under the playback.
        val power = app.getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "noor:azaan").apply {
            setReferenceCounted(false)
            acquire(mp.duration.toLong() + 60_000L)
        }

        mp.setOnCompletionListener {
            release()
            onStopped?.invoke()
            notifyEnded()
        }
        mp.setOnErrorListener { _, _, _ ->
            Log.w(TAG, "playback error for $sound")
            release()
            onStopped?.invoke()
            notifyEnded()
            true
        }

        player = mp
        mp.start()
        Log.i(
            TAG,
            if (downloaded) {
                "recitation on the ringtone stream — the owner's clip for $sound"
            } else {
                "recitation on the ringtone stream"
            }
        )
        watchStreamVolume(app)
        return true
    }

    /**
     * Notices the rocker being touched at all, and ends the recitation.
     *
     * The stop condition is **any fall from where the level started**, not the
     * stream's floor. Waiting for zero looked tidy and was the wrong question:
     * the alarm stream has no zero to reach — it bottoms out at 3 without an
     * app-op and 1 with one, so "stop at silence" is a promise the rocker
     * physically cannot keep there. And even on the ringtone stream, where the
     * floor is genuinely zero, getting from 15 down to it is fifteen presses.
     * Nobody holds a volume key for fifteen steps to make a sound stop; they
     * press once and expect it gone. Reading *any* drop as that press is what
     * makes one button do what a person already believes it does.
     *
     * It is polled, not observed, and that is not laziness. The obvious
     * observer — a [ContentObserver] on the `volume_alarm` settings row —
     * reports a different number from the one the stream actually uses: on
     * the device this was written against the row read 8 while the alarm
     * stream was playing at 10. The row is a stale copy that this build never
     * refreshes, so a watcher parked on it waits for a change the rocker's
     * own handling never sends. Asking [AudioManager] directly answers the
     * only question that matters, on every OEM, once a second — a price worth
     * paying for a recitation that already holds a wake lock.
     */
    private fun watchStreamVolume(context: Context) {
        val app = context.applicationContext
        stopWatchingStreamVolume()
        val audio = try {
            app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        } catch (_: Exception) {
            return
        }
        // Where the rocker stood when the Azaan began. The Azaan starting is
        // the one thing that must not count as a press, so the comparison
        // starts from the level the playback itself was born at.
        val startLevel = try {
            audio.getStreamVolume(AudioManager.STREAM_RING)
        } catch (_: Exception) {
            return
        }
        val handler = Handler(Looper.getMainLooper())
        val poll = object : Runnable {
            override fun run() {
                if (player == null) return
                val level = try {
                    audio.getStreamVolume(AudioManager.STREAM_RING)
                } catch (_: Exception) {
                    return
                }
                if (level >= startLevel) {
                    handler.postDelayed(this, POLL_INTERVAL_MS)
                    return
                }
                Log.i(TAG, "ringtone volume dropped $startLevel → $level — stopping the recitation")
                stop()
            }
        }
        volumePoll = poll
        handler.postDelayed(poll, POLL_INTERVAL_MS)
    }

    private fun stopWatchingStreamVolume() {
        val poll = volumePoll ?: return
        volumePoll = null
        try {
            Handler(Looper.getMainLooper()).removeCallbacks(poll)
        } catch (_: Exception) {
        }
    }

    @Synchronized
    fun stop() = stopLocked()

    private fun stopLocked() {
        val old = player
        player = null
        if (old != null) {
            // The one line that proves a stop actually reached the player —
            // whether it came from a volume key, the recitation screen, the
            // notification action or the end of the clip itself.
            Log.i(TAG, "recitation stopped (player torn down)")
            try {
                if (old.isPlaying) old.stop()
            } catch (_: Exception) {
            }
            try {
                old.reset()
            } catch (_: Exception) {
            }
            try {
                old.release()
            } catch (_: Exception) {
            }
        }
        release()
    }

    private fun release() {
        // The run is over, so the stream is no longer ours to watch — a
        // watcher left behind would keep waking a stopped app to ask a
        // question it no longer has any use for the answer to.
        stopWatchingStreamVolume()
        val held = wakeLock
        wakeLock = null
        if (held?.isHeld == true) {
            try {
                held.release()
            } catch (_: Exception) {
            }
        }
    }
}
