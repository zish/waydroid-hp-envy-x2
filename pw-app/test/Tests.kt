/*
 * Unit tests for pw-app: everything that decides what the user sees, what a
 * slider sends, or what the app trusts, without a socket, a Context or a
 * PipeWire graph. Run by tests/run.sh; see tests/kotlin/Harness.kt for how and
 * with what limits.
 *
 * The JSON fed in is shaped the way artifacts/pipewire/waydroid-pwd writes it
 * -- its Graph._project_* allow-lists (which send an absent property as JSON
 * null, never as a missing key), Graph._controls, Client.fail() with the
 * cmd_auth refusal, and the ProfileWriter payload in main() -- and the property
 * values are the ones docs/56 measured on bigtab01, so these check the app
 * against the daemon it actually talks to.
 *
 * Every number a ControlSpec test expects is derived by hand in the comment
 * beside it from the range table in Controls.kt and the formula it documents,
 * not read back from a run.
 */
package com.systemhalted.patchbay

import org.json.JSONArray
import org.json.JSONObject
import testharness.suite
import java.io.ByteArrayInputStream
import java.security.cert.CertificateException
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.Locale
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** A projection: every pair is put, and a Kotlin null becomes JSON null. */
private fun obj(vararg pairs: Pair<String, Any?>) = JSONObject().apply {
    for ((k, v) in pairs) put(k, v ?: JSONObject.NULL)
}

private fun arr(vararg items: Any) = JSONArray().apply { for (i in items) put(i) }

/*
 * The six-band EQ of artifacts/pipewire/eq6-sink.conf.example as
 * Graph._controls projects it: per band Freq/Q/Gain plus the six biquad
 * coefficient ports, the latter flagged readonly because they are in the
 * daemon's COEFFICIENT_PORTS. docs/56 measured this node at "18 adjustable
 * controls out of 54 keys".
 */
private val EQ6_FREQS = doubleArrayOf(100.0, 250.0, 800.0, 2500.0, 6000.0, 10000.0)
private val COEFFICIENT_PORTS = listOf("b0", "b1", "b2", "a0", "a1", "a2")

private fun eq6Controls(): JSONArray {
    val out = JSONArray()
    for ((i, freq) in EQ6_FREQS.withIndex()) {
        val filter = "eq_band_${i + 1}"
        val ports = listOf("Freq" to freq, "Q" to 1.0, "Gain" to 0.0) +
            COEFFICIENT_PORTS.map { it to 0.5 }
        for ((port, value) in ports) {
            out.put(obj("key" to "$filter:$port", "filter" to filter, "port" to port,
                "value" to value, "readonly" to (port in COEFFICIENT_PORTS)))
        }
    }
    return out
}

/*
 * A graph snapshot as the daemon's `ready` event carries it, built from what
 * docs/56 measured: two driver nodes with no media.class and no ports, a sink
 * with two playback ports and a monitor, the container's pipewire-pulse
 * client (application.name=Waydroid, process.host=waydroid, binary
 * threaded-ml) owning a stream node (node 65 -> client 62, the pacat check),
 * WirePlumber's client, a link, and the `settings` metadata.
 */
private const val SINK = "alsa_output.pci-0000_00_1b.0.analog-stereo"

private fun node(id: Int, vararg pairs: Pair<String, Any?>): JSONObject {
    val o = obj("id" to id, "kind" to "node", "name" to null, "description" to null,
        "nick" to null, "media_class" to null, "media_role" to null, "serial" to null,
        "state" to null, "in_ports" to null, "out_ports" to null, "device" to null,
        "client" to null, "app_name" to null, "app_host" to null)
    for ((k, v) in pairs) o.put(k, v ?: JSONObject.NULL)
    return o
}

private fun port(id: Int, node: Int?, direction: String, name: String?, monitor: Boolean = false) =
    obj("id" to id, "kind" to "port", "node" to node, "direction" to direction,
        "name" to name, "alias" to null, "channel" to null, "dsp" to null,
        "physical" to false, "terminal" to false, "monitor" to monitor)

private fun client(id: Int, vararg pairs: Pair<String, Any?>): JSONObject {
    val o = obj("id" to id, "kind" to "client", "app_name" to null, "app_binary" to null,
        "app_host" to null, "app_user" to null, "api" to null, "access" to null)
    for ((k, v) in pairs) o.put(k, v ?: JSONObject.NULL)
    return o
}

private fun snapshot() = arr(
    node(30, "name" to "Dummy-Driver"),
    node(31, "name" to "Freewheel-Driver"),
    node(56, "name" to SINK, "description" to "Built-in Audio Analog Stereo",
        "media_class" to "Audio/Sink", "state" to "suspended"),
    port(70, 56, "in", "playback_FL"),
    port(71, 56, "in", "playback_FR"),
    port(72, 56, "out", "monitor_FL", monitor = true),
    client(62, "app_name" to "Waydroid", "app_binary" to "threaded-ml",
        "app_host" to "waydroid", "app_user" to "system", "api" to "pipewire-pulse",
        "access" to "unrestricted"),
    client(40, "app_name" to "WirePlumber", "app_binary" to "wireplumber",
        "access" to "unrestricted"),
    node(65, "name" to "AudioTrack", "media_class" to "Stream/Output/Audio",
        "client" to 62, "app_name" to "Waydroid", "app_host" to "waydroid"),
    port(80, 65, "out", "output_FL"),
    obj("id" to 90, "kind" to "link", "output_node" to 65, "output_port" to 80,
        "input_node" to 56, "input_port" to 70, "state" to "active"),
    // docs/56: clock.quantum 1024, min 32, max 2048, force-quantum 0, rate 48000.
    obj("id" to 33, "kind" to "metadata", "name" to "settings",
        "entries" to obj("clock.quantum" to 1024, "clock.min-quantum" to 32,
            "clock.max-quantum" to 2048, "clock.force-quantum" to 0,
            "clock.rate" to 48000)),
    obj("id" to 34, "kind" to "metadata", "name" to "default",
        "entries" to obj("default.audio.sink" to "{\"name\":\"$SINK\"}"))
)

private fun loaded() = Graph().apply { replace(snapshot()) }

/* A self-signed P-256 certificate made for this test with openssl, and its
 * SHA-256 computed two independent ways that agree: `openssl x509
 * -fingerprint -sha256` with the colons removed, and the daemon's own
 * cert_fingerprint() -- hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem)) -- which
 * is the exact form waydroid-pwd publishes as the profile's "pin". */
private const val CERT_PEM = """-----BEGIN CERTIFICATE-----
MIIBjzCCATWgAwIBAgIUCYsqtw2lR5hsKJz8yF17ur73xjMwCgYIKoZIzj0EAwIw
HDEaMBgGA1UEAwwRd2F5ZHJvaWQtcHdkLXRlc3QwIBcNMjYxMDE3MjE0MDI0WhgP
MjEyNjA5MjMyMTQwMjRaMBwxGjAYBgNVBAMMEXdheWRyb2lkLXB3ZC10ZXN0MFkw
EwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEvuIzUdb6iONRyWqZZOvEvlicgHf9Yms+
b8LEw2rlIUsCqozu2YRkWWLQte0okDS0JkEuk/AdwMYWV9UoDYmqLqNTMFEwHQYD
VR0OBBYEFCz+iVCRgM3HTovKyJhfF9iny3AFMB8GA1UdIwQYMBaAFCz+iVCRgM3H
TovKyJhfF9iny3AFMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIg
MSTbXg9816GhXb0+sH4KugOyUQLtT3PY8qJo/fqpyQgCIQDXc58w3wDPphyDeEUu
x57FSA2Hmwkfsy8F6q50ABZrwA==
-----END CERTIFICATE-----
"""
private const val CERT_SHA256 =
    "8302e36b0a0b65a69c32868f7a7631dcd52db5042ff528b0467124dd1f65cf28"

private fun cert(): X509Certificate =
    CertificateFactory.getInstance("X.509")
        .generateCertificate(ByteArrayInputStream(CERT_PEM.toByteArray())) as X509Certificate

private const val EPS = 1e-9

fun main() = suite("pw-app") {

    // ControlSpec.format's "%.Nf" uses the default locale, so a decimal comma
    // would fail these for a reason that is not the code under test.
    Locale.setDefault(Locale.US)

    // ---- ApiVersion ------------------------------------------------------

    test("the app declares a range the shipped daemon accepts") {
        // waydroid-pwd: API_MIN = API_MAX = 1, and negotiate_api(lo, hi)
        // succeeds iff hi >= lo, lo <= API_MAX and hi >= API_MIN.
        val auth = ApiVersion.declare(JSONObject().put("id", 0).put("cmd", "auth"))
        val lo = auth.getInt("api_min")
        val hi = auth.getInt("api_max")
        assertEquals(ApiVersion.MIN, lo)
        assertEquals(ApiVersion.MAX, hi)
        assertTrue(hi >= lo && lo <= 1 && hi >= 1)
        // MAX 1 gives (1 - 2).coerceAtLeast(1): there is no API 0.
        assertEquals(1, ApiVersion.MIN)
    }

    test("the daemon's success and bad-token replies are not mismatches") {
        // cmd_auth's client.reply(...) on success.
        val ok = JSONObject().put("ok", true).put("api", 1).put("api_min", 1)
            .put("api_max", 1).put("version", 1)
            .put("policy", obj("mixer" to true, "links" to true)).put("id", 0)
        assertNull(ApiVersion.Mismatch.from(ok))
        // cmd_auth's client.fail(msg, "bad token"): no err field.
        assertNull(ApiVersion.Mismatch.from(
            JSONObject().put("ok", false).put("error", "bad token").put("id", 0)))
    }

    test("app_too_new blames the host and names its package") {
        // Exactly cmd_auth's refusal, through Client.fail().
        val reply = JSONObject()
            .put("ok", false).put("error", "no common API version")
            .put("err", "api_unsupported").put("reason", "app_too_new")
            .put("daemon", obj("api_min" to 1, "api_max" to 1,
                "package" to "waydroid-ext-pwd", "version" to "0-dev"))
            .put("app", obj("api_min" to 2, "api_max" to 3))
            .put("id", 0)
        val m = assertNotNull(ApiVersion.Mismatch.from(reply))
        assertTrue(m.hostIsBehind)
        assertEquals("Host service is too old", m.title())
        assertNull(m.actionLabel())
        assertEquals(2, m.appMin); assertEquals(3, m.appMax)
        assertEquals(1, m.daemonMin); assertEquals(1, m.daemonMax)
        assertTrue("sudo dnf upgrade waydroid-ext-pwd" in m.detail())
        assertTrue("daemon 0-dev speaks 1–1" in m.detail())
        assertTrue("sudo rpm-ostree upgrade" in m.detail())
    }

    test("app_too_old blames the app and offers the update") {
        val reply = JSONObject().put("ok", false).put("err", "api_unsupported")
            .put("reason", "app_too_old")
            .put("daemon", obj("api_min" to 4, "api_max" to 5))
        val m = assertNotNull(ApiVersion.Mismatch.from(reply))
        assertFalse(m.hostIsBehind)
        assertEquals("This app is too old", m.title())
        assertEquals("Get the latest app", m.actionLabel())
        // No package/version from the daemon: the advice still reads.
        assertTrue("daemon speaks 4–5" in m.detail())
    }

    test("app_range_invalid is reported as an app bug, not guessed at") {
        // negotiate_api's third reason, for hi < lo.
        val m = assertNotNull(ApiVersion.Mismatch.from(JSONObject()
            .put("err", "api_unsupported").put("reason", "app_range_invalid")
            .put("app", obj("api_min" to 3, "api_max" to 2))))
        assertFalse(m.hostIsBehind)
        assertEquals("Cannot agree a protocol version", m.title())
        assertTrue("bug in the app" in m.detail())
        assertTrue("protocol 3–2" in m.detail())
    }

    test("a bare refusal still yields a screen, with the app's own range") {
        // The tolerance Mismatch.from documents: an older daemon sending only err.
        val m = assertNotNull(ApiVersion.Mismatch.from(JSONObject().put("err", "api_unsupported")))
        assertEquals("unknown", m.reason)
        assertEquals(ApiVersion.MIN, m.appMin); assertEquals(ApiVersion.MAX, m.appMax)
        assertEquals(0, m.daemonMin); assertEquals(0, m.daemonMax)
        assertNull(m.hostPackage); assertNull(m.hostVersion)
    }

    // ---- Profile ---------------------------------------------------------

    test("the profile the daemon publishes parses as published") {
        // ProfileWriter's payload from main(), TLS off: pin is None -> null.
        val json = JSONObject()
            .put("api_min", 1).put("api_max", 1)
            .put("host_package", "waydroid-ext-pwd").put("host_package_version", "0-dev")
            .put("version", 1).put("host", "192.168.240.1").put("port", 7713)
            .put("tls", false).put("pin", JSONObject.NULL).put("token", "abc")
            .put("package", "com.systemhalted.patchbay")
        val p = Profile.parse(json, "published by the host")
        assertEquals("192.168.240.1", p.host)
        assertEquals(7713, p.port)
        assertEquals("abc", p.token)
        assertFalse(p.tls)
        // JSON null: json.org's optString gives the fallback, Android's gives
        // "null"; parse() maps both to no pin.
        assertNull(p.pin)
        assertEquals("192.168.240.1:7713 · plaintext · published by the host", p.describe())
    }

    test("a TLS profile carries the daemon's pin") {
        val p = Profile.parse(JSONObject().put("host", "10.0.0.5").put("port", 9000)
            .put("tls", true).put("pin", CERT_SHA256).put("token", "t"), "x")
        assertTrue(p.tls)
        assertEquals(CERT_SHA256, p.pin)
        assertEquals("10.0.0.5:9000 · TLS · x", p.describe())
        assertNull(Profile.parse(JSONObject().put("pin", ""), "x").pin)
        // What Android's optString makes of the JSON null a plaintext daemon
        // publishes; json.org never produces it, so it is spelled out here.
        assertNull(Profile.parse(JSONObject().put("pin", "null"), "x").pin)
    }

    test("a sparse profile falls back to the bridge and the daemon's port") {
        // waydroid-pwd: DEFAULT_PORT = 7713; main() assumes 192.168.240.1 when
        // waydroid0 has no address.
        assertEquals(7713, Profile.DEFAULT_PORT)
        val p = Profile.parse(JSONObject(), "x")
        assertEquals("192.168.240.1", p.host)
        assertEquals(7713, p.port)
        assertEquals("", p.token)
        assertFalse(p.tls)
        assertNull(p.pin)
    }

    // ---- certificate pinning --------------------------------------------

    test("the pinned certificate is trusted, in either case") {
        PwClient.Pinned(CERT_SHA256).checkServerTrusted(arrayOf(cert()), "ECDHE_ECDSA")
        PwClient.Pinned(CERT_SHA256.uppercase()).checkServerTrusted(arrayOf(cert()), "ECDHE_ECDSA")
    }

    test("any other certificate is refused") {
        assertFailsWith<CertificateException> {
            PwClient.Pinned("0".repeat(64)).checkServerTrusted(arrayOf(cert()), "x")
        }
        // A truncated pin is not a prefix match.
        assertFailsWith<CertificateException> {
            PwClient.Pinned(CERT_SHA256.substring(0, 32)).checkServerTrusted(arrayOf(cert()), "x")
        }
        // openssl's colon-separated display form is not the published form.
        val colons = CERT_SHA256.chunked(2).joinToString(":")
        assertFailsWith<CertificateException> {
            PwClient.Pinned(colons).checkServerTrusted(arrayOf(cert()), "x")
        }
    }

    test("an empty chain is refused even with no pin") {
        assertFailsWith<CertificateException> {
            PwClient.Pinned(null).checkServerTrusted(emptyArray(), "x")
        }
    }

    test("no pin trusts what it is shown -- the documented hand-entered case") {
        PwClient.Pinned(null).checkServerTrusted(arrayOf(cert()), "x")
        PwClient.Pinned("").checkServerTrusted(arrayOf(cert()), "x")
    }

    test("this side never acts as a TLS server") {
        assertFailsWith<CertificateException> {
            PwClient.Pinned(CERT_SHA256).checkClientTrusted(arrayOf(cert()), "x")
        }
        assertEquals(0, PwClient.Pinned(CERT_SHA256).acceptedIssuers.size)
    }

    // ---- Controls --------------------------------------------------------

    test("the six-band EQ reads as 54 controls, 18 adjustable, 6 filters") {
        val list = Controls.of(obj("id" to 84, "controls" to eq6Controls()))
        assertEquals(54, list.size)
        val adjustable = list.filter { !it.readonly }
        assertEquals(18, adjustable.size)
        assertEquals(6, adjustable.map { it.filter }.distinct().size)
        assertEquals(setOf("Freq", "Q", "Gain"), adjustable.map { it.port }.toSet())
        val f3 = list.single { it.key == "eq_band_3:Freq" }
        assertEquals("eq_band_3", f3.filter)
        assertEquals("Freq", f3.port)
        assertEquals(800.0, f3.value, EPS)
        assertFalse(f3.readonly)
        assertTrue(list.single { it.key == "eq_band_3:b0" }.readonly)
    }

    test("a node without controls has none, and keyless entries are skipped") {
        // _project_node only adds "controls" when there are some.
        assertTrue(Controls.of(node(56, "media_class" to "Audio/Sink")).isEmpty())
        val list = Controls.of(obj("controls" to arr(
            obj("key" to null, "filter" to "x", "port" to "Freq", "value" to 1.0),
            obj("key" to "b:Gain", "filter" to "b", "port" to "Gain", "value" to -3.0)
        )))
        assertEquals(listOf("b:Gain"), list.map { it.key })
        assertFalse(list[0].readonly)   // absent readonly means adjustable
    }

    // ---- ControlSpec -----------------------------------------------------

    test("only ports with a known range get a slider") {
        assertNotNull(ControlSpec.of("Freq", 1000.0))
        assertNotNull(ControlSpec.of("Delay (s)", 0.5))
        assertNotNull(ControlSpec.of("Gain 1", 1.0))
        assertNotNull(ControlSpec.of("Gain 8", 1.0))
        // Unknown to the table, or not the plugin's exact spelling.
        assertNull(ControlSpec.of("Ratio", 1.0))
        assertNull(ControlSpec.of("freq", 1000.0))
        assertNull(ControlSpec.of("Gain x", 1.0))
        assertNull(ControlSpec.of("b0", 1.0))
    }

    test("Freq is logarithmic over 20 Hz to 20 kHz") {
        // 20..20000 is three decades, so each decade is a third of 1000 steps:
        // 200 Hz -> round(333.33) = 333, 2 kHz -> round(666.67) = 667.
        val s = assertNotNull(ControlSpec.of("Freq", 800.0))
        assertEquals(20.0, s.min, EPS); assertEquals(20000.0, s.max, EPS)
        assertEquals(0, s.toProgress(20.0))
        assertEquals(333, s.toProgress(200.0))
        assertEquals(667, s.toProgress(2000.0))
        assertEquals(1000, s.toProgress(20000.0))
        // Halfway is the geometric mean, 20 * sqrt(1000) = 632.4555...
        assertEquals(20.0 * Math.sqrt(1000.0), s.fromProgress(500), 1e-6)
        // Out-of-range values pin to the ends rather than leaving the bar.
        assertEquals(0, s.toProgress(1.0))
    }

    test("Gain is linear over ±24 dB and snaps to 0 dB within 1% of the bar") {
        // Linear: (6 - -24) / 48 * 1000 = 625. 0 dB is the midpoint, 500.
        val s = assertNotNull(ControlSpec.of("Gain", 0.0))
        assertEquals(625, s.toProgress(6.0))
        assertEquals(500, s.toProgress(0.0))
        // STEPS / 100 = 10 steps either side of 500 snap to exactly 0.0.
        assertEquals(0.0, s.fromProgress(505))
        assertEquals(0.0, s.fromProgress(490))
        assertEquals(0.0, s.fromProgress(510))
        // 511 is outside: -24 + 48 * 0.511 = 0.528.
        assertEquals(0.528, s.fromProgress(511), 1e-9)
        assertEquals(-24.0, s.fromProgress(0), EPS)
        assertEquals(24.0, s.fromProgress(1000), EPS)
    }

    test("Freq and Q have no detent") {
        // docs: there is no neutral frequency, so no snapping near the middle.
        val f = assertNotNull(ControlSpec.of("Freq", 1000.0))
        assertTrue(f.fromProgress(501) > f.fromProgress(500))
        val q = assertNotNull(ControlSpec.of("Q", 1.0))
        // Q is log over 0.1..10, two decades: 1.0 sits at exactly 500.
        assertEquals(500, q.toProgress(1.0))
        assertEquals(1.0, q.fromProgress(500), 1e-12)
        assertTrue(q.fromProgress(505) > 1.0)
    }

    test("a mixer Gain N is linear 0..2 with a detent at unity") {
        val s = assertNotNull(ControlSpec.of("Gain 3", 1.0))
        assertEquals(0.0, s.min, EPS); assertEquals(2.0, s.max, EPS)
        assertEquals(500, s.toProgress(1.0))
        assertEquals(1.0, s.fromProgress(495))
        assertEquals("1.00", s.format(1.0))
    }

    test("a value outside the range widens it instead of being clamped") {
        // Gain at -30 dB: the bar becomes -30..24 and the value sits at 0.
        val g = assertNotNull(ControlSpec.of("Gain", -30.0))
        assertEquals(-30.0, g.min, EPS); assertEquals(24.0, g.max, EPS)
        assertEquals(0, g.toProgress(-30.0))
        // Freq at 25 kHz stays logarithmic: 20..25000.
        val hi = assertNotNull(ControlSpec.of("Freq", 25000.0))
        assertEquals(25000.0, hi.max, EPS)
        assertEquals(1000, hi.toProgress(25000.0))
        // Non-finite values leave the stock range alone.
        val nan = assertNotNull(ControlSpec.of("Gain", Double.NaN))
        assertEquals(-24.0, nan.min, EPS); assertEquals(24.0, nan.max, EPS)
    }

    test("a Freq at 0 demotes the slider to linear rather than breaking log") {
        // log(x / 0) is undefined. Demoted to linear 0..20000, 10 kHz is the
        // midpoint, 500; the logarithmic scale would have put it at
        // round(1000 * log(500) / log(1000)) = 900.
        val s = assertNotNull(ControlSpec.of("Freq", 0.0))
        assertEquals(0.0, s.min, EPS)
        assertEquals(500, s.toProgress(10000.0))
        assertEquals(0, s.toProgress(0.0))
    }

    test("progress round-trips through the value away from a detent") {
        val freq = assertNotNull(ControlSpec.of("Freq", 1000.0))
        val gain = assertNotNull(ControlSpec.of("Gain", 0.0))
        for (p in 0..ControlSpec.STEPS) {
            assertEquals(p, freq.toProgress(freq.fromProgress(p)), "Freq at $p")
            if (Math.abs(p - 500) > 10) {
                assertEquals(p, gain.toProgress(gain.fromProgress(p)), "Gain at $p")
            }
        }
    }

    test("readouts carry the unit, the sign where it means something, and kHz") {
        val freq = assertNotNull(ControlSpec.of("Freq", 1000.0))
        assertEquals("800 Hz", freq.format(800.0))
        assertEquals("1.00 kHz", freq.format(1000.0))
        assertEquals("12.50 kHz", freq.format(12500.0))
        val gain = assertNotNull(ControlSpec.of("Gain", 0.0))
        assertEquals("+5.5 dB", gain.format(5.5))
        assertEquals("+0.0 dB", gain.format(0.0))
        assertEquals("-2.0 dB", gain.format(-2.0))
        assertEquals("1.00", assertNotNull(ControlSpec.of("Q", 1.0)).format(1.0))
        assertEquals("0.500 s", assertNotNull(ControlSpec.of("Delay (s)", 0.5)).format(0.5))
        assertEquals("-23.0 LUFS", assertNotNull(ControlSpec.of("LUFS", -23.0)).format(-23.0))
    }

    // ---- Graph -----------------------------------------------------------

    test("a snapshot replaces everything and marks the graph ready") {
        val g = Graph()
        assertFalse(g.ready)
        g.replace(snapshot())
        assertTrue(g.ready)
        assertEquals(snapshot().length(), g.size())
        assertEquals(4, g.nodes().size)   // two drivers, the sink, the stream
        assertEquals(1, g.links().size)
        assertEquals(2, g.clients().size)
        // A second replace drops what the first had.
        g.replace(arr(node(1, "name" to "only")))
        assertEquals(1, g.size())
        assertNull(g.byId(56))
    }

    test("reset forgets every id and clears ready") {
        val g = loaded()
        g.reset()
        assertFalse(g.ready)
        assertEquals(0, g.size())
        assertNull(g.byId(56))
    }

    test("an update applies changes and removals by id") {
        val g = loaded()
        g.update(
            arr(node(56, "name" to SINK, "description" to "Renamed", "media_class" to "Audio/Sink"),
                node(99, "name" to "new", "media_class" to "Audio/Source")),
            arr(65, 1234)   // 1234 was never there; harmless
        )
        assertEquals("Renamed", g.label(assertNotNull(g.byId(56))))
        assertNotNull(g.byId(99))
        assertNull(g.byId(65))
        // An item with no id is not filed under -1.
        g.update(arr(obj("kind" to "node")), null)
        assertNull(g.byId(-1))
    }

    test("driver nodes are hidden; a classless node with ports is not") {
        val g = loaded()
        assertFalse(g.interesting(assertNotNull(g.byId(30))))   // Dummy-Driver
        assertFalse(g.interesting(assertNotNull(g.byId(31))))   // Freewheel-Driver
        assertTrue(g.interesting(assertNotNull(g.byId(56))))
        g.update(arr(node(40, "name" to "bare"), port(41, 40, "out", "out")), null)
        assertTrue(g.interesting(assertNotNull(g.byId(40))))
    }

    test("a projected JSON null never reaches the screen as \"null\"") {
        // docs/56: optString on JSON null gave "null · id 31".
        val driver = node(31, "name" to "Freewheel-Driver")
        assertNull(Graph.text(driver, "media_class"))
        assertNull(Graph.text(driver, "absent"))
        assertNull(Graph.text(obj("x" to ""), "x"))
        // json.org's optString already turns JSON null into "", so the guard
        // that matters on Android -- where it becomes the four characters
        // "null" -- is only reachable on the JVM through that literal string.
        assertNull(Graph.text(obj("media_class" to "null"), "media_class"))
        assertEquals("Freewheel-Driver", Graph.text(driver, "name"))
    }

    test("labels prefer description, then nick, then name, then id") {
        val g = Graph()
        assertEquals("Built-in Audio Analog Stereo",
            g.label(node(56, "name" to SINK, "description" to "Built-in Audio Analog Stereo")))
        assertEquals("Nick", g.label(node(1, "name" to "n", "nick" to "Nick")))
        assertEquals("Dummy-Driver", g.label(node(30, "name" to "Dummy-Driver")))
        assertEquals("node 7", g.label(node(7)))
    }

    test("nodes are sectioned by media.class") {
        val g = Graph()
        fun sec(cls: String?) = g.section(node(1, "media_class" to cls))
        assertEquals(Graph.SECTION_SINKS, sec("Audio/Sink"))
        assertEquals(Graph.SECTION_SOURCES, sec("Audio/Source"))
        assertEquals(Graph.SECTION_SOURCES, sec("Audio/Source/Virtual"))
        // Both stream directions land together: Android's stream shows up as
        // whichever direction it is playing.
        assertEquals(Graph.SECTION_STREAMS, sec("Stream/Output/Audio"))
        assertEquals(Graph.SECTION_STREAMS, sec("Stream/Input/Audio"))
        assertEquals(Graph.SECTION_MIDI, sec("Midi/Bridge"))
        assertEquals(Graph.SECTION_VIDEO, sec("Video/Source"))
        assertEquals(Graph.SECTION_OTHER, sec(null))
        assertEquals(6, Graph.SECTIONS.distinct().size)
    }

    test("a port's identity is node name and port name, never the id") {
        val g = loaded()
        assertEquals("$SINK:playback_FL", g.nameKey(70))
        assertEquals("AudioTrack:output_FL", g.nameKey(80))
        assertEquals(56, assertNotNull(g.nodeOfPort(70)).optInt("id"))
        assertNull(g.nameKey(12345))
        // A port whose node is unknown, or whose name is null, has no key.
        g.update(arr(port(81, 777, "out", "x"), port(82, 56, "in", null)), null)
        assertNull(g.nameKey(81))
        assertNull(g.nameKey(82))
    }

    test("ports are found by their owning node") {
        val g = loaded()
        assertEquals(listOf(70, 71, 72), g.portsOf(56).map { it.optInt("id") }.sorted())
        assertTrue(g.portsOf(30).isEmpty())
    }

    test("the container's client is found by its self-reported name or host") {
        val g = loaded()
        assertEquals(listOf(62), g.waydroidClients().map { it.optInt("id") })
        assertEquals("Waydroid", g.clientLabel(assertNotNull(g.byId(62))))
        // Either property alone is enough, and case does not matter.
        g.replace(arr(client(1, "app_host" to "WAYDROID"),
            client(2, "app_name" to "waydroid"),
            client(3, "app_binary" to "pw-cat")))
        assertEquals(listOf(1, 2), g.waydroidClients().map { it.optInt("id") }.sorted())
        assertEquals("pw-cat", g.clientLabel(assertNotNull(g.byId(3))))
        assertEquals("client 4", g.clientLabel(client(4)))
    }

    test("a client's streams are the nodes carrying its client id") {
        val g = loaded()
        assertEquals(listOf(65), g.nodesOfClient(62).map { it.optInt("id") })
        // WirePlumber owns nothing in this snapshot.
        assertTrue(g.nodesOfClient(40).isEmpty())
    }

    test("settings are read from the settings metadata, not another") {
        val g = loaded()
        assertEquals("1024", g.setting("clock.quantum"))
        assertEquals("32", g.setting("clock.min-quantum"))
        assertEquals("0", g.setting("clock.force-quantum"))
        assertEquals("48000", g.setting("clock.rate"))
        assertNull(g.setting("default.audio.sink"))   // lives in "default"
        assertNull(g.setting("no.such.key"))
        assertEquals("default", Graph.text(assertNotNull(g.metadata("default")), "name"))
        assertNull(Graph().setting("clock.quantum"))
    }

    test("a setting present with a JSON null value is absent, not \"null\"") {
        val g = Graph()
        g.replace(arr(obj("id" to 33, "kind" to "metadata", "name" to "settings",
            "entries" to JSONObject().put("clock.quantum", JSONObject.NULL)
                .put("clock.rate", 48000))))
        assertNull(g.setting("clock.quantum"))
        assertEquals("48000", g.setting("clock.rate"))
    }

    // ---- the "Set…" dialog's round trip -----------------------------------

    test("a pre-filled control value parses back in a decimal-comma locale") {
        // German writes 0,5; Arabic writes its own digits. The dialog fills
        // the field with editText() and Set reads it with parseEntry(): a
        // user who changes nothing must get the value back.
        for (locale in listOf(Locale.GERMANY, Locale.FRANCE, Locale.forLanguageTag("ar-EG"), Locale.US)) {
            Locale.setDefault(locale)
            try {
                for (v in listOf(0.5, -12.25, 1024.0, 0.0001, -0.0)) {
                    assertEquals(v, assertNotNull(Controls.parseEntry(Controls.editText(v)), "$locale $v"), EPS)
                }
            } finally { Locale.setDefault(Locale.US) }
        }
    }

    test("a typed decimal comma is accepted, and garbage is still refused") {
        assertEquals(0.5, assertNotNull(Controls.parseEntry(" 0,5 ")), EPS)
        assertEquals(-3.0, assertNotNull(Controls.parseEntry("-3")), EPS)
        for (bad in listOf("", "abc", "1,2,3", "1.2.3")) assertNull(Controls.parseEntry(bad), bad)
    }

    // ---- the profile dialog ------------------------------------------------

    test("a hand-entered profile keeps TLS and its pin") {
        val p = Profile.entered(" 10.0.0.5 ", "7713", " tok ", true, " $CERT_SHA256 ")
        assertEquals("10.0.0.5", p.host)
        assertEquals(7713, p.port)
        assertEquals("tok", p.token)
        assertTrue(p.tls)
        assertEquals(CERT_SHA256, p.pin)
        assertEquals("entered by hand", p.source)
    }

    test("a hand-entered profile defaults a bad port and a blank pin") {
        val p = Profile.entered("h", "seventy", "t", false, "  ")
        assertEquals(Profile.DEFAULT_PORT, p.port)
        assertFalse(p.tls)
        assertNull(p.pin)
    }
}
