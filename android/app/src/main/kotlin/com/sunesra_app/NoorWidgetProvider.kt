package com.sunesra_app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.view.View
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
 * picture was ever sent), the widget still renders — with a hint line that
 * says to open the app, rather than a header over nothing.
 *
 * Each of the five prayers draws with the day's reading for it beneath its
 * time — the same pool the in-app reading cards show, already translated
 * by Dart into the reader's chosen language. The layout carries two faces
 * per reading (Nastaliq and plain) because RemoteViews cannot switch a
 * typeface at draw time; [render] shows exactly one of them.
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

        /** The five prayers, in the order the blocks are drawn. */
        private val PRAYER_KEYS =
            arrayOf("fajr", "dhuhr", "asr", "maghrib", "isha")

        /** The name, clock, reading and block of each prayer, index-aligned. */
        private val NAME_VIEWS =
            intArrayOf(R.id.widget_p0_name, R.id.widget_p1_name,
                R.id.widget_p2_name, R.id.widget_p3_name, R.id.widget_p4_name)
        private val TIME_VIEWS =
            intArrayOf(R.id.widget_p0_time, R.id.widget_p1_time,
                R.id.widget_p2_time, R.id.widget_p3_time, R.id.widget_p4_time)
        private val QUOTE_VIEWS =
            intArrayOf(R.id.widget_p0_quote, R.id.widget_p1_quote,
                R.id.widget_p2_quote, R.id.widget_p3_quote, R.id.widget_p4_quote)
        private val QUOTE_URDU_VIEWS =
            intArrayOf(R.id.widget_p0_quote_urdu, R.id.widget_p1_quote_urdu,
                R.id.widget_p2_quote_urdu, R.id.widget_p3_quote_urdu,
                R.id.widget_p4_quote_urdu)
        private val BLOCK_VIEWS =
            intArrayOf(R.id.widget_block_0, R.id.widget_block_1,
                R.id.widget_block_2, R.id.widget_block_3, R.id.widget_block_4)

        /**
         * Empties the widget.
         *
         * The payload goes, so the widget falls back to its blank state
         * instead of showing the last prayer times it was handed.
         */
        fun clear(context: Context) {
            prefs(context).edit().remove(KEY_PAYLOAD).apply()
            updateAll(context)
        }

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
            // opened still looks deliberate rather than empty — and the hint
            // line under the header says what to do about it.
            var city = "Prayer times"
            var hijri = ""
            var dateLabel = ""
            var nextLabel = "Next"
            var nextTime = "—"
            var noPayload = true
            // The app's default reading language: only an old payload that
            // predates the field could be silent, and Urdu is what it means.
            var urdu = true
            var tomorrow = false
            val byKey = mutableMapOf<String, JSONObject>()

            val raw = prefs(context).getString(KEY_PAYLOAD, null)
            if (raw != null) {
                try {
                    val json = JSONObject(raw)
                    noPayload = false

                    val now = System.currentTimeMillis()
                    // Past the prepared day's local midnight every row has a
                    // `tomorrowTime` / `tomorrowQuote` twin waiting, and the
                    // date and Hijri headers have theirs — the phone's clock
                    // alone decides which half of the picture is true now.
                    val dayEndMs = json.optLong("dayEndMs", 0L)
                    tomorrow = dayEndMs > 0L && now >= dayEndMs
                    urdu = json.optString("readingLang", "urdu") == "urdu"

                    city = json.optString("city").ifBlank { "Prayer times" }
                    hijri = (if (tomorrow) json.optString("hijriTomorrow") else "")
                        .ifBlank { json.optString("hijri") }
                    dateLabel = (if (tomorrow) json.optString("dateLabelTomorrow") else "")
                        .ifBlank { json.optString("dateLabel") }

                    val prayers = json.optJSONArray("prayers") ?: JSONArray()
                    for (i in 0 until prayers.length()) {
                        val p = prayers.optJSONObject(i) ?: continue
                        // `key` is what the rows are found by; the lowercased
                        // label stands in for a picture stored by an older
                        // build, which carried labels and nothing else.
                        val key = p.optString("key")
                            .ifBlank { p.optString("label").lowercase() }
                        if (key.isNotEmpty()) byKey[key] = p
                    }

                    // The first table entry still ahead of the phone's clock
                    // is today's next prayer; past the whole table, the last
                    // entry stands in until the next app-open refreshes it.
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
                    noPayload = true
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
            views.setViewVisibility(
                R.id.widget_hint,
                if (noPayload) View.VISIBLE else View.GONE,
            )

            // Each block: name and clock on the first line, the day's reading
            // for that prayer under it — in exactly one of the two faces, the
            // Nastaliq one or the plain one, matching the language the reader
            // chose in the app. A picture without readings (stored before the
            // widget learned them) simply leaves the second line out.
            for (i in PRAYER_KEYS.indices) {
                val p = byKey[PRAYER_KEYS[i]]
                val name = p?.optString("label").orEmpty()
                val time = pick(p, tomorrow, "time")
                val quote = pick(p, tomorrow, "quote")
                val source = pick(p, tomorrow, "source")

                views.setTextViewText(NAME_VIEWS[i], name)
                views.setTextViewText(TIME_VIEWS[i], time)
                val line = when {
                    quote.isEmpty() -> ""
                    source.isEmpty() -> quote
                    // Source first: whatever the ellipsis cuts, it never cuts
                    // away whose words these are.
                    else -> "$source — $quote"
                }
                views.setTextViewText(QUOTE_VIEWS[i], line)
                views.setTextViewText(QUOTE_URDU_VIEWS[i], line)
                val showQuote = line.isNotEmpty()
                views.setViewVisibility(
                    QUOTE_VIEWS[i],
                    if (showQuote && !urdu) View.VISIBLE else View.GONE,
                )
                views.setViewVisibility(
                    QUOTE_URDU_VIEWS[i],
                    if (showQuote && urdu) View.VISIBLE else View.GONE,
                )
                views.setViewVisibility(
                    BLOCK_VIEWS[i],
                    if (name.isEmpty() && time.isEmpty()) View.GONE else View.VISIBLE,
                )
            }

            // Sunrise falls between Fajr and Dhuhr in the day and gets the one
            // slim line there — no reading, because it is not a prayer.
            val rise = byKey["sunrise"]
            val riseTime = pick(rise, tomorrow, "time")
            val riseLabel = rise?.optString("label").orEmpty().ifBlank { "Sunrise" }
            val riseText = if (riseTime.isEmpty()) "" else "$riseLabel  $riseTime"
            views.setTextViewText(R.id.widget_sunrise, riseText)
            views.setViewVisibility(
                R.id.widget_sunrise,
                if (riseText.isEmpty()) View.GONE else View.VISIBLE,
            )

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

        /**
         * One field of a prayer's entry, for whichever half of the picture
         * the clock says is true — with tomorrow's copy falling back to
         * today's when the picture predates it, so an old payload keeps
         * rendering instead of reading as empty.
         *
         * `internal` because the lock-screen card reads the same picture and
         * must pick by the same rule, or the two surfaces would disagree
         * about every clock after midnight.
         */
        internal fun pick(p: JSONObject?, tomorrow: Boolean, field: String): String {
            if (p == null) return ""
            if (tomorrow) {
                val next = p.optString(
                    "tomorrow" + field.replaceFirstChar { it.uppercaseChar() },
                )
                if (next.isNotEmpty()) return next
            }
            return p.optString(field)
        }
    }
}
