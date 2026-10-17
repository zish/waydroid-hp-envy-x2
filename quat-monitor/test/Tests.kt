/*
 * Unit tests for quat-monitor: the quaternion arithmetic behind the two
 * divergence columns, and the CSV format that makes the log replayable --
 * written by LogWriter, read back by History, and read off the device by
 * whatever scores a candidate fusion. Run by tests/run.sh; see
 * tests/kotlin/Harness.kt for how and with what limits.
 *
 * Goldens come from standard quaternion identities (a rotation of theta about
 * a unit axis n is (n sin(theta/2), cos(theta/2)), and q and -q are the same
 * rotation), from Sample.HEADER read as the specification of column order,
 * and from docs/20-quat-monitor.md -- never from running the code under test.
 */
package com.systemhalted.quatmon

import testharness.suite
import java.io.File
import java.nio.file.Files
import java.util.TimeZone
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream
import kotlin.math.cos
import kotlin.math.sin
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/* Rotation of `deg` degrees about the unit axis (x, y, z), as (x, y, z, w). */
private fun rot(deg: Double, x: Double, y: Double, z: Double): FloatArray {
    val h = Math.toRadians(deg) / 2
    val s = sin(h)
    return floatArrayOf((x * s).toFloat(), (y * s).toFloat(), (z * s).toFloat(), cos(h).toFloat())
}

private fun ang(a: FloatArray, b: FloatArray) =
    Q.angleDeg(a[0], a[1], a[2], a[3], b[0], b[1], b[2], b[3])

/*
 * acos is ill-conditioned next to 1, and the dot product is a Float: the
 * float just below 1 is 1 - 2^-24, and 2*acos(1 - 2^-24) is ~0.04 degrees.
 * So that is the resolution of angleDeg near zero, and a tolerance tighter
 * than this near 0 would be testing float rounding, not the formula.
 */
private const val NEAR_ZERO_TOL = 0.05f

/*
 * A sample whose 30 fields are all different, so a column written in the
 * wrong place cannot coincide with the right value. Each value is chosen to
 * be exact at its column's precision (6, 4, 3 or 1 decimals -- Sample.toCsv),
 * so formatting does not move it.
 */
private fun distinct(wall: Long = 1_792_227_600_000L) = Sample(
    wall, 123_456_789L,
    0.1f, -0.2f, 0.3f, 0.9f, 31.5f,
    0.11f, -0.22f, 0.33f, 0.88f, 32.5f,
    0.12f, -0.23f, 0.34f, 0.87f, 33.5f,
    0.25f, -9.75f, 1.5f,
    0.015f, -0.025f, 0.035f,
    21.5f, -42.25f, 18.125f,
    3, 54.375f,
    21.75f, 7.125f
)

/* Header name -> the value written, as text, for exactly the fields of
 * distinct(). This is what a reader of the CSV relies on: the names. */
private val DISTINCT_BY_NAME = mapOf(
    "wall_ms" to "1792227600000", "elapsed_ms" to "123456789",
    "hw_x" to "0.1", "hw_y" to "-0.2", "hw_z" to "0.3", "hw_w" to "0.9", "hw_age_ms" to "31.5",
    "sw_x" to "0.11", "sw_y" to "-0.22", "sw_z" to "0.33", "sw_w" to "0.88", "sw_age_ms" to "32.5",
    "gm_x" to "0.12", "gm_y" to "-0.23", "gm_z" to "0.34", "gm_w" to "0.87", "gm_age_ms" to "33.5",
    "ax" to "0.25", "ay" to "-9.75", "az" to "1.5",
    "gx" to "0.015", "gy" to "-0.025", "gz" to "0.035",
    "mx" to "21.5", "my" to "-42.25", "mz" to "18.125",
    "m_acc" to "3", "b_ut" to "54.375",
    "ang_hw_sw" to "21.75", "ang_hw_gm" to "7.125"
)

private fun csv(s: Sample): String = StringBuilder().also { s.toCsv(it) }.toString()

/* Every field, so round trips can be compared whole. */
private fun fields(s: Sample): List<Any> = listOf(
    s.wallMs, s.elapsedMs,
    s.hwX, s.hwY, s.hwZ, s.hwW, s.hwAgeMs,
    s.swX, s.swY, s.swZ, s.swW, s.swAgeMs,
    s.gmX, s.gmY, s.gmZ, s.gmW, s.gmAgeMs,
    s.ax, s.ay, s.az, s.gx, s.gy, s.gz, s.mx, s.my, s.mz,
    s.mAcc, s.bUt, s.angHwSw, s.angHwGm
)

private fun tempDir(): File = Files.createTempDirectory("quatmon-test").toFile()

private fun gunzip(f: File): String =
    GZIPInputStream(f.inputStream()).bufferedReader().use { it.readText() }

private fun noErrors(f: File, e: Exception): Unit = throw AssertionError("${f.name}: $e")

fun main() = suite("quat-monitor") {
    // hourKey and Anomaly.iso format in the default zone, as on the device.
    // Pin it so the goldens below are a fact rather than a property of the
    // machine the suite happens to run on.
    TimeZone.setDefault(TimeZone.getTimeZone("UTC"))


    // ---- Q.w -------------------------------------------------------------

    test("w is taken as given when the sensor reports four values") {
        assertEquals(-0.5f, Q.w(floatArrayOf(0.5f, 0.5f, 0.5f, -0.5f)))
    }

    test("w is implied by unit length when only three are reported") {
        // (0.6, 0, 0) leaves 1 - 0.36 = 0.64 for w^2, so w = 0.8.
        assertEquals(0.8f, Q.w(floatArrayOf(0.6f, 0f, 0f)), 1e-6f)
        // And it is the non-negative root: a 3-value sensor cannot say
        // which hemisphere, and q / -q are the same rotation anyway.
        assertEquals(1f, Q.w(floatArrayOf(0f, 0f, 0f)))
    }

    test("an implied w is 0, not NaN, when rounding overshoots unit length") {
        // |v|^2 = 1.0002 > 1: sqrt of a negative would poison every
        // derived column with NaN, which the CSV writes as a missing value.
        assertEquals(0f, Q.w(floatArrayOf(0.7072f, 0.7072f, 0f)))
    }

    // ---- Q.angleDeg ------------------------------------------------------

    test("a quaternion is 0 degrees from itself") {
        val q = rot(37.0, 0.0, 0.6, 0.8)
        assertEquals(0f, ang(q, q), NEAR_ZERO_TOL)
    }

    test("q and -q are the same rotation: 0 degrees, not 360") {
        // Samples.kt: "Without it a perfect match intermittently reads as
        // 360 degrees apart". Two fusions agreeing on the rotation and
        // disagreeing on the sign must read as agreement.
        for (q in listOf(rot(37.0, 0.0, 0.6, 0.8), rot(170.0, 1.0, 0.0, 0.0),
                         floatArrayOf(0f, 0f, 0f, 1f))) {
            val neg = FloatArray(4) { -q[it] }
            assertEquals(0f, ang(q, neg), NEAR_ZERO_TOL)
            assertEquals(0f, ang(neg, q), NEAR_ZERO_TOL)
        }
    }

    test("the angle is the rotation between them, from the half-angle form") {
        val id = floatArrayOf(0f, 0f, 0f, 1f)
        assertEquals(90f, ang(id, rot(90.0, 0.0, 0.0, 1.0)), 1e-3f)
        assertEquals(180f, ang(id, rot(180.0, 1.0, 0.0, 0.0)), 1e-3f)
        // 30 then 75 about the same axis differ by 45, wherever they start.
        assertEquals(45f, ang(rot(30.0, 0.0, 1.0, 0.0), rot(75.0, 0.0, 1.0, 0.0)), 1e-3f)
        // Symmetric.
        assertEquals(ang(rot(10.0, 1.0, 0.0, 0.0), rot(50.0, 0.0, 0.0, 1.0)),
                     ang(rot(50.0, 0.0, 0.0, 1.0), rot(10.0, 1.0, 0.0, 0.0)), 1e-4f)
    }

    test("the angle never exceeds 180, because q and -q are folded together") {
        // 200 degrees about z is the same rotation as -160: 160 apart, not 200.
        val id = floatArrayOf(0f, 0f, 0f, 1f)
        assertEquals(160f, ang(id, rot(200.0, 0.0, 0.0, 1.0)), 1e-3f)
    }

    test("the inputs are normalised, so a non-unit sensor value still compares") {
        val q = rot(60.0, 0.0, 0.0, 1.0)
        val scaled = FloatArray(4) { q[it] * 3f }
        assertEquals(0f, ang(q, scaled), NEAR_ZERO_TOL)
        assertEquals(60f, ang(floatArrayOf(0f, 0f, 0f, 2f), scaled), 1e-3f)
    }

    test("a slot that has never been filled is NaN, not a number") {
        // docs/20: before a sensor's first event its slot holds zeros. A
        // zero quaternion is no rotation at all, and NaN is what the CSV
        // writes as an empty field -- distinct from a genuine 0 degrees.
        val zero = FloatArray(4)
        assertTrue(ang(zero, rot(10.0, 1.0, 0.0, 0.0)).isNaN())
        assertTrue(ang(rot(10.0, 1.0, 0.0, 0.0), zero).isNaN())
    }

    // ---- Ring --------------------------------------------------------------

    test("the ring keeps the newest cap samples, oldest first") {
        val r = Ring(3)
        assertEquals(0, r.size())
        for (t in 1L..5L) r.add(distinct(wall = t))
        assertEquals(5L, r.total)
        assertEquals(3, r.size())
        assertEquals(listOf(3L, 4L, 5L), (0 until r.size()).map { r.wallMs[r.idx(it)] })
    }

    test("before it wraps, the ring's oldest sample is the first one added") {
        val r = Ring(4)
        for (t in 10L..12L) r.add(distinct(wall = t))
        assertEquals(listOf(10L, 11L, 12L), (0 until r.size()).map { r.wallMs[r.idx(it)] })
    }

    // ---- Sample.fmt --------------------------------------------------------

    test("fmt rounds to the column's precision") {
        // Decimal rounding by hand: 0.1234567 to 6 places is 0.123457, and
        // -9.81234 to 4 is -9.8123.
        assertEquals("0.123457", Sample.fmt(0.1234567f, 1e6f))
        assertEquals("-9.8123", Sample.fmt(-9.81234f, 1e4f))
        assertEquals("1.0", Sample.fmt(1f, 1e6f))
    }

    test("an age column keeps rising past 59.65 hours of silence") {
        // Int.MAX_VALUE / 10 ms is 59.65 h. 60 h and 100 h of age must come out
        // as themselves, not both as 214748364.7.
        val h60 = 60 * 3_600_000f
        val h100 = 100 * 3_600_000f
        assertEquals(h60.toDouble(), Sample.fmt(h60, 10f).toDouble())
        assertEquals(h100.toDouble(), Sample.fmt(h100, 10f).toDouble())
        assertEquals("1234.5", Sample.fmt(1234.5f, 10f))
    }

    test("fmt writes NaN as an empty field, so missing stays distinct from zero") {
        assertEquals("", Sample.fmt(Float.NaN, 1e6f))
        assertEquals("0.0", Sample.fmt(0f, 1e6f))
    }

    // ---- the CSV format ----------------------------------------------------

    test("the header names 30 columns, as docs/20 says") {
        val names = Sample.HEADER.trimEnd('\n').split(',')
        assertEquals(30, names.size)
        assertEquals(names.size, names.toSet().size, "duplicate column name")
        assertTrue(Sample.HEADER.endsWith("\n"))
    }

    test("every value lands under its own header name") {
        // The headline property: a reader finds columns by name, so a
        // field written one place over is silently a different quantity.
        val names = Sample.HEADER.trimEnd('\n').split(',')
        val row = csv(distinct())
        assertTrue(row.endsWith("\n"))
        val values = row.trimEnd('\n').split(',')
        assertEquals(names.size, values.size)
        assertEquals(DISTINCT_BY_NAME, names.zip(values).toMap())
    }

    test("a NaN is an empty field and the row keeps all 30 columns") {
        val s = Sample(1L, 2L,
            Float.NaN, Float.NaN, Float.NaN, Float.NaN, Float.NaN,
            0f, 0f, 0f, 1f, 1f, 0f, 0f, 0f, 1f, 1f,
            0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, -1, 0f, Float.NaN, Float.NaN)
        val v = csv(s).trimEnd('\n').split(',')
        assertEquals(30, v.size)
        assertEquals(listOf("", "", "", "", ""), v.subList(2, 7))
        assertEquals("-1", v[26])
        assertEquals("", v[28]); assertEquals("", v[29])
    }

    test("toCsv clears the builder, so a reused one never accumulates rows") {
        val sb = StringBuilder("stale")
        distinct().toCsv(sb); distinct().toCsv(sb)
        assertEquals(1, sb.count { it == '\n' })
        assertFalse(sb.contains("stale"))
    }

    test("a written row parses back to the same sample") {
        val back = assertNotNull(History.parse(csv(distinct()).trimEnd('\n')))
        assertEquals(fields(distinct()), fields(back))
    }

    test("values small enough for scientific notation survive the round trip") {
        // Float.toString switches to E notation below 1e-3, so a gyro at
        // rest writes "1.0E-4" -- legal for Kotlin's toFloat and for any
        // CSV reader, and worth pinning because it surprises people.
        val s = Sample(1L, 2L, 1e-4f, 0f, 0f, 1f, 0f, 0f, 0f, 0f, 1f, 0f,
            0f, 0f, 0f, 1f, 0f, 0f, 0f, 0f, 2e-6f, 0f, 0f, 0f, 0f, 0f, 0, 0f, 0f, 0f)
        val row = csv(s)
        assertTrue(row.contains("E-"), row)
        val back = assertNotNull(History.parse(row.trimEnd('\n')))
        assertEquals(1e-4f, back.hwX)
        assertEquals(2e-6f, back.gx)
    }

    test("empty fields parse back as NaN rather than discarding the row") {
        val back = assertNotNull(History.parse(
            "5,6,,,,,,0.0,0.0,0.0,1.0,1.0,0.0,0.0,0.0,1.0,1.0," +
            "0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,-1,0.0,,"))
        assertTrue(back.hwX.isNaN() && back.hwAgeMs.isNaN())
        assertTrue(back.angHwSw.isNaN() && back.angHwGm.isNaN())
        assertEquals(-1, back.mAcc)
    }

    test("the header, a blank line, a short row and garbage are skipped") {
        assertNull(History.parse(Sample.HEADER.trimEnd('\n')))
        assertNull(History.parse(""))
        assertNull(History.parse("1,2,3"))
        assertNull(History.parse(csv(distinct()).trimEnd('\n').replaceFirst("1792227600000", "x")))
    }

    // ---- History.load --------------------------------------------------------

    test("history reads plain and gzipped hours, oldest first") {
        val dir = tempDir()
        try {
            File(dir, "quat-20261017-08.csv.gz").outputStream().let(::GZIPOutputStream).use {
                it.write((Sample.HEADER + csv(distinct(wall = 1L)) + csv(distinct(wall = 2L))).toByteArray())
            }
            File(dir, "quat-20261017-09.csv").writeText(Sample.HEADER + csv(distinct(wall = 3L)))
            // Siblings in the same directory that are not sample logs.
            File(dir, "events.csv").writeText("id,wall_ms,iso,description,capture\n9,9,x,,\n")
            File(dir, "meta.txt").writeText("hw=ITE8350\n")
            File(dir, "capture-9.txt").writeText("# capture\n")

            val r = Ring(10)
            assertEquals(Pair(3, 2), History.load(dir, r, ::noErrors))
            assertEquals(listOf(1L, 2L, 3L), (0 until r.size()).map { r.wallMs[r.idx(it)] })
        } finally { dir.deleteRecursively() }
    }

    test("history loads only the newest FILES hours") {
        val dir = tempDir()
        try {
            // File names sort chronologically because hourKey is yyyyMMdd-HH.
            for (h in 5..9) File(dir, "quat-20261017-0$h.csv")
                .writeText(Sample.HEADER + csv(distinct(wall = h.toLong())))
            val r = Ring(10)
            assertEquals(Pair(History.FILES, 5), History.load(dir, r, ::noErrors))
            assertEquals((10 - History.FILES..9).map { it.toLong() },
                         (0 until r.size()).map { r.wallMs[r.idx(it)] })
        } finally { dir.deleteRecursively() }
    }

    test("a corrupt hour is reported and skipped, and the others still load") {
        val dir = tempDir()
        try {
            File(dir, "quat-20261017-08.csv.gz").writeText("not gzip")
            File(dir, "quat-20261017-09.csv").writeText(Sample.HEADER + csv(distinct(wall = 7L)))
            val bad = mutableListOf<String>()
            val r = Ring(10)
            assertEquals(Pair(1, 2), History.load(dir, r) { f, _ -> bad += f.name })
            assertEquals(listOf("quat-20261017-08.csv.gz"), bad)
            assertEquals(7L, r.wallMs[r.idx(0)])
        } finally { dir.deleteRecursively() }
    }

    test("history with nothing to load says so, rather than claiming zero samples") {
        val dir = tempDir()
        try {
            assertNull(History.load(dir, Ring(1), ::noErrors))
            assertNull(History.load(File(dir, "absent"), Ring(1), ::noErrors))
        } finally { dir.deleteRecursively() }
    }

    // ---- LogWriter -----------------------------------------------------------

    test("hourKey names the local hour, so file names sort chronologically") {
        // 1792227600 is `date -u -d '2026-10-17 09:00:00' +%s`.
        assertEquals("20261017-09", LogWriter.hourKey(1_792_227_600_000L))
        assertEquals("20261017-09", LogWriter.hourKey(1_792_231_199_999L))
        assertEquals("20261017-10", LogWriter.hourKey(1_792_231_200_000L))
    }

    test("the writer rolls over on the hour and gzips the closed file") {
        val dir = tempDir()
        try {
            val w = LogWriter(dir)
            w.start()
            val nine = 1_792_227_600_000L
            val ten = 1_792_231_200_000L
            assertTrue(w.offer(distinct(wall = nine)))
            assertTrue(w.offer(distinct(wall = nine + 50)))
            assertTrue(w.offer(distinct(wall = ten)))
            w.stop()
            assertEquals(3L, w.written.get())
            assertEquals(0L, w.dropped.get())

            assertFalse(File(dir, "quat-20261017-09.csv").exists(), "closed hour left uncompressed")
            assertEquals(Sample.HEADER + csv(distinct(wall = nine)) + csv(distinct(wall = nine + 50)),
                         gunzip(File(dir, "quat-20261017-09.csv.gz")))
            // The open hour is flushed and closed on stop, but stays plain.
            assertEquals(Sample.HEADER + csv(distinct(wall = ten)),
                         File(dir, "quat-20261017-10.csv").readText())
            assertEquals("quat-20261017-10.csv", w.currentFile)
        } finally { dir.deleteRecursively() }
    }

    test("a restart in the same hour appends without a second header") {
        val dir = tempDir()
        try {
            val nine = 1_792_227_600_000L
            File(dir, "quat-20261017-09.csv").writeText(Sample.HEADER + csv(distinct(wall = nine)))
            val w = LogWriter(dir)
            w.start(); w.offer(distinct(wall = nine + 50)); w.stop()
            assertEquals(Sample.HEADER + csv(distinct(wall = nine)) + csv(distinct(wall = nine + 50)),
                         File(dir, "quat-20261017-09.csv").readText())
        } finally { dir.deleteRecursively() }
    }

    test("what LogWriter writes, History reads back") {
        val dir = tempDir()
        try {
            val nine = 1_792_227_600_000L
            val w = LogWriter(dir)
            w.start()
            for (i in 0 until 4) w.offer(distinct(wall = nine + 3_599_900L + 50L * i))
            w.stop()
            // Two in the 09 hour (now gzipped) and two in the 10 hour.
            assertTrue(File(dir, "quat-20261017-09.csv.gz").exists())
            val r = Ring(10)
            assertEquals(Pair(4, 2), History.load(dir, r, ::noErrors))
            for (i in 0 until 4) {
                assertEquals(nine + 3_599_900L + 50L * i, r.wallMs[r.idx(i)])
                assertEquals(21.75f, r.angHwSw[r.idx(i)])
                assertEquals(0.88f, r.swW[r.idx(i)])
            }
        } finally { dir.deleteRecursively() }
    }

    test("opening an hour prunes gzipped hours past RETAIN_DAYS and nothing else") {
        val dir = tempDir()
        try {
            val day = 86_400_000L
            val now = System.currentTimeMillis()
            fun aged(name: String, days: Long) = File(dir, name).apply {
                writeText("x"); setLastModified(now - days * day)
            }
            val old = aged("quat-20260901-00.csv.gz", LogWriter.RETAIN_DAYS + 1)
            val recent = aged("quat-20261010-00.csv.gz", LogWriter.RETAIN_DAYS - 1)
            val events = aged("events.csv", LogWriter.RETAIN_DAYS + 1)
            val oldPlain = aged("quat-20260901-01.csv", LogWriter.RETAIN_DAYS + 1)

            val w = LogWriter(dir)
            w.start(); w.offer(distinct(wall = now)); w.stop()
            assertFalse(old.exists(), "expired hour kept")
            assertTrue(recent.exists(), "hour inside retention pruned")
            assertTrue(events.exists(), "anomaly log pruned")
            // A plain hour left by a mid-hour stop is swept into a .gz that
            // keeps its age, so it expires with everything else.
            assertFalse(oldPlain.exists(), "expired plain hour kept")
            assertFalse(File(dir, "quat-20260901-01.csv.gz").exists(), "expired plain hour kept as .gz")
        } finally { dir.deleteRecursively() }
    }

    test("a later start compresses the hour a mid-hour stop left plain") {
        val dir = tempDir()
        try {
            val nine = 1_792_227_600_000L
            val ten = 1_792_231_200_000L
            val w1 = LogWriter(dir)
            w1.start(); w1.offer(distinct(wall = nine)); w1.stop()
            assertTrue(File(dir, "quat-20261017-09.csv").exists())

            val w2 = LogWriter(dir)
            w2.start(); w2.offer(distinct(wall = ten)); w2.stop()
            assertFalse(File(dir, "quat-20261017-09.csv").exists(), "stopped hour left plain")
            assertEquals(Sample.HEADER + csv(distinct(wall = nine)),
                         gunzip(File(dir, "quat-20261017-09.csv.gz")))
            // The hour being written is not swept out from under the writer.
            assertEquals(Sample.HEADER + csv(distinct(wall = ten)),
                         File(dir, "quat-20261017-10.csv").readText())
            assertFalse(File(dir, "quat-20261017-10.csv.gz").exists())
        } finally { dir.deleteRecursively() }
    }

    test("only quat-<yyyyMMdd-HH>.csv counts as a stray hour") {
        assertEquals("20261017-09", LogWriter.strayHour("quat-20261017-09.csv"))
        for (other in listOf("quat-20261017-09.csv.gz", "events.csv", "meta.txt",
                             "capture-9.txt", "quat-2026101-09.csv", "xquat-20261017-09.csv"))
            assertNull(LogWriter.strayHour(other), other)
    }

    test("offer drops and counts rather than blocking when the queue is full") {
        // Not started, so nothing drains the queue.
        val w = LogWriter(tempDir())
        repeat(LogWriter.QUEUE_CAP) { assertTrue(w.offer(distinct())) }
        assertFalse(w.offer(distinct()))
        assertEquals(1L, w.dropped.get())
    }

    // ---- Anomaly -------------------------------------------------------------

    test("a mark stamps the moment and leaves description and capture empty") {
        val dir = tempDir()
        try {
            val t = 1_792_227_600_123L
            assertEquals(t, Anomaly.mark(dir, t))
            assertEquals(
                "id,wall_ms,iso,description,capture\n" +
                "$t,$t,2026-10-17 09:00:00.123,,\n",
                Anomaly.eventsFile(dir).readText())
        } finally { dir.deleteRecursively() }
    }

    test("describe and capture each fill their own column, in either order") {
        val dir = tempDir()
        try {
            val a = Anomaly.mark(dir, 1_792_227_600_000L)
            val b = Anomaly.mark(dir, 1_792_227_601_000L)
            Anomaly.setCapture(dir, a, "capture-$a.txt")
            Anomaly.describe(dir, a, "screen flipped")
            Anomaly.describe(dir, b, "nothing")
            val rows = Anomaly.eventsFile(dir).readLines()
            assertEquals(3, rows.size)
            assertEquals("$a,$a,2026-10-17 09:00:00.000,screen flipped,capture-$a.txt", rows[1])
            assertEquals("$b,$b,2026-10-17 09:00:01.000,nothing,", rows[2])
        } finally { dir.deleteRecursively() }
    }

    test("a description cannot break the CSV with commas or newlines") {
        val dir = tempDir()
        try {
            val a = Anomaly.mark(dir, 1_000L)
            Anomaly.describe(dir, a, "  rotated, then\r\nrotated back \n")
            val cols = Anomaly.eventsFile(dir).readLines()[1].split(',')
            assertEquals(5, cols.size)
            assertEquals("rotated  then  rotated back", cols[3])
        } finally { dir.deleteRecursively() }
    }

    test("describing with no events file creates nothing") {
        val dir = tempDir()
        try {
            Anomaly.describe(dir, 1L, "x")
            Anomaly.setCapture(dir, 1L, "x")
            assertFalse(Anomaly.eventsFile(dir).exists())
        } finally { dir.deleteRecursively() }
    }
}
