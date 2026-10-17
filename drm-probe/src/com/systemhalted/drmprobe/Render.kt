package com.systemhalted.drmprobe

import android.media.MediaDrm

/*
 * How the probe turns what MediaDrm hands back into report text. Moved out of
 * MainActivity unchanged, because an Activity cannot be constructed off a
 * device and these functions never needed one: they are the part of the
 * report drm-probe/test can check without a CDM.
 */

/** The section header: `=== <title> ` padded with '=' to 72 columns. */
internal fun ruleLine(title: String): String = "=== $title ".padEnd(72, '=')

/** Runs [f] and renders either its value or the exception it threw. */
internal fun tryOf(f: () -> Any?): String =
    try { f()?.toString() ?: "null" } catch (t: Throwable) { "THREW ${describe(t)}" }

internal fun describe(t: Throwable): String {
    val extra = if (t is MediaDrm.MediaDrmStateException) {
        " diagnostic=${t.diagnosticInfo}"
    } else ""
    return "${t.javaClass.simpleName}: ${t.message}$extra"
}

internal fun hex(b: ByteArray?): String {
    if (b == null) return "null"
    val sb = StringBuilder("(${b.size} bytes) ")
    for (i in 0 until minOf(b.size, 32)) sb.append("%02x".format(b[i]))
    if (b.size > 32) sb.append("...")
    return sb.toString()
}

internal fun hdcp(v: Int) = when (v) {
    MediaDrm.HDCP_LEVEL_UNKNOWN -> "UNKNOWN"
    MediaDrm.HDCP_NONE -> "NONE"
    MediaDrm.HDCP_NO_DIGITAL_OUTPUT -> "NO_DIGITAL_OUTPUT"
    MediaDrm.HDCP_V1 -> "V1"
    MediaDrm.HDCP_V2 -> "V2"
    MediaDrm.HDCP_V2_1 -> "V2_1"
    MediaDrm.HDCP_V2_2 -> "V2_2"
    MediaDrm.HDCP_V2_3 -> "V2_3"
    else -> "?($v)"
}

internal fun level(v: Int) = when (v) {
    MediaDrm.SECURITY_LEVEL_UNKNOWN -> "UNKNOWN"
    MediaDrm.SECURITY_LEVEL_SW_SECURE_CRYPTO -> "SW_SECURE_CRYPTO (L3)"
    MediaDrm.SECURITY_LEVEL_SW_SECURE_DECODE -> "SW_SECURE_DECODE"
    MediaDrm.SECURITY_LEVEL_HW_SECURE_CRYPTO -> "HW_SECURE_CRYPTO"
    MediaDrm.SECURITY_LEVEL_HW_SECURE_DECODE -> "HW_SECURE_DECODE"
    MediaDrm.SECURITY_LEVEL_HW_SECURE_ALL -> "HW_SECURE_ALL (L1)"
    else -> "?($v)"
}
