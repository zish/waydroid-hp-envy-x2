/*
 * Copyright 2026 Jeremy Melanson
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
package com.systemhalted.audioprobe

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.graphics.Typeface
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.io.File
import kotlin.math.PI
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Answers the one question the host-side dumps cannot: is an ordinary app
 * actually GRANTED a fast track, and with what buffer?
 *
 * Context, from docs/44. Waydroid's audio HAL hardcoded a 1024-frame buffer and
 * reported it to AudioFlinger, which decides whether to build a FastMixer from
 *
 *     initFastMixer = (mFrameCount < mNormalFrameCount)
 *
 * where mNormalFrameCount is the HAL count scaled UP only as far as 20 ms (960
 * frames at 48 kHz). At 1024 the scaling declines to act, both counts land at
 * 1024, and NO FastMixer is constructed -- so AUDIO_OUTPUT_FLAG_FAST was denied
 * for every app on the device while `pm list features` advertised
 * android.hardware.audio.low_latency. Patching the HAL to report one card period
 * (256 frames) produced `Normal frame count: 768` and a real FastMixer.
 *
 * `dumpsys media.audio_flinger` can show that FastMixer exists. It cannot show
 * that an app gets to use it: a media player produces
 * `Fast tracks: activeMask=0x1` -- slot 0, the normal-mixer submix -- because
 * media players deliberately ask for deep buffers. This probe asks for the
 * opposite and prints what it is given.
 *
 * Three arms, built identically except for the performance mode, so the
 * difference between them is attributable:
 *
 *     PERFORMANCE_MODE_LOW_LATENCY   should be granted a fast track
 *     PERFORMANCE_MODE_NONE          the ordinary path, for contrast
 *     PERFORMANCE_MODE_POWER_SAVING  deep buffer, the other extreme
 *
 * The decisive field is getPerformanceMode() READ BACK from the built track.
 * AudioTrack silently downgrades a request it cannot honour, so the requested
 * and granted modes differing IS the result.
 *
 * It also times its own write() calls. That matters because AudioFlinger's
 * `Hal write jitter` changes identity once a FastMixer exists -- the normal
 * mixer then writes into a MonoPipe rather than into the HAL, so the figure
 * stops describing the card and is not comparable across the change. An
 * app-side write cadence is measured in the same place in both configurations
 * and so can be compared.
 *
 * Audio is played QUIETLY and briefly on purpose: a 1 kHz sine at a quarter of
 * full scale with the track volume at 0.2, for 1.5 s per arm. Audibility is not
 * what is being measured; underruns and granted buffers are.
 */
class MainActivity : Activity() {

    private val out = StringBuilder()

    private fun emit(line: String) {
        synchronized(out) { out.append(line).append('\n') }
        Log.i(TAG, line)
    }

    private fun rule(title: String) {
        emit("")
        emit("=== $title ".padEnd(72, '='))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val tv = TextView(this).apply {
            typeface = Typeface.MONOSPACE
            textSize = 9f
            setPadding(16, 16, 16, 16)
            setTextIsSelectable(true)
            text = "probing..."
        }
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(About.link(this@MainActivity))
            addView(ScrollView(this@MainActivity).apply { addView(tv) },
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        })

        // Off the main thread: the three arms block in write() for 1.5 s each,
        // and 4.5 s of that in onCreate is an ANR waiting to happen.
        Thread {
            try {
                probe()
            } catch (t: Throwable) {
                emit("FATAL: $t")
                Log.e(TAG, "probe failed", t)
            }
            val report = synchronized(out) { out.toString() }
            save(report)
            runOnUiThread { tv.text = report }
        }.start()
    }

    private fun probe() {
        emit("Audio Probe -- ${java.util.Date()}")
        emit("  ${Build.MANUFACTURER} ${Build.MODEL}  SDK ${Build.VERSION.SDK_INT} (${Build.VERSION.RELEASE})")

        val am = getSystemService(AUDIO_SERVICE) as AudioManager

        rule("what the framework advertises")
        // PROPERTY_OUTPUT_FRAMES_PER_BUFFER is the number every low-latency
        // guide tells apps to use as their buffer quantum. It comes from the
        // primary output's frame count, so it is the HAL's buffer as the
        // framework sees it -- the cleanest app-visible proof the patch landed.
        val fpb = am.getProperty(AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER)
        val sr = am.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)
        emit("  PROPERTY_OUTPUT_FRAMES_PER_BUFFER   ${fpb ?: "(null)"}")
        emit("  PROPERTY_OUTPUT_SAMPLE_RATE         ${sr ?: "(null)"}")
        val fpbN = fpb?.toIntOrNull()
        val srN = sr?.toIntOrNull() ?: RATE
        if (fpbN != null) emit("  => advertised quantum               ${ms(fpbN, srN)}")

        emit("")
        for ((name, feat) in listOf(
            "audio.low_latency" to PackageManager.FEATURE_AUDIO_LOW_LATENCY,
            "audio.pro" to PackageManager.FEATURE_AUDIO_PRO,
            "audio.output" to PackageManager.FEATURE_AUDIO_OUTPUT,
            "midi" to PackageManager.FEATURE_MIDI,
        )) {
            emit("  feature %-20s %s".format(name, packageManager.hasSystemFeature(feat)))
        }

        emit("")
        val minBytes = AudioTrack.getMinBufferSize(RATE, CHMASK, ENCODING)
        if (minBytes > 0) {
            val minFrames = minBytes / FRAME_BYTES
            emit("  getMinBufferSize                    $minBytes bytes = $minFrames frames")
            emit("  => ordinary AudioTrack floor        ${ms(minFrames, RATE)}")
        } else {
            emit("  getMinBufferSize                    FAILED ($minBytes)")
        }

        rule("output devices")
        for (d in am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
            emit("  type=${devType(d.type)} id=${d.id} ${d.productName}")
            emit("      sampleRates   ${d.sampleRates.joinToString(",").ifEmpty { "(unrestricted)" }}")
            emit("      channelCounts ${d.channelCounts.joinToString(",").ifEmpty { "(unrestricted)" }}")
            emit("      channelMasks  ${d.channelMasks.joinToString(",") { "0x%x".format(it) }.ifEmpty { "(unrestricted)" }}")
            emit("      encodings     ${d.encodings.joinToString(",") { encName(it) }.ifEmpty { "(unrestricted)" }}")
        }

        val results = ArrayList<Arm>()
        for ((label, mode) in ARMS) {
            rule("AudioTrack arm: $label")
            results.add(runArm(label, mode, fpbN ?: 256))
        }

        rule("rate and format matrix")
        matrix(fpbN ?: 256)

        rule("capture")
        runCapture()

        rule("verdict")
        val low = results.firstOrNull { it.requested == AudioTrack.PERFORMANCE_MODE_LOW_LATENCY }
        if (low == null || !low.built) {
            emit("  LOW_LATENCY arm did not build -- nothing can be concluded")
        } else if (low.granted == AudioTrack.PERFORMANCE_MODE_LOW_LATENCY) {
            emit("  LOW_LATENCY was GRANTED.")
            emit("  An ordinary app is on the fast path: buffer ${low.bufFrames} frames" +
                " = ${ms(low.bufFrames, RATE)}, underruns ${low.underruns}.")
        } else {
            emit("  LOW_LATENCY was REQUESTED and NOT granted.")
            emit("  getPerformanceMode() came back ${perfName(low.granted)}, so AudioFlinger")
            emit("  refused the fast track. Check `dumpsys media.audio_flinger` for the")
            emit("  AUDIO_OUTPUT_FLAG_FAST denied line, and whether a FastMixer exists at all.")
        }
        emit("")
        emit("  %-22s %-12s %-12s %9s %9s %9s".format(
            "arm", "requested", "granted", "bufFrames", "capFrames", "underrun"))
        for (r in results) {
            emit("  %-22s %-12s %-12s %9s %9s %9s".format(
                r.label, perfName(r.requested), if (r.built) perfName(r.granted) else "-",
                if (r.built) r.bufFrames.toString() else "-",
                if (r.built) r.capFrames.toString() else "-",
                if (r.built) r.underruns.toString() else "-"))
        }
        emit("")
        emit("  write cadence, measured app-side (comparable across configurations,")
        emit("  unlike AudioFlinger's 'Hal write jitter', which changes identity when")
        emit("  a FastMixer is inserted and the normal mixer starts writing to a pipe):")
        emit("  %-22s %9s %9s %9s %9s".format("arm", "chunk", "mean ms", "sd ms", "max ms"))
        for (r in results) {
            if (!r.built) continue
            emit("  %-22s %9d %9.3f %9.3f %9.3f".format(
                r.label, r.chunkFrames, r.meanMs, r.sdMs, r.maxMs))
        }
    }

    private class Arm(val label: String, val requested: Int) {
        var built = false
        var granted = -1
        var bufFrames = 0
        var capFrames = 0
        var underruns = 0
        var chunkFrames = 0
        var meanMs = 0.0
        var sdMs = 0.0
        var maxMs = 0.0
    }

    private fun runArm(label: String, mode: Int, quantum: Int): Arm {
        val arm = Arm(label, mode)

        // Two quanta is the usual low-latency recommendation: enough to survive
        // one late wakeup, small enough that AudioFlinger will still grant FAST.
        // A buffer much larger than the fast mixer's own period gets the request
        // denied, so this is deliberately not generous.
        val wantFrames = when (mode) {
            AudioTrack.PERFORMANCE_MODE_LOW_LATENCY -> quantum * 2
            AudioTrack.PERFORMANCE_MODE_POWER_SAVING -> quantum * 32
            else -> maxOf(AudioTrack.getMinBufferSize(RATE, CHMASK, ENCODING) / FRAME_BYTES, quantum * 4)
        }
        emit("  requested mode   ${perfName(mode)}")
        emit("  requested buffer $wantFrames frames (${ms(wantFrames, RATE)})")

        val track = try {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build())
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(ENCODING)
                        .setSampleRate(RATE)
                        .setChannelMask(CHMASK)
                        .build())
                .setBufferSizeInBytes(wantFrames * FRAME_BYTES)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setPerformanceMode(mode)
                .build()
        } catch (t: Throwable) {
            emit("  BUILD FAILED: $t")
            return arm
        }

        try {
            arm.built = true
            arm.granted = track.performanceMode
            arm.bufFrames = track.bufferSizeInFrames
            arm.capFrames = track.bufferCapacityInFrames
            emit("  granted mode     ${perfName(arm.granted)}" +
                if (arm.granted == mode) "" else "   <-- DOWNGRADED from ${perfName(mode)}")
            emit("  granted buffer   ${arm.bufFrames} frames (${ms(arm.bufFrames, RATE)})")
            emit("  capacity         ${arm.capFrames} frames (${ms(arm.capFrames, RATE)})")
            emit("  session id       ${track.audioSessionId}")

            // Hidden since forever and blocked for non-system apps since API 28,
            // but it is the only direct read of the framework's own latency
            // estimate, so it is worth one guarded attempt. A failure here is a
            // result, not an error.
            try {
                val m = AudioTrack::class.java.getMethod("getLatency")
                emit("  getLatency()     ${m.invoke(track)} ms (hidden API, reflection)")
            } catch (t: Throwable) {
                emit("  getLatency()     unavailable (${t.javaClass.simpleName}) -- expected, hidden API")
            }

            val chunk = minOf(arm.bufFrames, 1024).coerceAtLeast(64)
            arm.chunkFrames = chunk
            val buf = sine(chunk)
            track.setVolume(VOLUME)
            track.play()

            val intervals = ArrayList<Double>()
            val totalFrames = (RATE * PLAY_SECONDS).toInt()
            var written = 0
            var last = System.nanoTime()
            while (written < totalFrames) {
                val n = track.write(buf, 0, buf.size)
                if (n <= 0) { emit("  write returned $n -- stopping early"); break }
                val now = System.nanoTime()
                // Discard the first interval: it contains the cold-start warmup
                // (AudioFlinger measures its own as ~11 ms) and would dominate.
                if (written > 0) intervals.add((now - last) / 1_000_000.0)
                last = now
                written += n / CHANNELS
            }

            arm.underruns = track.underrunCount
            if (intervals.isNotEmpty()) {
                val mean = intervals.average()
                arm.meanMs = mean
                arm.sdMs = sqrt(intervals.sumOf { (it - mean) * (it - mean) } / intervals.size)
                arm.maxMs = intervals.max()
                emit("  write cadence    n=${intervals.size} chunk=$chunk frames" +
                    " mean=%.3f sd=%.3f min=%.3f max=%.3f ms".format(
                        mean, arm.sdMs, intervals.min(), arm.maxMs))
            }
            emit("  underrun count   ${arm.underruns}")

            val ts = AudioTimestamp()
            if (track.getTimestamp(ts)) {
                emit("  getTimestamp     framePosition=${ts.framePosition} nanoTime=${ts.nanoTime}")
            } else {
                emit("  getTimestamp     unavailable -- the HAL reports no presentation position")
            }
            emit("  playbackHeadPos  ${track.playbackHeadPosition}")
        } finally {
            try { track.stop() } catch (t: Throwable) { }
            track.release()
        }
        return arm
    }

    /**
     * What rates and formats an app can actually get, and -- the part that
     * matters for a DAW -- whether it can get a FAST track at anything other
     * than the device's own rate.
     *
     * AudioFlinger will happily build a track at any rate and resample it to
     * the output's, so a track existing at 96 kHz proves nothing about the
     * hardware. The output rate is fixed by the policy XML profile, which
     * declares 48000 alone. A fast track additionally has to match the output
     * exactly, because it bypasses the resampler -- so the granted performance
     * mode across rates is the real measurement here, not whether build()
     * threw.
     *
     * Tracks are built and released without playing: this is about what the
     * policy and AudioFlinger permit, and playing 12 tones would add nothing
     * but noise.
     */
    private fun matrix(quantum: Int) {
        emit("  output is pinned to ${RATE} Hz by the policy profile; anything else is resampled.")
        emit("  A FAST track must match the output rate, so 'granted' is the real column.")
        emit("")
        emit("  %-8s %-10s %-9s %-12s %9s".format("rate", "encoding", "built", "granted", "bufFrames"))
        for (rate in intArrayOf(44100, 48000, 96000, 192000)) {
            for ((encName, enc) in listOf(
                "PCM_16" to AudioFormat.ENCODING_PCM_16BIT,
                "PCM_FLOAT" to AudioFormat.ENCODING_PCM_FLOAT,
            )) {
                var built = "no"; var granted = "-"; var frames = "-"
                var t: AudioTrack? = null
                try {
                    t = AudioTrack.Builder()
                        .setAudioAttributes(
                            AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_MEDIA)
                                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                                .build())
                        .setAudioFormat(
                            AudioFormat.Builder()
                                .setEncoding(enc).setSampleRate(rate)
                                .setChannelMask(CHMASK).build())
                        .setBufferSizeInBytes(quantum * 2 * CHANNELS *
                            if (enc == AudioFormat.ENCODING_PCM_FLOAT) 4 else 2)
                        .setTransferMode(AudioTrack.MODE_STREAM)
                        .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
                        .build()
                    built = "yes"
                    granted = perfName(t.performanceMode)
                    frames = t.bufferSizeInFrames.toString()
                } catch (th: Throwable) {
                    built = "FAILED"
                    granted = th.javaClass.simpleName
                } finally {
                    try { t?.release() } catch (th: Throwable) { }
                }
                emit("  %-8d %-10s %-9s %-12s %9s".format(rate, encName, built, granted, frames))
            }
        }
    }

    /**
     * Capture. A DAW records, and this project has never exercised the input
     * side at all -- so this is a first look, not a regression check.
     *
     * It also matters for a reason specific to what was patched: the HAL's
     * get_buffer_size() is ONE function shared by the input and output vtables,
     * so shrinking it for playback shrank the reported capture buffer too. That
     * side effect has never been tested, and this is the test.
     *
     * Peak level is reported because a capture path can be perfectly healthy by
     * every API measure and still deliver digital silence, which is the failure
     * mode worth catching.
     */
    private fun runCapture() {
        val minBytes = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, ENCODING)
        emit("  getMinBufferSize  $minBytes bytes" +
            if (minBytes > 0) " = ${minBytes / 2} frames mono (${ms(minBytes / 2, RATE)})" else " (FAILED)")

        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                != PackageManager.PERMISSION_GRANTED) {
            emit("  RECORD_AUDIO is NOT granted -- reinstall with `pm install -g`.")
            emit("  Nothing below could be measured.")
            return
        }
        emit("  RECORD_AUDIO       granted")

        val want = if (minBytes > 0) minBytes else 4096
        val rec = try {
            AudioRecord.Builder()
                .setAudioSource(MediaRecorder.AudioSource.MIC)
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(ENCODING).setSampleRate(RATE)
                        .setChannelMask(AudioFormat.CHANNEL_IN_MONO).build())
                .setBufferSizeInBytes(want)
                .build()
        } catch (t: Throwable) {
            emit("  BUILD FAILED: $t"); return
        }

        try {
            emit("  state              ${recState(rec.state)}")
            if (rec.state != AudioRecord.STATE_INITIALIZED) {
                emit("  not initialised -- the input stream could not be opened"); return
            }
            emit("  granted buffer     ${rec.bufferSizeInFrames} frames (${ms(rec.bufferSizeInFrames, RATE)})")
            emit("  source / rate      ${rec.audioSource} / ${rec.sampleRate} Hz, ${rec.channelCount} ch")
            emit("  session id         ${rec.audioSessionId}")

            val chunk = minOf(rec.bufferSizeInFrames, 1024).coerceAtLeast(64)
            val buf = ShortArray(chunk)
            rec.startRecording()
            if (rec.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                emit("  startRecording did NOT take -- recordingState=${rec.recordingState}"); return
            }

            val intervals = ArrayList<Double>()
            var frames = 0; var peak = 0; var nonZero = 0L; var reads = 0
            val target = (RATE * CAPTURE_SECONDS).toInt()
            var last = System.nanoTime()
            while (frames < target) {
                val n = rec.read(buf, 0, buf.size)
                if (n <= 0) { emit("  read returned $n -- stopping early"); break }
                val now = System.nanoTime()
                if (reads > 0) intervals.add((now - last) / 1_000_000.0)
                last = now; reads++
                for (i in 0 until n) {
                    val v = buf[i].toInt()
                    val a = if (v < 0) -v else v
                    if (a > peak) peak = a
                    if (v != 0) nonZero++
                }
                frames += n
            }
            rec.stop()

            if (intervals.isNotEmpty()) {
                val mean = intervals.average()
                emit("  read cadence       n=${intervals.size} chunk=$chunk frames" +
                    " mean=%.3f sd=%.3f min=%.3f max=%.3f ms".format(
                        mean, sqrt(intervals.sumOf { (it - mean) * (it - mean) } / intervals.size),
                        intervals.min(), intervals.max()))
            }
            emit("  frames captured    $frames in $reads reads")
            emit("  peak sample        $peak of 32767" +
                if (peak > 0) " = %.1f dBFS".format(20.0 * kotlin.math.log10(peak / 32767.0)) else "")
            emit("  non-zero samples   $nonZero of $frames" +
                if (nonZero == 0L) "   <-- DIGITAL SILENCE: the stream opened but delivered nothing"
                else "")

            val ts = AudioTimestamp()
            if (rec.getTimestamp(ts, AudioTimestamp.TIMEBASE_MONOTONIC) == AudioRecord.SUCCESS) {
                emit("  getTimestamp       framePosition=${ts.framePosition} nanoTime=${ts.nanoTime}")
            } else {
                emit("  getTimestamp       unavailable -- no capture presentation position")
            }
        } finally {
            try { rec.stop() } catch (t: Throwable) { }
            rec.release()
        }
    }

    /** 1 kHz, interleaved stereo, at a quarter of full scale. */
    private fun sine(frames: Int): ShortArray {
        val a = ShortArray(frames * CHANNELS)
        for (i in 0 until frames) {
            val v = (Short.MAX_VALUE * 0.25 * sin(2.0 * PI * 1000.0 * i / RATE)).toInt().toShort()
            a[i * CHANNELS] = v
            a[i * CHANNELS + 1] = v
        }
        return a
    }

    private fun ms(frames: Int, rate: Int): String =
        if (rate <= 0) "?" else "%.2f ms".format(frames * 1000.0 / rate)

    private fun save(report: String) {
        try {
            val dir = getExternalFilesDir("reports") ?: return
            dir.mkdirs()
            File(dir, "audio-probe.txt").writeText(report)
        } catch (t: Throwable) {
            Log.w(TAG, "could not save report: $t")
        }
    }

    companion object {
        const val TAG = "AUDIOPROBE"

        private const val RATE = 48000
        private const val CHANNELS = 2
        private const val CHMASK = AudioFormat.CHANNEL_OUT_STEREO
        private const val ENCODING = AudioFormat.ENCODING_PCM_16BIT
        private const val FRAME_BYTES = CHANNELS * 2
        private const val PLAY_SECONDS = 1.5
        private const val CAPTURE_SECONDS = 1.5
        /** Quiet on purpose. Audibility is not what is being measured. */
        private const val VOLUME = 0.2f

        private val ARMS = listOf(
            "LOW_LATENCY" to AudioTrack.PERFORMANCE_MODE_LOW_LATENCY,
            "NONE (ordinary)" to AudioTrack.PERFORMANCE_MODE_NONE,
            "POWER_SAVING (deep)" to AudioTrack.PERFORMANCE_MODE_POWER_SAVING,
        )

        private fun recState(s: Int): String = when (s) {
            AudioRecord.STATE_INITIALIZED -> "INITIALIZED"
            AudioRecord.STATE_UNINITIALIZED -> "UNINITIALIZED"
            else -> "?($s)"
        }

        private fun perfName(m: Int): String = when (m) {
            AudioTrack.PERFORMANCE_MODE_NONE -> "NONE"
            AudioTrack.PERFORMANCE_MODE_LOW_LATENCY -> "LOW_LATENCY"
            AudioTrack.PERFORMANCE_MODE_POWER_SAVING -> "POWER_SAVING"
            else -> "?($m)"
        }

        private fun devType(t: Int): String = when (t) {
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "BUILTIN_SPEAKER"
            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "BUILTIN_EARPIECE"
            AudioDeviceInfo.TYPE_WIRED_HEADSET -> "WIRED_HEADSET"
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "WIRED_HEADPHONES"
            AudioDeviceInfo.TYPE_USB_DEVICE -> "USB_DEVICE"
            AudioDeviceInfo.TYPE_USB_HEADSET -> "USB_HEADSET"
            AudioDeviceInfo.TYPE_USB_ACCESSORY -> "USB_ACCESSORY"
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "BLUETOOTH_A2DP"
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "BLUETOOTH_SCO"
            AudioDeviceInfo.TYPE_HDMI -> "HDMI"
            AudioDeviceInfo.TYPE_TELEPHONY -> "TELEPHONY"
            AudioDeviceInfo.TYPE_REMOTE_SUBMIX -> "REMOTE_SUBMIX"
            else -> "type$t"
        }

        private fun encName(e: Int): String = when (e) {
            AudioFormat.ENCODING_PCM_8BIT -> "PCM_8"
            AudioFormat.ENCODING_PCM_16BIT -> "PCM_16"
            AudioFormat.ENCODING_PCM_FLOAT -> "PCM_FLOAT"
            AudioFormat.ENCODING_PCM_24BIT_PACKED -> "PCM_24_PACKED"
            AudioFormat.ENCODING_PCM_32BIT -> "PCM_32"
            AudioFormat.ENCODING_AC3 -> "AC3"
            AudioFormat.ENCODING_E_AC3 -> "E_AC3"
            AudioFormat.ENCODING_IEC61937 -> "IEC61937"
            else -> "enc$e"
        }
    }
}
