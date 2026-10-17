/*
 * Unit tests for appfuse-probe: the parts of the probe that decide whether a
 * PASS means anything, without a StorageManager, a proxy fd or a FUSE mount.
 * Run by tests/run.sh; see tests/kotlin/Harness.kt for how and with what limits.
 *
 * The probe's verdict (docs/55: 8 of 8 checks, 8 of 8 fds, 128 KiB largest
 * onRead) rests on Pattern being right in a way the probe itself cannot see:
 * onRead serves Pattern and the checker compares against Pattern, so a pattern
 * that is wrong but self-consistent would pass every check on the device and
 * prove nothing. So Pattern is tested here against its DEFINITION, re-derived
 * independently, and against the specific faults its comment says it exists to
 * catch -- not against its own output.
 */
package com.systemhalted.appfuseprobe

import com.systemhalted.appfuseprobe.Probe.Companion.FILE_SIZE
import com.systemhalted.appfuseprobe.Probe.Companion.MAX_SPOT
import com.systemhalted.appfuseprobe.Probe.Companion.SEED
import testharness.suite
import java.util.Random
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/*
 * The documented definition, byte N = N*31 + (N >>> 12)*131 + 17 (mod 256),
 * re-derived by a different route: reduce every term mod 256 in Int arithmetic
 * first, rather than computing the Long and truncating with toByte() as
 * Pattern.at does. Both are correct only if the definition is what the code
 * implements, so agreement over many offsets is evidence and not a tautology.
 */
private fun expected(n: Long): Byte {
    val low = ((n % 256).toInt() * 31) % 256
    val page = (((n / 4096) % 256).toInt() * 131) % 256
    return ((low + page + 17) % 256).toByte()
}

/*
 * Goldens worked by hand from the definition (and cross-checked with a one-line
 * Python evaluation of it, not with this code). 31*4096 = 126976 = 496*256, so a
 * page boundary contributes only the 131: at(4096) = 131+17 = 148 = -108 as a
 * byte, and at(8192) = 262+17 = 279 = 23. at(4095): 31*4095 = 126945, which is
 * 225 mod 256, +17 = 242 = -14.
 */
private val GOLDEN = listOf(
    0L to 17, 1L to 48, 2L to 79, 8L to 9, 255L to -14, 256L to 17,
    4095L to -14, 4096L to -108, 4097L to -77, 8192L to 23, 65535L to -97,
    131072L to 113, (1L shl 20) - 100 to 114, (1L shl 20) - 1 to 111,
)

private const val PAGE = 4096L
private const val ONREAD_MAX = 128 * 1024 // docs/55's measured largest onRead

fun main() = suite("appfuse-probe") {

    // ---- Pattern ---------------------------------------------------------

    test("Pattern.at matches hand-worked goldens") {
        for ((offset, byte) in GOLDEN) {
            assertEquals(byte.toByte(), Pattern.at(offset), "at($offset)")
        }
    }

    test("Pattern.at matches the definition over every byte of the probe's file") {
        // All 1 MiB the probe serves, plus a page past it for the EOF checks' sake.
        for (n in 0 until FILE_SIZE + PAGE) {
            if (Pattern.at(n) != expected(n)) {
                throw AssertionError("at($n) = ${Pattern.at(n)}, definition says ${expected(n)}")
            }
        }
    }

    test("Pattern.at matches the definition far beyond the file, where Long matters") {
        // offset*31 overflows Int at ~69 M; toByte() of a Long must still be mod 256.
        val random = Random(1)
        val far = listOf(Int.MAX_VALUE.toLong(), 1L shl 32, (1L shl 40) + 4095, Long.MAX_VALUE / 64)
        for (n in far + List(1000) { random.nextLong() ushr 2 }) {
            assertEquals(expected(n), Pattern.at(n), "at($n)")
        }
    }

    test("Pattern is deterministic: the same offset always yields the same byte") {
        val a = ByteArray(9000).also { Pattern.fill(it, 0, 123_456, it.size) }
        val b = ByteArray(9000).also { Pattern.fill(it, 0, 123_456, it.size) }
        assertContentEquals(a, b)
    }

    test("fill at a random offset equals the same slice of one sequential fill") {
        // The on-device relationship: a pread anywhere must equal the bytes a
        // whole-file sequential read put at that place.
        val whole = ByteArray(FILE_SIZE.toInt()).also { Pattern.fill(it, 0, 0, it.size) }
        val random = Random(SEED)
        repeat(500) {
            val (offset, length) = spot(random, MAX_SPOT, FILE_SIZE)
            val part = ByteArray(length).also { Pattern.fill(it, 0, offset, length) }
            assertContentEquals(
                whole.copyOfRange(offset.toInt(), offset.toInt() + length), part,
                "fill($offset, $length)",
            )
        }
    }

    test("fill honours destOffset and count and touches nothing else") {
        val buf = ByteArray(64) { 0x5A }
        Pattern.fill(buf, 10, 4090, 20) // spans the first page boundary
        for (i in buf.indices) {
            val want = if (i in 10 until 30) expected(4090L + (i - 10)) else 0x5A.toByte()
            assertEquals(want, buf[i], "buf[$i]")
        }
        Pattern.fill(buf, 0, 0, 0) // count 0 is a no-op, not an error
    }

    test("firstMismatch: -1 on a match, else the index of the first wrong byte") {
        val buf = ByteArray(PAGE.toInt() * 2).also { Pattern.fill(it, 0, 7000, it.size) }
        assertEquals(-1, Pattern.firstMismatch(buf, buf.size, 7000))
        assertEquals(-1, Pattern.firstMismatch(buf, 0, 7000))
        for (at in listOf(0, 1, 1191, 1192, buf.size - 1)) { // 7000+1192 = page 2's first byte
            val bad = buf.copyOf().also { it[at] = (it[at] + 1).toByte() }
            assertEquals(at, Pattern.firstMismatch(bad, bad.size, 7000), "corrupt [$at]")
        }
        // Two wrong bytes: the FIRST is reported, not the last.
        val two = buf.copyOf().also { it[5] = (it[5] + 1).toByte(); it[900] = (it[900] + 1).toByte() }
        assertEquals(5, Pattern.firstMismatch(two, two.size, 7000))
    }

    test("firstMismatch looks at only count bytes") {
        val buf = ByteArray(100).also { Pattern.fill(it, 0, 0, 50) } // tail is zeros, wrong
        assertEquals(-1, Pattern.firstMismatch(buf, 50, 0))
        assertTrue(Pattern.firstMismatch(buf, 100, 0) >= 50)
    }

    test("a read served one page off fails on EVERY byte, as the comment promises") {
        // The fault Pattern's `ushr 12` term exists for: 4096 is FUSE's transfer
        // granularity, so a page-shifted result is the likeliest wrong answer.
        // at(n+4096*k) - at(n) = 131*k (mod 256), and 131 is odd, so no byte
        // survives a shift of 1..255 pages -- the whole 1 MiB file is 256 pages.
        for (k in 1L..255L) {
            for (n in listOf(0L, 1L, 4095L, 70_000L, FILE_SIZE - PAGE * k - 1)) {
                assertNotEquals(Pattern.at(n), Pattern.at(n + PAGE * k), "n=$n shift=$k pages")
            }
        }
        val asked = 300_000L
        val served = ByteArray(PAGE.toInt()).also { Pattern.fill(it, 0, asked + PAGE, it.size) }
        assertEquals(0, Pattern.firstMismatch(served, served.size, asked))
    }

    test("any shift that is not a multiple of 256 bytes is visible within a page") {
        // 31 is odd, so 31*s = 0 (mod 256) only when 256 divides s.
        for (s in 1L..4095L) {
            if (s % 256 == 0L) continue
            val n = 8192L // page-aligned start, so n and n+s share a page for s < 4096
            assertNotEquals(Pattern.at(n), Pattern.at(n + s), "shift $s")
        }
    }

    test("its blind spots are recorded, not assumed: 256-byte shifts inside a page, and 1 MiB") {
        // Not a defect in the probe -- every check that could be fooled here also
        // spans page boundaries -- but the comment only claims page-aligned shifts,
        // and this pins down why that wording is exact. Within one page a shift by
        // a multiple of 256 bytes is invisible; across 256 pages (1 MiB, the file's
        // whole size) the pattern repeats outright.
        assertEquals(Pattern.at(8192), Pattern.at(8192 + 256))
        assertEquals(Pattern.at(8192), Pattern.at(8192 + 3840))
        assertNotEquals(Pattern.at(8192 + 3840), Pattern.at(8192 + 4096))
        assertEquals(Pattern.at(12_345), Pattern.at(12_345 + FILE_SIZE))
    }

    test("no two pages of the file hold the same bytes") {
        // A wrong page anywhere in the file is detectable because every one of its
        // 256 pages is distinct. (The 8 simultaneous fds serve identical files, so
        // one fd answered with another's bytes would NOT be caught -- a limit of
        // that check, by design: it asks whether each mount works, not whether
        // mounts are kept apart.)
        val pages = (0 until (FILE_SIZE / PAGE).toInt()).map { p ->
            ByteArray(PAGE.toInt()).also { Pattern.fill(it, 0, p * PAGE, it.size) }.toList()
        }
        assertEquals(pages.size, pages.toSet().size)
    }

    // ---- servePattern: onRead's clamping ---------------------------------

    test("servePattern fills a full request in the middle of the file") {
        val data = ByteArray(ONREAD_MAX)
        assertEquals(ONREAD_MAX, servePattern(FILE_SIZE, 3 * ONREAD_MAX.toLong(), ONREAD_MAX, data))
        assertEquals(-1, Pattern.firstMismatch(data, ONREAD_MAX, 3L * ONREAD_MAX))
    }

    test("servePattern: 8 onReads of 128 KiB cover exactly the 1 MiB file") {
        // docs/55: the shared-fd onRead count was 8, "1 MiB / 128 KiB and nothing more".
        assertEquals(8L, FILE_SIZE / ONREAD_MAX)
        val whole = ByteArray(FILE_SIZE.toInt())
        var offset = 0L
        var calls = 0
        val data = ByteArray(ONREAD_MAX)
        while (true) {
            val n = servePattern(FILE_SIZE, offset, ONREAD_MAX, data)
            if (n == 0) break
            data.copyInto(whole, offset.toInt(), 0, n)
            offset += n; calls++
        }
        assertEquals(8, calls)
        assertEquals(FILE_SIZE, offset)
        for (i in whole.indices step 4093) assertEquals(expected(i.toLong()), whole[i], "byte $i")
    }

    test("servePattern is short across EOF: the probe's EOF-100 read gets 100") {
        val data = ByteArray(8192) { 0x77 }
        assertEquals(100, servePattern(FILE_SIZE, FILE_SIZE - 100, data.size, data))
        assertEquals(-1, Pattern.firstMismatch(data, 100, FILE_SIZE - 100))
        // Bytes past what it returned are left alone, not padded with pattern.
        assertTrue(data.copyOfRange(100, data.size).all { it == 0x77.toByte() })
    }

    test("servePattern returns 0 at and past EOF, never a negative count") {
        val data = ByteArray(64) { 0x33 }
        assertEquals(0, servePattern(FILE_SIZE, FILE_SIZE, 64, data))
        assertEquals(0, servePattern(FILE_SIZE, FILE_SIZE + 4096, 64, data))
        assertEquals(0, servePattern(FILE_SIZE, Long.MAX_VALUE / 2, 64, data))
        assertTrue(data.all { it == 0x33.toByte() })
        assertEquals(0, servePattern(FILE_SIZE, 0, 0, data))
    }

    test("servePattern at the last byte serves exactly one") {
        val data = ByteArray(16)
        assertEquals(1, servePattern(FILE_SIZE, FILE_SIZE - 1, 16, data))
        assertEquals(111.toByte(), data[0]) // golden: at(2^20 - 1)
    }

    // ---- spot: the pseudorandom reads ------------------------------------

    test("spot never asks for a read that runs past EOF, or for zero bytes") {
        // A spot ending past EOF would make the probe's `got != length` check fail
        // against a perfectly working mount. Tiny files make the edge reachable.
        for (size in listOf(FILE_SIZE, 8193L, 2L)) {
            val max = minOf(MAX_SPOT.toLong(), size - 1).toInt()
            val random = Random(SEED)
            repeat(20_000) {
                val (offset, length) = spot(random, max, size)
                assertTrue(length in 1..max, "length $length")
                assertTrue(offset >= 0 && offset + length <= size, "($offset, $length) in $size")
            }
        }
    }

    test("spot with a fixed seed names the same reads every run") {
        val a = Random(SEED).let { r -> List(200) { spot(r, MAX_SPOT, FILE_SIZE) } }
        val b = Random(SEED).let { r -> List(200) { spot(r, MAX_SPOT, FILE_SIZE) } }
        assertEquals(a, b)
        // And it draws nextInt first, then nextDouble -- the order the probe always
        // used, so an offset printed by an earlier build is still the same offset.
        val r = Random(SEED)
        val length = 1 + r.nextInt(MAX_SPOT)
        val offset = (r.nextDouble() * (FILE_SIZE - length)).toLong()
        assertEquals(offset to length, a[0])
    }

    test("the 200 seeded spots are spread over the file, not bunched") {
        // If they all landed in one 128 KiB onRead window the random check would
        // be exercising one transfer, not random access.
        val r = Random(SEED)
        val windows = List(200) { spot(r, MAX_SPOT, FILE_SIZE).first / ONREAD_MAX }.toSet()
        assertEquals(8, windows.size)
    }

    // ---- failureLines: the report's cause chain --------------------------

    test("failureLines prints the throw and each cause, indented by depth") {
        val t = IllegalStateException("Failed to mount",
            java.io.IOException("Invalid argument", RuntimeException(null as String?)))
        assertEquals(
            listOf(
                "  openProxyFileDescriptor FAILED",
                "    throw java.lang.IllegalStateException: Failed to mount",
                "    cause   java.io.IOException: Invalid argument",
                "    cause     java.lang.RuntimeException: null",
            ),
            failureLines("openProxyFileDescriptor", t),
        )
    }

    test("failureLines stops at eight throwables, so a long chain cannot run away") {
        var t: Throwable = RuntimeException("0")
        for (i in 1..20) t = RuntimeException("$i", t)
        val lines = failureLines("x", t)
        assertEquals(1 + 8, lines.size)
        assertEquals("    throw java.lang.RuntimeException: 20", lines[1])
        assertEquals("    cause " + "  ".repeat(7) + "java.lang.RuntimeException: 13", lines[8])
    }

    // ---- constants the docs and the checks depend on --------------------

    test("the probe's constants are the ones docs/55 reports against") {
        // 1 MiB: docs/55's "sequential read of 1 MiB" and its 8 = 1 MiB / 128 KiB.
        assertEquals(1L shl 20, FILE_SIZE)
        // The random spots must be able to span a page boundary, or a sub-page
        // 256-byte shift (the blind spot above) could never be caught by them.
        assertTrue(MAX_SPOT > PAGE)
    }
}
