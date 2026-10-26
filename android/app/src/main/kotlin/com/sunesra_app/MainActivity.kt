package com.sunesra_app

import android.app.NotificationManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import android.view.KeyEvent
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Registers the `noor_masjid_time/azaan` channel.
 *
 * It exists because a notification channel cannot cover every case: it plays
 * the bundled mp3 with the app closed, but not with the phone on silent, and
 * it cannot be re-tuned from Dart once Android has frozen it. Everything the
 * Dart side needs — arm an exact alarm, retire one, play a clip on the alarm
 * stream now, and ask for the two permissions that decide whether any of it
 * arrives on time — is answered from here.
 */
class MainActivity : FlutterActivity() {

    private var azaanChannel: MethodChannel? = null

    /**
     * Whether this activity is the one in front.
     *
     * A recitation has no reason to raise its own screen over the app that is
     * already taking the volume keys — [onKeyDown] does that job — so the
     * playback service asks this before deciding to put one up.
     */
    companion object {
        @Volatile
        var visible: Boolean = false
            private set

        private const val TAG = "Noor/MainActivity"
        private const val CHANNEL_NAME = "noor_masjid_time/azaan"
        private const val WIDGET_CHANNEL_NAME = "noor_masjid_time/widget"
        private const val METHOD_WIDGET_CLEAR = "clear"
        private const val METHOD_WIDGET_UPDATE = "update"

        private const val METHOD_SCHEDULE = "schedule"
        private const val METHOD_CANCEL = "cancel"
        private const val METHOD_CANCEL_RANGE = "cancelRange"
        private const val METHOD_PLAY_NOW = "playNow"
        private const val METHOD_STOP = "stop"
        private const val METHOD_CAN_SCHEDULE_EXACT = "canScheduleExact"
        private const val METHOD_ALARM_LEDGER = "alarmLedger"
        private const val METHOD_ARE_NOTIFICATIONS_ENABLED = "areNotificationsEnabled"
        private const val METHOD_REQUEST_EXACT_ALARM = "requestExactAlarm"
        private const val METHOD_REQUEST_NO_BATTERY_OPTIMISATION = "requestNoBatteryOptimisation"
        private const val METHOD_CAN_USE_FULLSCREEN_INTENT = "canUseFullScreenIntent"
        private const val METHOD_REQUEST_FULLSCREEN_INTENT = "requestFullScreenIntent"
        private const val METHOD_CAN_DRAW_OVERLAYS = "canDrawOverlays"
        private const val METHOD_REQUEST_OVERLAY = "requestOverlay"
        private const val METHOD_NEEDS_OVERLAY = "deviceNeedsOverlay"
        private const val METHOD_PLAYBACK_FINISHED = "playbackFinished"
        private const val METHOD_STOP_REQUESTED = "stopRequested"
        private const val METHOD_SET_LAUNCHER_ICON = "setLauncherIcon"

        // The lock-screen prayer card's two upstream switches, read together:
        // notifications at all, and the phone's own "on the lock screen" one.
        private const val METHOD_LOCK_SCREEN_STATUS = "lockScreenStatus"
        private const val METHOD_OPEN_NOTIFICATION_SETTINGS = "openNotificationSettings"
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // An app update clears every component state back to the manifest's
        // defaults, which means the icon everyone sees *before* Dart has said
        // anything is variant 0 — so the owner's last choice is re-applied on
        // the way in. See [LauncherIcons] for why aliases are how this works.
        LauncherIcons.restore(this)
    }

    override fun onResume() {
        super.onResume()
        visible = true
    }

    override fun onPause() {
        visible = false
        super.onPause()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        azaanChannel = channel

        // Only the player knows when a preview really ended, and the settings
        // row has to stop highlighting itself at that exact moment.
        AzaanAudio.onFinished = {
            runOnUiThread {
                try {
                    channel.invokeMethod(METHOD_PLAYBACK_FINISHED, null)
                } catch (_: Exception) {
                }
            }
        }

        channel.setMethodCallHandler { call, result -> handle(call, result) }

        // The home-screen widget's one-way dialect: Dart sends a prepared
        // picture of the day as JSON, this side stores it and redraws every
        // placed widget. The split exists because prayer times come out of
        // an engine only this process can host — see NoorWidgetProvider.
        // The lock-screen card has no channel of its own: it eats from the
        // same stored picture, refreshed right after every push.
        val widgetChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            WIDGET_CHANNEL_NAME,
        )
        widgetChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                METHOD_WIDGET_CLEAR -> {
                    NoorWidgetProvider.clear(this)
                    LockScreenNotifier.clear(this)
                    result.success(null)
                }
                METHOD_WIDGET_UPDATE -> {
                    val json = call.arguments as? String
                    if (json == null) {
                        result.error("bad-args", "payload JSON string required", null)
                    } else {
                        android.util.Log.i(TAG, "widget picture received from Dart")
                        NoorWidgetProvider.push(this, json)
                        LockScreenNotifier.refresh(this)
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                METHOD_SCHEDULE -> {
                    val id = call.argument<Int>("id")
                    val atMs = call.argument<Number>("atMs")
                    val sound = call.argument<String>("sound")
                    if (id == null || atMs == null || sound.isNullOrBlank()) {
                        result.error("bad-args", "id, atMs and sound are required", null)
                        return
                    }
                    AzaanAlarms.schedule(
                        context = this,
                        id = id,
                        atMs = atMs.toLong(),
                        sound = sound,
                        title = call.argument<String>("title"),
                        // Prayer alarms come back tomorrow; the Settings probe
                        // deliberately does not, or it would ring every morning.
                        recurring = call.argument<Boolean>("recurring") ?: true,
                    )
                    result.success(null)
                }

                METHOD_CANCEL -> {
                    val id = call.argument<Int>("id")
                    if (id == null) {
                        result.error("bad-args", "id is required", null)
                        return
                    }
                    AzaanAlarms.cancel(this, id)
                    result.success(null)
                }

                // The keys here are a contract with `AzaanAlarm.cancelRange`,
                // which sends `from` / `to`. Reading `until` instead used to
                // hand back bad-args on every call, and Dart's `_call` only
                // debugPrints a PlatformException — so no range was ever
                // retired and an un-starred masjid kept reciting from the
                // alarm stream long after its notification was cancelled.
                METHOD_CANCEL_RANGE -> {
                    val from = call.argument<Int>("from")
                    val to = call.argument<Int>("to")
                    if (from == null || to == null) {
                        result.error("bad-args", "from and to are required", null)
                        return
                    }
                    AzaanAlarms.cancelRange(this, from, to)
                    result.success(null)
                }

                // The owner picked a different launcher icon. Nothing about
                // the running app changes — only which alias the launcher
                // starts next time, which is the entire trick.
                METHOD_SET_LAUNCHER_ICON -> {
                    val variant = call.argument<Number>("variant")?.toInt() ?: 0
                    LauncherIcons.apply(this, variant)
                    result.success(null)
                }

                // The preview must not consult the ringer mode: the user
                // pressed the button to *hear* it, whatever the phone is set to.
                METHOD_PLAY_NOW -> {
                    val sound = call.argument<String>("sound")
                    result.success(!sound.isNullOrBlank() && AzaanAudio.play(this, sound))
                }

                // Dart is the one asking, so Dart does not need telling — and
                // telling it is not free. [stopAzaan] echoes `stopRequested`
                // back over the channel; that reply is delivered one frame
                // later, *after* whatever Dart starts next, and its handler
                // stops again. A preview was therefore torn down 20 ms after
                // it began, which is how "Test Azaan" could report a running
                // player while making a sound nobody could have heard. The
                // synchronous stop below is the whole answer here; the echo
                // belongs to stops that started on this side, where the chain
                // upward does not already know.
                //
                // The service is asked to stand down too — its "STOP AZAN"
                // notification must not outlive the clip — but only when it is
                // actually up, which is what makes that dispatch harmless:
                // see [AzaanPlaybackService.stopFromAnywhere].
                METHOD_STOP -> {
                    AzaanAudio.stop()
                    stopAzaanService()
                    result.success(null)
                }

                METHOD_CAN_SCHEDULE_EXACT -> result.success(AzaanAlarms.canScheduleExact(this))

                // What the alarm ledger actually holds, for the admin panel's
                // diagnostics. It is the same map `rearmAll` walks after a
                // reboot, so what is listed here is what survives one — the
                // honest answer to "is my Fajr armed?", which the Dart side
                // cannot answer on its own because the ledger lives in
                // SharedPreferences on this side of the channel.
                METHOD_ALARM_LEDGER -> result.success(alarmLedger())

                // Android 13+ made notifications a runtime permission, and a
                // single "Don't allow" leaves every reminder silently
                // unschedulable-looking: the alarms fire, the recitation runs,
                // and no banner ever appears. The app has to be able to *ask*
                // whether it is in that state, not assume it is not.
                METHOD_ARE_NOTIFICATIONS_ENABLED -> result.success(areNotificationsEnabled())

                METHOD_REQUEST_EXACT_ALARM -> {
                    AzaanAlarms.openExactAlarmSettings(this)
                    result.success(null)
                }

                METHOD_REQUEST_NO_BATTERY_OPTIMISATION -> {
                    AzaanAlarms.openBatteryOptimisationPrompt(this)
                    result.success(null)
                }

                // The recitation screen only lands where the system allows a
                // full-screen view — Android 14+ made that its own switch, and
                // without it a locked phone has no window of ours to catch the
                // volume key.
                METHOD_CAN_USE_FULLSCREEN_INTENT -> result.success(canUseFullScreenIntent())

                METHOD_REQUEST_FULLSCREEN_INTENT -> {
                    openFullScreenIntentSettings()
                    result.success(null)
                }

        // MIUI's "Display pop-up windows while running in the
                // background". Checked on every return to the app: when the
                // full-screen route is blocked as well, this is the permission
                // that decides whether a recitation has any window at all.
                METHOD_CAN_DRAW_OVERLAYS -> result.success(canDrawOverlays())

                METHOD_REQUEST_OVERLAY -> {
                    openOverlaySettings()
                    result.success(null)
                }

                // Whether this OEM is one that refuses a background activity
                // start outright, making the overlay permission the last route
                // to a window. MIUI is the archetypal case: `appops get`
                // shows the rejection landing at the exact second an alarm
                // fires, and nothing in the app is told.
                METHOD_NEEDS_OVERLAY -> result.success(PopUpWindows.isMiuiFamily())

                // The lock-screen card has one owner the app cannot reach:
                // the phone's own "notifications on the lock screen" switch.
                // Off, and the card posts perfectly into the shade and
                // vanishes the moment the phone locks — which reads as a
                // broken app. The Dart side reads this and says so, with the
                // page that holds the switch one tap away.
                METHOD_LOCK_SCREEN_STATUS -> result.success(lockScreenStatus())

                METHOD_OPEN_NOTIFICATION_SETTINGS -> {
                    openAppNotificationSettings()
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("azaan-error", error.message, null)
        }
    }

    /**
     * Brings an Azaan down wherever it is sounding.
     *
     * There is exactly one player in the process — [AzaanAudio], which is the
     * global `mediaPlayer` both `playNow()` and the alarm twin hand their clip
     * to — so stopping it is stopping *the* azaan, not just the preview. Its
     * [AzaanAudio.stop] is stop + release: player stopped, reset, released and
     * its wake lock dropped, so nothing can keep sounding after this returns.
     * The foreground service is told to stand down too, which is what removes
     * its "STOP AZAN" notification.
     */
    private fun stopAzaan() {
        AzaanAudio.stop()
        stopAzaanService()
        notifyDartToStop()
        announceStopped()
    }

    /**
     * The alarm ledger as a list, for the admin panel's diagnostics.
     *
     * This is the same map [AzaanAlarms.rearmAll] walks after a reboot, so
     * what is returned here is what survives one — the honest answer to "is
     * my Fajr actually armed?", which the Dart side cannot answer for itself
     * because the ledger lives in SharedPreferences on this side of the
     * channel. Sorted by id so the five calculated reminders stay in prayer
     * order ahead of the favourite-masjid block.
     */
    private fun alarmLedger(): List<Map<String, Any?>> =
        AzaanAlarms.specs(this)
            .toSortedMap()
            .map { (id, spec) ->
                mapOf(
                    "id" to id,
                    "hour" to spec.hour,
                    "minute" to spec.minute,
                    "sound" to spec.sound,
                    "title" to spec.title,
                    "recurring" to spec.recurring,
                )
            }

    /**
     * The Dart side can hold a clip of its own — the fallback player that runs
     * where the native one does not. A stop pressed here has to reach it too,
     * or the key is swallowed and the clip plays on, which is one way "the
     * volume button does nothing" came about.
     */
    private fun notifyDartToStop() {
        val channel = azaanChannel ?: return
        runOnUiThread {
            try {
                channel.invokeMethod(METHOD_STOP_REQUESTED, null)
            } catch (_: Exception) {
            }
        }
    }

    /**
     * Whether Android will show this app's notifications at all.
     *
     * One "Don't allow" on the Android 13+ prompt — or the same switch in
     * system settings a month later — is enough to make every reminder
     * invisible while its alarms keep firing normally. The Dart side reads
     * this and says so, rather than letting the app look like it is working.
     */
    private fun areNotificationsEnabled(): Boolean =
        NotificationManagerCompat.from(this).areNotificationsEnabled()

    /**
     * The two switches that decide whether the lock-screen card can be seen:
     * notifications at all, and the phone's own lock-screen visibility one.
     *
     * The second lives entirely with the user — Android keeps it away from
     * apps — so a card posted with `VISIBILITY_PUBLIC` into a phone that has
     * it off still shows only while unlocked. Every maker names it their own
     * way ("On the lock screen", "Lock screen notifications", "Show while
     * locked"), but the secure setting behind the AOSP one is a single read,
     * and a phone that does not carry it counts as visible: showing lock
     * notifications is the platform default. OEM pages that keep a *separate*
     * per-app toggle are reached through the settings page this opens, where
     * the row's own text points the user at whatever it is called there.
     */
    private fun lockScreenStatus(): Map<String, Any> = mapOf(
        "notificationsEnabled" to NotificationManagerCompat.from(this).areNotificationsEnabled(),
        "lockScreenNotifications" to (
            Build.VERSION.SDK_INT < Build.VERSION_CODES.N ||
                Settings.Secure.getInt(
                    contentResolver,
                    // The platform's own key — SystemUI's
                    // NotificationLockscreenUserManagerImpl reads the same one
                    // to decide whether *any* app may show there — but the
                    // constant is @hide, so it is named by its string rather
                    // than compiled against. An absent key defaults to 1:
                    // showing is the platform default.
                    "lock_screen_show_notifications",
                    1,
                ) == 1
            ),
    )

    /**
     * Opens this app's notification page — the one screen every phone has
     * that carries its lock-screen switch, under whatever name the maker gave
     * it. Both spellings of the package extra go along: API 26+ reads
     * [Settings.EXTRA_APP_PACKAGE] ("android.provider.extra.APP_PACKAGE"),
     * older pages and several OEM forks still read "app_package". A skin with
     * no page of its own falls back to the app detail screen, whose
     * Notifications row leads to the same place.
     */
    private fun openAppNotificationSettings() {
        try {
            startActivity(
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra("app_package", packageName)
                    .putExtra("android.provider.extra.APP_PACKAGE", packageName)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (error: Exception) {
            Log.w(TAG, "cannot open notification settings: ${error.message}")
            try {
                startActivity(
                    Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:$packageName"),
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            } catch (ignored: Exception) {
                // A phone that refuses both leaves the row merely useless;
                // it must not take the screen down with it.
            }
        }
    }

    /**
     * Whether this app may place windows over others.
     *
     * Delegates to [PopUpWindows] because there is more than one switch here
     * and the app's warning names the MIUI one: `Settings.canDrawOverlays`
     * answers for the AOSP overlay permission, while MIUI keeps the toggle the
     * message actually talks about — "Display pop-up windows while running in
     * the background" — behind its own private op 10021. Reading only the
     * first is what let the warning stay on for a user who had already
     * granted the second. `appops get` on a Redmi shows the rejection landing
     * at the exact second an alarm fires.
     */
    private fun canDrawOverlays(): Boolean = PopUpWindows.allowed(this)

    /** Opens the screen that holds the switch being named — MIUI's own
     *  permission editor where there is one, the AOSP overlay page elsewhere. */
    private fun openOverlaySettings() = PopUpWindows.openSettings(this)

    /** Android 14+ asks the user before an app may raise a full-screen view. */
    private fun canUseFullScreenIntent(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE ||
            getSystemService(NotificationManager::class.java)?.canUseFullScreenIntent() == true

    private fun openFullScreenIntentSettings() {
        val action =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT
            } else {
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS
            }
        try {
            startActivity(
                Intent(action)
                    .setData(Uri.parse("package:$packageName"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (error: Exception) {
            Log.w(TAG, "cannot open full-screen-intent settings: ${error.message}")
        }
    }

    /** Reports a run that ended, however it ended — a clip stopped by hand
     *  never reaches `OnCompletionListener`, so the Settings row would keep
     *  showing itself as "playing" until the next tap. */
    private fun announceStopped() {
        val channel = azaanChannel ?: return
        runOnUiThread {
            try {
                channel.invokeMethod(METHOD_PLAYBACK_FINISHED, null)
            } catch (_: Exception) {
            }
        }
    }

    /**
     * The volume rocker silences a recitation the user did not ask for.
     *
     * A favourite masjid's Azaan can land in the middle of a namaz, on the
     * alarm stream, which the rocker cannot silence — it only moves the alarm
     * volume of a clip that keeps going. So while one is actually sounding,
     * the key is taken over and the playback is torn down instead; with no
     * Azaan running the keys behave exactly as Android left them.
     *
     * This is the half that needs an activity in front. Nothing here runs
     * with the phone locked, so the rest of the coverage is
     * [AzaanPlaybackService]'s media session (stop control wherever the
     * system renders playing media) and the "STOP AZAN" action on its
     * notification — the same stop, spelled twice more.
     */
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN || keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
            if (AzaanAudio.isPlaying()) {
                Log.i(TAG, "volume key $keyCode in the foreground — stopping the recitation")
                stopAzaan()
                return true
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    /**
     * Asks the playback service to stand down if it is holding one open.
     *
     * The stop goes out as a plain `startService()`, NOT
     * `startForegroundService()` — see [AzaanPlaybackService.stopFromAnywhere],
     * which owns the reasoning and the fallback for when Android refuses a
     * service start from a backgrounded app.
     */
    private fun stopAzaanService() = AzaanPlaybackService.stopFromAnywhere(this)

    override fun onDestroy() {
        visible = false
        AzaanAudio.onFinished = null
        azaanChannel?.setMethodCallHandler(null)
        azaanChannel = null
        super.onDestroy()
    }
}
