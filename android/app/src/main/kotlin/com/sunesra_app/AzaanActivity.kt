package com.sunesra_app

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.view.KeyEvent
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/**
 * The screen a recitation puts up so the volume keys can be taken over.
 *
 * Android hands a key event to the focused window and to nothing else. With the
 * phone locked or Noor shut, that window belongs to the keyguard or the
 * launcher — which is exactly why a volume press during an Azaan did nothing:
 * the clip runs on the **alarm** stream, the one stream the rocker refuses to
 * silence, and no window of this app was on screen to catch the press. An
 * "unstoppable" azaan was never a playback problem, it was a focus problem.
 *
 * So a prayer time brings this screen up — over the lock screen, because a
 * prayer does not wait for an unlock — and here the volume keys mean "stop it",
 * a big button says the same thing, and the screen closes itself the moment the
 * clip does. It is deliberately *not* used for the Settings preview: that one
 * runs with the app in front, where [MainActivity] already has the keys.
 */
class AzaanActivity : Activity() {

    /** Fires from [AzaanAudio] when the clip ends, errors or is torn down. */
    private val onPlaybackEnded: () -> Unit = {
        runOnUiThread {
            if (!isFinishing) finish()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
            )
        }
        window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))

        // A launch that lands after the clip has run out must not leave a card
        // sitting on the lock screen with nothing behind it.
        if (!AzaanAudio.isPlaying()) {
            finish()
            return
        }

        setContentView(buildCard(intent.getStringExtra(EXTRA_TITLE)))
        AzaanAudio.endListeners.add(onPlaybackEnded)
        // Proof in the log that the window the volume keys need is actually up
        // — this line, and only this line, is what makes the fix verifiable.
        Log.i(TAG, "recitation screen up (over the lock screen if it was off)")
    }

    override fun onResume() {
        super.onResume()
        // The clip can be brought down from under this screen — the activity
        // in front takes the volume key too — so a return to it with nothing
        // playing must not leave a stale card behind.
        if (!AzaanAudio.isPlaying()) finish()
    }

    override fun onDestroy() {
        AzaanAudio.endListeners.remove(onPlaybackEnded)
        super.onDestroy()
    }

    /**
     * The whole point of the screen: a volume press is the mute the user
     * reaches for, so it is taken over and the playback is torn down instead
     * of Android quietly moving the alarm volume of a clip that keeps going.
     */
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN || keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
            Log.i(TAG, "volume key $keyCode pressed — stopping the recitation")
            AzaanPlaybackService.stopFromAnywhere(this)
            finish()
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    /** Back steps away from the control, not out of the recitation. */
    override fun onBackPressed() = finish()

    /** One column, built in code: there is nothing here worth a layout file. */
    private fun buildCard(title: String?): LinearLayout {
        val body = TextView(this).apply {
            text = title?.takeIf { it.isNotBlank() } ?: "Azaan is playing"
            setTextColor(Color.WHITE)
            textSize = 24f
            gravity = Gravity.CENTER
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        }
        val hint = TextView(this).apply {
            text = "Press either volume key to stop it"
            setTextColor(Color.parseColor("#CCFFFFFF"))
            textSize = 15f
            gravity = Gravity.CENTER
            setPadding(0, dp(10), 0, 0)
        }
        val stop = Button(this).apply {
            text = "STOP AZAN"
            textSize = 16f
            setOnClickListener {
                AzaanPlaybackService.stopFromAnywhere(this@AzaanActivity)
                finish()
            }
        }

        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.argb(238, 8, 34, 30))
            setPadding(dp(32), dp(48), dp(32), dp(48))
            addView(
                body,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ),
            )
            addView(
                hint,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ),
            )
            addView(
                stop,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ).apply { topMargin = dp(28) },
            )
        }
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()

    companion object {
        private const val TAG = "Noor/AzanActivity"
        const val EXTRA_TITLE = "title"

        /** One launch style for every caller, so a repeat never stacks. */
        fun launch(context: android.content.Context, title: String?): Intent =
            Intent(context, AzaanActivity::class.java)
                .putExtra(EXTRA_TITLE, title)
                .addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP,
                )
    }
}
