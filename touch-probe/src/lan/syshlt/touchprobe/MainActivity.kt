package lan.syshlt.touchprobe

import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.WindowInsets
import android.view.WindowManager
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Full-screen host for [TouchView], plus a report file so the measured contact
 * count can be read off the host instead of off the screen.
 *
 * The report also records which of the three android.hardware.touchscreen.*
 * features the platform declares, because the whole point of the exercise is
 * the gap between what the panel can do and what Android says it can do.
 *
 * FLAG_KEEP_SCREEN_ON matters more here than usual: Android's display policy
 * drives the real panel backlight on this host (docs/42), so without it the
 * screen dims 10 s after the last Android touch -- in the middle of a test
 * whose whole content is touching the screen.
 */
class MainActivity : Activity() {

    private lateinit var view: TouchView

    private val features = listOf(
        "android.hardware.touchscreen",
        "android.hardware.touchscreen.multitouch",
        "android.hardware.touchscreen.multitouch.distinct",
        "android.hardware.touchscreen.multitouch.jazzhand",
        "android.hardware.faketouch",
        "android.hardware.faketouch.multitouch.distinct",
        "android.hardware.faketouch.multitouch.jazzhand"
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        view = TouchView(this)
        view.onNewMax = { writeReport() }
        setContentView(view)

        // AFTER setContentView, always. window.insetsController reaches through
        // PhoneWindow to the DecorView, and before setContentView there is no
        // DecorView -- the getter itself throws, so a `?.` does not save it.
        goFullScreen()
    }

    private fun goFullScreen() {
        try {
            if (Build.VERSION.SDK_INT >= 30) {
                window.setDecorFitsSystemWindows(false)
                window.insetsController?.hide(WindowInsets.Type.systemBars())
            } else {
                @Suppress("DEPRECATION")
                window.decorView.systemUiVisibility = 0x00000004 or 0x00000002 or 0x00001000
            }
        } catch (t: Throwable) {
            // Cosmetic only. A probe must not die because the status bar stayed.
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) goFullScreen()
    }

    override fun onPause() {
        super.onPause()
        writeReport()
    }

    private fun writeReport() {
        try {
            val dir = File(getExternalFilesDir(null), "reports")
            dir.mkdirs()
            val stamp = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date())
            val text = buildString {
                appendLine("Touch Probe report")
                appendLine("written $stamp")
                appendLine()
                append(view.summary())
                appendLine()
                appendLine("declared platform features:")
                for (f in features) {
                    val has = packageManager.hasSystemFeature(f)
                    appendLine("  %-52s %s".format(f, if (has) "YES" else "no"))
                }
                appendLine()
                appendLine("build: ${Build.MODEL} / ${Build.DEVICE} / SDK ${Build.VERSION.SDK_INT}")
            }
            File(dir, "touch-probe.txt").writeText(text)
        } catch (t: Throwable) {
            // A probe that crashes on its own bookkeeping is worse than one
            // that silently loses the file; the screen still has the answer.
        }
    }
}
