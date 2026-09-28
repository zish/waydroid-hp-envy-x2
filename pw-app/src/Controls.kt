/*
 * Copyright 2026 Jeremy Melanson
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
package com.systemhalted.patchbay

import org.json.JSONObject

/**
 * A filter graph's control ports, as the daemon projects them.
 *
 * waydroid-pwd reads these out of the SECOND Props entry of a filter-chain
 * node -- the first belongs to audioconvert -- and hands them over already
 * split into filter and port, with the biquad coefficient ports flagged
 * readonly. See docs/56 and waydroid-pwd's Graph._controls.
 */
object Controls {

    class Control(
        val key: String,
        val filter: String,
        val port: String,
        val value: Double,
        val readonly: Boolean
    )

    fun of(node: JSONObject): List<Control> {
        val array = node.optJSONArray("controls") ?: return emptyList()
        val out = ArrayList<Control>(array.length())
        for (index in 0 until array.length()) {
            val entry = array.optJSONObject(index) ?: continue
            val key = Graph.text(entry, "key") ?: continue
            out.add(
                Control(
                    key,
                    Graph.text(entry, "filter") ?: "",
                    Graph.text(entry, "port") ?: "",
                    entry.optDouble("value", 0.0),
                    entry.optBoolean("readonly", false)
                )
            )
        }
        return out
    }
}

/**
 * How wide a slider for one control port should be, and how to print it.
 *
 * WHY THIS IS KEYED ON THE PORT NAME AND NOT THE FILTER
 *
 * Because the port name is the only thing available. PipeWire publishes a
 * control as `<filter-node-name>:<port>`, and the filter node's name is
 * whatever the person who wrote the config called it -- "eq_band_1" here,
 * which says nothing about what kind of filter it is. The LABEL (bq_peaking,
 * delay, noisegate) is in the config and is not in the graph, so nothing the
 * daemon can see reports it. Port names, in contrast, are fixed by the plugin:
 * every biquad has "Freq", "Q" and "Gain", the delay has "Delay (s)", and so
 * on. libpipewire-module-filter-chain(7) is the list.
 *
 * The cost of that is one known collision: lufs2gain publishes an OUTPUT
 * control also called "Gain", which is linear, and it gets a biquad's dB
 * slider here. Writing to an output control does nothing, so the damage is a
 * misleading readout rather than a wrong sound. Fixing it properly means the
 * host telling the app what each control is, which is the recipe catalogue
 * docs/56 sketches and this file deliberately does not pretend to be.
 *
 * WHY AN UNKNOWN PORT GETS NO SLIDER
 *
 * A slider is a claim about where the ends are. For a port this table has
 * never heard of there is no honest claim to make, and a made-up range would
 * put a real control somewhere arbitrary on the bar. Those fall back to typing
 * the number, which is exactly as capable and does not lie about the range.
 */
class ControlSpec private constructor(
    val min: Double,
    val max: Double,
    private val log: Boolean,
    private val unit: String,
    private val decimals: Int,
    private val signed: Boolean
) {

    fun toProgress(value: Double): Int {
        val clamped = value.coerceIn(min, max)
        val fraction = if (log) {
            Math.log(clamped / min) / Math.log(max / min)
        } else {
            (clamped - min) / (max - min)
        }
        return Math.round(fraction * STEPS).toInt().coerceIn(0, STEPS)
    }

    fun fromProgress(progress: Int): Double {
        val fraction = progress.toDouble() / STEPS
        return if (log) min * Math.pow(max / min, fraction) else min + (max - min) * fraction
    }

    fun format(value: Double): String {
        // A six-band EQ's top bands are five digits of hertz, which is the one
        // place a raw number is harder to read than a scaled one.
        if (unit == "Hz" && Math.abs(value) >= 1000.0) {
            return "%.2f kHz".format(value / 1000.0)
        }
        val number = if (signed) "%+.${decimals}f".format(value)
        else "%.${decimals}f".format(value)
        return if (unit.isEmpty()) number else "$number $unit"
    }

    /**
     * The same spec, widened if the control is already outside it.
     *
     * Clamping instead would leave the slider pinned at one end while the
     * readout showed a value it cannot reach, and the first touch would jump
     * the control to the end of the bar without the user asking for it.
     */
    private fun covering(value: Double): ControlSpec {
        if (!value.isFinite()) return this
        if (value >= min && value <= max) return this
        val low = Math.min(min, value)
        val high = Math.max(max, value)
        // A logarithmic scale cannot reach or cross zero, so a value at or
        // below zero demotes the control to a linear slider rather than
        // dropping the value off the end of the bar.
        return ControlSpec(low, high, log && low > 0.0, unit, decimals, signed)
    }

    companion object {
        const val STEPS = 1000

        // Ports named by libpipewire-module-filter-chain(7). Ranges are this
        // app's choice, not the plugin's: PipeWire publishes no range for a
        // control port, and the host clamps what it needs to (the delay to its
        // configured max-delay, for one), so an over-wide slider is safe and an
        // over-narrow one is not.
        private val BY_PORT = mapOf(
            // Every biquad, and so every band of an equalizer.
            "Freq" to ControlSpec(20.0, 20000.0, true, "Hz", 0, false),
            "Q" to ControlSpec(0.1, 10.0, true, "", 2, false),
            "Gain" to ControlSpec(-24.0, 24.0, false, "dB", 1, true),
            // delay
            "Delay (s)" to ControlSpec(0.0, 2.0, false, "s", 3, false),
            "Feedback" to ControlSpec(-1.0, 1.0, false, "", 2, true),
            "Feedforward" to ControlSpec(-1.0, 1.0, false, "", 2, true),
            // noisegate
            "Attack (s)" to ControlSpec(0.0, 2.0, false, "s", 3, false),
            "Release (s)" to ControlSpec(0.0, 2.0, false, "s", 3, false),
            "Hold (s)" to ControlSpec(0.0, 2.0, false, "s", 3, false),
            "Open threshold" to ControlSpec(0.0, 1.0, false, "", 3, false),
            "Close threshold" to ControlSpec(0.0, 1.0, false, "", 3, false),
            // ebur128 / lufs2gain
            "LUFS" to ControlSpec(-70.0, 0.0, false, "LUFS", 1, true),
            "Target LUFS" to ControlSpec(-70.0, 0.0, false, "LUFS", 1, true)
        )

        // mixer publishes "Gain 1" to "Gain 8", and unlike a biquad's "Gain"
        // these are linear multipliers with a default of 1.0.
        private val MIXER_GAIN = ControlSpec(0.0, 2.0, false, "", 2, false)

        /** A slider for this port, or null if this app has no honest range. */
        fun of(port: String, value: Double): ControlSpec? {
            BY_PORT[port]?.let { return it.covering(value) }
            if (port.startsWith("Gain ") && port.substring(5).toIntOrNull() != null) {
                return MIXER_GAIN.covering(value)
            }
            return null
        }
    }
}
