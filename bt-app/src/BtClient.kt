package lan.syshlt.bluetooth

import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.InetSocketAddress
import java.net.Socket
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/**
 * The wire to waydroid-btd: newline-delimited JSON over one long-lived socket.
 *
 * Three threads, and each has a reason:
 *
 *   btd-io    owns the socket lifecycle and blocks on readLine(). It also does
 *             the reconnect backoff, so a daemon restart, or a container that
 *             came up before the host daemon did, heals by itself.
 *   btd-tx    drains the outbox. Sends cannot happen on the caller's thread,
 *             because the caller is the UI thread and Android throws
 *             NetworkOnMainThreadException for a socket write there.
 *   (caller)  every callback is posted back to the main looper, so the Activity
 *             never has to think about threads.
 *
 * TLS, when the profile asks for it, is pinned to the daemon's certificate
 * rather than validated against a CA. There is no name to verify on a bridge
 * address and no CA to verify against, so a SHA-256 of the exact certificate
 * the daemon generated is both simpler and stronger.
 */
class BtClient(private val profile: Profile, private val listener: Listener) {

    interface Listener {
        fun onConnected()
        fun onDisconnected(reason: String)
        fun onEvent(event: JSONObject)
        fun onReply(id: Int, reply: JSONObject)
    }

    private val main = Handler(Looper.getMainLooper())
    private val outbox = LinkedBlockingQueue<String>()
    private val nextId = AtomicInteger(1)

    @Volatile private var running = false
    @Volatile private var socket: Socket? = null

    @Volatile var connected = false
        private set

    fun start() {
        if (running) return
        running = true
        Thread({ loop() }, "btd-io").apply { isDaemon = true }.start()
        Thread({ writer() }, "btd-tx").apply { isDaemon = true }.start()
    }

    fun stop() {
        running = false
        outbox.offer(WAKE)
        closeSocket()
    }

    /** Queue a command; returns the id its reply will carry. */
    fun send(command: String, build: (JSONObject) -> Unit = {}): Int {
        val id = nextId.getAndIncrement()
        val msg = JSONObject()
        msg.put("id", id)
        msg.put("cmd", command)
        build(msg)
        outbox.offer(msg.toString())
        return id
    }

    // ---- threads ---------------------------------------------------------

    private fun loop() {
        var backoff = 1000L
        while (running) {
            try {
                val sock = open()
                socket = sock
                backoff = 1000L
                val reader = BufferedReader(InputStreamReader(sock.getInputStream()))
                // The token goes first, and deliberately not through send():
                // nothing else is accepted until it lands, so queuing it behind
                // whatever the UI asked for would deadlock a fresh connection.
                writeLine(
                    sock,
                    JSONObject().put("id", 0).put("cmd", "auth")
                        .put("token", profile.token).toString()
                )
                connected = true
                main.post { listener.onConnected() }
                while (running) {
                    val line = reader.readLine() ?: break
                    if (line.isBlank()) continue
                    val msg = try {
                        JSONObject(line)
                    } catch (exc: Exception) {
                        continue
                    }
                    dispatch(msg)
                }
                report("the host daemon closed the connection")
            } catch (exc: Exception) {
                report(exc.message ?: exc.javaClass.simpleName)
            }
            closeSocket()
            if (!running) break
            try {
                Thread.sleep(backoff)
            } catch (exc: InterruptedException) {
                break
            }
            backoff = minOf(backoff * 2, 15000L)
        }
    }

    private fun dispatch(msg: JSONObject) {
        if (msg.has("ev")) {
            main.post { listener.onEvent(msg) }
        } else {
            val id = msg.optInt("id", -1)
            main.post { listener.onReply(id, msg) }
        }
    }

    private fun writer() {
        while (running) {
            val line = try {
                outbox.take()
            } catch (exc: InterruptedException) {
                return
            }
            if (!running) return
            if (line.isEmpty()) continue
            val sock = socket
            if (sock == null || !connected) {
                // Dropped on purpose rather than buffered: the Activity asks
                // for a full `state` on every reconnect, so a command issued
                // while the socket was down would only ever apply to a picture
                // the user is no longer looking at.
                continue
            }
            try {
                writeLine(sock, line)
            } catch (exc: Exception) {
                closeSocket()
            }
        }
    }

    private fun writeLine(sock: Socket, line: String) {
        val out = sock.getOutputStream()
        out.write((line + "\n").toByteArray(Charsets.UTF_8))
        out.flush()
    }

    private fun report(reason: String) {
        connected = false
        // A socket we closed ourselves is not a disconnection. stop() clears
        // `running` before closing, so this suppresses the callback that would
        // otherwise follow every deliberate teardown -- which had the tile
        // caching "Host daemon unreachable" every time the shade closed, and
        // then painting it on the next pull-down.
        if (!running) return
        main.post { listener.onDisconnected(reason) }
    }

    private fun closeSocket() {
        connected = false
        val sock = socket
        socket = null
        try {
            sock?.close()
        } catch (exc: Exception) {
            // already gone
        }
    }

    // ---- transport -------------------------------------------------------

    private fun open(): Socket {
        val raw = Socket()
        raw.connect(InetSocketAddress(profile.host, profile.port), 5000)
        raw.tcpNoDelay = true
        raw.keepAlive = true
        // No SO_TIMEOUT: this connection is idle by design between events, and
        // a read timeout would tear down a perfectly good socket every time
        // nobody touched the radio for a while.
        if (!profile.tls) return raw
        val context = SSLContext.getInstance("TLSv1.2")
        context.init(null, arrayOf<TrustManager>(Pinned(profile.pin)), null)
        val tls = context.socketFactory
            .createSocket(raw, profile.host, profile.port, true) as SSLSocket
        tls.startHandshake()
        return tls
    }

    /**
     * Trusts exactly one certificate, by SHA-256 of its DER encoding.
     *
     * An empty pin trusts whatever it is shown, which is only reachable from a
     * hand-entered profile -- the daemon always publishes a fingerprint
     * alongside the token when TLS is on.
     */
    private class Pinned(private val pin: String?) : X509TrustManager {

        override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) {
            throw CertificateException("this side is the client")
        }

        override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
            if (chain.isEmpty()) throw CertificateException("empty certificate chain")
            if (pin == null || pin.isEmpty()) return
            val digest = MessageDigest.getInstance("SHA-256").digest(chain[0].encoded)
            val hex = StringBuilder(digest.size * 2)
            for (byte in digest) hex.append(String.format("%02x", byte))
            if (!hex.toString().equals(pin, ignoreCase = true)) {
                throw CertificateException(
                    "certificate does not match the pinned fingerprint"
                )
            }
        }

        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }

    private companion object {
        /** Queued only to wake the writer out of take() when stopping. */
        const val WAKE = ""
    }
}
