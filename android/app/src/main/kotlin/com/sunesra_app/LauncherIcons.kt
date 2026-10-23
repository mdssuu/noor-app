package com.sunesra_app

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.util.Log

/**
 * Points the launcher at one of the four icons this build ships with.
 *
 * An icon cannot be downloaded: Android resolves the launcher icon from the
 * app's own resources, so "change the icon for everyone" can only ever mean
 * *choosing* among prepared ones. The four are declared as `activity-alias`
 * entries over [MainActivity], each with its own icon and its own launcher
 * intent filter, and exactly one of them is enabled at a time — which is what
 * makes the switch possible at all, without an update.
 *
 * [MainActivity] stays the activity behind every alias: the launcher starts
 * the alias, Android starts the activity it points at, and the whole app —
 * Flutter engine, alarms, recitation screen — carries on as before.
 *
 * One wrinkle worth knowing about: an **app update** clears every component
 * state back to what the manifest declares, which is variant 0. That is why
 * the choice is also written to preferences and re-applied on the way in,
 * and why the manifest enables variant 0 and disables the rest — a phone
 * that has never been told anything still has exactly one icon to tap.
 */
object LauncherIcons {

    private const val TAG = "Noor/LauncherIcons"

    /** The aliases, in the order Dart counts them (`kLauncherIconLabels`). */
    private val ALIASES = listOf(".Launcher0", ".Launcher1", ".Launcher2", ".Launcher3")

    private const val PREFS = "noor_launcher"
    private const val KEY_VARIANT = "variant"

    /** The variant a fresh install shows — the original gold mosque. */
    const val DEFAULT_VARIANT = 0

    /**
     * Switches the launcher to [variant] and remembers it.
     *
     * Out-of-range values are clamped rather than refused: a hand-edited
     * config document must not be able to leave a phone with no launcher
     * entry at all. Components already in the wanted state are left alone,
     * so calling this on every launch costs one preference read.
     */
    fun apply(context: Context, variant: Int) {
        val app = context.applicationContext
        val index = variant.coerceIn(0, ALIASES.size - 1)
        val pm = app.packageManager
        var changed = false

        for ((position, alias) in ALIASES.withIndex()) {
            val component = ComponentName(app, "${app.packageName}$alias")
            val wanted = if (position == index) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            } else {
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            }
            val current = try {
                pm.getComponentEnabledSetting(component)
            } catch (_: Exception) {
                PackageManager.COMPONENT_ENABLED_STATE_DEFAULT
            }
            if (current == wanted) continue
            try {
                // DONT_KILL_APP: the whole point is that the app keeps
                // running and the launcher refreshes its icon around it.
                pm.setComponentEnabledSetting(component, wanted, PackageManager.DONT_KILL_APP)
                changed = true
            } catch (error: Exception) {
                Log.w(TAG, "cannot switch to $alias: $error")
            }
        }

        app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putInt(KEY_VARIANT, index)
            .apply()

        if (changed) Log.i(TAG, "launcher icon is now alias #$index")
    }

    /** Re-applies the variant from the last run — see the class note. */
    fun restore(context: Context) {
        val app = context.applicationContext
        val variant = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getInt(KEY_VARIANT, DEFAULT_VARIANT)
        apply(context, variant)
    }
}
