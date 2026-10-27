package com.sunesra_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import java.util.concurrent.TimeUnit

/**
 * Fired by the exact alarm that [AzaanAlarms] arms at every prayer time, and
 * by the snooze action on the prayer's own card.
 *
 * It is the **only** audible path the app has, and — since [PrayerCard] took
 * over the shade — the only card a prayer with a bell on it has too. The
 * reminder notification posts to a channel that carries no sound at all,
 * which is what lets the volume rocker mean the same thing every time: while
 * the recitation runs, `AzaanAudio.isPlaying()` is true, so a volume key
 * tears the playback down, and the card offers `STOP AZAN` for when nothing
 * is on screen.
 *
 * Every branch that ends without a recitation still ends with a card. That is
 * the whole point of moving the posting here: the Dart side holds its banner
 * back whenever this receiver is armed — clip or no clip — on the
 * understanding that this receiver speaks for the prayer, and a receiver
 * that answered "the phone is on vibrate" by returning quietly left the
 * reader with nothing at all, which is
 * how a reminder could be *set*, *armed* and *silent* at once.
 *
 * Silence stays silence, and it is asked here. The recitation rides the alarm
 * stream, which a ringer key does not mute, so unless this receiver asks
 * first "the phone is on silent" means nothing at all. It is asked before
 * [AzaanAudio.play] gets the chance as well — and before the service is
 * started — because a playback notification blinking over a clip nobody will
 * hear is a promise the reader can see but not hear. Today's alarm has
 * already rearmed itself by this point, so a declined prayer still owns
 * tomorrow.
 */
class AzaanAlarmReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_PLAY -> play(context, intent)
            ACTION_SNOOZE -> snooze(context, intent)
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
            PrayerCard.show(context, id, title, body, sound, playing = false)
            return
        }

        // Silence is the reader's, and this is where it is honoured. Today's
        // alarm has already put tomorrow's in place above, so returning here
        // costs only this prayer — which is exactly what was asked for. The
        // card still arrives: a reminder that is *visible* while silent is
        // the whole of what "notify without ringing" means.
        if (!AzaanAudio.ringerAllowsRecitation(context)) {
            Log.i(TAG, "azaan $id declined — the phone is on silent or vibrate, so it stays silent")
            PrayerCard.show(context, id, title, body, sound, playing = false)
            return
        }

        // Never stack a second recitation on one that is already sounding.
        if (AzaanAudio.isPlaying()) {
            Log.i(TAG, "azaan $id ignored, one is already playing")
            return
        }

        Log.i(TAG, "azaan $id fired for $sound")

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
            // and post the card by hand, because with no service there is no
            // foreground notification either.
            //
            // No recitation screen is raised here either: the rocker is the
            // mute the user reaches for, it needs no window of ours, and on
            // this device the system refuses to launch one outright.
            Log.w(TAG, "foreground start refused, playing inline: ${error.message}")
            PrayerCard.show(context, id, title, body, sound, playing = true)
            AzaanAudio.play(context, sound) {
                PrayerCard.show(context, id, title, body, sound, playing = false)
            }
        }
    }

    /**
     * The card's own "Snooze 10 min" — the prayer put back ten minutes,
     * answered without opening the app.
     *
     * Both halves move together exactly as they arrived: the card is
     * replaced by a snoozed one, and the recitation is re-armed for ten
     * minutes hence under [PrayerCard.SNOOZE_ID]. That id is deliberately
     * outside the daily block, so re-snoozing *replaces* the pending copy
     * rather than queueing a second, and it can never take tomorrow's place.
     *
     * The original alarm is left alone — it has already rearmed itself for
     * tomorrow, and cancelling it here would cost the reader the next day's
     * prayer to buy ten minutes on this one.
     */
    private fun snooze(context: Context, intent: Intent) {
        val id = intent.getIntExtra(EXTRA_ID, -1)
        val sound = intent.getStringExtra(EXTRA_SOUND)?.trim()?.takeIf { it.isNotEmpty() }
            ?: DEFAULT_SOUND
        val title = intent.getStringExtra(EXTRA_TITLE)
        val body = intent.getStringExtra(EXTRA_BODY)

        // The card being snoozed has said its piece. Dropping it here is
        // what keeps the promise the shade makes: one prayer, one card,
        // never two — the snoozed copy takes its place below.
        if (id >= 0) PrayerCard.dismiss(context, id)

        val at = System.currentTimeMillis() +
            TimeUnit.MINUTES.toMillis(PrayerCard.SNOOZE_MINUTES.toLong())
        val snoozedTitle = "Snoozed • " + (title?.substringBefore('•')?.trim() ?: "Prayer")

        try {
            AzaanAlarms.schedule(
                context = context,
                id = PrayerCard.SNOOZE_ID,
                atMs = at,
                sound = sound,
                title = snoozedTitle,
                body = SNOOZE_BODY,
                recurring = false,
            )
        } catch (error: Exception) {
            Log.w(TAG, "snooze refused: ${error.message}")
            // No alarm, no point in a card promising one.
            return
        }

        PrayerCard.show(
            context,
            PrayerCard.SNOOZE_ID,
            snoozedTitle,
            SNOOZE_BODY,
            sound,
            playing = false,
        )
        Log.i(TAG, "azaan $id snoozed to the next ${PrayerCard.SNOOZE_MINUTES} minutes")
    }

    companion object {
        const val ACTION_PLAY = "com.sunesra_app.action.PLAY_AZAAN"
        const val ACTION_SNOOZE = "com.sunesra_app.action.SNOOZE_AZAAN"
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

        /** Matches `NotificationService.snoozeAzan`'s own words. */
        private const val SNOOZE_BODY = "Ten minutes back, as you asked."

        private const val TAG = "Noor/AzanReceiver"
    }
}
