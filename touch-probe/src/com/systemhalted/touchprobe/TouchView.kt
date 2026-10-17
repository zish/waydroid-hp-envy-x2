package com.systemhalted.touchprobe

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.view.MotionEvent
import android.view.View

/**
 * Draws one coloured blob per active pointer, with a trail, over a HUD that
 * counts concurrent contacts.
 *
 * The load-bearing number is [maxConcurrent] -- the most pointers ever present
 * in a single MotionEvent. Everything else on screen exists to make that count
 * obviously real: ten separate colours, ten separate ids, ten separate trails,
 * rather than one contact reported ten times.
 *
 * It also names the device and source each event arrived on. On Waydroid that
 * answers which of hwcomposer's FIFOs delivered it -- wayland_touch,
 * wayland_pointer or (once a pen exists) wayland_tablet -- which is why the HUD
 * shows it rather than assuming a touchscreen.
 */
class TouchView(context: Context) : View(context) {

    /** Invoked whenever [maxConcurrent] increases, so the report can be rewritten. */
    var onNewMax: ((Int) -> Unit)? = null

    /** Invoked when the ABOUT target is tapped. See [aboutRect]. */
    var onAbout: (() -> Unit)? = null

    val maxConcurrent get() = ledger.maxConcurrent
    val eventCount get() = ledger.eventCount
    var deviceLabel = "-"
        private set
    var sourceLabel = "-"
        private set
    val toolTypesSeen: Set<String> get() = ledger.toolTypesSeen

    private class Contact(val id: Int) {
        var x = 0f
        var y = 0f
        var pressure = 0f
        var size = 0f
        var toolType = MotionEvent.TOOL_TYPE_UNKNOWN
        var tilt = Float.NaN
        var distance = Float.NaN
        var hovering = false
        val trail = Path()
        var trailStarted = false
    }

    /** A lifted contact's trail, kept briefly so a finished gesture stays visible. */
    private class Ghost(val trail: Path, val colour: Int, val bornNanos: Long)

    // The pointer bookkeeping lives in Pointers.kt so touch-probe/test can
    // reach it without a MotionEvent; this view only unpacks events into it.
    private val ledger = PointerLedger { id -> Contact(id) }
    private val contacts get() = ledger.live
    private val ghosts = ArrayList<Ghost>()
    private var buttonState = 0

    private val d = resources.displayMetrics.density

    private val palette = intArrayOf(
        0xFF4FC3F7.toInt(), 0xFFFFB74D.toInt(), 0xFFAED581.toInt(), 0xFFF06292.toInt(),
        0xFFBA68C8.toInt(), 0xFF4DD0E1.toInt(), 0xFFFFF176.toInt(), 0xFFFF8A65.toInt(),
        0xFF9575CD.toInt(), 0xFF81C784.toInt()
    )

    private val bg = 0xFF0D1117.toInt()
    private val gridPaint = Paint().apply {
        color = 0xFF1B2027.toInt(); strokeWidth = 1f * d; isAntiAlias = false
    }
    private val trailPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; strokeWidth = 3f * d
        strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND
    }
    private val blobPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; strokeWidth = 2f * d
    }
    private val crossPaint = Paint().apply { strokeWidth = 1f * d }
    private val hudBg = Paint().apply { color = 0xD00D1117.toInt() }
    private val hudText = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFFE6EDF3.toInt(); textSize = 15f * d
        typeface = android.graphics.Typeface.MONOSPACE
    }
    private val hudBig = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFFE6EDF3.toInt(); textSize = 26f * d
        typeface = android.graphics.Typeface.create("monospace", android.graphics.Typeface.BOLD)
    }
    private val hudDim = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFF8B949E.toInt(); textSize = 13f * d
        typeface = android.graphics.Typeface.MONOSPACE
    }
    private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 17f * d
        typeface = android.graphics.Typeface.create("monospace", android.graphics.Typeface.BOLD)
    }

    private val resetRect = RectF()
    // Drawn rather than laid out: this view fills the window on its own, and a
    // real TextView over it would swallow every touch that landed on it
    // *without* the swallow being visible in the count -- which is exactly the
    // measurement this app exists to make. A canvas target is consumed in
    // onTouchEvent, on the same terms as RESET, where the rule is written down.
    private val aboutRect = RectF()
    private val tmpRect = RectF()

    init {
        setBackgroundColor(bg)
        isFocusable = true
        isFocusableInTouchMode = true
    }

    private fun colourFor(id: Int) = palette[((id % palette.size) + palette.size) % palette.size]

    private fun toolName(t: Int) = Names.tool(t)

    /** Clears trails and the max counter. */
    fun reset() {
        ledger.reset()
        ghosts.clear()
        invalidate()
    }

    /** A one-shot textual summary, for the report file. */
    fun summary(): String =
        summaryText(maxConcurrent, eventCount, deviceLabel, sourceLabel, toolTypesSeen, width, height)

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_DOWN &&
            resetRect.contains(event.x, event.y)
        ) {
            reset()
            return true
        }
        if (event.actionMasked == MotionEvent.ACTION_DOWN &&
            aboutRect.contains(event.x, event.y)
        ) {
            onAbout?.invoke()
            return true
        }
        ingest(event, hover = false)
        return true
    }

    override fun onGenericMotionEvent(event: MotionEvent): Boolean {
        return when (event.actionMasked) {
            MotionEvent.ACTION_HOVER_ENTER,
            MotionEvent.ACTION_HOVER_MOVE,
            MotionEvent.ACTION_HOVER_EXIT -> {
                ingest(event, hover = true)
                true
            }
            else -> super.onGenericMotionEvent(event)
        }
    }

    private fun ingest(event: MotionEvent, hover: Boolean) {
        val action = event.actionMasked
        val going = ledger.begin(action, ::ghost)
        buttonState = event.buttonState
        deviceLabel = event.device?.name ?: "id=${event.deviceId}"
        sourceLabel = Names.source(event.source)

        if (!going) {
            invalidate()
            return
        }

        // Replay history first, so a fast drag draws a curve rather than a jump.
        for (h in 0 until event.historySize) {
            for (i in 0 until event.pointerCount) {
                track(event.getPointerId(i), event.getHistoricalX(i, h), event.getHistoricalY(i, h))
            }
        }

        for (i in 0 until event.pointerCount) {
            val id = event.getPointerId(i)
            val c = track(id, event.getX(i), event.getY(i))
            c.pressure = event.getPressure(i)
            c.size = event.getSize(i)
            c.toolType = event.getToolType(i)
            c.tilt = event.getAxisValue(MotionEvent.AXIS_TILT, i)
            c.distance = event.getAxisValue(MotionEvent.AXIS_DISTANCE, i)
            c.hovering = hover
            ledger.sawTool(c.toolType)
        }

        // Count before removing the lifted pointer -- PointerLedger.end().
        // actionIndex is only meaningful for the UP actions, which are the
        // only ones end() reads it for.
        val lifted = action == MotionEvent.ACTION_POINTER_UP || action == MotionEvent.ACTION_UP
        ledger.end(action, hover, if (lifted) event.getPointerId(event.actionIndex) else -1,
            onNewMax = { onNewMax?.invoke(it) }, onRetire = ::ghost)
        invalidate()
    }

    private fun track(id: Int, x: Float, y: Float): Contact {
        val c = ledger.track(id)
        c.x = x
        c.y = y
        if (!c.trailStarted) {
            c.trail.moveTo(x, y); c.trailStarted = true
        } else {
            c.trail.lineTo(x, y)
        }
        return c
    }

    /** A retired contact leaves its trail behind, briefly. */
    private fun ghost(c: Contact) {
        if (c.trailStarted) ghosts += Ghost(c.trail, colourFor(c.id), System.nanoTime())
        if (ghosts.size > 40) ghosts.removeAt(0)
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)

        // A faint decile grid, so a reported position can be sanity-checked
        // against where the finger actually is.
        for (k in 1 until 10) {
            val fx = width * k / 10f
            val fy = height * k / 10f
            canvas.drawLine(fx, 0f, fx, height.toFloat(), gridPaint)
            canvas.drawLine(0f, fy, width.toFloat(), fy, gridPaint)
        }

        // Fading trails of lifted contacts.
        val now = System.nanoTime()
        var animating = false
        val it = ghosts.iterator()
        while (it.hasNext()) {
            val g = it.next()
            val age = (now - g.bornNanos) / 1_500_000_000f
            if (age >= 1f) { it.remove(); continue }
            animating = true
            trailPaint.color = g.colour
            trailPaint.alpha = (200 * (1f - age)).toInt()
            canvas.drawPath(g.trail, trailPaint)
        }

        for (c in contacts.values) {
            val col = colourFor(c.id)

            trailPaint.color = col
            trailPaint.alpha = 150
            canvas.drawPath(c.trail, trailPaint)

            crossPaint.color = col
            crossPaint.alpha = 70
            canvas.drawLine(c.x, 0f, c.x, height.toFloat(), crossPaint)
            canvas.drawLine(0f, c.y, width.toFloat(), c.y, crossPaint)

            // Radius follows pressure so a pen's pressure curve is visible.
            val r = (16f + 44f * c.pressure.coerceIn(0f, 1f)) * d
            if (c.hovering) {
                ringPaint.color = col
                ringPaint.alpha = 255
                canvas.drawCircle(c.x, c.y, r, ringPaint)
            } else {
                blobPaint.color = col
                blobPaint.alpha = 110
                canvas.drawCircle(c.x, c.y, r, blobPaint)
                ringPaint.color = col
                ringPaint.alpha = 255
                canvas.drawCircle(c.x, c.y, r, ringPaint)
            }

            labelPaint.color = col
            canvas.drawText("#${c.id} ${toolName(c.toolType)}", c.x + r + 8f * d, c.y - 4f * d, labelPaint)
            canvas.drawText(
                "p=%.3f sz=%.3f".format(c.pressure, c.size),
                c.x + r + 8f * d, c.y + 16f * d, hudDim
            )
        }

        drawHud(canvas)
        if (animating) postInvalidateOnAnimation()
    }

    private fun drawHud(canvas: Canvas) {
        val pad = 14f * d
        val lines = ArrayList<String>()
        lines += "device  : $deviceLabel"
        lines += "source  : $sourceLabel"
        lines += "buttons : ${Names.buttons(buttonState)}"
        lines += "tools   : ${if (toolTypesSeen.isEmpty()) "-" else toolTypesSeen.joinToString(",")}"
        lines += "events  : $eventCount"
        for (c in contacts.values) {
            lines += Names.contactLine(c.id, c.toolType, c.x, c.y, c.pressure, c.tilt, c.distance)
        }

        val bigH = 34f * d
        val h = pad * 2 + bigH + lines.size * 19f * d
        var w = 0f
        for (l in lines) w = maxOf(w, hudText.measureText(l))
        w = maxOf(w, hudBig.measureText("ACTIVE 10   MAX 10")) + pad * 2

        tmpRect.set(pad, pad, pad + w, pad + h)
        canvas.drawRoundRect(tmpRect, 8f * d, 8f * d, hudBg)

        var y = pad * 2 + 22f * d
        hudBig.color = if (maxConcurrent >= 5) 0xFF7EE787.toInt() else 0xFFE6EDF3.toInt()
        canvas.drawText("ACTIVE %-3d MAX %d".format(contacts.size, maxConcurrent), pad * 2, y, hudBig)
        y += 16f * d
        for (l in lines) {
            y += 19f * d
            canvas.drawText(l, pad * 2, y, hudText)
        }

        // Reset target, kept in a corner a gesture is unlikely to land on.
        val rw = 108f * d
        val rh = 42f * d
        resetRect.set(width - rw - pad, pad, width - pad, pad + rh)
        canvas.drawRoundRect(resetRect, 8f * d, 8f * d, hudBg)
        canvas.drawText("RESET", resetRect.left + 22f * d, resetRect.centerY() + 6f * d, hudText)

        // Directly under it, in the same dead corner and on the same terms: a
        // tap here is consumed, so it is neither a contact nor a lost one.
        aboutRect.set(resetRect.left, resetRect.bottom + 8f * d,
            resetRect.right, resetRect.bottom + 8f * d + rh)
        canvas.drawRoundRect(aboutRect, 8f * d, 8f * d, hudBg)
        canvas.drawText("ABOUT", aboutRect.left + 22f * d, aboutRect.centerY() + 6f * d, hudDim)

        canvas.drawText(
            "put as many fingers on the glass as you can -- MAX is the answer",
            pad * 2, height - pad, hudDim
        )
    }
}
