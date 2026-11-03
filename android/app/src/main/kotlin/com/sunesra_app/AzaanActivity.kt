package com.sunesra_app

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
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

        setContentView(buildCard(intent.getStringExtra(EXTRA_TITLE)))
        AzaanAudio.endListeners.add(onPlaybackEnded)
        // Proof in the log that the window the volume keys need is actually up
        // — this line, and only this line, is what makes the fix verifiable.
        Log.i(TAG, "recitation screen up (over the lock screen if it was off)")

        // The screen is shown *before* asking whether anything is playing, and
        // that ordering is the fix behind "the Azaan sounds but no popup comes".
        //
        // This window is opened by the card's full-screen intent, and the card
        // is posted by the receiver *before* it starts [AzaanPlaybackService] —
        // so at the moment this activity is created `AzaanAudio.isPlaying()` is
        // routinely still false. Finishing on that answer closed the popup
        // before it had ever been drawn, every time, and the recitation then
        // ran with no window of ours on the lock screen at all. The old code
        // read a race as a fact.
        //
        // A launch that really does land after the clip has run out still has
        // to go away; that is what the watchdog is for — if nothing is sounding
        // by the time the clip would certainly have begun, there is nothing to
        // control.
        watchdog.postDelayed(absentCheck, ABSENCE_GRACE_MS)
    }

    /** Nothing ever started under this window — close it, silently. */
    private val absentCheck = Runnable {
        if (!AzaanAudio.isPlaying() && !isFinishing) {
            Log.i(TAG, "no recitation started — closing the screen")
            finish()
        }
    }

    private val watchdog = Handler(Looper.getMainLooper())

    override fun onResume() {
        super.onResume()
        // Deliberately no "finish if nothing is playing" here. `onResume`
        // lands in the same instant as `onCreate` for this launch, so it read
        // the same premature false and closed the popup the fix above opens.
        // The watchdog and the clip's own end listener answer the same case
        // with an answer that is actually about the clip.
    }

    override fun onDestroy() {
        watchdog.removeCallbacks(absentCheck)
        AzaanAudio.endListeners.remove(onPlaybackEnded)
        super.onDestroy()
    }

    /**
     * The whole point of the screen: a volume press is not a request for a
     * softer Azaan, it is the mute the user reaches for — "strictly off" was
     * the ask — so it is taken over and the playback is torn down rather than
     * the phone lowering a number while the clip plays on.
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

        /**
         * How long the screen waits for the clip the card promised.
         *
         * Long enough for a service start and a decoder handshake on a busy
         * phone, short enough that a launch which landed after the clip ended
         * does not leave a dead window on the lock screen.
         */
        private const val ABSENCE_GRACE_MS = 6_000L

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
