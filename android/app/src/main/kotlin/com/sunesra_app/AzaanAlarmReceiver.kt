package com.sunesra_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * Fired by the exact alarm that [AzaanAlarms] arms at every prayer time.
 *
 * It is the **only** audible path the app has. The reminder notification
 * posts to a channel that carries no sound at all, which is what lets the
 * volume rocker mean the same thing every time: while the recitation runs,
 * `AzaanAudio.isPlaying()` is true, so a volume key in the app tears the
 * playback down and the playback notification offers a STOP AZAN button for
 * when nothing is on screen. It used to be different — the channel carried
 * the same mp3, so a second copy of the Azaan arrived as notification sound
 * on the notification stream, where no key could reach it, and it arrived at
 * the advance "in 10 minutes" reminder too.
 *
 * Nothing here consults the ringer mode any more: there is no second sound
 * to stay quiet for, and the alarm stream is the one volume position Android
 * refuses to silence — which is exactly what a prayer reminder needs.
 */
class AzaanAlarmReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_PLAY) return

        val id = intent.getIntExtra(EXTRA_ID, -1)
        val recurring = intent.getBooleanExtra(EXTRA_RECURRING, true)

        // Today's copy puts tomorrow's in place the moment it has rung. A
        // one-shot alarm that does not do this would leave the *second*
        // prayer of the day silent — the app would recite for exactly as long
        // as the user kept it open, which is the one condition a prayer time
        // never has. The ledger is what makes it possible: the alarm carries
        // its sound, but not the clock face it should come back on tomorrow.
        if (id >= 0 && recurring) {
            AzaanAlarms.rearmNext(context, id)
        }

        // An intent that lost its extras used to produce *nothing at all* —
        // no sound, no service, not even a log line. Fall back to the app's
        // default clip: a recitation at the wrong volume beats silence at the
        // right one.
        val sound = intent.getStringExtra(EXTRA_SOUND)?.trim()?.takeIf { it.isNotEmpty() }
            ?: DEFAULT_SOUND
        if (sound == "silent") return

        // Never stack a second recitation on one that is already sounding.
        if (AzaanAudio.isPlaying()) {
            Log.i(TAG, "azaan $id ignored, one is already playing")
            return
        }

        Log.i(TAG, "azaan $id fired for $sound")

        val service = Intent(context, AzaanPlaybackService::class.java)
            .setAction(AzaanPlaybackService.ACTION_PLAY)
            .putExtra(AzaanPlaybackService.EXTRA_SOUND, sound)
            .putExtra(AzaanPlaybackService.EXTRA_TITLE, intent.getStringExtra(EXTRA_TITLE))

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(service)
            } else {
                context.startService(service)
            }
        } catch (error: Exception) {
            // A few OEM builds refuse a background foreground-service start
            // even from an alarm. Play inline rather than lose the Azaan.
            //
            // No recitation card is raised here either. The rocker is the
            // mute the user reaches for, and it needs no window of ours: the
            // clip sounds on the alarm stream, which is the stream the volume
            // keys move while anything is on it, and one press in its
            // direction is the fall [AzaanAudio.watchStreamVolume] reads as
            // that mute. A popup would only be one more thing to dismiss over
            // an Azaan, and on this device the system refuses it outright.
            Log.w(TAG, "foreground start refused, playing inline: ${error.message}")
            AzaanAudio.play(context, sound)
        }
    }

    companion object {
        const val ACTION_PLAY = "com.sunesra_app.action.PLAY_AZAAN"
        const val EXTRA_ID = "id"
        const val EXTRA_SOUND = "sound"
        const val EXTRA_TITLE = "title"

        /** Whether this alarm owns a tomorrow — prayer alarms do, probes do not. */
        const val EXTRA_RECURRING = "recurring"

        /** `AzanSound('makkah', …)` — what the app plays when it is not told. */
        private const val DEFAULT_SOUND = "azaan1"
        private const val TAG = "Noor/AzanReceiver"
    }
}
