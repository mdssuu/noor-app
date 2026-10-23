package com.sunesra_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Puts the Azaan back after every event that quietly takes it away.
 *
 * AlarmManager keeps its list in memory. A reboot empties it and nothing
 * repopulates it until the user happens to open the app — which is how a phone
 * that is restarted on Sunday recites only on Monday morning. An OS update
 * does the same. A timezone or manual clock change is subtler: the alarms are
 * still armed, but every one of them now points at the wrong wall-clock time,
 * because an alarm holds an epoch and the clock it was chosen from has moved.
 *
 * All four are answered by one pass over [AzaanAlarms]' ledger: a prayer is a
 * time of *day*, so re-deriving each armed instant from its stored local time
 * is correct in the new zone and correct after the gap. The banner half of the
 * reminder already survives this on its own — `flutter_local_notifications`
 * registers its own boot receiver and repeats on `DateTimeComponents.time` —
 * so this is the missing audible half, not a second copy of the same idea.
 */
class AzaanScheduleReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action !in WIPING_EVENTS) return

        val rearmed = AzaanAlarms.rearmAll(context)
        Log.i(TAG, "$action — $rearmed prayer alarm(s) put back")

        // The clock moved under the lock-screen card too: re-read its stored
        // picture against the new time and re-arm the flip that keeps it.
        LockScreenNotifier.refresh(context)
    }

    companion object {
        private const val TAG = "Noor/AzanSchedule"

        /**
         * The events worth re-deriving for.
         *
         * `TIME_SET` is the manual clock change (`ACTION_TIME_CHANGED`); the
         * travel case arrives as `TIMEZONE_CHANGED`. `MY_PACKAGE_REPLACED` is
         * an app update, which some builds treat as a fresh boot and some do
         * not — handling it costs nothing and covers the ones that do not.
         */
        private val WIPING_EVENTS = setOf(
            Intent.ACTION_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON",
            Intent.ACTION_MY_PACKAGE_REPLACED,
            Intent.ACTION_TIMEZONE_CHANGED,
            Intent.ACTION_TIME_CHANGED,
        )
    }
}
