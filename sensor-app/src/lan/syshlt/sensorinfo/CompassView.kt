/*
 * CompassView -- a rotating-card compass dial.
 *
 * Heading-indicator convention rather than magnetic-needle convention: the
 * card turns under a fixed lubber index at the top, so whatever the device's
 * +Y axis (the top edge of the screen) is pointing at reads off directly at
 * twelve o'clock, with the number repeated in the middle. The red north needle
 * rides on the card so which way is north stays obvious at a glance.
 *
 * Heading comes from the same rotation matrix that drives AttitudeView, so the
 * two always agree; disagreement would mean a bug here, not in the HAL.
 */
package lan.syshlt.sensorinfo

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Typeface
import android.view.View
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

private val NEEDLE_N = 0xFFE05252.toInt()
private val NEEDLE_S = 0xFF8A9099.toInt()

class CompassView(context: Context) : View(context) {

    private var azimuth = 0.0
    private var live = false
    private var point = ""

    private val ink = themeInk(context)
    private val dim = withAlpha(ink, 0xB0)
    private val faint = withAlpha(ink, 0x55)

    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val cardText = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
        typeface = Typeface.DEFAULT_BOLD
    }
    private val bigText = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
        typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
    }
    private val smallText = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
        typeface = Typeface.MONOSPACE
    }
    private val path = Path()

    fun setHeading(az: Double, ok: Boolean, compassPoint: String) {
        // A tenth of a degree is below what the dial can show; skipping those
        // keeps the invalidate rate down when the machine is sitting still.
        if (live == ok && point == compassPoint && kotlin.math.abs(az - azimuth) < 0.1) return
        azimuth = az
        live = ok
        point = compassPoint
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat()
        val h = height.toFloat()
        if (w < 16f || h < 16f) return
        val dp = resources.displayMetrics.density
        val cx = w / 2f
        val cy = h / 2f
        val r = min(w, h) / 2f - 7f * dp

        stroke.color = faint
        stroke.strokeWidth = 1.5f * dp
        canvas.drawCircle(cx, cy, r, stroke)

        canvas.save()
        // The card carries the world: rotating it by -heading brings the
        // bearing the device is pointing at up to the lubber index.
        canvas.rotate(-azimuth.toFloat(), cx, cy)

        cardText.textSize = r * 0.19f
        for (deg in 0 until 360 step 15) {
            val b = deg * PI / 180.0
            val sb = sin(b).toFloat()
            val cb = cos(b).toFloat()
            val major = deg % 90 == 0
            val medium = deg % 30 == 0
            val inner = if (major) 0.80f else if (medium) 0.85f else 0.89f
            stroke.color = if (deg == 0) NEEDLE_N else dim
            stroke.strokeWidth = if (major) 2.6f * dp else if (medium) 1.5f * dp else 1f * dp
            canvas.drawLine(cx + r * inner * sb, cy - r * inner * cb,
                cx + r * 0.98f * sb, cy - r * 0.98f * cb, stroke)

            if (major) {
                cardText.color = if (deg == 0) NEEDLE_N else dim
                cardText.textSize = r * 0.21f
                drawAt(canvas, CARD[deg / 90], cx, cy, r * 0.66f, sb, cb, cardText)
            } else if (medium) {
                cardText.color = faint
                cardText.textSize = r * 0.14f
                drawAt(canvas, "${deg / 10}", cx, cy, r * 0.68f, sb, cb, cardText)
            }
        }

        // North needle, drawn in the outer band so it never fights the readout.
        needle(canvas, cx, cy, r, 0f, NEEDLE_N)
        needle(canvas, cx, cy, r, 180f, NEEDLE_S)
        canvas.restore()

        // Fixed lubber index: a wedge biting into the dial from the top.
        fill.color = if (live) NEEDLE_N else faint
        path.reset()
        path.moveTo(cx, cy - r * 0.86f)
        path.lineTo(cx - r * 0.09f, cy - r * 1.04f)
        path.lineTo(cx + r * 0.09f, cy - r * 1.04f)
        path.close()
        canvas.drawPath(path, fill)

        bigText.color = ink
        bigText.textSize = r * 0.34f
        smallText.color = dim
        smallText.textSize = r * 0.16f
        if (live) {
            canvas.drawText("%.0f°".format(azimuth), cx, cy + bigText.textSize * 0.20f, bigText)
            canvas.drawText(point, cx, cy + bigText.textSize * 0.20f + smallText.textSize * 1.5f,
                smallText)
        } else {
            smallText.color = faint
            canvas.drawText("no heading", cx, cy + smallText.textSize * 0.4f, smallText)
        }
    }

    private fun needle(c: Canvas, cx: Float, cy: Float, r: Float, deg: Float, color: Int) {
        c.save()
        c.rotate(deg, cx, cy)
        path.reset()
        path.moveTo(cx, cy - r * 0.74f)
        path.lineTo(cx - r * 0.055f, cy - r * 0.40f)
        path.lineTo(cx + r * 0.055f, cy - r * 0.40f)
        path.close()
        fill.color = color
        c.drawPath(path, fill)
        c.restore()
    }

    private fun drawAt(c: Canvas, s: String, cx: Float, cy: Float, rad: Float,
                       sb: Float, cb: Float, p: Paint) {
        c.drawText(s, cx + rad * sb, cy - rad * cb - (p.descent() + p.ascent()) / 2f, p)
    }

    private companion object {
        val CARD = arrayOf("N", "E", "S", "W")
    }
}
