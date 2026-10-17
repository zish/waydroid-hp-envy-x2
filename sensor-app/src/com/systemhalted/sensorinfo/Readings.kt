/*
 * How a sensor reading becomes the text on its card, and the 16-point compass
 * name used beside every heading.
 *
 * Lifted out of MainActivity unchanged so they can be tested on the JVM: they
 * take a sensor TYPE rather than a Sensor, because Sensor.getType() is one of
 * the android.jar stubs that throws off-device. rotationVector() still calls
 * SensorManager and so only runs on Android; the rest is plain arithmetic.
 */
package com.systemhalted.sensorinfo

import android.hardware.Sensor
import android.hardware.SensorManager
import kotlin.math.sqrt

internal fun formatValues(type: Int, v: FloatArray?): String {
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

    return when (type) {
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
                .format(v[0], v[1], v[2], "facing " + compassPoint(v[0].toDouble()))

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
internal fun rotationVector(v: FloatArray): String {
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
                azimuth, pitch, roll, "facing " + compassPoint(azimuth))
}

internal fun compassPoint(azimuth: Double): String {
    val points = arrayOf("N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                         "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW")
    val idx = (((azimuth % 360.0 + 360.0) % 360.0) / 22.5 + 0.5).toInt() % 16
    return points[idx]
}
