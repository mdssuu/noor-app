package com.sunesra_app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.widget.RemoteViews
import org.json.JSONArray
import org.json.JSONObject

/**
 * The home-screen widget.
 *
 * A widget provider is plain Kotlin and never runs Dart — prayer times come
 * out of an engine only the app process can host. So the division of labour
 * is: Dart *prepares* a picture (today's times, and a table of the next few
 * prayer instants with their wall-clock labels), [MainActivity] stores it in
 * [PREFS] and calls [push]; this provider renders it, and re-picks "next"
 * from the phone's own clock every time it draws.
 *
 * That last part is what keeps the widget honest while the app is closed:
 * an `updatePeriodMillis` redraw re-reads the stored table and advances the
 * "next prayer" line on its own for a day or two, instead of freezing on
 * whatever was next at the last app open. When the table runs out (or no
 * picture was ever sent), the widget still renders — with the day's times,
 * which do not expire until tomorrow's picture arrives.
 */
class NoorWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        manager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        updateAll(context)
        // The half-hourly tick doubles as the lock-screen card's clock —
        // the one redraw it gets for free while a widget is placed.
        LockScreenNotifier.refresh(context)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        // Clock, timezone and boot all move what "next" means; the system
        // hands them to the same receiver as APPWIDGET_UPDATE (see the
        // manifest filter) so a phone restarted at 4 a.m. shows tomorrow's
        // Fajr, not yesterday's. The lock-screen card reads the same
        // picture, so it is taken back along with the widget.
        when (intent.action) {
            Intent.ACTION_TIME_CHANGED,
            Intent.ACTION_TIMEZONE_CHANGED,
            Intent.ACTION_BOOT_COMPLETED,
            -> {
                updateAll(context)
                LockScreenNotifier.refresh(context)
            }
        }
    }

    companion object {
        private const val TAG = "Noor/Widget"

        // Shared with LockScreenNotifier: the lock-screen card reads the
        // same store, so one picture Dart prepares feeds both surfaces and
        // they can never drift apart.
        internal const val PREFS = "noor_widget"
        internal const val KEY_PAYLOAD = "payload_json"

        /** Rows of prayer times the layout can hold: 3 rows x 2 columns. */
        private val TIME_VIEWS =
            intArrayOf(R.id.widget_time_0, R.id.widget_time_1, R.id.widget_time_2,
                R.id.widget_time_3, R.id.widget_time_4, R.id.widget_time_5)

        /**
         * Stores the picture Dart prepared and redraws every widget from it.
         * Called from [MainActivity]'s method-channel handler.
         */
        fun push(context: Context, payloadJson: String) {
            prefs(context).edit().putString(KEY_PAYLOAD, payloadJson).apply()
            updateAll(context)
        }

        /** Redraws every placed instance of this widget. */
        fun updateAll(context: Context) {
            try {
                val manager = AppWidgetManager.getInstance(context) ?: return
                val ids = manager.getAppWidgetIds(
                    ComponentName(context, NoorWidgetProvider::class.java),
                )
                if (ids.isEmpty()) return
                val views = render(context) ?: return
                for (id in ids) manager.updateAppWidget(id, views)
            } catch (t: Throwable) {
                // A widget is a decoration; it must never take the process
                // down over a bad reading of its own preferences.
                android.util.Log.w(TAG, "widget update failed: $t")
            }
        }

        private fun prefs(context: Context): SharedPreferences =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        private fun render(context: Context): RemoteViews? {
            val views = RemoteViews(context.packageName, R.layout.noor_widget)

            // Sensible blanks first: a widget placed before the app has ever
            // opened still looks deliberate rather than empty.
            var city = "Prayer times"
            var hijri = ""
            var dateLabel = ""
            var nextLabel = "Next"
            var nextTime = "—"
            val times = mutableListOf<String>()

            val raw = prefs(context).getString(KEY_PAYLOAD, null)
            if (raw != null) {
                try {
                    val json = JSONObject(raw)
                    city = json.optString("city").ifBlank { "Prayer times" }
                    hijri = json.optString("hijri")
                    dateLabel = json.optString("dateLabel")

                    val prayers = json.optJSONArray("prayers") ?: JSONArray()
                    for (i in 0 until prayers.length()) {
                        val p = prayers.optJSONObject(i) ?: continue
                        val label = p.optString("label")
                        val time = p.optString("time")
                        if (label.isNotEmpty() && time.isNotEmpty()) {
                            times.add("$label  $time")
                        }
                    }

                    // The first table entry still ahead of the phone's clock
                    // is today's next prayer; past the whole table, the last
                    // entry stands in until the next app-open refreshes it.
                    val now = System.currentTimeMillis()
                    val transitions = json.optJSONArray("transitions") ?: JSONArray()
                    var chosen: JSONObject? = null
                    for (i in 0 until transitions.length()) {
                        val t = transitions.optJSONObject(i) ?: continue
                        if (t.optLong("atMs") > now) {
                            chosen = t
                            break
                        }
                        chosen = t
                    }
                    if (chosen != null) {
                        nextLabel = chosen.optString("label").ifBlank { nextLabel }
                        nextTime = chosen.optString("time").ifBlank { nextTime }
                    }
                } catch (t: Throwable) {
                    android.util.Log.w(TAG, "payload unreadable, rendering blanks: $t")
                }
            }

            views.setTextViewText(
                R.id.widget_title,
                if (dateLabel.isEmpty()) "Noor" else "Noor  ·  $dateLabel",
            )
            views.setTextViewText(R.id.widget_city, city)
            views.setTextViewText(
                R.id.widget_hijri,
                if (hijri.isEmpty()) "Masjid Time" else hijri,
            )
            views.setTextViewText(R.id.widget_next_label, nextLabel)
            views.setTextViewText(R.id.widget_next_time, nextTime)

            for (i in TIME_VIEWS.indices) {
                val text = if (i < times.size) times[i] else ""
                views.setTextViewText(TIME_VIEWS[i], text)
            }

            // Tap anywhere on it: the enabled launcher component, so the tap
            // lands on whichever icon variant the owner has switched to.
            val launch = context.packageManager
                .getLaunchIntentForPackage(context.packageName)
                ?.apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
                ?: Intent(context, MainActivity::class.java)
            val tap = PendingIntent.getActivity(
                context,
                0,
                launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            views.setOnClickPendingIntent(R.id.widget_root, tap)

            return views
        }
    }
}
