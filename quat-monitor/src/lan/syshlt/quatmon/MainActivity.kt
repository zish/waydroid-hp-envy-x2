package lan.syshlt.quatmon

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import java.util.Locale

/*
 * The viewer. Deliberately thin: it starts the service, draws the ring, and
 * gets out of the way. All sampling and I/O happen elsewhere, so nothing here
 * can stall the data path -- closing this activity does not stop logging, and
 * a slow redraw cannot cost a sample.
 */
class MainActivity : Activity() {

    private lateinit var graph: GraphView
    private lateinit var status: TextView
    private lateinit var legend: TextView
    private lateinit var toggle: Button
    private val ui = Handler(Looper.getMainLooper())

    private val refresh = object : Runnable {
        override fun run() {
            updateStatus()
            graph.invalidate()
            ui.postDelayed(this, 500)
        }
    }

    override fun onCreate(saved: Bundle?) {
        super.onCreate(saved)

        /* API 33 gates the foreground-service notification behind a runtime
         * grant. Without it the service still samples, but the notification --
         * and with it the "Report anomaly" action that works from other apps --
         * never appears, which is most of the point. */
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(0xFF12161A.toInt())
        }

        status = TextView(this).apply {
            setTextColor(0xFFCFD8DC.toInt())
            textSize = 12f
            setPadding(16, 12, 16, 4)
        }
        root.addView(status)

        graph = GraphView(this)
        root.addView(graph, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

        legend = TextView(this).apply {
            textSize = 12f
            setPadding(16, 4, 16, 4)
            text = buildLegend()
        }
        root.addView(legend)

        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(8, 0, 8, 8)
        }
        toggle = button("Stop") { onToggle() }
        bar.addView(toggle, row())
        bar.addView(button("Report anomaly") { report() }, row())
        bar.addView(button("Reset zoom") { graph.resetView() }, row())
        root.addView(bar)

        setContentView(root)
        startSampler()
    }

    private fun row() = LinearLayout.LayoutParams(0,
        ViewGroup.LayoutParams.WRAP_CONTENT, 1f)

    private fun button(label: String, onClick: () -> Unit) =
        Button(this).apply {
            text = label
            isAllCaps = false
            setOnClickListener { onClick() }
        }

    private fun buildLegend(): CharSequence {
        val sb = android.text.SpannableStringBuilder()
        fun add(s: String, c: Int) {
            val at = sb.length
            sb.append(s)
            sb.setSpan(android.text.style.ForegroundColorSpan(c), at, sb.length,
                android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        add("hw (ITE8350 9-axis)", 0xFF66BB6A.toInt())
        sb.append("  ")
        add("sw (AOSP 9-axis)", 0xFFFFB300.toInt())
        sb.append("  ")
        add("game (AOSP 6-axis, no magn)", 0xFF4FC3F7.toInt())
        sb.append("  ")
        add("hw-sw", 0xFFEF5350.toInt())
        sb.append("  ")
        add("hw-game", 0xFFBA68C8.toInt())
        sb.append("\n")
        val at = sb.length
        sb.append("band = min/max, line = median   pinch to zoom, drag to pan, double-tap to reset")
        sb.setSpan(android.text.style.ForegroundColorSpan(0xFF78909C.toInt()),
            at, sb.length, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        return sb
    }

    private fun startSampler() {
        startForegroundService(Intent(this, SamplerService::class.java))
        toggle.text = "Stop"
    }

    private fun onToggle() {
        if (SamplerService.ring != null && toggle.text == "Stop") {
            stopService(Intent(this, SamplerService::class.java))
            toggle.text = "Start"
        } else {
            startSampler()
        }
    }

    private fun report() {
        startService(Intent(this, SamplerService::class.java)
            .setAction(SamplerService.ACTION_MARK))
    }

    private fun updateStatus() {
        val r = SamplerService.ring
        val w = SamplerService.writer
        if (r == null || w == null) {
            status.text = "service not running"
            return
        }
        val n = r.size()
        val sb = StringBuilder()
        sb.append("${r.total} samples  |  ${w.written.get()} written")
        val d = w.dropped.get()
        if (d > 0) sb.append("  |  ").append(d).append(" DROPPED")
        sb.append("  |  ").append(w.currentFile).append('\n')

        if (n > 0) {
            val i = r.idx(n - 1)
            sb.append(String.format(Locale.US,
                "hw %+.3f %+.3f %+.3f %+.3f  (age %.0fms)\n",
                r.hwX[i], r.hwY[i], r.hwZ[i], r.hwW[i], r.hwAgeMs[i]))
            sb.append(String.format(Locale.US,
                "sw %+.3f %+.3f %+.3f %+.3f  (age %.0fms)  hw-sw %.2f deg\n",
                r.swX[i], r.swY[i], r.swZ[i], r.swW[i], r.swAgeMs[i], r.angHwSw[i]))
            sb.append(String.format(Locale.US,
                "gm %+.3f %+.3f %+.3f %+.3f  (age %.0fms)  hw-gm %.2f deg   |B| %.1f uT\n",
                r.gmX[i], r.gmY[i], r.gmZ[i], r.gmW[i], r.gmAgeMs[i],
                r.angHwGm[i], r.bUt[i]))
        }
        sb.append(graph.rangeLabel())

        /* A rising age is how a stalled sensor announces itself; anything past
         * a second means it has stopped publishing, not that the machine is
         * still. See docs/19. */
        val stale = n > 0 && (r.hwAgeMs[r.idx(n - 1)] > 1000f ||
                              r.swAgeMs[r.idx(n - 1)] > 1000f ||
                              r.gmAgeMs[r.idx(n - 1)] > 1000f)
        status.setTextColor(if (stale || d > 0) 0xFFEF5350.toInt() else 0xFFCFD8DC.toInt())
        status.text = sb
    }

    override fun onResume() {
        super.onResume()
        ui.post(refresh)
    }

    override fun onPause() {
        super.onPause()
        ui.removeCallbacks(refresh)
    }
}
