/*
 * AttitudeView -- a software-rendered 3-D attitude indicator.
 *
 * Draws a thin rectangular slab standing in for the laptop, oriented by the
 * rotation matrix SensorManager derives from the rotation vector, inside a
 * compass ring that is fixed to the world. The slab's +Z face (the screen
 * side) is labelled FRONT, its -Z face BACK, so a wrong axis convention or a
 * wrong quaternion component order is obvious the moment the machine is
 * tilted -- which is the whole reason this exists. See docs/14-sensors.md.
 *
 * WHY NOT OpenGL
 *
 * The scene is six quads and a 48-segment ring. A GLSurfaceView would pull in
 * an EGL context and a render thread to draw less geometry than a launcher
 * icon, on a fanless Core M-5Y70 rendering through Waydroid's Wayland surface.
 * Canvas with a hand-rolled projection is cheaper and has no setup cost.
 *
 * FRAMES
 *
 * SensorManager's rotation matrix maps device coordinates to the world frame
 * (X=East, Y=North, Z=Up), so a device vector becomes a world vector by
 * multiplying on the left -- see toWorld(). The camera sits south of and above
 * the origin looking north, so screen-right is East and screen-up is roughly
 * Up. The ring is drawn in the world plane, the slab in the device frame
 * pushed through the rotation matrix; the slab therefore moves and the ring
 * stays put, which is the reading that makes heading legible.
 */
package lan.syshlt.sensorinfo

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Typeface
import android.hardware.SensorManager
import android.view.View
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.sin

// Slab half-extents in the device frame: +X right across the screen, +Y up the
// screen, +Z out of the screen. 16:10-ish, and thin.
private const val HX = 1.00
private const val HY = 0.62
private const val HZ = 0.055

private const val RING_R = 1.60
private const val RING_SEG = 48
private const val CAM_D = 6.0          // camera distance from the origin
private const val CAM_EL = 26.0        // camera elevation above the world plane

// Light direction in world coordinates (from above, slightly south and east),
// pre-normalised. Used for a flat Lambert term so adjacent faces separate.
private const val LX = 0.2494
private const val LY = -0.4490
private const val LZ = 0.8580

/*
 * Face corners, ordered top-left, top-right, bottom-right, bottom-left AS SEEN
 * FROM OUTSIDE the slab. That ordering is clockwise when viewed from outside,
 * which after the y-flip of screen coordinates makes the shoelace area of a
 * visible face positive -- so backface culling is one sign test and needs no
 * normals. The box is convex, so culling alone gives correct occlusion and no
 * depth sort is required.
 */
private val FACE_XYZ = arrayOf(
    doubleArrayOf(-HX, +HY, +HZ, +HX, +HY, +HZ, +HX, -HY, +HZ, -HX, -HY, +HZ), // +Z front
    doubleArrayOf(+HX, +HY, -HZ, -HX, +HY, -HZ, -HX, -HY, -HZ, +HX, -HY, -HZ), // -Z back
    doubleArrayOf(+HX, +HY, +HZ, +HX, +HY, -HZ, +HX, -HY, -HZ, +HX, -HY, +HZ), // +X right
    doubleArrayOf(-HX, +HY, -HZ, -HX, +HY, +HZ, -HX, -HY, +HZ, -HX, -HY, -HZ), // -X left
    doubleArrayOf(+HX, +HY, +HZ, -HX, +HY, +HZ, -HX, +HY, -HZ, +HX, +HY, -HZ), // +Y top
    doubleArrayOf(-HX, -HY, +HZ, +HX, -HY, +HZ, +HX, -HY, -HZ, -HX, -HY, -HZ)  // -Y bottom
)

private val FACE_N = arrayOf(
    doubleArrayOf(0.0, 0.0, 1.0), doubleArrayOf(0.0, 0.0, -1.0),
    doubleArrayOf(1.0, 0.0, 0.0), doubleArrayOf(-1.0, 0.0, 0.0),
    doubleArrayOf(0.0, 1.0, 0.0), doubleArrayOf(0.0, -1.0, 0.0)
)

private val FACE_COLOR = intArrayOf(
    0xFF2E7DD1.toInt(), 0xFFD1662E.toInt(),
    0xFF7A828C.toInt(), 0xFF7A828C.toInt(),
    0xFF5E656E.toInt(), 0xFF5E656E.toInt()
)

private val FACE_LABEL = arrayOf("FRONT", "BACK", null, null, null, null)

private val CARDINAL = arrayOf("N", "E", "S", "W")

/*
 * Canned attitudes, cycled by tapping the view.
 *
 * Two jobs. It demonstrates what the slab is claiming without needing the
 * machine physically tilted, and -- the reason it exists -- it is the only way
 * to check the FRONT and BACK faces render correctly when the only access to
 * the host is ssh. Each matrix is written as its three columns: where device
 * X, Y and Z land in the world frame (East, North, Up).
 */
private val DEMO_R = arrayOf(
    // X=East, Y=North, Z=Up -- flat on its back, screen up, top edge north.
    floatArrayOf(1f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 1f),
    // X=West, Y=North, Z=Down -- flat on its face.
    floatArrayOf(-1f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, -1f),
    // X=East, Y=Up, Z=South -- standing upright, screen toward the camera.
    floatArrayOf(1f, 0f, 0f, 0f, 0f, -1f, 0f, 1f, 0f),
    // X=Up, Y=West, Z=South -- on its left edge, screen toward the camera.
    floatArrayOf(0f, -1f, 0f, 0f, 0f, -1f, 1f, 0f, 0f)
)

private val DEMO_NAME = arrayOf(
    "demo · flat on its back, top edge north",
    "demo · flat on its face",
    "demo · upright, screen facing south",
    "demo · on its left edge, screen south"
)

private val NORTH_INK = 0xFFE05252.toInt()
private val HEADING_INK = 0xFFF0B429.toInt()

/** textColorPrimary for the current theme, so the app works day and night. */
internal fun themeInk(context: Context): Int {
    val a = context.obtainStyledAttributes(intArrayOf(android.R.attr.textColorPrimary))
    try {
        return a.getColorStateList(0)?.defaultColor ?: 0xFF9AA3AD.toInt()
    } finally {
        a.recycle()
    }
}

internal fun withAlpha(color: Int, alpha: Int) = (color and 0x00FFFFFF) or (alpha shl 24)

class AttitudeView(context: Context) : View(context) {

    /** Device -> world (East, North, Up), row-major, exactly as SensorManager gives it. */
    private val rot = floatArrayOf(1f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 1f)
    private var live = false
    private var azimuth = 0.0
    private var pitchDeg = 0.0
    private var rollDeg = 0.0
    private var source = "waiting for a rotation source…"

    /** -1 is live; otherwise an index into DEMO_R. Tap the view to cycle. */
    private var demo = -1
    private var demoAz = 0.0
    private var demoPitch = 0.0
    private var demoRoll = 0.0

    // What onDraw actually renders, resolved from live data or the demo pose.
    private val cur = FloatArray(9)
    private val tmpAngles = FloatArray(3)
    private var curAz = 0.0
    private var curPitch = 0.0
    private var curRoll = 0.0
    private var curLive = false
    private var curLabel = ""

    init {
        setOnClickListener { selectDemo(if (demo >= DEMO_R.size - 1) -1 else demo + 1) }
    }

    private fun selectDemo(i: Int) {
        demo = i
        if (i >= 0) {
            SensorManager.getOrientation(DEMO_R[i], tmpAngles)
            demoAz = Math.toDegrees(tmpAngles[0].toDouble()).let { if (it < 0) it + 360.0 else it }
            demoPitch = Math.toDegrees(tmpAngles[1].toDouble())
            demoRoll = Math.toDegrees(tmpAngles[2].toDouble())
        }
        invalidate()
    }

    /**
     * The heading currently being drawn, or null when the view is live. The
     * dial follows this so the two halves of the panel never disagree -- a
     * demo pose reading 270 next to a dial still showing the real 107 would
     * look exactly like the bug this app exists to catch.
     */
    fun demoHeading(): Double? = if (demo < 0) null else demoAz

    private val ink = themeInk(context)
    private val dim = withAlpha(ink, 0xB0)

    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val edge = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        color = 0x77000000
    }
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
        typeface = Typeface.DEFAULT_BOLD
    }
    private val facePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
        typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
        color = Color.WHITE
    }
    private val hudPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Typeface.MONOSPACE
        color = dim
    }

    // Everything below is preallocated: onDraw runs ~15 times a second and the
    // last thing this machine needs is a garbage collection in the frame path.
    private val path = Path()
    private val textMatrix = Matrix()
    private val srcPoly = FloatArray(6)
    private val dstPoly = FloatArray(6)
    private val ringSx = FloatArray(RING_SEG + 1)
    private val ringSy = FloatArray(RING_SEG + 1)
    private val ringZc = FloatArray(RING_SEG + 1)
    private val vx = FloatArray(4)
    private val vy = FloatArray(4)
    private val wp = DoubleArray(3)
    private val sp = DoubleArray(3)

    private val sinEl = sin(CAM_EL * PI / 180.0)
    private val cosEl = cos(CAM_EL * PI / 180.0)
    private var cx = 0f
    private var cy = 0f
    private var focal = 0.0
    private var dpv = 1f

    // ------------------------------------------------------------------- input

    fun setAttitude(r: FloatArray, az: Double, pitch: Double, roll: Double, label: String) {
        System.arraycopy(r, 0, rot, 0, 9)
        azimuth = az
        pitchDeg = pitch
        rollDeg = roll
        source = label
        live = true
        if (demo < 0) invalidate()
    }

    fun setUnavailable(label: String) {
        if (!live && source == label) return
        live = false
        source = label
        if (demo < 0) invalidate()
    }

    // -------------------------------------------------------------- projection

    /** Device frame -> world frame. cur maps device vectors into East/North/Up. */
    private fun toWorld(x: Double, y: Double, z: Double, out: DoubleArray) {
        out[0] = cur[0] * x + cur[1] * y + cur[2] * z
        out[1] = cur[3] * x + cur[4] * y + cur[5] * z
        out[2] = cur[6] * x + cur[7] * y + cur[8] * z
    }

    /**
     * World frame -> screen, perspective. out = [screen x, screen y, camera
     * depth relative to the origin]; that third value is what splits the ring
     * into a half drawn behind the slab and a half drawn in front of it.
     */
    private fun project(e: Double, n: Double, u: Double, out: DoubleArray) {
        val yc = n * sinEl + u * cosEl
        val zc = n * cosEl - u * sinEl
        val d = CAM_D + zc
        out[0] = cx + focal * e / d
        out[1] = cy - focal * yc / d
        out[2] = zc
    }

    // ------------------------------------------------------------------ drawing

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat()
        val h = height.toFloat()
        if (w < 16f || h < 16f) return

        dpv = resources.displayMetrics.density

        val d = demo
        if (d >= 0) {
            System.arraycopy(DEMO_R[d], 0, cur, 0, 9)
            curAz = demoAz
            curPitch = demoPitch
            curRoll = demoRoll
            curLive = true
            curLabel = DEMO_NAME[d]
        } else {
            System.arraycopy(rot, 0, cur, 0, 9)
            curAz = azimuth
            curPitch = pitchDeg
            curRoll = rollDeg
            curLive = live
            curLabel = source
        }

        // Reserve a strip along the bottom for the HUD and fit the scene into
        // what is left, so chrome and geometry never share pixels: without it
        // the S label lands in the middle of the az readout.
        hudPaint.textSize = 10f * dpv
        val hs = h - (hudPaint.textSize * 1.35f * 3f + 6f * dpv)

        // Fit to whichever axis is tighter. The widest feature is the ring's
        // outer label circle seen side-on; the tallest is whichever of that
        // circle's near edge or the slab standing on a corner reaches further
        // from the centre. Those two do NOT stack -- budgeting for their sum,
        // as the first cut did, shrank the whole scene by a third.
        val fx = 1.28 * w
        val fy = 2.15 * hs
        focal = if (fx < fy) fx else fy
        cx = w / 2f
        // Perspective throws the near (south) side of the ring further from
        // the centre than the far side, so lift the horizon to balance it.
        cy = (hs / 2.0 - 0.019 * focal).toFloat()

        labelPaint.textSize = 12f * dpv
        edge.strokeWidth = 1.1f * dpv

        for (i in 0..RING_SEG) {
            val b = 2.0 * PI * i / RING_SEG
            project(RING_R * sin(b), RING_R * cos(b), 0.0, sp)
            ringSx[i] = sp[0].toFloat()
            ringSy[i] = sp[1].toFloat()
            ringZc[i] = sp[2].toFloat()
        }

        // Far half of the world plane, then the slab, then the near half: the
        // ring reads as a hoop the object sits inside rather than a flat decal.
        drawRingHalf(canvas, far = true)
        drawTicks(canvas, far = true)
        drawHeading(canvas, far = true)
        drawCardinals(canvas, far = true)

        drawSlab(canvas)

        drawRingHalf(canvas, far = false)
        drawTicks(canvas, far = false)
        drawHeading(canvas, far = false)
        drawCardinals(canvas, far = false)

        drawHud(canvas)
    }

    private fun drawRingHalf(c: Canvas, far: Boolean) {
        stroke.color = dim
        stroke.strokeWidth = 1.5f * dpv
        for (i in 0 until RING_SEG) {
            if (((ringZc[i] + ringZc[i + 1]) * 0.5f >= 0f) != far) continue
            c.drawLine(ringSx[i], ringSy[i], ringSx[i + 1], ringSy[i + 1], stroke)
        }
    }

    private fun drawTicks(c: Canvas, far: Boolean) {
        for (deg in 0 until 360 step 15) {
            val b = deg * PI / 180.0
            val major = deg % 90 == 0
            project(RING_R * sin(b), RING_R * cos(b), 0.0, sp)
            if ((sp[2] >= 0.0) != far) continue
            val x0 = sp[0].toFloat()
            val y0 = sp[1].toFloat()
            val r1 = if (major) RING_R * 1.15 else RING_R * 1.07
            project(r1 * sin(b), r1 * cos(b), 0.0, sp)
            stroke.color = if (major && deg == 0) NORTH_INK else dim
            stroke.strokeWidth = if (major) 2.4f * dpv else 1.2f * dpv
            c.drawLine(x0, y0, sp[0].toFloat(), sp[1].toFloat(), stroke)
        }
    }

    private fun drawCardinals(c: Canvas, far: Boolean) {
        for (k in 0..3) {
            val b = k * PI / 2.0
            project(RING_R * 1.31 * sin(b), RING_R * 1.31 * cos(b), 0.0, sp)
            if ((sp[2] >= 0.0) != far) continue
            labelPaint.color = if (k == 0) NORTH_INK else dim
            c.drawText(CARDINAL[k], sp[0].toFloat(),
                sp[1].toFloat() + labelPaint.textSize * 0.36f, labelPaint)
        }
    }

    /** A wedge lying in the world plane, pointing along the reported heading. */
    private fun drawHeading(c: Canvas, far: Boolean) {
        if (!curLive) return
        val b = curAz * PI / 180.0
        project(RING_R * 0.99 * sin(b), RING_R * 0.99 * cos(b), 0.0, sp)
        if ((sp[2] >= 0.0) != far) return
        val tipX = sp[0].toFloat()
        val tipY = sp[1].toFloat()
        val br = RING_R * 0.74
        project(br * sin(b - 0.17), br * cos(b - 0.17), 0.0, sp)
        val ax = sp[0].toFloat()
        val ay = sp[1].toFloat()
        project(br * sin(b + 0.17), br * cos(b + 0.17), 0.0, sp)
        path.reset()
        path.moveTo(tipX, tipY)
        path.lineTo(ax, ay)
        path.lineTo(sp[0].toFloat(), sp[1].toFloat())
        path.close()
        fill.color = withAlpha(HEADING_INK, 0xCC)
        c.drawPath(path, fill)
    }

    private fun drawSlab(c: Canvas) {
        for (f in 0 until 6) {
            val g = FACE_XYZ[f]
            for (i in 0 until 4) {
                toWorld(g[i * 3], g[i * 3 + 1], g[i * 3 + 2], wp)
                project(wp[0], wp[1], wp[2], sp)
                vx[i] = sp[0].toFloat()
                vy[i] = sp[1].toFloat()
            }
            // Twice the signed screen area; positive means the outside of the
            // face is toward the camera. See the FACE_XYZ comment.
            var area2 = 0.0
            for (i in 0 until 4) {
                val j = (i + 1) and 3
                area2 += vx[i].toDouble() * vy[j] - vx[j].toDouble() * vy[i]
            }
            if (area2 <= 0.0) continue

            toWorld(FACE_N[f][0], FACE_N[f][1], FACE_N[f][2], wp)
            val lambert = wp[0] * LX + wp[1] * LY + wp[2] * LZ
            val k = 0.58 + 0.42 * max(0.0, lambert)

            path.reset()
            path.moveTo(vx[0], vy[0])
            path.lineTo(vx[1], vy[1])
            path.lineTo(vx[2], vy[2])
            path.lineTo(vx[3], vy[3])
            path.close()
            fill.color = shade(FACE_COLOR[f], k)
            c.drawPath(path, fill)
            c.drawPath(path, edge)

            val label = FACE_LABEL[f]
            // Skip the label once the face is near edge-on: the affine map goes
            // singular and the glyphs turn into smears.
            if (label != null && area2 > 1800.0 * dpv * dpv) drawFaceText(c, label, f)
        }
    }

    /**
     * Map a label into the projected face with Matrix.setPolyToPoly.
     *
     * Three points, not four, so the result is affine. A four-point map would
     * be the true perspective one, but a non-affine canvas matrix pushes Skia
     * onto a slow path for glyphs; at this camera distance the difference is
     * invisible and the cost is not.
     */
    private fun drawFaceText(c: Canvas, text: String, f: Int) {
        val tw = 100f * (HX / HY).toFloat()
        val th = 100f
        srcPoly[0] = 0f; srcPoly[1] = 0f      // -> top-left
        srcPoly[2] = tw; srcPoly[3] = 0f      // -> top-right
        srcPoly[4] = 0f; srcPoly[5] = th      // -> bottom-left
        dstPoly[0] = vx[0]; dstPoly[1] = vy[0]
        dstPoly[2] = vx[1]; dstPoly[3] = vy[1]
        dstPoly[4] = vx[3]; dstPoly[5] = vy[3]
        if (!textMatrix.setPolyToPoly(srcPoly, 0, dstPoly, 0, 3)) return
        c.save()
        c.concat(textMatrix)
        facePaint.textSize = 34f
        c.drawText(text, tw / 2f,
            th / 2f - (facePaint.descent() + facePaint.ascent()) / 2f, facePaint)
        c.restore()
    }

    /*
     * Bottom-left, stacked upwards. The top-left looks like the natural place
     * until the slab stands on its long edge, which reaches high enough to
     * strike through the text; nothing in the scene reaches the bottom corner.
     */
    private fun drawHud(c: Canvas) {
        val step = hudPaint.textSize * 1.35f
        var y = height - 5f * dpv
        if (demo < 0) {
            hudPaint.color = withAlpha(ink, 0x55)
            c.drawText("tap for demo poses", 5f * dpv, y, hudPaint)
            y -= step
        }
        hudPaint.color = withAlpha(if (demo >= 0) HEADING_INK else ink, 0x90)
        c.drawText(curLabel, 5f * dpv, y, hudPaint)
        y -= step
        hudPaint.color = if (demo >= 0) HEADING_INK else dim
        c.drawText(
            if (curLive) "az %6.1f°   pitch %+6.1f°   roll %+6.1f°"
                .format(curAz, curPitch, curRoll)
            else "no attitude data",
            5f * dpv, y, hudPaint
        )
    }

    private fun shade(color: Int, k: Double): Int {
        val f = if (k < 0.0) 0.0 else if (k > 1.0) 1.0 else k
        return Color.rgb(
            (Color.red(color) * f).toInt(),
            (Color.green(color) * f).toInt(),
            (Color.blue(color) * f).toInt()
        )
    }
}
