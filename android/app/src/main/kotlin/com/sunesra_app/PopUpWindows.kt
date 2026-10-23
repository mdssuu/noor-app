package com.sunesra_app

import android.app.Activity
import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Process
import android.provider.Settings
import android.util.Log

/**
 * "May this app put a window up while it is in the background?" — the one
 * permission the recitation screen lives or dies by.
 *
 * There are **two** switches here, and they are not the same switch, which is
 * exactly how the warning in `main.dart` came to be wrong:
 *
 *  * `SYSTEM_ALERT_WINDOW` (op 24), the AOSP one, which
 *    [Settings.canDrawOverlays] reads. It is what `ACTION_MANAGE_OVERLAY_PERMISSION`
 *    opens the screen for.
 *  * MIUI's private op **10021**, which the Settings app labels *"Display
 *    pop-up windows while running in the background"*. A separate toggle, off
 *    by default, and the one the app's own warning names.
 *
 * The app was checking the first while the message talked about the second, so
 * a user who switched on the setting the message asked for was still told the
 * phone was blocking them — and the message had no way to become false. Either
 * switch open is enough to let a background launch through on its own device,
 * so both are asked.
 *
 * MIUI also has no public API for op 10021. [miuiAllowsBackgroundPopup] uses
 * the same app-op number Telegram and the documented workarounds use, and
 * declines to ask on anything that is not Xiaomi-family, where the op does not
 * exist.
 */
object PopUpWindows {

    private const val TAG = "Noor/PopUpWindows"

    /** MIUI's private op for "Display pop-up windows while running in the
     *  background". Absent outside the MIUI family — never queried there. */
    private const val OP_BACKGROUND_START_ACTIVITY = 10021

    /** Whether a background recitation may raise a window at all. */
    fun allowed(context: Context): Boolean =
        Settings.canDrawOverlays(context) || miuiAllowsBackgroundPopup(context)

    /** Whether this is the OEM that keeps its pop-up switch behind op 10021.
     *  Same test as `MainActivity.deviceNeedsOverlay` — a build, not a guess. */
    fun isMiuiFamily(): Boolean {
        val vendor = Build.MANUFACTURER.lowercase() + Build.BRAND.lowercase()
        return listOf("xiaomi", "redmi", "poco").any(vendor::contains)
    }

    /**
     * Reads MIUI's own toggle.
     *
     * The integer form of `checkOpNoThrow` is the call that takes op 10021,
     * and it is no longer on the public SDK — op 10021 was never public in the
     * first place, so the argument is fetched by signature the way every other
     * caller of MIUI's private ops does it. Three ways this comes back false
     * rather than throwing: the op is not registered on AOSP-based builds (it
     * answers "Bad operation"), the reflection target is not there at all, and
     * a MIUI build that has never been touched answers anything but
     * [AppOpsManager.MODE_ALLOWED] — which is the honest answer anyway, since
     * default is denied.
     */
    private fun miuiAllowsBackgroundPopup(context: Context): Boolean {
        if (!isMiuiFamily()) return false
        return try {
            val ops = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
            val check = AppOpsManager::class.java.getMethod(
                "checkOpNoThrow",
                Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType,
                String::class.java,
            )
            val mode = check.invoke(ops, OP_BACKGROUND_START_ACTIVITY, Process.myUid(), context.packageName)
            mode == AppOpsManager.MODE_ALLOWED
        } catch (error: Exception) {
            Log.w(TAG, "op $OP_BACKGROUND_START_ACTIVITY unreadable: ${error.message}")
            false
        }
    }

    /**
     * Opens the screen that actually holds the switch being complained about.
     *
     * On MIUI that is SecurityCenter's own permission editor — it is where
     * *"Display pop-up windows while running in the background"* is listed,
     * and it is not what `ACTION_MANAGE_OVERLAY_PERMISSION` shows: that one
     * opens the AOSP overlay page, a different toggle, which is why tapping
     * "Allow" used to land the user on a setting they could switch on and
     * still be blocked. Every step falls through to the next if the target is
     * missing, so no device is left with a dead button.
     */
    fun openSettings(activity: Activity) {
        if (isMiuiFamily() && startMiuiEditor(activity)) return
        if (startOverlaySettings(activity)) return
        openAppDetails(activity)
    }

    private fun startMiuiEditor(activity: Activity): Boolean = try {
        val editor = Intent("miui.intent.action.APP_PERM_EDITOR")
            .setPackage("com.miui.securitycenter")
            .putExtra("extra_pkgname", activity.packageName)
            .putExtra("extra_package_uid", Process.myUid())
        if (editor.resolveActivity(activity.packageManager) == null) {
            Log.i(TAG, "no MIUI permission editor on this build")
            false
        } else {
            activity.startActivity(editor)
            true
        }
    } catch (error: Exception) {
        Log.w(TAG, "MIUI permission editor refused: ${error.message}")
        false
    }

    private fun startOverlaySettings(activity: Activity): Boolean = try {
        activity.startActivity(
            Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION)
                .setData(Uri.parse("package:${activity.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        true
    } catch (error: Exception) {
        Log.w(TAG, "overlay settings refused: ${error.message}")
        false
    }

    private fun openAppDetails(activity: Activity) {
        try {
            activity.startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                    .setData(Uri.parse("package:${activity.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (error: Exception) {
            Log.w(TAG, "app details refused: ${error.message}")
        }
    }
}
