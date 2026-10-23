package com.sunesra_app

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log

/**
 * Exact alarms for the Azaan, plus the bookkeeping needed to cancel them.
 *
 * The ids deliberately match the `flutter_local_notifications` ids, so one
 * Dart call can retire a notification and its sound together. Android offers
 * no "cancel every alarm belonging to a receiver" call, so armed ids are
 * mirrored into SharedPreferences — that is what makes cancelling a whole id
 * *range* (the favourite-masjid block) possible without iterating 999 million
 * numbers.
 */
object AzaanAlarms {

    private const val TAG = "Noor/AzanAlarm"
    private const val PREFS = "noor_azaan_alarms"
    private const val KEY_IDS = "armedIds"
    private const val KEY_SPECS = "specs"

    /**
     * One armed alarm, in the only form that survives the process.
     *
     * `flutter_local_notifications` repeats its banner on its own
     * (`matchDateTimeComponents`), but the recitation is a one-shot exact
     * alarm: without this record, every alarm dies with the process — at
     * reboot certainly, and every day in between — and the app would recite
     * only for as long as the user kept it open. The local wall-clock time is
     * what is kept, because that is what a prayer *is*; the day and the epoch
     * are recomputed on the way back in.
     */
    data class Spec(
        val hour: Int,
        val minute: Int,
        val sound: String,
        val title: String?,
        val recurring: Boolean,
    )

    /**
     * Arms one exact alarm at [atMs].
     *
     * [recurring] marks the alarms a prayer time owns: the receiver re-arms
     * those for the next day as soon as they have fired, and every
     * boot/time-change broadcast re-arms all of them from the ledger. The
     * Settings "test reminder" probe passes `false` — a diagnostic that
     * resurrects itself every morning would be a bug, not a feature.
     */
    fun schedule(
        context: Context,
        id: Int,
        atMs: Long,
        sound: String,
        title: String?,
        recurring: Boolean = true,
    ) {
        val app = context.applicationContext
        val am = app.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pending = pendingIntent(app, id, sound, title, recurring)

        // The ledger is written *before* the arm, never after. A crash in
        // between used to leave an alarm nothing could ever cancel or re-arm,
        // because the bookkeeping came second.
        remember(app, id, specFor(atMs, sound, title, recurring))

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                // `setAlarmClock`, not `setExactAndAllowWhileIdle`.
                //
                // Both are exact and both ring through Doze, but only one
                // carries the privilege that decided everything else. An
                // alarm-clock alarm is on Android's own list of exemptions to
                // the background-activity-start restriction, so the moment it
                // fires, the recitation screen this app raises is *allowed*
                // to appear over the lock screen — on any device, with no
                // permission to grant, no OEM setting to hunt for, and no
                // notification the user has to approve. This is what every
                // clock and alarm app on the platform does, and it is why
                // they can all put a window in front of you at 5 a.m.
                //
                // The alternative was refused at the exact second the prayer
                // arrived — "Abort background activity starts from <uid>",
                // silently — leaving the Azaan sounding on the alarm stream,
                // the one stream Android refuses to silence, with no window
                // anywhere for a volume key to reach.
                am.setAlarmClock(
                    AlarmManager.AlarmClockInfo(atMs, showIntent(app, title)),
                    pending,
                )
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMs, pending)
            } else {
                am.setExact(AlarmManager.RTC_WAKEUP, atMs, pending)
            }
        } catch (error: SecurityException) {
            // Android 12+ hands SCHEDULE_EXACT_ALARM out per app and can take
            // it back. A late Azaan still beats none, so fall back rather than
            // silently dropping the recitation.
            Log.w(TAG, "exact alarm refused, retrying inexact: ${error.message}")
            try {
                am.set(AlarmManager.RTC_WAKEUP, atMs, pending)
            } catch (fallback: Exception) {
                Log.e(TAG, "alarm scheduling failed for $id: ${fallback.message}")
                forget(app, id)
                return
            }
        } catch (error: Exception) {
            Log.e(TAG, "alarm scheduling failed for $id: ${error.message}")
            forget(app, id)
            return
        }
    }

    /**
     * Re-arms the alarm that has just fired, for its next occurrence.
     *
     * This is the whole of "the Azaan keeps coming after the app is closed":
     * a one-shot alarm that does not put tomorrow's copy in place at the
     * moment it rings would leave the *second* prayer of the day silent, and
     * nothing else in the app would notice.
     *
     * @return `false` when there is nothing to go on (never armed, or a
     * one-shot probe).
     */
    fun rearmNext(context: Context, id: Int): Boolean {
        val app = context.applicationContext
        val spec = specFor(app, id) ?: return false
        if (!spec.recurring) return false
        val next = nextOccurrence(spec.hour, spec.minute)
        Log.i(TAG, "azaan $id fired — re-armed for ${spec.hour}:${ "%02d".format(spec.minute) }")
        schedule(app, id, next, spec.sound, spec.title, recurring = true)
        return true
    }

    /**
     * Puts every recurring alarm back after the events that wipe them.
     *
     * AlarmManager keeps its list in memory: a reboot empties it, and so does
     * an OS update. A timezone or clock change does not empty it, but makes
     * every armed instant wrong — an alarm holds an epoch, and the wall clock
     * it was picked from has moved. Re-deriving each one from its stored local
     * time answers both with a single pass: a prayer is a time of day, not a
     * moment in UTC.
     *
     * @return how many alarms were put back.
     */
    fun rearmAll(context: Context): Int {
        val app = context.applicationContext
        var rearmed = 0
        for ((id, spec) in specs(app)) {
            if (!spec.recurring) continue
            try {
                schedule(
                    app,
                    id,
                    nextOccurrence(spec.hour, spec.minute),
                    spec.sound,
                    spec.title,
                    recurring = true,
                )
                rearmed++
            } catch (error: Exception) {
                Log.e(TAG, "could not re-arm $id: ${error.message}")
            }
        }
        Log.i(TAG, "re-armed $rearmed prayer alarm(s)")
        return rearmed
    }

    /** The next time of day [hour]:[minute] that is still in the future. */
    private fun nextOccurrence(hour: Int, minute: Int): Long {
        val now = java.util.Calendar.getInstance()
        val target = java.util.Calendar.getInstance().apply {
            set(java.util.Calendar.HOUR_OF_DAY, hour)
            set(java.util.Calendar.MINUTE, minute)
            set(java.util.Calendar.SECOND, 0)
            set(java.util.Calendar.MILLISECOND, 0)
        }
        if (target.timeInMillis <= now.timeInMillis) {
            target.add(java.util.Calendar.DAY_OF_YEAR, 1)
        }
        return target.timeInMillis
    }

    fun cancel(context: Context, id: Int) {
        val app = context.applicationContext
        val am = app.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        // Extras are not part of Intent.filterEquals, so this resolves to the
        // very PendingIntent that was armed, whatever it carried.
        am.cancel(pendingIntent(app, id, null, null, recurring = true))
        forget(app, id)
    }

    /** Retires every armed alarm in `[from, until)`. */
    fun cancelRange(context: Context, from: Int, until: Int) {
        val app = context.applicationContext
        for (id in armed(app)) {
            if (id >= from && id < until) cancel(app, id)
        }
    }

    /**
     * What the system shows when someone asks *which* alarm this is — the
     * status-bar alarm icon and the "next alarm" card both point here.
     *
     * `setAlarmClock` insists on one, and it may as well do its job: tapping
     * it opens the app rather than a blank activity, so a prayer time the user
     * did not expect is one tap from an explanation.
     */
    private fun showIntent(context: Context, title: String?): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .setAction(Intent.ACTION_MAIN)
            .putExtra(AzaanAlarmReceiver.EXTRA_TITLE, title)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getActivity(context, 0, intent, flags)
    }

    private fun pendingIntent(
        context: Context,
        id: Int,
        sound: String?,
        title: String?,
        recurring: Boolean,
    ): PendingIntent {
        val intent = Intent(context, AzaanAlarmReceiver::class.java)
            .setAction(AzaanAlarmReceiver.ACTION_PLAY)
            // Extras are not part of `Intent.filterEquals`, so the id rides
            // along for the receiver's log line without changing which
            // PendingIntent a cancel resolves to. `recurring` tells the
            // receiver whether to put tomorrow's copy in place.
            .putExtra(AzaanAlarmReceiver.EXTRA_ID, id)
            .putExtra(AzaanAlarmReceiver.EXTRA_SOUND, sound)
            .putExtra(AzaanAlarmReceiver.EXTRA_TITLE, title)
            .putExtra(AzaanAlarmReceiver.EXTRA_RECURRING, recurring)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getBroadcast(context, id, intent, flags)
    }

    // ---------------------------------------------------------------- storage

    /**
     * Every alarm the app still considers armed, keyed by id.
     *
     * This is the single source of truth for both halves of the job: what to
     * cancel (`cancelRange` walks these keys) and what to put back after a
     * reboot or a timezone change (`rearmAll` walks the specs). It lives in
     * SharedPreferences rather than memory precisely because the events that
     * need it are the ones that take the process down.
     */
    fun specs(context: Context): Map<Int, Spec> {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_SPECS, "") ?: ""
        if (raw.isBlank()) return emptyMap()

        return try {
            val json = org.json.JSONObject(raw)
            val out = mutableMapOf<Int, Spec>()
            for (key in json.keys()) {
                val id = key.toIntOrNull() ?: continue
                val entry = json.getJSONObject(key)
                out[id] = Spec(
                    hour = entry.optInt("h", 0).coerceIn(0, 23),
                    minute = entry.optInt("m", 0).coerceIn(0, 59),
                    sound = entry.optString("s", ""),
                    title = if (entry.isNull("t")) null else entry.optString("t"),
                    recurring = entry.optBoolean("r", true),
                )
            }
            out
        } catch (error: Exception) {
            Log.w(TAG, "azaan ledger unreadable, starting empty: ${error.message}")
            emptyMap()
        }
    }

    /** The record behind one armed id, or null when it was never armed. */
    fun specFor(context: Context, id: Int): Spec? = specs(context)[id]

    /** Turns an armed instant into the record that survives losing it. */
    private fun specFor(atMs: Long, sound: String, title: String?, recurring: Boolean): Spec {
        val calendar = java.util.Calendar.getInstance().apply { timeInMillis = atMs }
        return Spec(
            hour = calendar.get(java.util.Calendar.HOUR_OF_DAY),
            minute = calendar.get(java.util.Calendar.MINUTE),
            sound = sound,
            title = title,
            recurring = recurring,
        )
    }

    private fun armed(context: Context): Set<Int> = specs(context).keys

    private fun remember(context: Context, id: Int, spec: Spec) {
        val all = specs(context).toMutableMap()
        all[id] = spec
        write(context, all)
    }

    private fun forget(context: Context, id: Int) {
        val all = specs(context).toMutableMap()
        if (all.remove(id) != null) write(context, all)
    }

    private fun write(context: Context, all: Map<Int, Spec>) {
        val json = org.json.JSONObject()
        for ((id, spec) in all) {
            json.put(
                id.toString(),
                org.json.JSONObject()
                    .put("h", spec.hour)
                    .put("m", spec.minute)
                    .put("s", spec.sound)
                    .put("t", spec.title ?: org.json.JSONObject.NULL)
                    .put("r", spec.recurring),
            )
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_SPECS, json.toString())
            // The old id-only ledger says nothing that this one does not.
            .remove(KEY_IDS)
            .apply()
    }

    // ----------------------------------------------------------- permissions

    /** Android 12+ lets the user revoke exact alarms per app. */
    fun canScheduleExact(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        return try {
            am.canScheduleExactAlarms()
        } catch (_: Exception) {
            false
        }
    }

    fun openExactAlarmSettings(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        try {
            context.startActivity(
                Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
                    .setData(Uri.parse("package:${context.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        } catch (error: Exception) {
            Log.w(TAG, "cannot open exact-alarm settings: ${error.message}")
            openExactAlarmFallback(context)
        }
    }

    /**
     * Doze delays anything that is not exempt, which is exactly how a
     * "test in one minute" check silently misses.
     */
    fun openBatteryOptimisationPrompt(context: Context) {
        try {
            context.startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                    .setData(Uri.parse("package:${context.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        } catch (error: Exception) {
            Log.w(TAG, "cannot ask to ignore battery optimisation: ${error.message}")
            openSettings(context, Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
        }
    }

    private fun openSettings(context: Context, action: String) {
        try {
            context.startActivity(Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (error: Exception) {
            Log.w(TAG, "no settings screen for $action: ${error.message}")
        }
    }

    private fun openExactAlarmFallback(context: Context) = openSettings(
        context,
        // Not exposed as a Settings constant on every compile SDK, but the
        // action itself is part of the platform contract.
        "android.settings.SCHEDULE_EXACT_ALARM_PERMISSION_REQUEST_SETTINGS",
    )
}
