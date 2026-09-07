package lan.syshlt.quatmon

import kotlin.math.abs
import kotlin.math.acos
import kotlin.math.min
import kotlin.math.sqrt

/*
 * One paired sample.
 *
 * WHAT IS RECORDED, AND WHY EACH PIECE EARNS ITS PLACE
 *
 * The point of this log is to decide whether the ITE8350's firmware fusion is
 * meaningfully steadier than Android's software fusion, and if not, to give a
 * better software fusion something to be developed against. That decides the
 * columns:
 *
 *   THREE quaternions, not two.
 *     hw    ITE8350 firmware fusion, 9-axis, via waydroid-sensord
 *     sw    AOSP TYPE_ROTATION_VECTOR, 9-axis in software
 *     gm    AOSP TYPE_GAME_ROTATION_VECTOR, 6-axis -- accel + gyro, NO magnetometer
 *   The third is what makes the log diagnostic rather than merely descriptive.
 *   bigtab01's magnetometer is badly hard-iron contaminated by the keyboard's
 *   attachment magnets: docs/14 measured |B| ranging 52-134 uT against a true
 *   field near 54. If hw and sw diverge while hw and gm agree, the divergence
 *   is the magnetometer poisoning the 9-axis fusion, not the algorithm being
 *   worse. Without gm those two explanations are indistinguishable.
 *
 *   THE RAW INPUTS: accel, gyro, magn.
 *   A log of outputs alone can show that two fusions disagree but can never
 *   test a third. Recording the inputs makes the data replayable, so a
 *   candidate fusion can be developed and scored offline against exactly the
 *   samples that produced a real anomaly -- no device round-trip per attempt.
 *
 *   |B|, precomputed.
 *   Scale-invariant contamination detector, and the fastest way to see at a
 *   glance whether the magnetometer was trustworthy at a given moment.
 *
 *   THE AGE OF EACH READING.
 *   A sensor that has stopped publishing still answers reads with its last
 *   value. That is exactly how the hub failed after a bad resume (docs/19),
 *   and from Android's side it is indistinguishable from a motionless machine.
 *   Recording age turns a stall into an obvious rising ramp instead of a
 *   plausible flat line.
 */
object Q {
    /* Rotation-vector sensors report (x, y, z) and, since API 18, w. Some
     * report only three, with w implied by the unit-length constraint. */
    fun w(v: FloatArray): Float {
        if (v.size >= 4) return v[3]
        val s = 1f - v[0] * v[0] - v[1] * v[1] - v[2] * v[2]
        return if (s > 0f) sqrt(s) else 0f
    }

    /*
     * Angle between two orientations, in degrees.
     *
     * abs() on the dot product is load-bearing: q and -q are the same
     * rotation, and independent fusions have no reason to agree on the sign.
     * Without it a perfect match intermittently reads as 360 degrees apart.
     */
    fun angleDeg(ax: Float, ay: Float, az: Float, aw: Float,
                 bx: Float, by: Float, bz: Float, bw: Float): Float {
        val na = sqrt(ax * ax + ay * ay + az * az + aw * aw)
        val nb = sqrt(bx * bx + by * by + bz * bz + bw * bw)
        if (na < 1e-6f || nb < 1e-6f) return Float.NaN
        val dot = (ax * bx + ay * by + az * bz + aw * bw) / (na * nb)
        return (2.0 * acos(min(1.0, abs(dot).toDouble())) * 180.0 / Math.PI).toFloat()
    }
}

/*
 * Fixed-capacity ring of recent samples, held as parallel arrays so sampling
 * allocates nothing and the graph can walk one component without touching the
 * others. Only the graphed fields live here; the raw inputs go straight to
 * disk, since replay analysis happens off the device.
 *
 * Concurrency: exactly one writer (the sampler thread), any number of readers
 * (the UI). `total` is written last and is volatile, so a reader that has seen
 * index i is guaranteed to see the values stored before it. Nothing on the
 * sampling path takes a lock. A reader can in principle be lapped and read a
 * torn sample, but at 20 Hz that needs an hour to elapse inside one frame.
 */
class Ring(val cap: Int) {
    val wallMs = LongArray(cap)
    val hwX = FloatArray(cap); val hwY = FloatArray(cap)
    val hwZ = FloatArray(cap); val hwW = FloatArray(cap)
    val swX = FloatArray(cap); val swY = FloatArray(cap)
    val swZ = FloatArray(cap); val swW = FloatArray(cap)
    val gmX = FloatArray(cap); val gmY = FloatArray(cap)
    val gmZ = FloatArray(cap); val gmW = FloatArray(cap)
    val angHwSw = FloatArray(cap)
    val angHwGm = FloatArray(cap)
    val bUt = FloatArray(cap)
    val hwAgeMs = FloatArray(cap); val swAgeMs = FloatArray(cap)
    val gmAgeMs = FloatArray(cap)

    @Volatile var total: Long = 0L
        private set

    fun add(s: Sample) {
        val i = ((total % cap).toInt() + cap) % cap
        wallMs[i] = s.wallMs
        hwX[i] = s.hwX; hwY[i] = s.hwY; hwZ[i] = s.hwZ; hwW[i] = s.hwW
        swX[i] = s.swX; swY[i] = s.swY; swZ[i] = s.swZ; swW[i] = s.swW
        gmX[i] = s.gmX; gmY[i] = s.gmY; gmZ[i] = s.gmZ; gmW[i] = s.gmW
        angHwSw[i] = s.angHwSw; angHwGm[i] = s.angHwGm
        bUt[i] = s.bUt
        hwAgeMs[i] = s.hwAgeMs; swAgeMs[i] = s.swAgeMs; gmAgeMs[i] = s.gmAgeMs
        total = total + 1              // volatile write publishes the slot
    }

    fun size(): Int = min(total, cap.toLong()).toInt()

    /** Ring index of the n-th oldest retained sample. */
    fun idx(n: Int): Int {
        val t = total
        val first = if (t > cap) t - cap else 0L
        return (((first + n) % cap).toInt() + cap) % cap
    }
}

class Sample(
    @JvmField val wallMs: Long,
    @JvmField val elapsedMs: Long,
    @JvmField val hwX: Float, @JvmField val hwY: Float,
    @JvmField val hwZ: Float, @JvmField val hwW: Float, @JvmField val hwAgeMs: Float,
    @JvmField val swX: Float, @JvmField val swY: Float,
    @JvmField val swZ: Float, @JvmField val swW: Float, @JvmField val swAgeMs: Float,
    @JvmField val gmX: Float, @JvmField val gmY: Float,
    @JvmField val gmZ: Float, @JvmField val gmW: Float, @JvmField val gmAgeMs: Float,
    @JvmField val ax: Float, @JvmField val ay: Float, @JvmField val az: Float,
    @JvmField val gx: Float, @JvmField val gy: Float, @JvmField val gz: Float,
    @JvmField val mx: Float, @JvmField val my: Float, @JvmField val mz: Float,
    @JvmField val mAcc: Int, @JvmField val bUt: Float,
    @JvmField val angHwSw: Float, @JvmField val angHwGm: Float
) {
    /* Formatted on the writer thread, never on the sampler thread. */
    fun toCsv(sb: StringBuilder) {
        sb.setLength(0)
        sb.append(wallMs).append(',').append(elapsedMs).append(',')
        f6(sb, hwX); f6(sb, hwY); f6(sb, hwZ); f6(sb, hwW); f1(sb, hwAgeMs)
        f6(sb, swX); f6(sb, swY); f6(sb, swZ); f6(sb, swW); f1(sb, swAgeMs)
        f6(sb, gmX); f6(sb, gmY); f6(sb, gmZ); f6(sb, gmW); f1(sb, gmAgeMs)
        f4(sb, ax); f4(sb, ay); f4(sb, az)
        f6(sb, gx); f6(sb, gy); f6(sb, gz)
        f3(sb, mx); f3(sb, my); f3(sb, mz)
        sb.append(mAcc).append(',')
        f3(sb, bUt)
        f4(sb, angHwSw)
        sb.append(fmt(angHwGm, 1e4f)).append('\n')
    }

    private fun f6(sb: StringBuilder, v: Float) { sb.append(fmt(v, 1e6f)).append(',') }
    private fun f4(sb: StringBuilder, v: Float) { sb.append(fmt(v, 1e4f)).append(',') }
    private fun f3(sb: StringBuilder, v: Float) { sb.append(fmt(v, 1e3f)).append(',') }
    private fun f1(sb: StringBuilder, v: Float) { sb.append(fmt(v, 10f)).append(',') }

    companion object {
        const val HEADER =
            "wall_ms,elapsed_ms," +
            "hw_x,hw_y,hw_z,hw_w,hw_age_ms," +
            "sw_x,sw_y,sw_z,sw_w,sw_age_ms," +
            "gm_x,gm_y,gm_z,gm_w,gm_age_ms," +
            "ax,ay,az,gx,gy,gz,mx,my,mz,m_acc,b_ut," +
            "ang_hw_sw,ang_hw_gm\n"

        /* String.format allocates a Formatter per call and is clearly visible
         * in a 20 Hz loop with 30 columns; this does the same job by rounding
         * through an int. Empty for NaN so a missing sensor stays distinct
         * from a genuine zero. */
        fun fmt(v: Float, scale: Float): String =
            if (v.isNaN()) "" else (Math.round(v * scale) / scale).toString()
    }
}
