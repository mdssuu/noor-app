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
 * Plays the Azaan clip, on the **ringtone** stream — the reader's own ringer.
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
 * The stream is the ringer's own, and that is the reader's decision, not the
 * app's: one slider then sets how loud a prayer is allowed to be, and it is
 * the slider the volume keys move, so the rocker is already pointing at
 * whatever is sounding. It used to be `USAGE_ALARM` — loud, and deliberately
 * deaf to the rocker — which is why "the volume button cannot stop it" had to
 * be answered twice over, by [watchStreamVolume] and by the recitation screen.
 * With one stream there is only one number in play, and the pair still
 * answers the case that stream cannot: a ringer at zero.
 *
 * What the stream does **not** decide is whether the app wants to be heard at
 * all: that question is answered once, at the top of [play], by
 * [ringerAllowsRecitation]. The two were written as one for a while — the app
 * promised out loud that it rang "at alarm volume when the phone is on
 * silent" — until it was asked, plainly, not to: a silence somebody set on
 * purpose is not a gap for a reminder to fill. Now the stream says the same
 * thing the gate says, and neither alone is left holding the answer.
 */
object AzaanAudio {

    private const val TAG = "Noor/AzaanAudio"

    /** `filesDir/azaan_<sound>.clip`, where a downloaded clip is kept. */
    fun cachedClip(context: Context, sound: String): File =
        File(context.applicationContext.filesDir, "azaan_$sound.clip")

    /**
     * The bundled clip's resource id, without asking `getIdentifier` for it.
     *
     * `Resources.getIdentifier` is a reflective lookup, and a release build's
     * resource shrinker cannot see one: every clip in `res/raw` was dropped
     * from the APK, `getIdentifier` answered `0`, and the Azaan never sounded
     * at all — a prayer that rang was reported as "nothing to play". Naming
     * the four bundled clips here is a compile-time answer to the same
     * question, and it fails the build rather than the reader if a clip is
     * ever taken out of the tree. Unknown names still go through
     * `getIdentifier`, so a clip added later is not worse off than before.
     *
     * It is asked from outside as well: [PhoneRingtones] copies a clip into
     * the phone's own ringtone list, and that row has to hold the *same*
     * file the recitation plays, or the two could drift apart with nothing
     * to notice.
     */
    fun bundledId(context: Context, sound: String): Int = when (sound) {
        "azaan1" -> R.raw.azaan1
        "azaan2" -> R.raw.azaan2
        "azaan3" -> R.raw.azaan3
        "beep" -> R.raw.beep
        else -> context.resources.getIdentifier(sound, "raw", context.packageName)
    }

    /**
     * Whether the phone's own ringer says the recitation may sound.
     *
     * Silent and vibrate are answers a person gave on purpose, and a prayer
     * reminder that overrules them is a reminder that has stopped being
     * welcome. The clip now rides the ringer's own stream, so a phone on
     * either would mute it anyway — which is exactly why the choice cannot be
     * left to the stream: the refusal has to happen *before* the player is
     * touched, or a silent phone would be left holding a wake lock, a volume
     * watcher and a foreground service against a stream carrying nothing.
     * Asked in one place so the exact-alarm receiver (which has no Dart side
     * to consult), the foreground service and the "Test Azaan" button cannot
     * end up disagreeing.
     *
     * Anything unreadable answers `true`: a ringer mode this build fails to
     * ask about must not be able to take a prayer away. `play` asks again,
     * because [AzaanAlarmReceiver] has usually asked first and the two must
     * not drift apart.
     */
    fun ringerAllowsRecitation(context: Context): Boolean = try {
        val audio = context.applicationContext
            .getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        audio == null || audio.ringerMode == AudioManager.RINGER_MODE_NORMAL
    } catch (_: Exception) {
        true
    }

    /**
     * How often each watched stream is asked about while a recitation sounds.
     *
     * A keypress should be answered while the finger is still on the key —
     * which is what the paragraph below promised at a full second and could
     * not keep. A quarter of one is still free next to a recitation that
     * already holds a wake lock, and it is fast enough that "the volume
     * button stops it" reads as immediate rather than as a beat.
     */
    private const val POLL_INTERVAL_MS = 250L

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
     * Starts [sound] at the ring volume — the reader's own slider, and the
     * one the volume keys move while it plays. Returns false when the
     * resource is missing, the decoder refuses it, or
     * [ringerAllowsRecitation] says the phone is silenced, so callers can
     * fall back rather than report success for silence. [onStopped] fires
     * when the clip finishes or errors out — the foreground service uses it
     * to retire itself.
     */
    @Synchronized
    fun play(context: Context, sound: String, onStopped: (() -> Unit)? = null): Boolean {
        val app = context.applicationContext

        // Silenced means silenced, and this is the side that does the work:
        // declining *before* touching the player leaves no wake lock, no
        // volume watcher and — for the service — a `false` that retires it
        // the same way a missing clip does. The stream agrees, and that
        // agreement is new: on this usage a phone left on vibrate would have
        // nothing to sound anyway. Two answers to one question, so that
        // neither a future stream change nor a future OEM shortcut can
        // reopen it.
        if (!ringerAllowsRecitation(app)) {
            Log.i(TAG, "phone is not on the normal ringer — recitation declined, the reminder stays silent")
            notifyEnded()
            return false
        }

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
            bundledId(app, sound)
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
                "recitation on the ring volume — the owner's clip for $sound"
            } else {
                "recitation on the ring volume"
            }
        )
        watchStreamVolume(app)
        return true
    }

    /**
     * Notices the rocker being touched at all, and ends the recitation.
     *
     * Two things were wrong with the first version, and both are answered by
     * watching more and asking less.
     *
     * **Which stream.** It read only `STREAM_ALARM`, on the theory that the
     * rocker moves whatever is sounding. It does not: Android picks the
     * stream a volume key adjusts from its own idea of what is *active*,
     * which is the ringtone almost always. The clip has since moved onto
     * that very stream — the reader's own ringer — so the press now lands on
     * the number the Azaan is actually playing at, which is the nicest
     * answer available: one slider, one key, one sound. The other three are
     * kept anyway. Builds differ in what they call active, a headset or a
     * locked screen can shift it, and reading a stream that did not move
     * costs nothing. Notification is not redundant with ring either — it is
     * aliased to it on most builds, so it moves together and whichever is
     * read first ends it; alarm stays in the set because some builds route
     * the key there regardless of what is playing.
     *
     * **Which direction.** It waited for a *fall*, because the clip is meant
     * to be quieted. But the reader who reaches for the rocker at 5 a.m. is
     * not adjusting anything — they want the thing gone, and they have said
     * so plainly: the button should turn it off, strictly. Any movement of
     * any watched stream, up or down, reads as that press. The floor is not
     * the question and never was: a ring volume already at zero changes
     * nothing under a downward press, and that is precisely the case the
     * recitation screen exists for — a key event reaches a focused window
     * even when it would move no number at all.
     *
     * It is polled, not observed, and that is not laziness. The obvious
     * observer — a [android.database.ContentObserver] on the `volume_alarm`
     * settings row — reports a different number from the one the stream
     * actually uses: on the device this was written against the row read 8
     * while the alarm stream was playing at 10. The row is a stale copy this
     * build never refreshes, so a watcher parked on it waits for a change the
     * rocker's own handling never sends. Asking [AudioManager] directly
     * answers the only question that matters, on every OEM, and often enough
     * that a keypress is answered before the finger has lifted.
     */
    private fun watchStreamVolume(context: Context) {
        val app = context.applicationContext
        stopWatchingStreamVolume()
        val audio = try {
            app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        } catch (_: Exception) {
            return
        }
        // Every stream a volume key could plausibly be sent to. `ring` is the
        // one the clip now plays on, so it is also the one the key changes;
        // the rest are insurance against a build that thinks otherwise.
        val watched = intArrayOf(
            AudioManager.STREAM_ALARM,
            AudioManager.STREAM_RING,
            AudioManager.STREAM_NOTIFICATION,
            AudioManager.STREAM_MUSIC,
        )
        // Where each stream stood when the Azaan began. The Azaan starting is
        // the one thing that must not count as a press, so the comparison
        // starts from the levels the playback itself was born at.
        val startLevels = IntArray(watched.size)
        try {
            for (i in watched.indices) startLevels[i] = audio.getStreamVolume(watched[i])
        } catch (_: Exception) {
            return
        }
        val handler = Handler(Looper.getMainLooper())
        val poll = object : Runnable {
            override fun run() {
                if (player == null) return
                for (i in watched.indices) {
                    val level = try {
                        audio.getStreamVolume(watched[i])
                    } catch (_: Exception) {
                        return
                    }
                    if (level == startLevels[i]) continue
                    Log.i(
                        TAG,
                        "volume key moved ${streamName(watched[i])} " +
                            "${startLevels[i]} → $level — stopping the recitation",
                    )
                    stop()
                    return
                }
                handler.postDelayed(this, POLL_INTERVAL_MS)
            }
        }
        volumePoll = poll
        handler.postDelayed(poll, POLL_INTERVAL_MS)
    }

    /** For the one log line that says which key the reader actually pressed. */
    private fun streamName(stream: Int): String = when (stream) {
        AudioManager.STREAM_ALARM -> "alarm"
        AudioManager.STREAM_RING -> "ring"
        AudioManager.STREAM_NOTIFICATION -> "notification"
        AudioManager.STREAM_MUSIC -> "media"
        else -> "stream $stream"
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
