package com.sunesra_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * Fired by the exact alarm that [AzaanAlarms] arms at every prayer time.
 *
 * It is the **only** audible path the app has, and — since [PrayerCard] took
 * over the shade — the only card a prayer with a bell on it has too. The
 * reminder notification posts to a channel that carries no sound at all,
 * which is what lets the volume rocker mean the same thing every time: while
 * the recitation runs, `AzaanAudio.isPlaying()` is true, so a volume key
 * tears the playback down, and the card offers `STOP AZAN` for when nothing
 * is on screen.
 *
 * Every branch ends with a card — including the branches that *do* recite.
 * That is the fix behind "the Azaan sounds but no notification comes": the
 * card used to be posted only by the service's foreground notification, and
 * a `startForeground` that throws is caught, logged and played past, so the
 * recitation ran with nothing in the shade to show for it and no button to
 * stop it. Posting here as well costs nothing — same id, same object, one
 * card — and makes the card's arrival independent of a grant the reader
 * cannot see. The Dart side holds its banner back whenever this receiver is
 * armed — clip or no clip — on the understanding that this receiver speaks
 * for the prayer.
 *
 * Silence stays silence, and it is asked here. The recitation rides the
 * reader's own ringer now — a stream a silenced phone mutes anyway — but
 * that is the stream answering, not this receiver, and a check left to the
 * stream arrives after the player, the wake lock and the service are all
 * already up. So it is asked before [AzaanAudio.play] gets the chance as
 * well — and before the service is started — because a playback
 * notification blinking over a clip nobody will hear is a promise the
 * reader can see but not hear. Today's alarm has already rearmed itself by
 * this point, so a declined prayer still owns tomorrow.
 */
class AzaanAlarmReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_PLAY -> play(context, intent)
            else -> Unit
        }
    }

    private fun play(context: Context, intent: Intent) {
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
        val title = intent.getStringExtra(EXTRA_TITLE)
        val body = intent.getStringExtra(EXTRA_BODY)

        // A bell on `silent` promises a card and no recitation — that is
        // what Mute means, and what the profile's own "None (silent)" means.
        // This alarm exists precisely so that promise is kept on the path
        // that needs no exact-alarm grant to keep it: the card is posted,
        // nothing is played, and the reader is left with the one
        // notification they asked for. The Dart banner used to be the only
        // voice in this state, and it was the half that could go missing
        // while an Azaan bell on the same phone still arrived.
        if (sound == "silent") {
            Log.i(TAG, "azaan $id fired on a muted bell — card only")
            PrayerCard.show(context, id, title, body, playing = false)
            return
        }

        // Silence is the reader's, and this is where it is honoured. Today's
        // alarm has already put tomorrow's in place above, so returning here
        // costs only this prayer — which is exactly what was asked for. The
        // card still arrives: a reminder that is *visible* while silent is
        // the whole of what "notify without ringing" means.
        if (!AzaanAudio.ringerAllowsRecitation(context)) {
            Log.i(TAG, "azaan $id declined — the phone is on silent or vibrate, so it stays silent")
            PrayerCard.show(context, id, title, body, playing = false)
            return
        }

        // Never stack a second recitation on one that is already sounding.
        if (AzaanAudio.isPlaying()) {
            Log.i(TAG, "azaan $id ignored, one is already playing")
            return
        }

        Log.i(TAG, "azaan $id fired for $sound")

        // The card is posted *here* — not left to the service's foreground
        // notification, which was the whole of "the Azaan sounds but no
        // notification comes, and with the notification no STOP AZAN". The
        // service posts the very same card under the very same id, so in the
        // normal case this one is replaced by an identical object and the
        // reader sees one card, never two. But `startForeground` can throw
        // — a grant revoked, an OEM's own rule — and the service catches
        // that, logs it, and plays on; the recitation then ran with nothing
        // in the shade to show for it and no button to stop it. A card whose
        // arrival waits on a foreground grant the reader cannot see is not a
        // card, it is a hope.
        PrayerCard.show(context, id, title, body, playing = true)

        val service = Intent(context, AzaanPlaybackService::class.java)
            .setAction(AzaanPlaybackService.ACTION_PLAY)
            .putExtra(AzaanPlaybackService.EXTRA_SOUND, sound)
            .putExtra(AzaanPlaybackService.EXTRA_TITLE, title)
            .putExtra(AzaanPlaybackService.EXTRA_BODY, body)
            .putExtra(AzaanPlaybackService.EXTRA_ID, id)

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(service)
            } else {
                context.startService(service)
            }
        } catch (error: Exception) {
            // A few OEM builds refuse a background foreground-service start
            // even from an alarm. Play inline rather than lose the Azaan —
            // the card is already up, so only the clip is left to do by
            // hand, and its end puts the card back to its resting state.
            //
            // No recitation screen is raised here either: the rocker is the
            // mute the user reaches for, it needs no window of ours, and on
            // this device the system refuses to launch one outright.
            Log.w(TAG, "foreground start refused, playing inline: ${error.message}")
            AzaanAudio.play(context, sound) {
                PrayerCard.show(context, id, title, body, playing = false)
            }
        }
    }

    companion object {
        const val ACTION_PLAY = "com.sunesra_app.action.PLAY_AZAAN"
        const val EXTRA_ID = "id"
        const val EXTRA_SOUND = "sound"
        const val EXTRA_TITLE = "title"

        /**
         * The line the reminder carries.
         *
         * It rides the alarm so the card this receiver posts can say what the
         * Dart side's banner used to say — the two are the same card now, and
         * a prayer whose recitation was declined needs the words more than
         * the sound.
         */
        const val EXTRA_BODY = "body"

        /** Whether this alarm owns a tomorrow — prayer alarms do, probes do not. */
        const val EXTRA_RECURRING = "recurring"

        /** `AzanSound('makkah', …)` — what the app plays when it is not told. */
        private const val DEFAULT_SOUND = "azaan1"

        private const val TAG = "Noor/AzanReceiver"
    }
}
