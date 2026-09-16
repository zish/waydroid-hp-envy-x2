package lan.syshlt.removablemedia

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/**
 * A status screen, and a landing place for a notification tap that nothing else
 * could handle. Built programmatically for the same reason as sensor-app: no
 * AndroidX, no Compose, so the build stays four tool invocations.
 *
 * It lists what the app has been *told* about, never what is on disk -- see the
 * note in Volumes.known().
 */
class StatusActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        buildContent()
    }

    override fun onResume() {
        super.onResume()
        // Rebuild from our own record every time the screen is shown, so a
        // volume that arrived while it was backgrounded is not missed.
        buildContent()
    }

    private fun buildContent() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#121212"))
            setPadding(dp(24), dp(32), dp(24), dp(24))
        }

        root.addView(text(getString(R.string.app_name), 22f, Color.WHITE, bold = true))
        root.addView(spacer(dp(4)))

        val volumes = Volumes.known(this)
        if (volumes.isEmpty()) {
            root.addView(
                text(
                    "Nothing attached.\n\nInsert a USB drive or a memory card and it will " +
                        "appear here and in a notification.",
                    15f, Color.parseColor("#B0B0B0")
                )
            )
        } else {
            root.addView(
                text("${volumes.size} attached — tap to open", 14f,
                    Color.parseColor("#B0B0B0"))
            )
            root.addView(spacer(dp(16)))
            for ((label, detail) in volumes) {
                root.addView(row(label, detail))
                root.addView(spacer(dp(10)))
            }
        }

        setContentView(ScrollView(this).apply { addView(root) })
    }

    private fun row(label: String, detail: String): View {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#1E1E1E"))
            setPadding(dp(16), dp(14), dp(16), dp(14))
            isClickable = true
            setOnClickListener {
                try {
                    startActivity(Volumes.openIntent(label))
                } catch (e: Exception) {
                    toastish("No file manager handled that: ${e.message}")
                }
            }
        }
        box.addView(text(label, 17f, Color.WHITE, bold = true))
        box.addView(text(detail, 13f, Color.parseColor("#9E9E9E")))
        return box
    }

    private fun toastish(message: String) {
        android.widget.Toast.makeText(this, message, android.widget.Toast.LENGTH_LONG).show()
    }

    private fun text(value: String, size: Float, colour: Int, bold: Boolean = false) =
        TextView(this).apply {
            this.text = value
            setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
            setTextColor(colour)
            gravity = Gravity.START
            if (bold) setTypeface(typeface, android.graphics.Typeface.BOLD)
        }

    private fun spacer(height: Int) = View(this).apply {
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, height
        )
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()
}
