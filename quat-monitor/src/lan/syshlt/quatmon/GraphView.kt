package lan.syshlt.quatmon

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.max
import kotlin.math.min

/*
 * Zoomable time series of both quaternions, five stacked panels sharing one
 * time axis: x, y, z, w, and the angle between the two orientations.
 *
 * WHY PER-PIXEL-COLUMN BUCKETING
 *
 * The ring holds up to 144,000 samples and the panel is perhaps a thousand
 * pixels wide, so most of the data can never be drawn as distinct points. Each
 * pixel column therefore summarises the samples that fall in it: a translucent
 * band from min to max (the raw envelope -- nothing is hidden) and a solid line
 * through the median (the smoothed trace that was asked for).
 *
 * That makes the smoothing window follow the zoom for free. Wide out, each
 * column covers minutes and the median is heavily smoothed; zoomed in, columns
 * cover a handful of samples and the line converges on the raw data. A fixed
 * smoothing window would be wrong at one end or the other.
 *
 * Cost is O(visible samples) per recompute, not per frame: the columns are
 * cached and only rebuilt when the range, the width, or the sample count
 * changes. The median takes a strided subsample of at most MED_MAX values per
 * bucket, which bounds the sort and is visually indistinguishable at these
 * column widths.
 *
 * The two quaternions are plotted on a fixed -1.05..1.05 scale rather than
 * autoscaled, so panels stay comparable with each other and over time; a
 * drifting axis would disguise exactly the slow divergence this is meant to
 * catch. The angle panel does autoscale, because its whole range of interest
 * is near zero.
 */
class GraphView(context: Context) : View(context) {

    companion object {
        private const val PANELS = 6
        private const val SERIES = 15
        private const val MED_MAX = 32
        private const val MIN_SPAN = 40           // 2 s at 20 Hz
        private val LABELS = arrayOf("x", "y", "z", "w", "divergence (deg)", "|B| (uT)")
        private const val C_HW = 0xFF66BB6A.toInt()   // hardware, 9-axis: green
        private const val C_SW = 0xFFFFB300.toInt()   // software, 9-axis: amber
        private const val C_GM = 0xFF4FC3F7.toInt()   // software, 6-axis: cyan
        private const val C_ANG = 0xFFEF5350.toInt()  // hw vs sw: red
        private const val C_ANG2 = 0xFFBA68C8.toInt() // hw vs game: violet
        /* docs/14: the local field is near 54 uT. Deviation from it is the
         * hard-iron contamination measure, so it is drawn as a reference. */
        private const val EARTH_UT = 54f
    }

    private val axis = Paint().apply { color = 0xFF546E7A.toInt(); strokeWidth = 1f }
    private val grid = Paint().apply { color = 0x22FFFFFF; strokeWidth = 1f }
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFFB0BEC5.toInt(); textSize = 22f
    }
    private val line = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; strokeWidth = 2f
    }
    private val band = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }

    /* Cached per-column summaries, rebuilt only when the view changes. */
    private var colMin = Array(SERIES) { FloatArray(0) }
    private var colMax = Array(SERIES) { FloatArray(0) }
    private var colMed = Array(SERIES) { FloatArray(0) }
    private var colT0 = 0L
    private var colT1 = 0L
    private var cachedW = -1
    private var cachedSpan = -1
    private var cachedEnd = -1
    private var cachedTotal = -1L
    private var angleMax = 2f
    private var bMax = 80f

    /** Visible window, in samples, ending at [endIndex] (logical, 0..size). */
    private var span = 6000                       // 5 minutes at 20 Hz
    private var endIndex = Int.MAX_VALUE          // MAX_VALUE == follow live
    private val medBuf = FloatArray(MED_MAX)

    private val scaleDet = ScaleGestureDetector(context,
        object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScale(d: ScaleGestureDetector): Boolean {
                val size = size()
                if (size <= 0) return true
                val old = span
                span = (span / d.scaleFactor).toInt().coerceIn(MIN_SPAN, max(MIN_SPAN, size))
                /* Keep the point under the fingers put, so zooming feels
                 * anchored rather than sliding toward the edge. */
                if (!following()) {
                    val frac = d.focusX / max(1, width).toFloat()
                    endIndex = (resolvedEnd() + ((old - span) * (1f - frac)).toInt())
                        .coerceIn(min(size, MIN_SPAN), size)
                }
                invalidate()
                return true
            }
        })

    private val gestureDet = GestureDetector(context,
        object : GestureDetector.SimpleOnGestureListener() {
            override fun onScroll(e1: MotionEvent, e2: MotionEvent, dx: Float, dy: Float): Boolean {
                val size = size()
                if (size <= 0) return true
                val shift = (dx * span / max(1, width)).toInt()
                endIndex = (resolvedEnd() + shift).coerceIn(min(size, MIN_SPAN), size)
                invalidate()
                return true
            }
            override fun onDoubleTap(e: MotionEvent): Boolean {
                span = 6000
                endIndex = Int.MAX_VALUE
                invalidate()
                return true
            }
        })

    fun resetView() {
        span = 6000
        endIndex = Int.MAX_VALUE
        invalidate()
    }

    fun following(): Boolean = endIndex == Int.MAX_VALUE

    /** Human-readable description of the visible window, for the status line. */
    fun rangeLabel(): String {
        if (colT1 == 0L) return "no data"
        val secs = (colT1 - colT0) / 1000.0
        val t = SimpleDateFormat("HH:mm:ss", Locale.US)
        return "${t.format(Date(colT0))} .. ${t.format(Date(colT1))}  " +
               "(${fmtDur(secs)}${if (following()) ", live" else ""})"
    }

    private fun fmtDur(s: Double): String = when {
        s < 90 -> "${s.toInt()}s"
        s < 5400 -> "${(s / 60).toInt()}m"
        else -> String.format(Locale.US, "%.1fh", s / 3600)
    }

    private fun ring(): Ring? = SamplerService.ring
    private fun size(): Int = ring()?.size() ?: 0
    private fun resolvedEnd(): Int {
        val size = size()
        return if (endIndex == Int.MAX_VALUE) size else min(endIndex, size)
    }

    override fun onTouchEvent(e: MotionEvent): Boolean {
        scaleDet.onTouchEvent(e)
        gestureDet.onTouchEvent(e)
        return true
    }

    private fun seriesArray(r: Ring, s: Int): FloatArray = when (s) {
        0 -> r.hwX;  1 -> r.swX;  2 -> r.gmX
        3 -> r.hwY;  4 -> r.swY;  5 -> r.gmY
        6 -> r.hwZ;  7 -> r.swZ;  8 -> r.gmZ
        9 -> r.hwW; 10 -> r.swW; 11 -> r.gmW
        12 -> r.angHwSw
        13 -> r.angHwGm
        else -> r.bUt
    }

    private fun recompute(r: Ring, w: Int) {
        val size = r.size()
        val end = resolvedEnd()
        val i1 = end.coerceIn(0, size)
        val i0 = max(0, i1 - span)
        val n = i1 - i0
        if (n <= 0 || w <= 0) { colT1 = 0L; return }

        if (colMin[0].size != w) {
            for (s in 0 until SERIES) {
                colMin[s] = FloatArray(w); colMax[s] = FloatArray(w); colMed[s] = FloatArray(w)
            }
        }

        var amax = 2f
        var bmax = 80f
        for (col in 0 until w) {
            val a = i0 + (n.toLong() * col / w).toInt()
            var b = i0 + (n.toLong() * (col + 1) / w).toInt()
            if (b <= a) b = a + 1
            val cnt = b - a
            val stride = max(1, cnt / MED_MAX)

            for (s in 0 until SERIES) {
                val arr = seriesArray(r, s)
                var lo = Float.MAX_VALUE
                var hi = -Float.MAX_VALUE
                var m = 0
                var k = a
                while (k < b && k < size) {
                    val v = arr[r.idx(k)]
                    if (!v.isNaN()) {
                        if (v < lo) lo = v
                        if (v > hi) hi = v
                        if (m < MED_MAX && ((k - a) % stride == 0)) medBuf[m++] = v
                    }
                    k++
                }
                if (lo > hi) {
                    colMin[s][col] = Float.NaN; colMax[s][col] = Float.NaN
                    colMed[s][col] = Float.NaN
                } else {
                    colMin[s][col] = lo; colMax[s][col] = hi
                    java.util.Arrays.sort(medBuf, 0, m)
                    colMed[s][col] = if (m == 0) Float.NaN else medBuf[m / 2]
                    if ((s == 12 || s == 13) && hi > amax) amax = hi
                    if (s == 14 && hi > bmax) bmax = hi
                }
            }
        }
        angleMax = amax * 1.1f
        bMax = bmax * 1.05f
        colT0 = r.wallMs[r.idx(i0)]
        colT1 = r.wallMs[r.idx(max(i0, i1 - 1))]
        cachedW = w; cachedSpan = span; cachedEnd = end; cachedTotal = r.total
    }

    override fun onDraw(c: Canvas) {
        c.drawColor(0xFF12161A.toInt())
        val r = ring()
        val w = width
        if (r == null || r.size() == 0 || w <= 0) {
            text.textSize = 30f
            c.drawText("waiting for samples...", 24f, height / 2f, text)
            text.textSize = 22f
            return
        }

        if (w != cachedW || span != cachedSpan || resolvedEnd() != cachedEnd ||
            r.total != cachedTotal) recompute(r, w)
        if (colT1 == 0L) return

        val axisH = 34f
        val ph = (height - axisH) / PANELS

        for (p in 0 until PANELS) {
            val top = p * ph
            val bot = top + ph
            val mid = (top + bot) / 2f

            c.drawLine(0f, bot, w.toFloat(), bot, axis)
            if (p < 4) c.drawLine(0f, mid, w.toFloat(), mid, grid)

            when {
                p < 4 -> {
                    drawSeries(c, 3 * p, C_HW, top, bot, -1.05f, 1.05f)
                    drawSeries(c, 3 * p + 1, C_SW, top, bot, -1.05f, 1.05f)
                    drawSeries(c, 3 * p + 2, C_GM, top, bot, -1.05f, 1.05f)
                }
                p == 4 -> {
                    drawSeries(c, 12, C_ANG, top, bot, 0f, angleMax)
                    drawSeries(c, 13, C_ANG2, top, bot, 0f, angleMax)
                }
                else -> {
                    /* Reference line at the true local field: any excursion is
                     * hard iron, and hard iron is the leading suspect whenever
                     * the two 9-axis fusions disagree. */
                    val yRef = bot - (EARTH_UT / bMax) * (bot - top)
                    c.drawLine(0f, yRef, w.toFloat(), yRef, grid)
                    drawSeries(c, 14, C_SW, top, bot, 0f, bMax)
                }
            }

            c.drawText(LABELS[p], 8f, top + 24f, text)
            if (p == 4) c.drawText(String.format(Locale.US, "max %.1f", angleMax),
                8f, top + 46f, text)
            if (p == 5) c.drawText(String.format(Locale.US, "ref %.0f", EARTH_UT),
                8f, top + 46f, text)
        }

        /* Time axis: three ticks is enough to orient without clutter. */
        val t = SimpleDateFormat("HH:mm:ss", Locale.US)
        for (i in 0..2) {
            val x = w * i / 2f
            val ts = colT0 + (colT1 - colT0) * i / 2
            val label = t.format(Date(ts))
            val tw = text.measureText(label)
            val tx = min(max(0f, x - tw / 2f), w - tw)
            c.drawText(label, tx, height - 10f, text)
        }
    }

    private fun drawSeries(c: Canvas, s: Int, color: Int, top: Float, bot: Float,
                           lo: Float, hi: Float) {
        val w = colMed[s].size
        if (w == 0) return
        val h = bot - top
        val span = (hi - lo).takeIf { it > 1e-6f } ?: 1f
        fun y(v: Float) = bot - ((v - lo) / span) * h

        /* Envelope first, so the median line sits on top of it. */
        band.color = (color and 0x00FFFFFF) or 0x40000000
        val path = Path()
        var started = false
        for (col in 0 until w) {
            val mx = colMax[s][col]
            if (mx.isNaN()) continue
            if (!started) { path.moveTo(col.toFloat(), y(mx)); started = true }
            else path.lineTo(col.toFloat(), y(mx))
        }
        if (started) {
            for (col in w - 1 downTo 0) {
                val mn = colMin[s][col]
                if (mn.isNaN()) continue
                path.lineTo(col.toFloat(), y(mn))
            }
            path.close()
            c.drawPath(path, band)
        }

        line.color = color
        val med = Path()
        started = false
        for (col in 0 until w) {
            val v = colMed[s][col]
            if (v.isNaN()) { started = false; continue }
            val py = y(v)
            if (!started) { med.moveTo(col.toFloat(), py); started = true }
            else med.lineTo(col.toFloat(), py)
        }
        c.drawPath(med, line)
    }
}
