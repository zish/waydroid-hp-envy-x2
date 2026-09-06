/*
 * Sensor Info -- a minimal live sensor viewer, written for bigtab01 to check
 * the waydroid-sensord IIO daemon from the Android side.
 *
 * It subscribes to *every* sensor SensorManager reports, which is the point:
 * Android only streams a sensor while something is listening, so before this
 * app existed the magnetometer was registered but never actually exercised
 * through the HIDL pipe. See docs/14-sensors.md.
 *
 * No AndroidX, no Compose, no Gradle -- the entire UI is built in code so the
 * build is aapt2 + kotlinc + d8 + apksigner. See build.sh.
 */
package lan.syshlt.sensorinfo

import android.app.Activity
import android.content.Context
import android.graphics.Typeface
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.TypedValue
import android.view.View
import android.view.ViewGroup
import android.widget.CheckBox
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import kotlin.math.sqrt

class MainActivity : Activity(), SensorEventListener {

    /** One rendered sensor: its live-value line and its accuracy/rate line. */
    private class Row(
        val card: LinearLayout,
        val values: TextView,
        val status: TextView,
        val isSoftware: Boolean
    ) {
        // setText() invalidates and re-lays-out, which is the expensive part.
        // Remember what is on screen so an unchanged line costs nothing.
        var shownValues: String = ""
        var shownStatus: String = ""
    }

    private lateinit var sensorManager: SensorManager
    private val rows = LinkedHashMap<Sensor, Row>()

    private val latest = HashMap<Sensor, FloatArray>()
    private val accuracy = HashMap<Sensor, Int>()
    private val eventCount = HashMap<Sensor, Long>()
    private val lastCount = HashMap<Sensor, Long>()
    private val rateHz = HashMap<Sensor, Double>()
    private var lastRateSample = 0L

    private val ui = Handler(Looper.getMainLooper())
    private lateinit var header: TextView
    private lateinit var hideSoftware: CheckBox

    private var dp = 1f

    // ---------------------------------------------------------------- lifecycle

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        dp = resources.displayMetrics.density
        sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad(12), pad(12), pad(12), pad(12))
        }

        header = TextView(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            typeface = Typeface.MONOSPACE
            setPadding(0, 0, 0, pad(8))
        }
        root.addView(header)

        hideSoftware = CheckBox(this).apply {
            text = "Hide sensors synthesised in software"
            setOnCheckedChangeListener { _, _ -> applyFilter() }
        }
        root.addView(hideSoftware)

        val list = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }

        // Hardware sensors first, then the software-fused ones, each group
        // ordered by sensor type so the numbering matches `dumpsys sensorservice`.
        val all = sensorManager.getSensorList(Sensor.TYPE_ALL)
            .sortedWith(compareBy({ isSoftware(it) }, { it.type }, { it.name }))

        for (sensor in all) list.addView(buildCard(sensor))

        root.addView(list)
        setContentView(ScrollView(this).apply { addView(root) })

        updateHeader()
        applyFilter()
    }

    override fun onResume() {
        super.onResume()
        // Subscribe to everything. SENSOR_DELAY_GAME is 20 ms requested; the
        // HAL advertises minDelay = 50 ms, so we get ~20 Hz and that is fine.
        for (sensor in rows.keys) {
            sensorManager.registerListener(this, sensor, SensorManager.SENSOR_DELAY_GAME)
        }
        lastRateSample = SystemClock.elapsedRealtime()
        ui.postDelayed(refresh, REFRESH_MS)
    }

    override fun onPause() {
        super.onPause()
        sensorManager.unregisterListener(this)
        ui.removeCallbacks(refresh)
    }

    // ------------------------------------------------------------- sensor input

    override fun onSensorChanged(event: SensorEvent) {
        // Copy: the framework reuses the event's array.
        latest[event.sensor] = event.values.copyOf()
        eventCount[event.sensor] = (eventCount[event.sensor] ?: 0L) + 1L
    }

    override fun onAccuracyChanged(sensor: Sensor, acc: Int) {
        accuracy[sensor] = acc
    }

    /**
     * Redraw on a timer rather than per event. With ~13 sensors at 20 Hz,
     * updating a TextView inside onSensorChanged would spend the whole frame
     * budget on layout.
     */
    private val refresh = object : Runnable {
        override fun run() {
            val now = SystemClock.elapsedRealtime()
            val elapsed = (now - lastRateSample) / 1000.0
            if (elapsed >= 1.0) {
                for (sensor in rows.keys) {
                    val total = eventCount[sensor] ?: 0L
                    val prev = lastCount[sensor] ?: 0L
                    rateHz[sensor] = (total - prev) / elapsed
                    lastCount[sensor] = total
                }
                lastRateSample = now
                updateHeader()
            }
            for ((sensor, row) in rows) {
                // Hidden cards cost nothing to skip, and an unchanged string
                // must not be re-set: on this hardware a full pass over ~40
                // TextViews costs enough that a 100 ms timer starved the main
                // looper and the app received barely 1 event/s while
                // SensorService was delivering 20.
                if (row.card.visibility != View.VISIBLE) continue

                val v = formatValues(sensor, latest[sensor])
                if (v != row.shownValues) {
                    row.values.text = v
                    row.shownValues = v
                }
                val st = statusLine(sensor)
                if (st != row.shownStatus) {
                    row.status.text = st
                    row.shownStatus = st
                }
            }
            ui.postDelayed(this, REFRESH_MS)
        }
    }

    // -------------------------------------------------------------------- views

    private fun pad(v: Int) = (v * dp).toInt()

    private fun buildCard(sensor: Sensor): View {
        val software = isSoftware(sensor)

        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad(10), pad(8), pad(10), pad(8))
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply { bottomMargin = pad(8) }
            setBackgroundColor(if (software) SOFTWARE_BG else HARDWARE_BG)
        }

        val title = TextView(this).apply {
            text = sensor.name
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            setTypeface(null, Typeface.BOLD)
        }

        val subtitle = TextView(this).apply {
            text = buildString {
                append(typeName(sensor))
                append("  ·  ")
                append(sensor.vendor)
                if (software) append("  ·  software")
            }
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            alpha = 0.7f
        }

        val values = TextView(this).apply {
            typeface = Typeface.MONOSPACE
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setPadding(0, pad(6), 0, pad(2))
        }

        val status = TextView(this).apply {
            typeface = Typeface.MONOSPACE
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 10f)
            alpha = 0.7f
        }

        val meta = TextView(this).apply {
            text = metaLine(sensor)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 10f)
            alpha = 0.55f
        }

        card.addView(title)
        card.addView(subtitle)
        card.addView(values)
        card.addView(status)
        card.addView(meta)

        rows[sensor] = Row(card, values, status, software)
        return card
    }

    private fun applyFilter() {
        val hide = hideSoftware.isChecked
        for (row in rows.values) {
            row.card.visibility = if (hide && row.isSoftware) View.GONE else View.VISIBLE
        }
    }

    private fun updateHeader() {
        val hw = rows.count { !it.value.isSoftware }
        val sw = rows.size - hw
        val total = rateHz.values.sum()
        header.text = buildString {
            append("${Build.MANUFACTURER} ${Build.MODEL}  ·  Android ${Build.VERSION.RELEASE}")
            append(" (API ${Build.VERSION.SDK_INT})\n")
            append("$hw hardware sensor(s), $sw synthesised in software")
            append("  ·  ${"%.0f".format(total)} events/s received")
        }
    }

    // ------------------------------------------------------------- formatting

    /**
     * Android reports a fused sensor's vendor as "AOSP" and gives it a
     * synthetic handle; the ones our HAL actually provides carry the HAL's own
     * vendor string. That is the only distinction exposed to an app.
     */
    private fun isSoftware(sensor: Sensor) = sensor.vendor.equals("AOSP", ignoreCase = true)

    private fun metaLine(sensor: Sensor): String {
        val minDelay = if (sensor.minDelay > 0) {
            "max %.0f Hz".format(1_000_000.0 / sensor.minDelay)
        } else {
            "on-change"
        }
        return "range %.4g   resolution %.6g   %s   power %.1f mA   v%d"
            .format(sensor.maximumRange, sensor.resolution, minDelay,
                    sensor.power, sensor.version)
    }

    private fun statusLine(sensor: Sensor): String {
        val acc = when (accuracy[sensor]) {
            SensorManager.SENSOR_STATUS_ACCURACY_HIGH -> "high"
            SensorManager.SENSOR_STATUS_ACCURACY_MEDIUM -> "medium"
            SensorManager.SENSOR_STATUS_ACCURACY_LOW -> "low"
            SensorManager.SENSOR_STATUS_UNRELIABLE -> "unreliable"
            SensorManager.SENSOR_STATUS_NO_CONTACT -> "no contact"
            else -> "-"
        }
        val n = eventCount[sensor] ?: 0L
        return "accuracy %s   %.1f Hz   %d events".format(acc, rateHz[sensor] ?: 0.0, n)
    }

    private fun formatValues(sensor: Sensor, v: FloatArray?): String {
        if (v == null || v.isEmpty()) return "waiting for data…"

        // Sensor types below assume three axes or a quaternion. A HAL that
        // reports fewer values than its type implies would otherwise crash us,
        // so fall through to the generic dump instead of trusting the type.
        val axes = v.size
        fun xyz(unit: String, magLabel: String): String {
            if (axes < 3) return v.joinToString("   ") { "%+.5f".format(it) }
            val mag = sqrt(v.take(3).fold(0.0) { acc, f -> acc + f.toDouble() * f })
            return "x %+9.4f   y %+9.4f   z %+9.4f  %s\n%s = %.4f %s"
                .format(v[0], v[1], v[2], unit, magLabel, mag, unit)
        }

        return when (sensor.type) {
            Sensor.TYPE_ACCELEROMETER,
            Sensor.TYPE_ACCELEROMETER_UNCALIBRATED,
            Sensor.TYPE_GRAVITY,
            Sensor.TYPE_LINEAR_ACCELERATION ->
                xyz("m/s²", "|a|")

            Sensor.TYPE_MAGNETIC_FIELD,
            Sensor.TYPE_MAGNETIC_FIELD_UNCALIBRATED ->
                xyz("µT", "|B|")

            Sensor.TYPE_GYROSCOPE,
            Sensor.TYPE_GYROSCOPE_UNCALIBRATED -> {
                if (axes < 3) return v.joinToString("   ") { "%+.5f".format(it) }
                val mag = sqrt(v.take(3).fold(0.0) { acc, f -> acc + f.toDouble() * f })
                "x %+9.4f   y %+9.4f   z %+9.4f  rad/s\n|ω| = %.3f rad/s = %.2f °/s"
                    .format(v[0], v[1], v[2], mag, Math.toDegrees(mag))
            }

            Sensor.TYPE_ORIENTATION ->
                if (axes < 3) v.joinToString("   ") { "%+.5f".format(it) }
                else "azimuth %7.2f°   pitch %+7.2f°   roll %+7.2f°\n%s"
                    .format(v[0], v[1], v[2], compassPoint(v[0].toDouble()))

            Sensor.TYPE_ROTATION_VECTOR,
            Sensor.TYPE_GAME_ROTATION_VECTOR,
            Sensor.TYPE_GEOMAGNETIC_ROTATION_VECTOR ->
                if (axes < 3) v.joinToString("   ") { "%+.5f".format(it) }
                else rotationVector(v)

            Sensor.TYPE_LIGHT -> "%.1f lx".format(v[0])
            Sensor.TYPE_PROXIMITY -> "%.1f cm".format(v[0])
            Sensor.TYPE_PRESSURE -> "%.2f hPa".format(v[0])
            Sensor.TYPE_AMBIENT_TEMPERATURE -> "%.2f °C".format(v[0])
            Sensor.TYPE_RELATIVE_HUMIDITY -> "%.1f %%".format(v[0])
            Sensor.TYPE_STEP_COUNTER -> "%.0f steps".format(v[0])

            else -> v.joinToString("   ") { "%+.5f".format(it) }
        }
    }

    /**
     * Show the quaternion and, underneath, the orientation an app would derive
     * from it -- which is what makes a wrong component order or a wrong world
     * frame obvious at a glance.
     */
    private fun rotationVector(v: FloatArray): String {
        val quat = FloatArray(4)
        // getRotationMatrixFromVector rejects vectors longer than 4 on some
        // releases, and a 3-element vector omits w (it is implied).
        SensorManager.getQuaternionFromVector(quat, v.copyOf(minOf(v.size, 4)))

        val matrix = FloatArray(9)
        SensorManager.getRotationMatrixFromVector(matrix, v.copyOf(minOf(v.size, 4)))
        val angles = FloatArray(3)
        SensorManager.getOrientation(matrix, angles)

        var azimuth = Math.toDegrees(angles[0].toDouble())
        if (azimuth < 0) azimuth += 360.0
        val pitch = Math.toDegrees(angles[1].toDouble())
        val roll = Math.toDegrees(angles[2].toDouble())
        val norm = sqrt(quat.fold(0.0) { acc, f -> acc + f.toDouble() * f })

        // getQuaternionFromVector returns w first; the HAL's wire order is
        // x, y, z, w. Print it in the HAL's order to make comparison with
        // in_rot_quaternion_raw on the host direct.
        return ("x %+8.5f  y %+8.5f  z %+8.5f  w %+8.5f   |q| = %.5f\n" +
                "-> azimuth %6.2f°  pitch %+6.2f°  roll %+6.2f°   %s")
            .format(quat[1], quat[2], quat[3], quat[0], norm,
                    azimuth, pitch, roll, compassPoint(azimuth))
    }

    private fun compassPoint(azimuth: Double): String {
        val points = arrayOf("N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                             "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW")
        val idx = (((azimuth % 360.0 + 360.0) % 360.0) / 22.5 + 0.5).toInt() % 16
        return "facing ${points[idx]}"
    }

    private fun typeName(sensor: Sensor): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP && sensor.stringType != null) {
            sensor.stringType.removePrefix("android.sensor.")
        } else {
            "type ${sensor.type}"
        }

    companion object {
        // 3 Hz. Fast enough to read, slow enough to leave the main looper
        // free to drain the sensor event queue on a fanless Core M.
        private const val REFRESH_MS = 333L
        private const val HARDWARE_BG = 0x2200AA55
        private const val SOFTWARE_BG = 0x22888888
    }
}
