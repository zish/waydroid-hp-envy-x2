/*
 * Unit tests for bt-app: everything that decides what the user sees or what
 * the app trusts, without a socket, a Context or a radio. Run by tests/run.sh;
 * see tests/kotlin/Harness.kt for how and with what limits.
 *
 * The JSON fed in is shaped the way artifacts/bluetooth/waydroid-btd writes
 * it -- its Client.fail() reply and its ProfilePublisher dict -- so these
 * check the app against the daemon it actually talks to.
 */
package com.systemhalted.bluetooth

import org.json.JSONArray
import org.json.JSONObject
import testharness.suite
import java.io.ByteArrayInputStream
import java.security.cert.CertificateException
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

private fun dev(vararg pairs: Pair<String, Any?>) = JSONObject().apply {
    for ((k, v) in pairs) put(k, v ?: JSONObject.NULL)
}

/* A self-signed P-256 certificate made for this test with openssl, and its
 * SHA-256 as `openssl x509 -fingerprint -sha256` prints it with the colons
 * removed -- the same form waydroid-btd's cert_fingerprint() publishes. */
private const val CERT_PEM = """-----BEGIN CERTIFICATE-----
MIIBjzCCATWgAwIBAgIUAaSh4mxZTemxkUhDskIVSH9y08UwCgYIKoZIzj0EAwIw
HDEaMBgGA1UEAwwRd2F5ZHJvaWQtYnRkLXRlc3QwIBcNMjYxMDE3MjEzNTA0WhgP
MjEyNjA5MjMyMTM1MDRaMBwxGjAYBgNVBAMMEXdheWRyb2lkLWJ0ZC10ZXN0MFkw
EwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE42Ybncl/TCyCcNnTYw6Kgc9P9qKKnKDI
8rMvKy+3oqm+r6mPb82APGDSAWEuIHQO7FKwN9PAjhUZCpHKNJVzb6NTMFEwHQYD
VR0OBBYEFCN3Ku3WNx28z8yMSN81CoFNO+jaMB8GA1UdIwQYMBaAFCN3Ku3WNx28
z8yMSN81CoFNO+jaMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIg
Vy5mHVrL9/eqhRiBdahc+DW/B8ds5odi7rhG14HMtOUCIQCKyl3GQvHoyzWKFEnC
lDHQ0NsNxE1C0mPTqa6uVokPtA==
-----END CERTIFICATE-----
"""
private const val CERT_SHA256 =
    "21119b71cbdec4df7e8b7b3614bfde9ed2779001d1bd08b17699aa61bab6718b"

private fun cert(): X509Certificate =
    CertificateFactory.getInstance("X.509")
        .generateCertificate(ByteArrayInputStream(CERT_PEM.toByteArray())) as X509Certificate

fun main() = suite("bt-app") {

    // ---- ApiVersion ------------------------------------------------------

    test("the app declares its range in the auth message") {
        val auth = ApiVersion.declare(JSONObject().put("token", "t"))
        assertEquals(ApiVersion.MIN, auth.getInt("api_min"))
        assertEquals(ApiVersion.MAX, auth.getInt("api_max"))
        assertTrue(ApiVersion.MIN in 1..ApiVersion.MAX)
    }

    test("an ordinary auth reply is not a mismatch") {
        val ok = JSONObject().put("ok", true).put("api", 1).put("id", 0)
        assertNull(ApiVersion.Mismatch.from(ok))
        val otherError = JSONObject().put("ok", false).put("error", "bad token")
        assertNull(ApiVersion.Mismatch.from(otherError))
    }

    test("app_too_new blames the host and offers no app link") {
        // Exactly what waydroid-btd's Client.fail() sends.
        val reply = JSONObject()
            .put("ok", false).put("error", "no common API version")
            .put("err", "api_unsupported").put("reason", "app_too_new")
            .put("daemon", JSONObject().put("api_min", 1).put("api_max", 1)
                .put("package", "waydroid-ext-btd").put("version", "1.2.0"))
            .put("app", JSONObject().put("api_min", 2).put("api_max", 3))
            .put("id", 0)
        val m = assertNotNull(ApiVersion.Mismatch.from(reply))
        assertTrue(m.hostIsBehind)
        assertEquals("Host service is too old", m.title())
        assertNull(m.actionLabel())
        assertEquals(2, m.appMin); assertEquals(3, m.appMax)
        assertEquals(1, m.daemonMin); assertEquals(1, m.daemonMax)
        assertTrue("sudo dnf upgrade waydroid-ext-btd" in m.detail())
        assertTrue("daemon 1.2.0 speaks 1–1" in m.detail())
    }

    test("app_too_old blames the app and offers the update") {
        val reply = JSONObject().put("err", "api_unsupported")
            .put("reason", "app_too_old")
            .put("daemon", JSONObject().put("api_min", 4).put("api_max", 5))
        val m = assertNotNull(ApiVersion.Mismatch.from(reply))
        assertFalse(m.hostIsBehind)
        assertEquals("This app is too old", m.title())
        assertEquals("Get the latest app", m.actionLabel())
        // A daemon that omits package/version still yields usable advice.
        assertTrue("daemon speaks 4–5" in m.detail())
    }

    test("an unknown reason is reported as an app bug, not guessed at") {
        val m = assertNotNull(ApiVersion.Mismatch.from(
            JSONObject().put("err", "api_unsupported").put("reason", "app_range_invalid")))
        assertEquals("Cannot agree a protocol version", m.title())
        assertTrue("bug in the app" in m.detail())
        // No "app" object: the range falls back to what this build declares.
        assertEquals(ApiVersion.MIN, m.appMin)
        assertEquals(ApiVersion.MAX, m.appMax)
    }

    // ---- Devices ---------------------------------------------------------

    test("title prefers alias, then name, then address") {
        assertEquals("Desk", Devices.title(dev("alias" to "Desk", "name" to "K380", "addr" to "AA")))
        assertEquals("K380", Devices.title(dev("alias" to "", "name" to "K380", "addr" to "AA")))
        assertEquals("AA:BB", Devices.title(dev("addr" to "AA:BB")))
        assertEquals("unknown", Devices.title(dev()))
        // BlueZ properties the daemon could not read arrive as JSON null.
        assertEquals("AA:BB", Devices.title(dev("alias" to null, "name" to null, "addr" to "AA:BB")))
    }

    test("a device named after its own address is anonymous") {
        // BlueZ aliases a nameless device as its address with dashes.
        assertTrue(Devices.isAnonymous(dev("alias" to "aa-bb-cc-dd-ee-ff", "addr" to "AA:BB:CC:DD:EE:FF")))
        assertFalse(Devices.isAnonymous(dev("alias" to "S24 Ultra", "addr" to "AA:BB:CC:DD:EE:FF")))
        assertFalse(Devices.isAnonymous(dev()))
    }

    test("subtitle lists state, battery, flags, signal and address in order") {
        val d = dev("connected" to true, "paired" to true, "battery" to 80,
            "trusted" to true, "rssi" to -60, "addr" to "AA:BB")
        assertEquals("Connected · battery 80% · trusted · -60 dBm · AA:BB", Devices.subtitle(d))
        assertEquals("Paired · AA:BB", Devices.subtitle(dev("paired" to true, "addr" to "AA:BB")))
        assertEquals("blocked · AA:BB", Devices.subtitle(dev("blocked" to true, "addr" to "AA:BB")))
    }

    test("glyph by icon, else by pairing") {
        assertEquals("🎧", Devices.glyph(dev("icon" to "audio-headset")))
        assertEquals("⌨", Devices.glyph(dev("icon" to "input-keyboard")))
        assertEquals("🔷", Devices.glyph(dev("icon" to "no-such-icon", "paired" to true)))
        assertEquals("○", Devices.glyph(dev()))
    }

    test("service names come from the 16-bit UUID prefix, case-insensitively") {
        assertEquals("audio output", Devices.serviceName("0000110B-0000-1000-8000-00805F9B34FB"))
        assertEquals("keyboard or mouse", Devices.serviceName("00001124-0000-1000-8000-00805f9b34fb"))
        assertEquals("a service", Devices.serviceName("deadbeef-0000-1000-8000-00805f9b34fb"))
        assertEquals("a service", Devices.serviceName(null))
        assertEquals("a service", Devices.serviceName("1124"))
    }

    test("available devices: named first, then strongest, then by title") {
        val list = listOf(
            dev("alias" to "aa-aa-aa-aa-aa-aa", "addr" to "AA:AA:AA:AA:AA:AA", "rssi" to -30),
            dev("alias" to "zeta", "addr" to "1", "rssi" to -70),
            dev("alias" to "Alpha", "addr" to "2", "rssi" to -70),
            dev("alias" to "near", "addr" to "3", "rssi" to -40),
            dev("alias" to "silent", "addr" to "4"),   // no rssi sorts last
        ).sortedWith { a, b -> Devices.compareAvailable(a, b) }
        assertEquals(listOf("near", "Alpha", "zeta", "silent", "aa-aa-aa-aa-aa-aa"),
            list.map { Devices.title(it) })
    }

    test("paired devices: connected first, then by title") {
        val list = listOf(
            dev("alias" to "b"), dev("alias" to "A"),
            dev("alias" to "z", "connected" to true),
        ).sortedWith { a, b -> Devices.comparePaired(a, b) }
        assertEquals(listOf("z", "A", "b"), list.map { Devices.title(it) })
    }

    // ---- Profile ---------------------------------------------------------

    test("the profile the daemon publishes parses as published") {
        // ProfilePublisher's dict, with TLS off: pin is None, so JSON null.
        val json = JSONObject()
            .put("api_min", 1).put("api_max", 1)
            .put("host_package", "waydroid-ext-btd").put("host_package_version", "1.2.0")
            .put("version", 1).put("host", "192.168.240.1").put("port", 7712)
            .put("tls", false).put("pin", JSONObject.NULL).put("token", "abc")
        val p = Profile.parse(json, "published by the host")
        assertEquals("192.168.240.1", p.host)
        assertEquals(7712, p.port)
        assertEquals("abc", p.token)
        assertFalse(p.tls)
        assertNull(p.pin)
        assertEquals("192.168.240.1:7712 · plaintext · published by the host", p.describe())
    }

    test("a sparse profile falls back to the bridge defaults") {
        val p = Profile.parse(JSONObject().put("tls", true).put("pin", CERT_SHA256), "x")
        assertEquals("192.168.240.1", p.host)
        assertEquals(7712, p.port)
        assertEquals(CERT_SHA256, p.pin)
        assertTrue(p.describe().contains("TLS"))
    }

    // ---- certificate pinning --------------------------------------------

    test("the pinned certificate is trusted, in either case") {
        BtClient.Pinned(CERT_SHA256).checkServerTrusted(arrayOf(cert()), "ECDHE_ECDSA")
        BtClient.Pinned(CERT_SHA256.uppercase()).checkServerTrusted(arrayOf(cert()), "ECDHE_ECDSA")
    }

    test("any other certificate is refused") {
        val wrong = "0".repeat(64)
        assertFailsWith<CertificateException> {
            BtClient.Pinned(wrong).checkServerTrusted(arrayOf(cert()), "ECDHE_ECDSA")
        }
        // A truncated pin is not a prefix match.
        assertFailsWith<CertificateException> {
            BtClient.Pinned(CERT_SHA256.substring(0, 32)).checkServerTrusted(arrayOf(cert()), "x")
        }
    }

    test("an empty chain is refused even with no pin") {
        assertFailsWith<CertificateException> {
            BtClient.Pinned(null).checkServerTrusted(emptyArray(), "x")
        }
    }

    test("no pin trusts what it is shown -- the documented hand-entered case") {
        BtClient.Pinned(null).checkServerTrusted(arrayOf(cert()), "x")
        BtClient.Pinned("").checkServerTrusted(arrayOf(cert()), "x")
    }

    test("this side never acts as a TLS server") {
        assertFailsWith<CertificateException> {
            BtClient.Pinned(CERT_SHA256).checkClientTrusted(arrayOf(cert()), "x")
        }
        assertEquals(0, BtClient.Pinned(CERT_SHA256).acceptedIssuers.size)
    }

    // A JSONArray import is kept honest by one use: the daemon's state
    // snapshot carries devices as an array, and Devices reads its members.
    test("devices read out of a state snapshot array") {
        val arr = JSONArray().put(dev("alias" to "K380", "addr" to "1"))
        assertEquals("K380", Devices.title(arr.getJSONObject(0)))
    }
}
