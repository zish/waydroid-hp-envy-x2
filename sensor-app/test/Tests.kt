/*
 * Unit tests for sensor-app: the arithmetic between a rotation matrix and what
 * the panel claims -- the heading, which way the slab faces, which faces are
 * culled -- and the text each sensor card shows. Run by tests/run.sh; see
 * tests/kotlin/Harness.kt for how and with what limits.
 *
 * Nothing here calls SensorManager: its statics are android.jar stubs that
 * throw off-device. Where a test needs the matrix SensorManager would build
 * from a quaternion, rotationMatrixFromQuaternion() below writes out AOSP's
 * getRotationMatrixFromVector() formula by hand, and the docs/14 golden is what
 * checks that transcription: fed the hub's recorded quaternion, it has to give
 * back the azimuth, pitch and roll the doc recorded from Android itself.
 *
 * Every other expected value is hand-derived from the frame definitions in
 * docs/18 (+X right, +Y toward the top of the screen, +Z out of the screen;
 * world East, North, Up), and the derivation is written next to it.
 */
package com.systemhalted.sensorinfo

import android.hardware.Sensor
import testharness.suite
import java.util.Locale
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.asin
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/*
 * AOSP SensorManager.getRotationMatrixFromVector(), 3x3 case, written out from
 * its source: no normalisation, w taken as given. Row-major, device -> world.
 */
private fun rotationMatrixFromQuaternion(x: Double, y: Double, z: Double, w: Double): FloatArray {
    val sqQ1 = 2 * x * x; val sqQ2 = 2 * y * y; val sqQ3 = 2 * z * z
    val q1q2 = 2 * x * y; val q3q0 = 2 * z * w
    val q1q3 = 2 * x * z; val q2q0 = 2 * y * w
    val q2q3 = 2 * y * z; val q1q0 = 2 * x * w
    return floatArrayOf(
        (1 - sqQ2 - sqQ3).toFloat(), (q1q2 - q3q0).toFloat(), (q1q3 + q2q0).toFloat(),
        (q1q2 + q3q0).toFloat(), (1 - sqQ1 - sqQ3).toFloat(), (q2q3 - q1q0).toFloat(),
        (q1q3 - q2q0).toFloat(), (q2q3 + q1q0).toFloat(), (1 - sqQ1 - sqQ2).toFloat()
    )
}

/*
 * A laptop whose top edge, while flat, points at compass bearing yaw, then
 * tilted back about its own X axis by tilt degrees (0 = flat on its back,
 * 90 = standing upright, screen toward the user). Built from its columns:
 *
 *   X = (cos yaw, -sin yaw, 0)                -- right edge, horizontal
 *   F = (sin yaw,  cos yaw, 0)                -- the flat top-edge bearing
 *   Y = cos(tilt) F + sin(tilt) Up
 *   Z = cos(tilt) Up - sin(tilt) F            -- X x Y, so right-handed
 *
 * The back of the screen, -Z, therefore always has horizontal part
 * sin(tilt) F: its bearing is yaw for every tilt > 0, exactly as the top
 * edge's is for every tilt < 90. That is the identity the heading's
 * continuity claim rests on, derived here rather than read off the code.
 */
private fun laptop(yawDeg: Double, tiltDeg: Double): FloatArray {
    val a = yawDeg * PI / 180.0
    val t = tiltDeg * PI / 180.0
    val x = doubleArrayOf(cos(a), -sin(a), 0.0)
    val f = doubleArrayOf(sin(a), cos(a), 0.0)
    val up = doubleArrayOf(0.0, 0.0, 1.0)
    val y = DoubleArray(3) { cos(t) * f[it] + sin(t) * up[it] }
    val z = DoubleArray(3) { cos(t) * up[it] - sin(t) * f[it] }
    return FloatArray(9) { i ->
        val row = i / 3
        when (i % 3) { 0 -> x[row]; 1 -> y[row]; else -> z[row] }.toFloat()
    }
}

/** Smallest absolute difference between two bearings, in degrees. */
private fun bearingDiff(a: Double, b: Double): Double {
    val d = abs(((a - b) % 360.0 + 360.0) % 360.0)
    return if (d > 180.0) 360.0 - d else d
}

private fun assertNear(expected: Double, actual: Double, tol: Double, what: String) =
    assertTrue(abs(expected - actual) <= tol, "$what: expected $expected ± $tol, got $actual")

private fun det3(m: FloatArray): Double =
    m[0].toDouble() * (m[4] * m[8] - m[5] * m[7]) -
    m[1].toDouble() * (m[3] * m[8] - m[5] * m[6]) +
    m[2].toDouble() * (m[3] * m[7] - m[4] * m[6])

/*
 * Project one face of the slab exactly as AttitudeView.drawSlab() does and
 * return its doubled signed screen area. focal and the screen centre are
 * arbitrary: a positive focal and a translation cannot change the sign.
 */
private fun faceArea(m: FloatArray, f: Int): Double {
    val sinEl = sin(CAM_EL * PI / 180.0)
    val cosEl = cos(CAM_EL * PI / 180.0)
    val vx = FloatArray(4)
    val vy = FloatArray(4)
    val wp = DoubleArray(3)
    val sp = DoubleArray(3)
    val g = FACE_XYZ[f]
    for (i in 0 until 4) {
        deviceToWorld(m, g[i * 3], g[i * 3 + 1], g[i * 3 + 2], wp)
        projectPoint(wp[0], wp[1], wp[2], sinEl, cosEl, 300f, 200f, 500.0, sp)
        vx[i] = sp[0].toFloat()
        vy[i] = sp[1].toFloat()
    }
    return signedArea2(vx, vy)
}

/*
 * The independent oracle for culling: a face of a convex solid is visible
 * exactly when its outward normal points toward the eye. The camera position
 * follows from projectPoint()'s own frame -- depth zc = n cos(el) - u sin(el)
 * is measured along (0, cos el, -sin el) and the eye sits at zc = -CAM_D --
 * so the eye is at (0, -CAM_D cos el, +CAM_D sin el): south of and above the
 * origin, as AttitudeView's header says. Returns n . (eye - face centre).
 */
private fun faceTowardEye(m: FloatArray, f: Int): Double {
    val el = CAM_EL * PI / 180.0
    val eye = doubleArrayOf(0.0, -CAM_D * cos(el), CAM_D * sin(el))
    val g = FACE_XYZ[f]
    val c = DoubleArray(3) { k -> (g[k] + g[3 + k] + g[6 + k] + g[9 + k]) / 4.0 }
    val cw = DoubleArray(3)
    val nw = DoubleArray(3)
    deviceToWorld(m, c[0], c[1], c[2], cw)
    deviceToWorld(m, FACE_N[f][0], FACE_N[f][1], FACE_N[f][2], nw)
    return (0 until 3).sumOf { nw[it] * (eye[it] - cw[it]) }
}

private const val FRONT = 0   // FACE_XYZ / FACE_N index of the +Z face
private const val BACK = 1    // and of the -Z face

fun main() = suite("sensor-app") {
    // String.format follows the default locale, so a comma-decimal JVM would
    // print "9,8100" and fail for a reason that is not the code's. Pin it.
    Locale.setDefault(Locale.US)

    // ---- the docs/14 golden ----------------------------------------------

    test("the hand-written AOSP matrix reproduces docs/14's azimuth, pitch and roll") {
        // docs/14: in_rot_quaternion_raw x 1e-7 = (0.3164, -0.4102, -0.6719,
        // 0.5273) in x, y, z, w order, and getOrientation() on it gave
        // azimuth 102.93, pitch -62.24, roll -0.92. getOrientation is
        // azimuth = atan2(R1, R4), pitch = asin(-R7), roll = atan2(-R6, R8).
        val r = rotationMatrixFromQuaternion(0.3164, -0.4102, -0.6719, 0.5273)
        val az = Math.toDegrees(atan2(r[1].toDouble(), r[4].toDouble()))
        val pitch = Math.toDegrees(asin(-r[7].toDouble()))
        val roll = Math.toDegrees(atan2(-r[6].toDouble(), r[8].toDouble()))
        assertNear(102.93, az, 0.01, "azimuth")
        assertNear(-62.24, pitch, 0.01, "pitch")
        assertNear(-0.92, roll, 0.01, "roll")
    }

    test("the hub's recorded pose is steep enough to take the heading from the screen back") {
        // Pitched 62 degrees, the top edge keeps cos(62) = 0.47 of its length
        // in the horizontal plane and the screen normal sin(62) = 0.88, so the
        // screen back is the longer projection.
        val r = rotationMatrixFromQuaternion(0.3164, -0.4102, -0.6719, 0.5273)
        assertEquals(false, useTopEdge(r))
        assertEquals("screen back", headingRefOf(r))
        // At zero roll the two references agree exactly (see laptop()); the
        // recorded roll is -0.92 degrees, which on a machine pitched 62 degrees
        // swings the two bearings apart by a degree or two. A reversed
        // reference (+Z) would land near 284, a w-first component order
        // nowhere near either.
        val h = headingOf(r)
        assertTrue(bearingDiff(102.93, h) < 2.0, "heading $h vs docs/14 azimuth 102.93")
    }

    // ---- headingOf -------------------------------------------------------

    test("a flat machine's heading is the bearing of its top edge") {
        for (yaw in listOf(0.0, 45.0, 90.0, 102.93, 180.0, 270.0, 359.0)) {
            val r = laptop(yaw, 0.0)
            assertEquals("top edge", headingRefOf(r))
            assertTrue(bearingDiff(yaw, headingOf(r)) < 1e-4, "yaw $yaw read ${headingOf(r)}")
        }
    }

    test("tilting a laptop back from flat to upright never moves its heading") {
        // docs/14's reported fault: standing the machine up froze the heading
        // and made it follow left/right tilt. laptop() proves the true bearing
        // is yaw at every tilt; the crossover between references sits at 45.
        for (yaw in listOf(0.0, 30.0, 102.93, 200.0, 315.0)) {
            var tilt = 0.0
            while (tilt <= 90.0) {
                val h = headingOf(laptop(yaw, tilt))
                assertTrue(bearingDiff(yaw, h) < 1e-3, "yaw $yaw tilt $tilt read $h")
                tilt += 2.5
            }
        }
    }

    test("the reference switches from top edge to screen back past 45 degrees of tilt") {
        assertEquals("top edge", headingRefOf(laptop(70.0, 44.0)))
        assertEquals("screen back", headingRefOf(laptop(70.0, 46.0)))
        assertEquals("screen back", headingRefOf(laptop(70.0, 90.0)))
    }

    test("an upright machine's heading tracks yaw") {
        // The second half of the fault: upright, yawing changed nothing.
        for (yaw in listOf(0.0, 90.0, 180.0, 270.0)) {
            assertTrue(bearingDiff(yaw, headingOf(laptop(yaw, 90.0))) < 1e-4)
        }
    }

    test("headings are reported in [0, 360)") {
        for (yaw in listOf(-90.0, -0.5, 0.0, 179.9, 180.1, 359.9)) {
            for (tilt in listOf(0.0, 90.0)) {
                val h = headingOf(laptop(yaw, tilt))
                assertTrue(h >= 0.0 && h < 360.0, "yaw $yaw tilt $tilt gave $h")
            }
        }
        // West, worked by hand: top edge at world (-1, 0, 0) is atan2(-1, 0)
        // = -90, which must come back as 270.
        assertNear(270.0, headingOf(laptop(270.0, 0.0)), 1e-4, "west")
    }

    // ---- the demo poses --------------------------------------------------

    test("every demo pose is a proper rotation") {
        // A reflection here would render the slab inside out -- FRONT drawn
        // where BACK is -- which is the very fault the demo exists to expose.
        for ((i, m) in DEMO_R.withIndex()) {
            assertNear(1.0, det3(m), 1e-6, "det of pose $i")
            for (a in 0 until 3) for (b in 0 until 3) {
                val dot = (0 until 3).sumOf { m[it * 3 + a].toDouble() * m[it * 3 + b] }
                assertNear(if (a == b) 1.0 else 0.0, dot, 1e-6, "pose $i columns $a.$b")
            }
        }
        assertEquals(DEMO_R.size, DEMO_NAME.size)
    }

    test("demo poses read the headings their comments promise") {
        // 0: top edge north -> 0. 1: face down, top edge still north -> 0.
        // 2: upright, screen south, so the back faces north -> 0.
        // 4: upright, Z = West, so the back faces East -> 90; the source
        //    comment requires poses 2 and 4 to read 90 apart.
        assertNear(0.0, bearingDiff(0.0, headingOf(DEMO_R[0])), 1e-6, "pose 0")
        assertNear(0.0, bearingDiff(0.0, headingOf(DEMO_R[1])), 1e-6, "pose 1")
        assertNear(0.0, bearingDiff(0.0, headingOf(DEMO_R[2])), 1e-6, "pose 2")
        assertNear(90.0, headingOf(DEMO_R[4]), 1e-6, "pose 4")
        assertEquals("screen back", headingRefOf(DEMO_R[2]))
        assertEquals("screen back", headingRefOf(DEMO_R[4]))
    }

    // ---- projection and culling -----------------------------------------

    test("deviceToWorld sends device axes to the matrix's columns") {
        // Pose 4's comment: X = South, Y = Up, Z = West.
        val out = DoubleArray(3)
        deviceToWorld(DEMO_R[4], 1.0, 0.0, 0.0, out)
        assertEquals(listOf(0.0, -1.0, 0.0), out.toList())
        deviceToWorld(DEMO_R[4], 0.0, 1.0, 0.0, out)
        assertEquals(listOf(0.0, 0.0, 1.0), out.toList())
        deviceToWorld(DEMO_R[4], 0.0, 0.0, 1.0, out)
        assertEquals(listOf(-1.0, 0.0, 0.0), out.toList())
    }

    test("the camera looks north from the south: East is screen-right, Up is screen-up, North is far") {
        val sinEl = sin(CAM_EL * PI / 180.0)
        val cosEl = cos(CAM_EL * PI / 180.0)
        val o = DoubleArray(3)
        val p = DoubleArray(3)
        projectPoint(0.0, 0.0, 0.0, sinEl, cosEl, 100f, 100f, 400.0, o)
        assertEquals(listOf(100.0, 100.0, 0.0), o.toList())   // origin -> centre, depth 0
        projectPoint(1.0, 0.0, 0.0, sinEl, cosEl, 100f, 100f, 400.0, p)
        assertTrue(p[0] > o[0] && p[1] == o[1], "East should be straight right")
        projectPoint(0.0, 0.0, 1.0, sinEl, cosEl, 100f, 100f, 400.0, p)
        assertTrue(p[1] < o[1], "Up should be up the screen (smaller y)")
        // Depth of Up is -sin(26) (toward the eye), of North +cos(26) (away):
        // the split that puts the near half of the ring in front of the slab.
        assertNear(-sin(CAM_EL * PI / 180.0), p[2], 1e-12, "depth of Up")
        projectPoint(0.0, 1.0, 0.0, sinEl, cosEl, 100f, 100f, 400.0, p)
        assertNear(cos(CAM_EL * PI / 180.0), p[2], 1e-12, "depth of North")
        // The perspective divide: the same East offset at the far (north) side
        // spans fewer pixels than at the near (south) side.
        val far = DoubleArray(3); val near = DoubleArray(3)
        projectPoint(1.0, 1.0, 0.0, sinEl, cosEl, 100f, 100f, 400.0, far)
        projectPoint(1.0, -1.0, 0.0, sinEl, cosEl, 100f, 100f, 400.0, near)
        assertTrue(far[0] - 100.0 < near[0] - 100.0, "far side should be foreshortened")
    }

    test("the shoelace sign is positive for a quad clockwise on screen") {
        // Screen y points down, so TL, TR, BR, BL of an axis-aligned 2 x 1
        // rectangle is clockwise as seen; twice its area is 4.
        val vx = floatArrayOf(0f, 2f, 2f, 0f)
        val vy = floatArrayOf(0f, 0f, 1f, 1f)
        assertEquals(4.0, signedArea2(vx, vy))
        assertEquals(-4.0, signedArea2(vx.reversedArray(), vy.reversedArray()))
    }

    test("flat on its back the FRONT face shows; flat on its face the BACK does") {
        assertTrue(faceArea(DEMO_R[0], FRONT) > 0.0, "pose 0 FRONT")
        assertTrue(faceArea(DEMO_R[0], BACK) <= 0.0, "pose 0 BACK")
        assertTrue(faceArea(DEMO_R[1], BACK) > 0.0, "pose 1 BACK")
        assertTrue(faceArea(DEMO_R[1], FRONT) <= 0.0, "pose 1 FRONT")
        // Upright with the screen facing south, i.e. toward the camera.
        assertTrue(faceArea(DEMO_R[2], FRONT) > 0.0, "pose 2 FRONT")
        assertTrue(faceArea(DEMO_R[2], BACK) <= 0.0, "pose 2 BACK")
    }

    test("winding-order culling agrees with the outward normal for every face and attitude") {
        // The header's claim -- corners listed so that visible means positive
        // area, no normals needed -- checked against the geometric definition
        // of visibility over a sweep of attitudes. Faces within a hair of
        // edge-on are skipped: there either answer is correct.
        var checked = 0
        val poses = DEMO_R.toMutableList()
        for (yaw in 0 until 360 step 30) for (tilt in -90..180 step 15) poses += laptop(yaw.toDouble(), tilt.toDouble())
        // And the hub's own recorded attitude.
        poses += rotationMatrixFromQuaternion(0.3164, -0.4102, -0.6719, 0.5273)
        for (m in poses) for (f in 0 until 6) {
            val toward = faceTowardEye(m, f)
            if (abs(toward) < 1e-3) continue
            val area = faceArea(m, f)
            assertEquals(toward > 0.0, area > 0.0, "face $f: n.(eye-c) = $toward, area2 = $area")
            checked++
        }
        assertTrue(checked > 1000, "only $checked face checks ran")
    }

    test("the face tables agree: each listed normal is outward and perpendicular to its face") {
        for (f in 0 until 6) {
            val g = FACE_XYZ[f]
            val n = FACE_N[f]
            // Every corner of an axis-aligned face sits at the same extent
            // along its normal, and that extent is the positive half-size.
            val half = listOf(HX, HY, HZ)[n.indexOfFirst { it != 0.0 }]
            for (i in 0 until 4) {
                val along = n[0] * g[i * 3] + n[1] * g[i * 3 + 1] + n[2] * g[i * 3 + 2]
                assertNear(half, along, 1e-12, "face $f corner $i")
            }
        }
    }

    test("the light direction is a unit vector from above, as its comment says") {
        assertNear(1.0, sqrt(LX * LX + LY * LY + LZ * LZ), 1e-3, "|L|")
        assertTrue(LZ > 0.0 && LY < 0.0 && LX > 0.0, "from above, south and east")
    }

    // ---- compassPoint ----------------------------------------------------

    test("compass points are centred on their bearings") {
        val names = listOf("N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                           "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW")
        for ((i, name) in names.withIndex()) assertEquals(name, compassPoint(i * 22.5))
    }

    test("compass point boundaries fall halfway between points, rounding up") {
        // Each point owns +-11.25 degrees; exactly on the boundary goes clockwise.
        assertEquals("N", compassPoint(11.24))
        assertEquals("NNE", compassPoint(11.25))
        assertEquals("NNW", compassPoint(348.74))
        assertEquals("N", compassPoint(348.75))
        assertEquals("N", compassPoint(359.99))
        // docs/14's azimuth: ESE is 101.25 to 123.75.
        assertEquals("ESE", compassPoint(102.93))
    }

    test("compass points wrap negative and multi-turn bearings") {
        assertEquals("W", compassPoint(-90.0))
        assertEquals("N", compassPoint(360.0))
        assertEquals("E", compassPoint(810.0))
        assertEquals("NNW", compassPoint(-22.5))
    }

    // ---- formatValues ----------------------------------------------------

    test("no reading yet says so") {
        assertEquals("waiting for data…", formatValues(Sensor.TYPE_ACCELEROMETER, null))
        assertEquals("waiting for data…", formatValues(Sensor.TYPE_ACCELEROMETER, FloatArray(0)))
    }

    test("an accelerometer at rest flat on the desk reads 1 g up +Z") {
        // docs/18: flat, screen up, Android needs (0, 0, +9.81).
        assertEquals(
            "x   +0.0000   y   +0.0000   z   +9.8100  m/s²\n|a| = 9.8100 m/s²",
            formatValues(Sensor.TYPE_ACCELEROMETER, floatArrayOf(0f, 0f, 9.81f)))
    }

    test("the magnitude line is the Euclidean norm of the first three values") {
        // 3-4-12 is a Pythagorean quadruple: norm 13 exactly. A fourth value
        // (uncalibrated sensors carry biases after the axes) must not count.
        val s = formatValues(Sensor.TYPE_MAGNETIC_FIELD_UNCALIBRATED,
            floatArrayOf(3f, -4f, 12f, 100f, 100f, 100f))
        assertTrue(s.endsWith("|B| = 13.0000 µT"), s)
    }

    test("gyroscope rate is shown in rad/s and in degrees per second") {
        // 1 rad/s about Z is 180/pi = 57.2958 deg/s.
        val s = formatValues(Sensor.TYPE_GYROSCOPE, floatArrayOf(0f, 0f, 1f))
        assertTrue(s.endsWith("|ω| = 1.000 rad/s = 57.30 °/s"), s)
    }

    test("a short reading falls back to the raw dump instead of crashing") {
        // The guard formatValues' comment describes: a HAL reporting fewer
        // values than its type implies.
        val raw = "+1.00000   -2.00000"
        val short = floatArrayOf(1f, -2f)
        assertEquals(raw, formatValues(Sensor.TYPE_ACCELEROMETER, short))
        assertEquals(raw, formatValues(Sensor.TYPE_GYROSCOPE, short))
        assertEquals(raw, formatValues(Sensor.TYPE_ORIENTATION, short))
        // The rotation-vector branch calls SensorManager, which would throw
        // "Stub!" here -- so reaching the dump proves the guard ran first.
        assertEquals(raw, formatValues(Sensor.TYPE_ROTATION_VECTOR, short))
    }

    test("orientation shows the docs/14 attitude and names its compass point") {
        assertEquals(
            "azimuth  102.93°   pitch  -62.24°   roll   -0.92°\nfacing ESE",
            formatValues(Sensor.TYPE_ORIENTATION, floatArrayOf(102.93f, -62.24f, -0.92f)))
    }

    test("scalar sensors carry their units") {
        assertEquals("250.0 lx", formatValues(Sensor.TYPE_LIGHT, floatArrayOf(250f)))
        assertEquals("1013.25 hPa", formatValues(Sensor.TYPE_PRESSURE, floatArrayOf(1013.25f)))
        assertEquals("45.0 %", formatValues(Sensor.TYPE_RELATIVE_HUMIDITY, floatArrayOf(45f)))
        assertEquals("1234 steps", formatValues(Sensor.TYPE_STEP_COUNTER, floatArrayOf(1234f)))
    }

    test("an unknown sensor type gets every value, signed") {
        assertEquals("+0.50000   -0.25000   +0.00000",
            formatValues(65536, floatArrayOf(0.5f, -0.25f, 0f)))
    }
}
