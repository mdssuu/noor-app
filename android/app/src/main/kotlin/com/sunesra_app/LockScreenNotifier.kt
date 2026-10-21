package com.sunesra_app

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import android.widget.RemoteViews
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import org.json.JSONArray
import org.json.JSONObject

/**
 * The lock-screen prayer card: one ongoing, silent notification that keeps
 * the next prayer and today's times where a phone shows them without being
 * opened.
 *
 * Android has no lock-screen widgets — third parties lost them after 4.2 —
 * so the lock screen's one honest surface is a notification. This one is
 * built to behave like furniture rather than an event: `LOW` importance is
 * no sound and no heads-up, `VISIBILITY_PUBLIC` means the times are readable
 * while the phone is locked, and ongoing means it cannot be swiped away
 * into amnesia.
 *
 * It shares the home-screen widget's picture verbatim — the JSON Dart
 * prepared in `prayer_widget.dart`, stored by [NoorWidgetProvider] — and
 * picks "next" with the same "first entry still ahead of the clock" rule
 * the widget draws with, so the two surfaces can never disagree about what
 * is next.
 *
 * The one thing a notification cannot do on its own is keep time: nothing
 * redraws it when the clock crosses a prayer. So every refresh arms one
 * exact alarm at the next instant the "Next" line must move; the alarm's
 * receiver calls [refresh] again, which arms the one after it. The chain is
 * restarted by every entry point — an app open, a boot, a clock change, a
 * widget's half-hourly tick — and keeps the card true for as long as the
 * picture's table runs, which is how long the widget stays true too.
 */
object LockScreenNotifier {

    private const val TAG = "Noor/LockCard"
    private const val CHANNEL_ID = "noor_lock_card"

    /** Azan banners own ids 0–4; this card stays well out of their way. */
    private const val NOTIFICATION_ID = 4200
    private const val FLIP_REQUEST = 4201
    const val FLIP_ACTION = "com.sunesra_app.LOCK_CARD_FLIP"

    /** The picture is the widget's own: one store, two surfaces. */
    private const val PREFS = NoorWidgetProvider.PREFS
    private const val KEY_PAYLOAD = NoorWidgetProvider.KEY_PAYLOAD

    /** The six time cells of the card's face, in reading order. */
    private val TIME_VIEWS =
        intArrayOf(R.id.lock_time_0, R.id.lock_time_1, R.id.lock_time_2,
            R.id.lock_time_3, R.id.lock_time_4, R.id.lock_time_5)

    /**
     * Re-posts the card from the stored picture and re-arms the flip at the
     * next prayer. Every entry point calls this; it is idempotent, and it
     * never throws — a card that misses one refresh is a few hours stale,
     * and being stale beats an exception taking a broadcast path down.
     */
    fun refresh(context: Context) {
        try {
            val raw = context
                .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(KEY_PAYLOAD, null) ?: return
            val json = JSONObject(raw)

            val dayLines = mutableListOf<String>()
            val prayers = json.optJSONArray("prayers") ?: JSONArray()
            for (i in 0 until prayers.length()) {
                val p = prayers.optJSONObject(i) ?: continue
                val label = p.optString("label")
                val time = p.optString("time")
                if (label.isNotEmpty() && time.isNotEmpty()) {
                    dayLines.add("$label  $time")
                }
            }
            if (dayLines.isEmpty()) return

            // The same pick the widget makes: the first table entry still
            // ahead of the phone's clock; past the whole table, the last
            // entry stands in until the next refresh arrives.
            val transitions = json.optJSONArray("transitions") ?: JSONArray()
            var chosen: JSONObject? = null
            for (i in 0 until transitions.length()) {
                val t = transitions.optJSONObject(i) ?: continue
                if (t.optLong("atMs") > System.currentTimeMillis()) {
                    chosen = t
                    break
                }
                chosen = t
            }
            val nextLabel = chosen?.optString("label").orEmpty().ifBlank { "Prayer" }
            val nextTime = chosen?.optString("time").orEmpty().ifBlank { "—" }
            val nextAtMs = chosen?.optLong("atMs") ?: 0L

            ensureChannel(context)
            val enabled = NotificationManagerCompat.from(context).areNotificationsEnabled()
            Log.i(TAG, "refresh: enabled=$enabled next=$nextLabel $nextTime at $nextAtMs")

            // Tap anywhere on it: the enabled launcher component, so the
            // tap lands on whichever icon variant the owner switched to —
            // the same intent the home-screen widget uses.
            val launch = context.packageManager
                .getLaunchIntentForPackage(context.packageName)
                ?.apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
                ?: Intent(context, MainActivity::class.java)
            val tap = PendingIntent.getActivity(
                context,
                // The widget's tap owns request code 0; distinct codes keep
                // the two PendingIntents from collapsing into one.
                1,
                launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

            val title = "Next: $nextLabel  $nextTime"
            // The face is a custom RemoteViews: the headline and all six
            // times in one card, visible without expanding — a collapsed
            // text line ellipsises half the times away, and a locked phone
            // deserves the whole day at a glance. The text style below is
            // only the fallback for surfaces with no custom views.
            val face = RemoteViews(context.packageName, R.layout.lock_card)
            face.setTextViewText(R.id.lock_next_label, nextLabel)
            face.setTextViewText(R.id.lock_next_time, nextTime)
            for (i in TIME_VIEWS.indices) {
                face.setTextViewText(TIME_VIEWS[i], if (i < dayLines.size) dayLines[i] else "")
            }

            val card = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_lock_moon)
                .setColor(0xFFC97F52.toInt()) // the copper the app titles with
                .setContentTitle(title)
                .setContentText(dayLines.joinToString("  ·  "))
                .setStyle(
                    NotificationCompat.BigTextStyle()
                        .setBigContentTitle(title)
                        .bigText(dayLines.joinToString("\n")),
                )
                .setCustomContentView(face)
                .setCustomBigContentView(face)
                .setContentIntent(tap)
                .setOngoing(true)
                .setShowWhen(false)
                .setOnlyAlertOnce(true)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setCategory(NotificationCompat.CATEGORY_REMINDER)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .build()
            NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, card)
            Log.i(TAG, "card posted")

            if (nextAtMs > System.currentTimeMillis()) armFlip(context, nextAtMs)
        } catch (t: Throwable) {
            Log.w(TAG, "lock card refresh failed: $t")
        }
    }

    /** One silent, badge-less channel the system will show while locked. */
    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Prayer times on the lock screen",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "The next prayer and today's times, kept on the lock screen."
            setShowBadge(false)
            setSound(null, null)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        manager.createNotificationChannel(channel)
    }

    /** One exact alarm at the moment the "Next" line must move. */
    private fun armFlip(context: Context, atMs: Long) {
        val alarm = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        val pending = PendingIntent.getBroadcast(
            context,
            FLIP_REQUEST,
            Intent(context, NextFlipReceiver::class.java).setAction(FLIP_ACTION),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarm.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMs, pending)
            } else {
                alarm.setExact(AlarmManager.RTC_WAKEUP, atMs, pending)
            }
        } catch (t: Throwable) {
            // Some phones hand the exact-alarm switch out late; an inexact
            // flip still moves the line, just not to the second.
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    alarm.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMs, pending)
                } else {
                    alarm.set(AlarmManager.RTC_WAKEUP, atMs, pending)
                }
            } catch (inner: Throwable) {
                Log.w(TAG, "flip alarm refused: $t / $inner")
            }
        }
    }
}

/**
 * The alarm half of the card: fires at the next prayer instant, calls
 * [LockScreenNotifier.refresh], which re-posts the card and arms the one
 * after. Manifest-registered like the Azaan receivers — it has to be
 * reachable with the app not running — and reached only by our own explicit
 * PendingIntent, so it needs no intent-filter.
 */
class NextFlipReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == LockScreenNotifier.FLIP_ACTION) {
            LockScreenNotifier.refresh(context)
        }
    }
}
