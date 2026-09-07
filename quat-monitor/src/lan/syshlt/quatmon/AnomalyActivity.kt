package lan.syshlt.quatmon

import android.app.Activity
import android.os.Bundle
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast

/*
 * Collects the description for a mark that has already been timestamped.
 *
 * Opened from the notification the service posts the moment the mark is taken,
 * so however long this dialog sits open, the recorded time is still the
 * instant the anomaly was seen rather than the instant it was described.
 */
class AnomalyActivity : Activity() {

    companion object { const val EXTRA_ID = "id" }

    override fun onCreate(saved: Bundle?) {
        super.onCreate(saved)
        val id = intent.getLongExtra(EXTRA_ID, 0L)
        if (id == 0L) { finish(); return }

        setTitle("Anomaly at ${Anomaly.iso(id).substring(11, 19)}")

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(32, 24, 32, 24)
        }
        root.addView(TextView(this).apply {
            text = "What did you see? (orientation, which app, what was wrong)"
            textSize = 14f
        })
        val input = EditText(this).apply {
            hint = "e.g. YouTube upside down after unlocking"
            minLines = 3
            setSingleLine(false)
        }
        root.addView(input, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        val bar = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        bar.addView(Button(this).apply {
            text = "Save"
            isAllCaps = false
            setOnClickListener {
                val t = input.text.toString()
                val dir = SamplerService.logDir(this@AnomalyActivity)
                /* File I/O off the main thread even though it is a few hundred
                 * bytes -- this lands on the host's LUKS volume. */
                Thread({ Anomaly.describe(dir, id, t) }, "quat-describe").start()
                Toast.makeText(this@AnomalyActivity,
                    "Saved. Capture is being collected.", Toast.LENGTH_SHORT).show()
                finish()
            }
        }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        bar.addView(Button(this).apply {
            text = "Skip"
            isAllCaps = false
            setOnClickListener { finish() }
        }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        root.addView(bar)

        setContentView(root)
    }
}
