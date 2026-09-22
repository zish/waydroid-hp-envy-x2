package lan.syshlt.touchprobe

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.view.InputDevice
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

    var maxConcurrent = 0
        private set
    var eventCount = 0
        private set
    var deviceLabel = "-"
        private set
    var sourceLabel = "-"
        private set
    val toolTypesSeen = LinkedHashSet<String>()

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

    private val contacts = LinkedHashMap<Int, Contact>()
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
    private val tmpRect = RectF()

    init {
        setBackgroundColor(bg)
        isFocusable = true
        isFocusableInTouchMode = true
    }

    private fun colourFor(id: Int) = palette[((id % palette.size) + palette.size) % palette.size]

    private fun toolName(t: Int) = when (t) {
        MotionEvent.TOOL_TYPE_FINGER -> "FINGER"
        MotionEvent.TOOL_TYPE_STYLUS -> "STYLUS"
        MotionEvent.TOOL_TYPE_ERASER -> "ERASER"
        MotionEvent.TOOL_TYPE_MOUSE -> "MOUSE"
        MotionEvent.TOOL_TYPE_UNKNOWN -> "UNKNOWN"
        else -> "tool$t"
    }

    private fun sourceName(s: Int): String {
        val parts = ArrayList<String>()
        if (s and InputDevice.SOURCE_TOUCHSCREEN == InputDevice.SOURCE_TOUCHSCREEN) parts += "TOUCHSCREEN"
        if (s and InputDevice.SOURCE_STYLUS == InputDevice.SOURCE_STYLUS) parts += "STYLUS"
        if (s and InputDevice.SOURCE_MOUSE == InputDevice.SOURCE_MOUSE) parts += "MOUSE"
        if (s and InputDevice.SOURCE_TOUCHPAD == InputDevice.SOURCE_TOUCHPAD) parts += "TOUCHPAD"
        if (parts.isEmpty()) parts += "0x%08x".format(s)
        return parts.joinToString("|")
    }

    private fun buttonNames(b: Int): String {
        if (b == 0) return "none"
        val parts = ArrayList<String>()
        if (b and MotionEvent.BUTTON_PRIMARY != 0) parts += "PRIMARY"
        if (b and MotionEvent.BUTTON_SECONDARY != 0) parts += "SECONDARY"
        if (b and MotionEvent.BUTTON_TERTIARY != 0) parts += "TERTIARY"
        if (b and MotionEvent.BUTTON_STYLUS_PRIMARY != 0) parts += "STYLUS_PRIMARY"
        if (b and MotionEvent.BUTTON_STYLUS_SECONDARY != 0) parts += "STYLUS_SECONDARY"
        return if (parts.isEmpty()) "0x%x".format(b) else parts.joinToString("|")
    }

    /** Clears trails and the max counter. */
    fun reset() {
        contacts.clear()
        ghosts.clear()
        maxConcurrent = 0
        eventCount = 0
        toolTypesSeen.clear()
        invalidate()
    }

    /** A one-shot textual summary, for the report file. */
    fun summary(): String = buildString {
        appendLine("max concurrent pointers : $maxConcurrent")
        appendLine("motion events seen      : $eventCount")
        appendLine("device                  : $deviceLabel")
        appendLine("source                  : $sourceLabel")
        appendLine("tool types seen         : ${if (toolTypesSeen.isEmpty()) "-" else toolTypesSeen.joinToString(", ")}")
        appendLine("view size               : ${width}x${height}")
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_DOWN &&
            resetRect.contains(event.x, event.y)
        ) {
            reset()
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
        eventCount++
        buttonState = event.buttonState
        deviceLabel = event.device?.name ?: "id=${event.deviceId}"
        sourceLabel = sourceName(event.source)

        val action = event.actionMasked
        if (action == MotionEvent.ACTION_HOVER_EXIT ||
            action == MotionEvent.ACTION_CANCEL
        ) {
            if (action == MotionEvent.ACTION_CANCEL) retireAll() else contacts.clear()
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
            toolTypesSeen += toolName(c.toolType)
        }

        // Count before removing the lifted pointer -- it was concurrent.
        if (!hover && contacts.size > maxConcurrent) {
            maxConcurrent = contacts.size
            onNewMax?.invoke(maxConcurrent)
        }

        if (action == MotionEvent.ACTION_POINTER_UP || action == MotionEvent.ACTION_UP) {
            retire(event.getPointerId(event.actionIndex))
        }
        invalidate()
    }

    private fun track(id: Int, x: Float, y: Float): Contact {
        val c = contacts.getOrPut(id) { Contact(id) }
        c.x = x
        c.y = y
        if (!c.trailStarted) {
            c.trail.moveTo(x, y); c.trailStarted = true
        } else {
            c.trail.lineTo(x, y)
        }
        return c
    }

    private fun retire(id: Int) {
        val c = contacts.remove(id) ?: return
        if (c.trailStarted) ghosts += Ghost(c.trail, colourFor(c.id), System.nanoTime())
        if (ghosts.size > 40) ghosts.removeAt(0)
    }

    private fun retireAll() {
        for (id in contacts.keys.toList()) retire(id)
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
        lines += "buttons : ${buttonNames(buttonState)}"
        lines += "tools   : ${if (toolTypesSeen.isEmpty()) "-" else toolTypesSeen.joinToString(",")}"
        lines += "events  : $eventCount"
        for (c in contacts.values) {
            lines += "#%d %-7s x=%-7.1f y=%-7.1f p=%.3f%s%s".format(
                c.id, toolName(c.toolType), c.x, c.y, c.pressure,
                if (c.tilt.isNaN() || c.tilt == 0f) "" else " tilt=%.2f".format(c.tilt),
                if (c.distance.isNaN() || c.distance == 0f) "" else " d=%.2f".format(c.distance)
            )
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

        canvas.drawText(
            "put as many fingers on the glass as you can -- MAX is the answer",
            pad * 2, height - pad, hudDim
        )
    }
}
