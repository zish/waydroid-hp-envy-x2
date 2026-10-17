/*
 * Unit tests for touch-probe: the bookkeeping behind the one number this app
 * exists to produce -- the most pointers ever down at once, which decides
 * whether the overlay gets a touchscreen.multitouch* feature XML -- plus the
 * names the HUD and the report put on MotionEvent's ints. Run by
 * tests/run.sh; see tests/kotlin/Harness.kt for how and with what limits.
 *
 * MotionEvent cannot be built here (android.jar is stubs), so each gesture is
 * replayed as the plain values TouchView.ingest() unpacks from one: the masked
 * action, the ids of every pointer in the event, and the id at actionIndex.
 *
 * Every constant below is a literal copied from the Android reference for
 * MotionEvent and InputDevice, not read back from the code under test, so a
 * name bound to the wrong constant fails here:
 *   ACTION_DOWN 0, UP 1, MOVE 2, CANCEL 3, POINTER_DOWN 5, POINTER_UP 6,
 *   HOVER_MOVE 7, HOVER_ENTER 9, HOVER_EXIT 10
 *   TOOL_TYPE_UNKNOWN 0, FINGER 1, STYLUS 2, MOUSE 3, ERASER 4
 *   BUTTON_PRIMARY 0x1, SECONDARY 0x2, TERTIARY 0x4, BACK 0x8, FORWARD 0x10,
 *   STYLUS_PRIMARY 0x20, STYLUS_SECONDARY 0x40
 *   SOURCE_TOUCHSCREEN 0x1002, MOUSE 0x2002, STYLUS 0x4002,
 *   BLUETOOTH_STYLUS 0xC002, TOUCHPAD 0x100008, KEYBOARD 0x101
 */
package com.systemhalted.touchprobe

import testharness.suite
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

private const val DOWN = 0
private const val UP = 1
private const val MOVE = 2
private const val CANCEL = 3
private const val POINTER_DOWN = 5
private const val POINTER_UP = 6
private const val HOVER_MOVE = 7
private const val HOVER_ENTER = 9
private const val HOVER_EXIT = 10

/** A ledger plus a record of what it called back with, so a test can assert
 *  on the report rewrites (onNewMax) and the trails left behind (onRetire). */
private class Rig {
    val ledger = PointerLedger { id -> "c$id" }
    val newMax = mutableListOf<Int>()
    val retired = mutableListOf<String>()

    /** One MotionEvent, in the order TouchView.ingest() drives the ledger. */
    fun event(action: Int, ids: List<Int>, actionId: Int = -1, hover: Boolean = false,
              tool: Int = 1) {
        if (!ledger.begin(action) { retired += it }) return
        for (id in ids) { ledger.track(id); ledger.sawTool(tool) }
        ledger.end(action, hover, actionId, { newMax += it }, { retired += it })
    }

    val live get() = ledger.live.keys.toList()

    val buttons = ButtonGestures()

    /** One MotionEvent through TouchView.onTouchEvent: [onButton] says whether
     *  a DOWN landed on RESET, which resets and is swallowed with its gesture. */
    fun touch(action: Int, ids: List<Int>, actionId: Int = -1, onButton: Boolean = false) {
        if (buttons.swallow(action, action == DOWN && onButton)) {
            if (action == DOWN && onButton) ledger.reset()
            return
        }
        event(action, ids, actionId)
    }
}

fun main() = suite("touch-probe") {

    // ---- HUD buttons -------------------------------------------------------

    test("a tap on RESET, wobble included, leaves the count at zero") {
        val r = Rig()
        r.touch(DOWN, listOf(0), onButton = true)
        r.touch(MOVE, listOf(0))
        r.touch(MOVE, listOf(0))
        r.touch(UP, listOf(0), actionId = 0)
        assertEquals(0, r.ledger.maxConcurrent)
        assertEquals(0, r.ledger.eventCount)
        assertEquals(emptyList(), r.live)
    }

    test("the gesture after a RESET tap is counted normally") {
        val r = Rig()
        r.touch(DOWN, listOf(0), onButton = true)
        r.touch(UP, listOf(0), actionId = 0)
        r.touch(DOWN, listOf(0))
        r.touch(POINTER_DOWN, listOf(0, 1), actionId = 1)
        r.touch(POINTER_UP, listOf(0, 1), actionId = 1)
        r.touch(UP, listOf(0), actionId = 0)
        assertEquals(2, r.ledger.maxConcurrent)
        assertEquals(4, r.ledger.eventCount)
    }

    test("a cancelled button gesture also ends the swallowing") {
        val r = Rig()
        r.touch(DOWN, listOf(0), onButton = true)
        r.touch(CANCEL, listOf(0))
        r.touch(DOWN, listOf(3))
        assertEquals(1, r.ledger.maxConcurrent)
    }

    test("a gesture that starts off the buttons is never swallowed") {
        val b = ButtonGestures()
        assertFalse(b.swallow(DOWN, false))
        // onButton is only read at DOWN, so a MOVE over RESET still counts.
        assertFalse(b.swallow(MOVE, true))
        assertFalse(b.swallow(UP, false))
    }

    // ---- PointerLedger: the concurrent count -----------------------------

    test("one tap counts one and leaves nothing live") {
        val r = Rig()
        r.event(DOWN, listOf(0))
        r.event(UP, listOf(0), actionId = 0)
        assertEquals(1, r.ledger.maxConcurrent)
        assertEquals(emptyList(), r.live)
        assertEquals(listOf(1), r.newMax)
        assertEquals(listOf("c0"), r.retired)
        assertEquals(2, r.ledger.eventCount)
    }

    test("ten fingers down one by one count ten, each rise reported once") {
        // The jazzhand case: the SYNA7500 advertises ABS_MT_SLOT max=9.
        val r = Rig()
        val down = mutableListOf<Int>()
        for (id in 0 until 10) {
            down += id
            r.event(if (id == 0) DOWN else POINTER_DOWN, down.toList(), actionId = id)
            r.event(MOVE, down.toList())
        }
        assertEquals(10, r.ledger.maxConcurrent)
        assertEquals((1..10).toList(), r.newMax)
    }

    test("the lifted pointer is counted in its own POINTER_UP event") {
        // Android's POINTER_UP still carries the lifting pointer, and it was
        // concurrent, so the count is taken before it is retired. To make
        // that the only chance to see two, the ledger first meets this
        // gesture at its POINTER_UP -- as it does when RESET (or the view
        // gaining focus) lands mid-gesture.
        val r = Rig()
        r.event(POINTER_UP, listOf(0, 1), actionId = 1)
        assertEquals(2, r.ledger.maxConcurrent)
        assertEquals(listOf(0), r.live)
        assertEquals(listOf("c1"), r.retired)
        r.event(UP, listOf(0), actionId = 0)
        assertEquals(2, r.ledger.maxConcurrent)
        assertEquals(listOf(2), r.newMax)
    }

    test("POINTER_UP retires the pointer at actionIndex, not the first one") {
        val r = Rig()
        r.event(DOWN, listOf(3))
        r.event(POINTER_DOWN, listOf(3, 7), actionId = 7)
        r.event(POINTER_UP, listOf(3, 7), actionId = 3)
        assertEquals(listOf(7), r.live)
        r.event(MOVE, listOf(7))
        assertEquals(listOf(7), r.live)
        assertEquals(2, r.ledger.maxConcurrent)
    }

    test("sequential taps never sum: two one-finger taps are max 1") {
        // The number the feature XML hangs on is concurrency, not a total of
        // distinct ids. Android may hand out a fresh id or reuse 0.
        val r = Rig()
        r.event(DOWN, listOf(0)); r.event(UP, listOf(0), actionId = 0)
        r.event(DOWN, listOf(1)); r.event(UP, listOf(1), actionId = 1)
        assertEquals(1, r.ledger.maxConcurrent)
        assertEquals(listOf(1), r.newMax)
    }

    test("a higher earlier peak is not lowered by a later smaller gesture") {
        val r = Rig()
        r.event(DOWN, listOf(0))
        r.event(POINTER_DOWN, listOf(0, 1), actionId = 1)
        r.event(POINTER_DOWN, listOf(0, 1, 2), actionId = 2)
        r.event(CANCEL, listOf(0, 1, 2))
        r.event(DOWN, listOf(0)); r.event(UP, listOf(0), actionId = 0)
        assertEquals(3, r.ledger.maxConcurrent)
        assertEquals(listOf(1, 2, 3), r.newMax)
    }

    test("hover never raises the count, however many pointers it carries") {
        // A hovering pen is not a contact; counting it would let a stylus
        // plus a palm pass for multitouch.
        val r = Rig()
        r.event(HOVER_ENTER, listOf(0), hover = true, tool = 2)
        r.event(HOVER_MOVE, listOf(0, 1), hover = true, tool = 2)
        assertEquals(0, r.ledger.maxConcurrent)
        assertEquals(emptyList(), r.newMax)
        assertEquals(listOf(0, 1), r.live)
    }

    test("HOVER_EXIT drops hover contacts without leaving trails") {
        val r = Rig()
        r.event(HOVER_ENTER, listOf(0), hover = true, tool = 2)
        r.event(HOVER_EXIT, listOf(0), hover = true, tool = 2)
        assertEquals(emptyList(), r.live)
        assertEquals(emptyList(), r.retired)
        assertEquals(2, r.ledger.eventCount)
    }

    test("CANCEL retires every live contact so each trail fades out") {
        val r = Rig()
        r.event(DOWN, listOf(4))
        r.event(POINTER_DOWN, listOf(4, 5), actionId = 5)
        r.event(CANCEL, listOf(4, 5))
        assertEquals(emptyList(), r.live)
        assertEquals(listOf("c4", "c5"), r.retired)
        assertEquals(3, r.ledger.eventCount)
    }

    test("a contact is made once per id, and moves reuse it") {
        var made = 0
        val l = PointerLedger { id -> made++; id }
        l.begin(DOWN) {}; l.track(0); l.end(DOWN, false, -1, {}, {})
        repeat(5) { l.begin(MOVE) {}; l.track(0); l.track(0); l.end(MOVE, false, -1, {}, {}) }
        assertEquals(1, made)
    }

    test("an UP for an id that is not live is harmless") {
        val r = Rig()
        r.ledger.retire(9) { r.retired += it }
        assertEquals(emptyList(), r.retired)
    }

    test("reset zeroes the count, the events and the tools, and drops contacts") {
        val r = Rig()
        r.event(DOWN, listOf(0), tool = 2)
        r.event(POINTER_DOWN, listOf(0, 1), actionId = 1)
        r.ledger.reset()
        assertEquals(0, r.ledger.maxConcurrent)
        assertEquals(0, r.ledger.eventCount)
        assertTrue(r.ledger.toolTypesSeen.isEmpty())
        assertEquals(emptyList(), r.live)
        // And counting starts again from nothing: the next single tap reports.
        r.event(DOWN, listOf(0))
        assertEquals(listOf(1, 2, 1), r.newMax)
    }

    test("tool types are recorded once each, in first-seen order") {
        val r = Rig()
        r.event(DOWN, listOf(0), tool = 2)
        r.event(MOVE, listOf(0), tool = 2)
        r.event(UP, listOf(0), actionId = 0, tool = 2)
        r.event(DOWN, listOf(0), tool = 1)
        r.event(UP, listOf(0), actionId = 0, tool = 4)
        assertEquals(listOf("STYLUS", "FINGER", "ERASER"), r.ledger.toolTypesSeen.toList())
    }

    // ---- Names -----------------------------------------------------------

    test("tool types name MotionEvent's documented values") {
        assertEquals("UNKNOWN", Names.tool(0))
        assertEquals("FINGER", Names.tool(1))
        assertEquals("STYLUS", Names.tool(2))
        assertEquals("MOUSE", Names.tool(3))
        assertEquals("ERASER", Names.tool(4))
        // A tool type this API level does not know (5 is PALM on API 34+)
        // still shows its number rather than vanishing.
        assertEquals("tool5", Names.tool(5))
    }

    test("no buttons is 'none', not an empty string") {
        assertEquals("none", Names.buttons(0))
    }

    test("stylus barrel buttons name the right bits") {
        assertEquals("STYLUS_PRIMARY", Names.buttons(0x20))
        assertEquals("STYLUS_SECONDARY", Names.buttons(0x40))
        assertEquals("STYLUS_PRIMARY|STYLUS_SECONDARY", Names.buttons(0x60))
    }

    test("mouse buttons combine in a fixed order") {
        assertEquals("PRIMARY", Names.buttons(0x1))
        assertEquals("PRIMARY|SECONDARY|TERTIARY", Names.buttons(0x7))
        assertEquals("SECONDARY|STYLUS_PRIMARY", Names.buttons(0x22))
    }

    test("buttons the HUD has no name for show as hex, not as 'none'") {
        // BACK and FORWARD are real bits; hiding them would read as no press.
        assertEquals("0x8", Names.buttons(0x8))
        assertEquals("0x18", Names.buttons(0x18))
        // A named bit wins; the unnamed one alongside it is dropped.
        assertEquals("PRIMARY", Names.buttons(0x9))
    }

    test("sources name the full class-qualified constants") {
        assertEquals("TOUCHSCREEN", Names.source(0x1002))
        assertEquals("MOUSE", Names.source(0x2002))
        assertEquals("STYLUS", Names.source(0x4002))
        assertEquals("TOUCHPAD", Names.source(0x100008))
        // A pen digitizer usually reports both.
        assertEquals("TOUCHSCREEN|STYLUS", Names.source(0x5002))
        // BLUETOOTH_STYLUS carries the STYLUS bits.
        assertEquals("STYLUS", Names.source(0xC002))
    }

    test("a source sharing only the POINTER class bit is not a match") {
        // TOUCHSCREEN, MOUSE and STYLUS all include SOURCE_CLASS_POINTER
        // (0x2); matching on any shared bit would name a mouse a touchscreen.
        // A bare class bit and an unrelated source fall through to hex.
        assertEquals("0x00000002", Names.source(0x2))
        assertEquals("0x00000101", Names.source(0x101))
    }

    test("a finger's HUD line has no tilt or distance") {
        assertEquals(
            "#0 FINGER  x=12.5    y=300.0   p=0.500",
            Names.contactLine(0, 1, 12.5f, 300f, 0.5f, 0f, Float.NaN)
        )
    }

    test("a pen's HUD line shows tilt and hover distance when reported") {
        assertEquals(
            "#1 STYLUS  x=1.0     y=2.0     p=0.000 tilt=0.79 d=3.25",
            Names.contactLine(1, 2, 1f, 2f, 0f, 0.785f, 3.25f)
        )
        assertEquals(
            "#2 ERASER  x=1.0     y=2.0     p=1.000 d=0.50",
            Names.contactLine(2, 4, 1f, 2f, 1f, Float.NaN, 0.5f)
        )
    }

    // ---- The report ------------------------------------------------------

    test("the report block, field by field") {
        val expected =
            "max concurrent pointers : 10\n" +
            "motion events seen      : 412\n" +
            "device                  : wayland_touch\n" +
            "source                  : TOUCHSCREEN\n" +
            "tool types seen         : FINGER, STYLUS\n" +
            "view size               : 1920x1280\n"
        assertEquals(expected, summaryText(10, 412, "wayland_touch", "TOUCHSCREEN",
            linkedSetOf("FINGER", "STYLUS"), 1920, 1280))
    }

    test("a report written before any touch says '-' for tools") {
        val text = summaryText(0, 0, "-", "-", emptySet(), 0, 0)
        assertTrue("tool types seen         : -\n" in text)
        assertTrue(text.startsWith("max concurrent pointers : 0\n"))
        assertFalse(text.contains(", "))
    }
}
