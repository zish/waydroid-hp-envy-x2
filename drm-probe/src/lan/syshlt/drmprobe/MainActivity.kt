package lan.syshlt.drmprobe

import android.app.Activity
import android.graphics.Typeface
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaDrm
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.widget.ScrollView
import android.widget.TextView
import java.io.File
import java.util.UUID

/**
 * Dumps everything a DRM client can learn about this device, for BOTH registered
 * crypto schemes, so the question "what does Netflix actually see?" can be answered
 * from data instead of inferred from Netflix's silence.
 *
 * Netflix's release build logs nothing under its own tags and self-terminates without
 * an exception (docs/22). The only externally visible DRM complaint is
 *
 *     E DrmHalHidl: Failed to get vendor from drm plugin: -1010
 *     E DrmHalHidl: Failed to get description from drm plugin: -1010
 *
 * where -1010 is ERROR_UNSUPPORTED. Both plugins are enumerated immediately before
 * those lines, so which one is responsible cannot be read off the log. This probe
 * calls the same getters directly, per scheme, and reports the exact failure.
 *
 * Every call is individually guarded: a plugin that throws on one property must not
 * cost us the other twenty. A throw is a RESULT here, not an error -- it is printed
 * with its exception class, message, and (for MediaDrmStateException) the diagnostic
 * info, because that is precisely the signal being hunted.
 */
class MainActivity : Activity() {

    private val out = StringBuilder()

    private fun emit(line: String) {
        out.append(line).append('\n')
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
        }
        setContentView(ScrollView(this).apply { addView(tv) })

        probe()
        tv.text = out.toString()
        save()
    }

    private fun probe() {
        emit("DRM Probe -- ${java.util.Date()}")

        rule("device identity")
        // These exact strings are what the Widevine client identification carries to
        // the license server; see docs/22 for the captured request.
        emit("  MODEL        ${Build.MODEL}")
        emit("  BRAND        ${Build.BRAND}")
        emit("  MANUFACTURER ${Build.MANUFACTURER}")
        emit("  DEVICE       ${Build.DEVICE}")
        emit("  PRODUCT      ${Build.PRODUCT}")
        emit("  HARDWARE     ${Build.HARDWARE}")
        emit("  TYPE         ${Build.TYPE}")
        emit("  TAGS         ${Build.TAGS}")
        emit("  SDK          ${Build.VERSION.SDK_INT} (${Build.VERSION.RELEASE})")
        emit("  FINGERPRINT  ${Build.FINGERPRINT}")

        for ((name, uuid) in SCHEMES) probeScheme(name, uuid)

        probeCodecs()
    }

    private fun probeScheme(name: String, uuid: UUID) {
        rule("$name  $uuid")

        emit("  isCryptoSchemeSupported            ${tryOf { MediaDrm.isCryptoSchemeSupported(uuid) }}")
        emit("  isCryptoSchemeSupported(video/mp4) ${tryOf { MediaDrm.isCryptoSchemeSupported(uuid, "video/mp4") }}")
        for ((label, level) in SECURITY_LEVELS) {
            emit("  supported at $label".padEnd(37) +
                tryOf { MediaDrm.isCryptoSchemeSupported(uuid, "video/mp4", level) })
        }

        val drm = try {
            MediaDrm(uuid)
        } catch (t: Throwable) {
            emit("  MediaDrm(uuid) FAILED -> ${describe(t)}")
            return
        }
        emit("  MediaDrm(uuid) constructed OK")

        emit("  -- string properties (the -1010 hunt) --")
        for (p in STRING_PROPS) {
            emit("    ${p.padEnd(24)} ${tryOf { drm.getPropertyString(p) }}")
        }

        emit("  -- byte[] properties --")
        for (p in BYTE_PROPS) {
            emit("    ${p.padEnd(24)} ${tryOf { hex(drm.getPropertyByteArray(p)) }}")
        }

        emit("  -- session accounting --")
        emit("    openSessionCount       ${tryOf { drm.openSessionCount }}")
        emit("    maxSessionCount        ${tryOf { drm.maxSessionCount }}")
        emit("    connectedHdcpLevel     ${tryOf { hdcp(drm.connectedHdcpLevel) }}")
        emit("    maxHdcpLevel           ${tryOf { hdcp(drm.maxHdcpLevel) }}")

        // The decisive one. A NotProvisionedException here would mean the CDM has no
        // device certificate yet -- a completely different fault from a rejected one.
        emit("  -- open a session --")
        var session: ByteArray? = null
        try {
            session = drm.openSession()
            emit("    openSession()          OK  sessionId=${hex(session)}")
            emit("    securityLevel(session) ${tryOf { level(drm.getSecurityLevel(session!!)) }}")
        } catch (t: Throwable) {
            emit("    openSession()          FAILED -> ${describe(t)}")
        } finally {
            if (session != null) {
                emit("    closeSession()         ${tryOf { drm.closeSession(session!!); "OK" }}")
            }
            try { drm.close() } catch (_: Throwable) { }
        }
    }

    private fun probeCodecs() {
        rule("video decoders (secure playback support)")
        // Netflix needs a decoder that advertises FEATURE_SecurePlayback for L1, but
        // plain software decoding is enough for L3. Listed so a missing decoder can be
        // ruled in or out without another round trip.
        val wanted = listOf("video/avc", "video/hevc", "video/x-vnd.on2.vp9", "video/av01")
        val list = try {
            MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
        } catch (t: Throwable) {
            emit("  MediaCodecList FAILED -> ${describe(t)}"); return
        }
        for (mime in wanted) {
            val decoders = list.filter { !it.isEncoder && it.supportedTypes.any { t -> t.equals(mime, true) } }
            if (decoders.isEmpty()) { emit("  ${mime.padEnd(22)} (no decoder)"); continue }
            for (ci in decoders) {
                val secure = try {
                    ci.getCapabilitiesForType(mime)
                        .isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_SecurePlayback)
                } catch (t: Throwable) { "?" }
                emit("  ${mime.padEnd(22)} ${ci.name.padEnd(38)} secure=$secure")
            }
        }
    }

    /** Runs [f] and renders either its value or the exception it threw. */
    private fun tryOf(f: () -> Any?): String =
        try { f()?.toString() ?: "null" } catch (t: Throwable) { "THREW ${describe(t)}" }

    private fun describe(t: Throwable): String {
        val extra = if (t is MediaDrm.MediaDrmStateException) {
            " diagnostic=${t.diagnosticInfo}"
        } else ""
        return "${t.javaClass.simpleName}: ${t.message}$extra"
    }

    private fun hex(b: ByteArray?): String {
        if (b == null) return "null"
        val sb = StringBuilder("(${b.size} bytes) ")
        for (i in 0 until minOf(b.size, 32)) sb.append("%02x".format(b[i]))
        if (b.size > 32) sb.append("...")
        return sb.toString()
    }

    private fun hdcp(v: Int) = when (v) {
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

    private fun level(v: Int) = when (v) {
        MediaDrm.SECURITY_LEVEL_UNKNOWN -> "UNKNOWN"
        MediaDrm.SECURITY_LEVEL_SW_SECURE_CRYPTO -> "SW_SECURE_CRYPTO (L3)"
        MediaDrm.SECURITY_LEVEL_SW_SECURE_DECODE -> "SW_SECURE_DECODE"
        MediaDrm.SECURITY_LEVEL_HW_SECURE_CRYPTO -> "HW_SECURE_CRYPTO"
        MediaDrm.SECURITY_LEVEL_HW_SECURE_DECODE -> "HW_SECURE_DECODE"
        MediaDrm.SECURITY_LEVEL_HW_SECURE_ALL -> "HW_SECURE_ALL (L1)"
        else -> "?($v)"
    }

    /** Also written to disk so build.sh --pull can retrieve it without logcat. */
    private fun save() {
        try {
            val dir = getExternalFilesDir("reports") ?: return
            dir.mkdirs()
            File(dir, "drm-probe.txt").writeText(out.toString())
            emit("")
        } catch (t: Throwable) {
            Log.w(TAG, "could not save report: $t")
        }
    }

    companion object {
        const val TAG = "DRMPROBE"

        private val SCHEMES = listOf(
            "Widevine" to UUID.fromString("edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"),
            "ClearKey" to UUID.fromString("e2719d58-a985-b3c9-781a-b030af78d30e"),
            "PlayReady" to UUID.fromString("9a04f079-9840-4286-ab92-e65be0885f95"),
        )

        private val SECURITY_LEVELS = listOf(
            "SW_SECURE_CRYPTO" to MediaDrm.SECURITY_LEVEL_SW_SECURE_CRYPTO,
            "SW_SECURE_DECODE" to MediaDrm.SECURITY_LEVEL_SW_SECURE_DECODE,
            "HW_SECURE_ALL" to MediaDrm.SECURITY_LEVEL_HW_SECURE_ALL,
        )

        // The first four are the documented MediaDrm.PROPERTY_* constants -- "vendor"
        // and "description" are the two the framework logged -1010 for. The rest are
        // Widevine's own, and are exactly what a player queries when deciding whether
        // a device is fit to play.
        private val STRING_PROPS = listOf(
            "vendor", "version", "description", "algorithms",
            "securityLevel", "systemId", "oemCryptoApiVersion",
            "maxNumberOfSessions", "numberOfOpenSessions",
            "hdcpLevel", "maxHdcpLevel",
            "privacyMode", "sessionSharing", "usageReportingSupport",
            "provisioningModel", "appId", "origin",
            "CurrentSRMVersion", "SRMUpdateSupport",
            "resourceRatingTier", "widevineCdmVersion",
        )

        private val BYTE_PROPS = listOf("deviceUniqueId", "provisioningUniqueId", "serviceCertificate")
    }
}
