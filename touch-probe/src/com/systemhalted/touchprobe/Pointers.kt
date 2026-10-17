package com.systemhalted.touchprobe

import android.view.InputDevice
import android.view.MotionEvent

/*
 * TouchView's bookkeeping, taken out of the view so it can be tested on the
 * JVM. Nothing here takes a MotionEvent: android.jar's MotionEvent is a stub
 * that throws on every call, so the view unpacks each event into the plain
 * values below (action, pointer id, tool type, bits) and hands those over.
 * The constants it compares against are compile-time constants and are
 * inlined, so naming them here costs no framework call.
 *
 * Behaviour is exactly what TouchView did inline before the split, in the same
 * order; the comments that explain *why* moved with the code they belong to.
 */

/** Human-readable names for the ints a MotionEvent carries. */
internal object Names {

    fun tool(t: Int) = when (t) {
        MotionEvent.TOOL_TYPE_FINGER -> "FINGER"
        MotionEvent.TOOL_TYPE_STYLUS -> "STYLUS"
        MotionEvent.TOOL_TYPE_ERASER -> "ERASER"
        MotionEvent.TOOL_TYPE_MOUSE -> "MOUSE"
        MotionEvent.TOOL_TYPE_UNKNOWN -> "UNKNOWN"
        else -> "tool$t"
    }

    fun source(s: Int): String {
        val parts = ArrayList<String>()
        if (s and InputDevice.SOURCE_TOUCHSCREEN == InputDevice.SOURCE_TOUCHSCREEN) parts += "TOUCHSCREEN"
        if (s and InputDevice.SOURCE_STYLUS == InputDevice.SOURCE_STYLUS) parts += "STYLUS"
        if (s and InputDevice.SOURCE_MOUSE == InputDevice.SOURCE_MOUSE) parts += "MOUSE"
        if (s and InputDevice.SOURCE_TOUCHPAD == InputDevice.SOURCE_TOUCHPAD) parts += "TOUCHPAD"
        if (parts.isEmpty()) parts += "0x%08x".format(s)
        return parts.joinToString("|")
    }

    fun buttons(b: Int): String {
        if (b == 0) return "none"
        val parts = ArrayList<String>()
        if (b and MotionEvent.BUTTON_PRIMARY != 0) parts += "PRIMARY"
        if (b and MotionEvent.BUTTON_SECONDARY != 0) parts += "SECONDARY"
        if (b and MotionEvent.BUTTON_TERTIARY != 0) parts += "TERTIARY"
        if (b and MotionEvent.BUTTON_STYLUS_PRIMARY != 0) parts += "STYLUS_PRIMARY"
        if (b and MotionEvent.BUTTON_STYLUS_SECONDARY != 0) parts += "STYLUS_SECONDARY"
        return if (parts.isEmpty()) "0x%x".format(b) else parts.joinToString("|")
    }

    /** One HUD line per live contact. Tilt and distance are omitted when the
     *  device does not report them (NaN) or reports a flat zero, which is what
     *  a finger sends -- so they appear only for a pen that has them. */
    fun contactLine(id: Int, toolType: Int, x: Float, y: Float, pressure: Float,
                    tilt: Float, distance: Float): String =
        "#%d %-7s x=%-7.1f y=%-7.1f p=%.3f%s%s".format(
            id, tool(toolType), x, y, pressure,
            if (tilt.isNaN() || tilt == 0f) "" else " tilt=%.2f".format(tilt),
            if (distance.isNaN() || distance == 0f) "" else " d=%.2f".format(distance)
        )
}

/**
 * Which pointers are down right now, and the most that ever were at once.
 *
 * [C] is whatever the view keeps per contact (position, trail, ...); the
 * ledger only needs to make one per new id and hand it back when it goes. Use
 * per event: [begin], then [track] each pointer (history first, then current),
 * [sawTool] each current pointer, then [end].
 */
internal class PointerLedger<C>(private val make: (Int) -> C) {

    val live = LinkedHashMap<Int, C>()

    /** The load-bearing number -- the most pointers ever present in a single
     *  MotionEvent. See TouchView's class comment. */
    var maxConcurrent = 0
        private set
    var eventCount = 0
        private set
    val toolTypesSeen = LinkedHashSet<String>()

    /**
     * Starts an event. Returns false when the action ends every contact
     * (HOVER_EXIT, CANCEL) and the event carries nothing further to track.
     * A cancelled gesture's contacts are retired through [onRetire] so their
     * trails linger; a hover exit's are simply dropped, there being no stroke.
     */
    fun begin(action: Int, onRetire: (C) -> Unit): Boolean {
        eventCount++
        if (action == MotionEvent.ACTION_HOVER_EXIT ||
            action == MotionEvent.ACTION_CANCEL
        ) {
            if (action == MotionEvent.ACTION_CANCEL) retireAll(onRetire) else live.clear()
            return false
        }
        return true
    }

    fun track(id: Int): C = live.getOrPut(id) { make(id) }

    fun sawTool(toolType: Int) {
        toolTypesSeen += Names.tool(toolType)
    }

    /**
     * Finishes an event: counts, then retires the pointer an UP or POINTER_UP
     * lifted. [actionPointerId] is getPointerId(actionIndex) and is only read
     * for those two actions.
     */
    fun end(action: Int, hover: Boolean, actionPointerId: Int,
            onNewMax: (Int) -> Unit, onRetire: (C) -> Unit) {
        // Count before removing the lifted pointer -- it was concurrent.
        if (!hover && live.size > maxConcurrent) {
            maxConcurrent = live.size
            onNewMax(maxConcurrent)
        }
        if (action == MotionEvent.ACTION_POINTER_UP || action == MotionEvent.ACTION_UP) {
            retire(actionPointerId, onRetire)
        }
    }

    fun retire(id: Int, onRetire: (C) -> Unit) {
        val c = live.remove(id) ?: return
        onRetire(c)
    }

    fun retireAll(onRetire: (C) -> Unit) {
        for (id in live.keys.toList()) retire(id, onRetire)
    }

    fun reset() {
        live.clear()
        maxConcurrent = 0
        eventCount = 0
        toolTypesSeen.clear()
    }
}

/**
 * Keeps a gesture that began on a HUD button (RESET, About) out of the count.
 *
 * Consuming only the button's ACTION_DOWN is not enough: returning true from
 * onTouchEvent claims the whole gesture, so its MOVEs and UP still arrive, and
 * once they reached the ledger a tap on RESET counted itself -- the peak read
 * 1 before anyone had touched the glass. So the decision is made once, at
 * ACTION_DOWN, and holds for every event up to and including the UP or
 * CANCEL that ends that gesture.
 *
 * The cost: a second finger that lands elsewhere while the button is still
 * held is swallowed with it. Pressing RESET with one hand while measuring
 * with the other is not a measurement anyone can make anyway.
 */
internal class ButtonGestures {
    private var swallowing = false

    /** Whether to drop this event. [downOnButton] is only read for ACTION_DOWN. */
    fun swallow(action: Int, downOnButton: Boolean): Boolean {
        if (action == MotionEvent.ACTION_DOWN) swallowing = downOnButton
        val drop = swallowing
        if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) swallowing = false
        return drop
    }
}

/** The report file's measurement block; MainActivity wraps it in a header
 *  and the declared-feature list. */
internal fun summaryText(maxConcurrent: Int, eventCount: Int, device: String, source: String,
                         toolTypesSeen: Collection<String>, width: Int, height: Int): String =
    buildString {
        appendLine("max concurrent pointers : $maxConcurrent")
        appendLine("motion events seen      : $eventCount")
        appendLine("device                  : $device")
        appendLine("source                  : $source")
        appendLine("tool types seen         : ${if (toolTypesSeen.isEmpty()) "-" else toolTypesSeen.joinToString(", ")}")
        appendLine("view size               : ${width}x${height}")
    }
