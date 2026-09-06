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
 *
 * Everything on the card is fixed in the CARD's frame, so the ticks, needles
 * and label positions are built once per size and then drawn under a single
 * canvas rotation. See AttitudeView for why that mattered.
 */
package lan.syshlt.sensorinfo

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Typeface
import android.view.View
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

private val NEEDLE_N = 0xFFE05252.toInt()
private val NEEDLE_S = 0xFF8A9099.toInt()

private val CARD = arrayOf("N", "E", "S", "W")

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

    // Built once per size, drawn under one canvas.rotate().
    private val tickMinor = Path()
    private val tickMedium = Path()
    private val tickMajor = Path()
    private val tickNorth = Path()
    private val needleNorth = Path()
    private val needleSouth = Path()
    private val lubber = Path()
    private val lab = arrayOfNulls<String>(12)
    private val labX = FloatArray(12)
    private val labY = FloatArray(12)
    private val labSize = FloatArray(12)
    private val labColor = IntArray(12)
    private var labN = 0
    private var cx = 0f
    private var cy = 0f
    private var r = 0f
    private var dp = 1f
    private var sizeW = 0
    private var sizeH = 0

    fun setHeading(az: Double, ok: Boolean, compassPoint: String) {
        // A third of a degree is under a pixel of movement at the rim and below
        // what the dial can show, so skipping those keeps the view from
        // redrawing on sensor noise alone while the machine sits still.
        if (live == ok && point == compassPoint && abs(az - azimuth) < 0.3) return
        azimuth = az
        live = ok
        point = compassPoint
        invalidate()
    }

    private fun buildDial() {
        dp = resources.displayMetrics.density
        cx = sizeW / 2f
        cy = sizeH / 2f
        r = min(sizeW, sizeH) / 2f - 7f * dp

        tickMinor.reset(); tickMedium.reset(); tickMajor.reset(); tickNorth.reset()
        labN = 0

        for (deg in 0 until 360 step 15) {
            val b = deg * PI / 180.0
            val sb = sin(b).toFloat()
            val cb = cos(b).toFloat()
            val major = deg % 90 == 0
            val medium = deg % 30 == 0
            val inner = if (major) 0.80f else if (medium) 0.85f else 0.89f
            val target = when {
                deg == 0 -> tickNorth
                major -> tickMajor
                medium -> tickMedium
                else -> tickMinor
            }
            target.moveTo(cx + r * inner * sb, cy - r * inner * cb)
            target.lineTo(cx + r * 0.98f * sb, cy - r * 0.98f * cb)

            if (major || medium) {
                val size = if (major) r * 0.21f else r * 0.14f
                val rad = if (major) r * 0.66f else r * 0.68f
                cardText.textSize = size
                lab[labN] = if (major) CARD[deg / 90] else "${deg / 10}"
                labX[labN] = cx + rad * sb
                labY[labN] = cy - rad * cb - (cardText.descent() + cardText.ascent()) / 2f
                labSize[labN] = size
                labColor[labN] = if (deg == 0) NEEDLE_N else if (major) dim else faint
                labN++
            }
        }

        needle(needleNorth, 1f)
        needle(needleSouth, -1f)

        lubber.reset()
        lubber.moveTo(cx, cy - r * 0.86f)
        lubber.lineTo(cx - r * 0.09f, cy - r * 1.04f)
        lubber.lineTo(cx + r * 0.09f, cy - r * 1.04f)
        lubber.close()
    }

    /** Drawn in the outer band only, so it never fights the centre readout. */
    private fun needle(p: Path, dir: Float) {
        p.reset()
        p.moveTo(cx, cy - dir * r * 0.74f)
        p.lineTo(cx - r * 0.055f, cy - dir * r * 0.40f)
        p.lineTo(cx + r * 0.055f, cy - dir * r * 0.40f)
        p.close()
    }

    override fun onDraw(canvas: Canvas) {
        if (width < 16 || height < 16) return
        if (width != sizeW || height != sizeH) {
            sizeW = width
            sizeH = height
            buildDial()
        }

        stroke.color = faint
        stroke.strokeWidth = 1.5f * dp
        canvas.drawCircle(cx, cy, r, stroke)

        canvas.save()
        // The card carries the world: rotating it by -heading brings the
        // bearing the device is pointing at up to the lubber index.
        canvas.rotate(-azimuth.toFloat(), cx, cy)

        stroke.color = dim
        stroke.strokeWidth = 1f * dp
        canvas.drawPath(tickMinor, stroke)
        stroke.strokeWidth = 1.5f * dp
        canvas.drawPath(tickMedium, stroke)
        stroke.strokeWidth = 2.6f * dp
        canvas.drawPath(tickMajor, stroke)
        stroke.color = NEEDLE_N
        canvas.drawPath(tickNorth, stroke)

        for (i in 0 until labN) {
            cardText.textSize = labSize[i]
            cardText.color = labColor[i]
            canvas.drawText(lab[i]!!, labX[i], labY[i], cardText)
        }

        fill.color = NEEDLE_N
        canvas.drawPath(needleNorth, fill)
        fill.color = NEEDLE_S
        canvas.drawPath(needleSouth, fill)
        canvas.restore()

        fill.color = if (live) NEEDLE_N else faint
        canvas.drawPath(lubber, fill)

        bigText.color = ink
        bigText.textSize = r * 0.34f
        smallText.textSize = r * 0.16f
        if (live) {
            smallText.color = dim
            canvas.drawText("%.0f°".format(azimuth), cx, cy + bigText.textSize * 0.20f, bigText)
            canvas.drawText(
                point, cx,
                cy + bigText.textSize * 0.20f + smallText.textSize * 1.5f, smallText
            )
        } else {
            smallText.color = faint
            canvas.drawText("no heading", cx, cy + smallText.textSize * 0.4f, smallText)
        }
    }
}
