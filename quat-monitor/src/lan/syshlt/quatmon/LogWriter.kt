package lan.syshlt.quatmon

import android.util.Log
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStreamWriter
import java.io.Writer
import java.util.Locale
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.zip.GZIPOutputStream

/*
 * Writes the sample stream to disk on its own thread.
 *
 * WHY A QUEUE THAT DROPS
 *
 * The sampler must never block on disk. Waydroid's /data lives on the host's
 * LUKS volume and an fsync there can stall for tens of milliseconds; if that
 * back-pressure reached the sensor callback it would distort the very timing
 * the log exists to measure. So the queue is bounded and offer() is
 * non-blocking: if the writer falls behind, samples are DROPPED and counted,
 * and the drop count is shown in the UI. A gap that is honestly reported is
 * worth more than a series whose timing was quietly bent by the logger.
 *
 * WHY NOT FLUSH PER SAMPLE
 *
 * 20 Hz is a perfectly reasonable rate to log; 20 flushes a second is not.
 * Each one is a write() plus the filesystem's own churn, and at this rate it
 * produces visible jank and pointless flash wear for no benefit. Samples are
 * buffered and flushed once a second, so a crash costs at most a second of
 * data -- an acceptable trade for a diagnostic.
 *
 * SIZE
 *
 * A row is about 110 bytes, so 20 Hz is ~2.2 KB/s, ~8 MB/hour, ~190 MB/day.
 * Files roll over hourly and the closed one is gzipped, which takes this to
 * roughly 25 MB/day. bigtab01 has ~188 GB free, so retention is a tidiness
 * question rather than a capacity one.
 */
class LogWriter(private val dir: File) {

    private val queue = ArrayBlockingQueue<Sample>(QUEUE_CAP)
    private val stopping = java.util.concurrent.atomic.AtomicBoolean(false)
    private var thread: Thread? = null

    val written = AtomicLong(0)
    val dropped = AtomicLong(0)

    @Volatile var currentFile: String = "-"
        private set

    fun start() {
        dir.mkdirs()
        val t = Thread({ run() }, "quat-writer")
        t.priority = Thread.NORM_PRIORITY - 1
        thread = t
        t.start()
    }

    /** Non-blocking. Returns false if the sample was dropped. */
    fun offer(s: Sample): Boolean {
        if (queue.offer(s)) return true
        dropped.incrementAndGet()
        return false
    }

    fun stop() {
        stopping.set(true)
        thread?.join(3000)
        thread = null
    }

    private fun run() {
        var writer: Writer? = null
        var openHour = ""
        var lastFlush = System.currentTimeMillis()
        val sb = StringBuilder(160)

        while (!stopping.get() || queue.isNotEmpty()) {
            val s = try {
                queue.poll(500, TimeUnit.MILLISECONDS)
            } catch (e: InterruptedException) {
                break
            }

            if (s != null) {
                val hour = hourKey(s.wallMs)
                if (hour != openHour) {
                    writer?.let { closeAndCompress(it, openHour) }
                    writer = openFor(hour)
                    openHour = hour
                    currentFile = "quat-$hour.csv"
                    pruneOldFiles()
                }
                try {
                    s.toCsv(sb)
                    writer?.append(sb)
                    written.incrementAndGet()
                } catch (e: Exception) {
                    Log.e(TAG, "write failed", e)
                }
            }

            val now = System.currentTimeMillis()
            if (now - lastFlush >= FLUSH_MS) {
                try { writer?.flush() } catch (e: Exception) { Log.e(TAG, "flush failed", e) }
                lastFlush = now
            }
        }
        try { writer?.flush(); writer?.close() } catch (e: Exception) { /* shutting down */ }
    }

    private fun openFor(hour: String): Writer {
        val f = File(dir, "quat-$hour.csv")
        val fresh = !f.exists() || f.length() == 0L
        val w = OutputStreamWriter(
            BufferedOutputStream(FileOutputStream(f, true), 64 * 1024), Charsets.UTF_8)
        if (fresh) w.append(Sample.HEADER)
        return w
    }

    /* Gzip the finished hour and drop the plain file. Roughly 8x on this data,
     * because consecutive quaternions share most of their digits. */
    private fun closeAndCompress(w: Writer, hour: String) {
        try { w.flush(); w.close() } catch (e: Exception) { return }
        if (hour.isEmpty()) return
        val src = File(dir, "quat-$hour.csv")
        if (!src.exists()) return
        try {
            val dst = File(dir, "quat-$hour.csv.gz")
            GZIPOutputStream(BufferedOutputStream(FileOutputStream(dst), 64 * 1024)).use { out ->
                src.inputStream().use { it.copyTo(out, 64 * 1024) }
            }
            src.delete()
        } catch (e: Exception) {
            Log.e(TAG, "compress failed for $hour", e)
        }
    }

    private fun pruneOldFiles() {
        val cutoff = System.currentTimeMillis() - RETAIN_DAYS * 86_400_000L
        dir.listFiles()?.forEach { f ->
            if (f.name.startsWith("quat-") && f.name.endsWith(".gz") &&
                f.lastModified() < cutoff) f.delete()
        }
    }

    companion object {
        private const val TAG = "quatmon"
        /* 100 seconds of slack at 20 Hz -- long enough to ride out a stalled
         * write, short enough that a wedged disk is noticed rather than
         * silently buffered into OOM. */
        const val QUEUE_CAP = 2000
        const val FLUSH_MS = 1000L
        const val RETAIN_DAYS = 14L

        fun hourKey(wallMs: Long): String =
            java.text.SimpleDateFormat("yyyyMMdd-HH", Locale.US)
                .format(java.util.Date(wallMs))
    }
}
