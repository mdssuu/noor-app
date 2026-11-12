package com.sunesra_app

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.os.Build
import android.util.Log

/**
 * The quiet half of the Azaan: after a recitation, the phone goes to
 * **vibrate** for the number of minutes the reader chose in Settings
 * ("Silence after Azaan") and then rings normally again on its own.
 *
 * Three rules decide everything here:
 *
 *  * **Only a recitation that happened may silence the phone.** The callers
 *    are the playback service (once the clip has actually started) and the
 *    receiver's inline fallback (whose callback only fires from a clip's own
 *    completion) — never a branch that declined to play.
 *  * **The window starts after the clip, never during it.** The Azaan rides
 *    the ringer's own stream, so flipping the switch mid-recitation would
 *    mute the very thing the reader asked to hear.
 *  * **The phone comes back the way it was found.** The mode in force when
 *    the window opened is saved and restored — and it is only restored while
 *    the ringer still reads `vibrate`, which is where this code left it. A
 *    reader who silenced the phone themselves, or rang it back early, gets
 *    exactly the answer they gave.
 *
 * The restore is an exact alarm of its own, so it survives the process, the
 * app being closed and Doze. [reconcile] puts that alarm back after the
 * events that wipe AlarmManager's list — a reboot, an app update — because a
 * window whose alarm died with the reboot would leave a phone on vibrate
 * with nothing ever scheduled to take it off.
 */
object RingerSilence {

    private const val TAG = "Noor/SilentWindow"

    /** Where the open window lives — it has to outlive the process. */
    private const val PREFS = "noor_ringer_silence"
    private const val KEY_END_MS = "endMs"
    private const val KEY_PREV_MODE = "prevMode"

    /** The action [RingerRestoreReceiver] answers when the minutes are up. */
    const val ACTION_RESTORE = "com.sunesra_app.action.RESTORE_RINGER"

    /**
     * Request code of the restore alarm's PendingIntent.
     *
     * Arbitrary but fixed: the intent's own component and action already set
     * it apart from every Azaan alarm (which request-code off their prayer
     * ids), and a fixed code is what lets a re-arm *replace* the pending
     * copy instead of stacking a second one beside it.
     */
    private const val REQUEST_RESTORE = 900701

    /**
     * Puts the phone on vibrate for [minutes] and books the alarm that puts
     * it back. Call this the moment a recitation ends.
     *
     * A window that is already open keeps the mode it saved — the original
     * — and only its end moves: the second prayer's choice must not record
     * `vibrate` as the thing to restore, or the phone would come back to
     * vibrate it never left.
     */
    fun engage(context: Context, minutes: Int) {
        if (minutes <= 0) return
        val app = context.applicationContext
        val audio = try {
            app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        } catch (_: Exception) {
            Log.w(TAG, "no AudioManager — quiet window not started")
            return
        }

        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        val endMs = now + minutes * 60_000L
        val open = prefs.getLong(KEY_END_MS, 0L) > now
        val editor = prefs.edit().putLong(KEY_END_MS, endMs)
        if (!open) {
            // The mode this window is taking away is the reader's own, and
            // it is that one that has to come back. (In practice it reads
            // `normal` — nothing recites on any other — but whatever it
            // says is what is filed, because whatever it says is what was
            // there.)
            editor.putInt(KEY_PREV_MODE, audio.ringerMode)
        }
        editor.apply()

        try {
            audio.ringerMode = AudioManager.RINGER_MODE_VIBRATE
        } catch (error: Exception) {
            // Nothing to undo — the switch never moved — but the window
            // must not be left open pointing at a restore that would fire
            // for no reason.
            prefs.edit().clear().apply()
            Log.w(TAG, "could not switch to vibrate: ${error.message}")
            return
        }

        arm(app, endMs)
        Log.i(TAG, "phone on vibrate for $minutes min (ringer was ${modeName(audio.ringerMode)})")
    }

    /**
     * Answers the events that take AlarmManager's list away — called by
     * [AzaanScheduleReceiver] on boot, app update, timezone and clock change.
     *
     * An open window whose alarm died with the reboot is put back (the
     * ringer itself survives a reboot, so the phone would otherwise stay on
     * vibrate for ever); a window whose minutes ran out while the phone was
     * off is finished right here, which is the same work the alarm would
     * have done.
     */
    fun reconcile(context: Context) {
        val app = context.applicationContext
        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val endMs = prefs.getLong(KEY_END_MS, 0L)
        if (endMs == 0L) return
        if (System.currentTimeMillis() >= endMs) {
            restore(app)
        } else {
            arm(app, endMs)
            Log.i(TAG, "quiet window survives the restart — restore re-armed")
        }
    }

    /**
     * The alarm's own answer: hand the ringer back, or re-book the alarm if
     * it fired early (a clock moved backwards under it).
     *
     * The guard is the whole safety of the feature: the mode is only
     * touched while it still reads `vibrate` — the state this code left it
     * in. A reader who changed it during the window has answered for
     * themselves, and this receiver must not overwrite that answer.
     */
    fun restore(context: Context) {
        val app = context.applicationContext
        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val endMs = prefs.getLong(KEY_END_MS, 0L)
        if (endMs == 0L) return

        val now = System.currentTimeMillis()
        if (now < endMs) {
            arm(app, endMs)
            return
        }

        val prevMode = prefs.getInt(KEY_PREV_MODE, AudioManager.RINGER_MODE_NORMAL)
        try {
            val audio = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (audio.ringerMode == AudioManager.RINGER_MODE_VIBRATE) {
                audio.ringerMode = prevMode
                Log.i(TAG, "quiet window over — ringer back to ${modeName(prevMode)}")
            } else {
                Log.i(TAG, "quiet window over — the reader already moved the ringer, leaving it")
            }
        } catch (error: Exception) {
            Log.w(TAG, "could not restore the ringer: ${error.message}")
        }
        prefs.edit().clear().apply()
        cancel(app)
    }

    /**
     * Books the restore at [atMs], through Doze and with the app shut.
     *
     * Exact where the platform allows it — a "15 minutes" that answers at
     * 17 is a setting that lies — and falling back in steps where it does
     * not: an inexact restore still beats one that never comes.
     */
    private fun arm(context: Context, atMs: Long) {
        val am = try {
            context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        } catch (_: Exception) {
            return
        }
        val intent = Intent(context, RingerRestoreReceiver::class.java)
            .setAction(ACTION_RESTORE)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        val pending = PendingIntent.getBroadcast(context, REQUEST_RESTORE, intent, flags)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMs, pending)
            } else {
                am.setExact(AlarmManager.RTC_WAKEUP, atMs, pending)
            }
        } catch (_: SecurityException) {
            // SCHEDULE_EXACT_ALARM revoked on Android 12+ — the azaan's own
            // alarms live with the same grant, so this is the unlikely road.
            try {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMs, pending)
            } catch (_: Exception) {
                am.set(AlarmManager.RTC_WAKEUP, atMs, pending)
            }
        } catch (error: Exception) {
            Log.w(TAG, "restore alarm fell back to inexact: ${error.message}")
            try {
                am.set(AlarmManager.RTC_WAKEUP, atMs, pending)
            } catch (_: Exception) {
            }
        }
    }

    private fun cancel(context: Context) {
        val am = try {
            context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        } catch (_: Exception) {
            return
        }
        val intent = Intent(context, RingerRestoreReceiver::class.java)
            .setAction(ACTION_RESTORE)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        am.cancel(PendingIntent.getBroadcast(context, REQUEST_RESTORE, intent, flags))
    }

    private fun modeName(mode: Int): String = when (mode) {
        AudioManager.RINGER_MODE_NORMAL -> "normal"
        AudioManager.RINGER_MODE_VIBRATE -> "vibrate"
        AudioManager.RINGER_MODE_SILENT -> "silent"
        else -> "mode $mode"
    }
}

/**
 * Fired by the exact alarm [RingerSilence] books when a quiet window opens.
 *
 * Registered in the manifest (not at runtime) because it has to be
 * reachable with the app not running — which is precisely the state a phone
 * left on vibrate for a quarter of an hour is usually in.
 */
class RingerRestoreReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != RingerSilence.ACTION_RESTORE) return
        RingerSilence.restore(context)
    }
}
