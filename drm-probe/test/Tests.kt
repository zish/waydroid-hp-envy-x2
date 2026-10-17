/*
 * Unit tests for drm-probe: the part of the report that does not need a CDM.
 * Run by tests/run.sh; see tests/kotlin/Harness.kt for how and with what limits.
 *
 * The probe is almost all MediaDrm calls, and on the JVM every one of those
 * throws "Stub!". What is left, and tested here, is what the report says about
 * what it was given: which schemes and properties it asks about, how it names
 * a security or HDCP level, how it prints bytes, and how it prints a throw --
 * which docs/21 relies on, because a throw is the RESULT the probe was written
 * to capture.
 *
 * Where the goldens come from, so none of them is the code grading itself:
 *  - the Widevine UUID and its 64-bit halves: docs/21, quoting this machine's
 *    own logcat (`DrmHalAidl: uuid=[edef8ba979d64ace a3c827dcd51d21ed]`);
 *  - ClearKey and PlayReady: the DASH-IF content-protection system ID registry
 *    (dashif.org/identifiers/content_protection), and for ClearKey also the
 *    byte array AOSP's clearkey plugin matches on (ClearKeyUUID.cpp);
 *  - security and HDCP level numbers: the MediaDrm API reference, written out
 *    as literals rather than read back through the constants under test;
 *  - the exception rendering: docs/21's recorded report line
 *    `openSession()  FAILED -> NotProvisionedException: ERROR_DRM_NOT_PROVISIONED`.
 */
package com.systemhalted.drmprobe

import android.media.MediaDrm
import testharness.suite
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/* Same simple name as android.media.NotProvisionedException, whose stub
 * constructor throws on the JVM. describe() prints only the simple name and
 * the message, so this renders exactly as the real one did on the device. */
private class NotProvisionedException(msg: String) : Exception(msg)

private fun bytesOf(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }

fun main() = suite("drm-probe") {

    // ---- the schemes probed ----------------------------------------------

    test("the probe asks about Widevine, ClearKey and PlayReady, in that order") {
        assertEquals(listOf("Widevine", "ClearKey", "PlayReady"),
            MainActivity.SCHEMES.map { it.first })
    }

    test("Widevine's UUID is the one this machine's DrmHal logged") {
        val uuid = MainActivity.SCHEMES.toMap().getValue("Widevine")
        assertEquals(UUID.fromString("edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"), uuid)
        // DrmHal prints the UUID as its two 64-bit halves; docs/21 quotes it
        // verbatim. A typo'd constant would probe a scheme nobody registers
        // and report "false" for Widevine, which is exactly the wrong answer.
        assertEquals("edef8ba979d64ace", "%016x".format(uuid.mostSignificantBits))
        assertEquals("a3c827dcd51d21ed", "%016x".format(uuid.leastSignificantBits))
    }

    test("ClearKey's UUID is the DASH-IF one AOSP's clearkey plugin accepts") {
        val uuid = MainActivity.SCHEMES.toMap().getValue("ClearKey")
        // ClearKeyUUID.cpp's kClearKeyUUID, byte for byte. (The W3C common
        // PSSH ID 1077efec-... is the other one it accepts; the probe uses
        // this one, which is what MediaDrm clients conventionally pass.)
        val aosp = bytesOf(0xe2, 0x71, 0x9d, 0x58, 0xa9, 0x85, 0xb3, 0xc9,
            0x78, 0x1a, 0xb0, 0x30, 0xaf, 0x78, 0xd3, 0x0e)
        val bytes = java.nio.ByteBuffer.allocate(16)
            .putLong(uuid.mostSignificantBits).putLong(uuid.leastSignificantBits).array()
        assertTrue(aosp.contentEquals(bytes), "got ${bytes.joinToString("") { "%02x".format(it) }}")
    }

    test("PlayReady's UUID is the DASH-IF registered system ID") {
        assertEquals(UUID.fromString("9a04f079-9840-4286-ab92-e65be0885f95"),
            MainActivity.SCHEMES.toMap().getValue("PlayReady"))
    }

    // ---- the properties probed -------------------------------------------

    test("the four documented string properties lead the list, by their API names") {
        // MainActivity's comment says "the first four are the documented
        // MediaDrm.PROPERTY_* constants". Check that against the SDK.
        assertEquals(listOf(MediaDrm.PROPERTY_VENDOR, MediaDrm.PROPERTY_VERSION,
            MediaDrm.PROPERTY_DESCRIPTION, MediaDrm.PROPERTY_ALGORITHMS),
            MainActivity.STRING_PROPS.take(4))
        assertEquals(MediaDrm.PROPERTY_DEVICE_UNIQUE_ID, MainActivity.BYTE_PROPS.first())
    }

    test("every property docs/21's table reports is still asked for") {
        // The Widevine-vs-ClearKey table in docs/21 is the probe's evidence
        // that -1010 is ClearKey's; dropping one of its rows loses that.
        for (p in listOf("vendor", "version", "description", "securityLevel", "systemId",
            "maxNumberOfSessions", "provisioningModel", "hdcpLevel", "maxHdcpLevel")) {
            assertTrue(p in MainActivity.STRING_PROPS, "missing $p")
        }
        assertEquals(MainActivity.STRING_PROPS.size, MainActivity.STRING_PROPS.toSet().size)
    }

    // ---- security levels -------------------------------------------------

    test("security levels are named by their API numbers, L3 and L1 marked") {
        assertEquals("UNKNOWN", level(0))
        assertEquals("SW_SECURE_CRYPTO (L3)", level(1))
        assertEquals("SW_SECURE_DECODE", level(2))
        assertEquals("HW_SECURE_CRYPTO", level(3))
        assertEquals("HW_SECURE_DECODE", level(4))
        assertEquals("HW_SECURE_ALL (L1)", level(5))
    }

    test("an unknown security level is shown raw, not guessed") {
        assertEquals("?(6)", level(6))
        assertEquals("?(-1)", level(-1))
    }

    test("each level probed with isCryptoSchemeSupported is labelled as level() names it") {
        // Two lists name the same levels; a mismatched pair would print one
        // level's label against another level's answer.
        for ((label, v) in MainActivity.SECURITY_LEVELS) {
            assertTrue(level(v).startsWith(label), "$label -> ${level(v)}")
        }
        assertEquals(listOf(1, 2, 5), MainActivity.SECURITY_LEVELS.map { it.second })
    }

    // ---- HDCP levels -----------------------------------------------------

    test("HDCP levels are named by their API numbers") {
        assertEquals("UNKNOWN", hdcp(0))
        assertEquals("NONE", hdcp(1))
        assertEquals("V1", hdcp(2))
        assertEquals("V2", hdcp(3))
        assertEquals("V2_1", hdcp(4))
        assertEquals("V2_2", hdcp(5))
        assertEquals("V2_3", hdcp(6))
        // Not 7: the API puts NO_DIGITAL_OUTPUT at Integer.MAX_VALUE.
        assertEquals("NO_DIGITAL_OUTPUT", hdcp(Int.MAX_VALUE))
        assertEquals("?(7)", hdcp(7))
    }

    // ---- byte[] properties -----------------------------------------------

    test("bytes print as lowercase hex with their count, high bit unsigned") {
        // 0x80 and 0xff are negative as a Kotlin Byte; they must not print
        // sign-extended as ffffff80.
        assertEquals("(4 bytes) 007f80ff", hex(bytesOf(0x00, 0x7f, 0x80, 0xff)))
    }

    test("null and empty byte arrays are distinguishable") {
        // A plugin returning null and one returning nothing are different
        // answers; the report must not merge them.
        assertEquals("null", hex(null))
        assertEquals("(0 bytes) ", hex(ByteArray(0)))
    }

    test("hex stops at 32 bytes and says so, but still reports the true size") {
        val exactly32 = ByteArray(32) { 0xab.toByte() }
        assertEquals("(32 bytes) " + "ab".repeat(32), hex(exactly32))
        val cert = ByteArray(3058) { 0xcd.toByte() }   // docs/21's device certificate size
        assertEquals("(3058 bytes) " + "cd".repeat(32) + "...", hex(cert))
    }

    // ---- rendering a call's outcome ----------------------------------------

    test("a throw renders as docs/21 recorded it") {
        assertEquals("NotProvisionedException: ERROR_DRM_NOT_PROVISIONED",
            describe(NotProvisionedException("ERROR_DRM_NOT_PROVISIONED")))
    }

    test("tryOf renders a value, a null, and a throw, and never propagates") {
        assertEquals("16", tryOf { 16 })
        assertEquals("true", tryOf { true })
        assertEquals("null", tryOf { null })
        assertEquals("THREW IllegalStateException: boom",
            tryOf { throw IllegalStateException("boom") })
        // An Error too: catching Throwable is what keeps one plugin's crash
        // from costing the other twenty properties.
        assertEquals("THREW NoSuchMethodError: gone", tryOf { throw NoSuchMethodError("gone") })
    }

    test("tryOf contains a real MediaDrm call that fails") {
        // On the JVM the stub throws, standing in for a plugin that does:
        // the call is guarded and its failure becomes a report line.
        val r = tryOf { MediaDrm.isCryptoSchemeSupported(MainActivity.SCHEMES[0].second) }
        assertTrue(r.startsWith("THREW RuntimeException: Stub!"), r)
    }

    // ---- report layout -----------------------------------------------------

    test("section headers are padded with '=' to 72 columns") {
        assertEquals("=== x " + "=".repeat(66), ruleLine("x"))
        val wv = ruleLine("Widevine  edef8ba9-79d6-4ace-a3c8-27dcd51d21ed")
        assertEquals(72, wv.length)
        assertTrue(wv.startsWith("=== Widevine  edef8ba9-79d6-4ace-a3c8-27dcd51d21ed ="))
    }

    test("a header longer than the rule is kept whole, not cut") {
        val long = "t".repeat(80)
        assertEquals("=== $long ", ruleLine(long))
        assertFalse(ruleLine(long).endsWith("="))
    }
}
