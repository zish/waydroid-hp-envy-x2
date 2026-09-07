package lan.syshlt.quatmon

import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/*
 * Manual anomaly reports.
 *
 * The timestamp is taken the instant the button is pressed and the description
 * is collected afterwards, never the other way round. Typing takes seconds and
 * the whole point of the mark is to say exactly when something was seen, so
 * folding the two together would smear the one number that matters.
 *
 * Capture runs POST_S after the mark and reaches back PRE_S before it, so the
 * window brackets the event rather than starting at it -- whatever caused a
 * rotation glitch is in the log before the glitch is visible on screen.
 */
object Anomaly {

    private const val TAG = "quatmon"
    private const val PRE_S = 60L
    private const val POST_S = 15L

    fun eventsFile(dir: File) = File(dir, "events.csv")

    /** Record a mark and return its id. Cheap; safe to call from anywhere. */
    @Synchronized
    fun mark(dir: File, wallMs: Long): Long {
        dir.mkdirs()
        val f = eventsFile(dir)
        if (!f.exists()) f.appendText("id,wall_ms,iso,description,capture\n")
        val id = wallMs
        f.appendText("$id,$wallMs,${iso(wallMs)},,\n")
        return id
    }

    /**
     * Attach a description to an existing mark. The events file is a handful of
     * rows, so rewriting it whole is simpler and safer than editing in place.
     */
    @Synchronized
    fun describe(dir: File, id: Long, text: String) {
        val f = eventsFile(dir)
        if (!f.exists()) return
        val clean = text.replace(Regex("[\r\n,]"), " ").trim()
        val out = StringBuilder()
        f.forEachLine { line ->
            val cols = line.split(',')
            if (cols.size >= 5 && cols[0] == id.toString()) {
                out.append("${cols[0]},${cols[1]},${cols[2]},$clean,${cols[4]}\n")
            } else {
                out.append(line).append('\n')
            }
        }
        f.writeText(out.toString())
    }

    @Synchronized
    private fun setCapture(dir: File, id: Long, name: String) {
        val f = eventsFile(dir)
        if (!f.exists()) return
        val out = StringBuilder()
        f.forEachLine { line ->
            val cols = line.split(',')
            if (cols.size >= 5 && cols[0] == id.toString()) {
                out.append("${cols[0]},${cols[1]},${cols[2]},${cols[3]},$name\n")
            } else {
                out.append(line).append('\n')
            }
        }
        f.writeText(out.toString())
    }

    /**
     * Snapshot logcat and the window manager's rotation state around a mark.
     * Blocking and slow; call it on a worker thread.
     */
    fun capture(dir: File, id: Long, wallMs: Long) {
        try {
            Thread.sleep(POST_S * 1000)
        } catch (e: InterruptedException) {
            return
        }
        val out = File(dir, "capture-$id.txt")
        val sb = StringBuilder(64 * 1024)
        sb.append("# quat-monitor capture for mark $id (${iso(wallMs)})\n")
        sb.append("# window: ${iso(wallMs - PRE_S * 1000)} .. ${iso(wallMs + POST_S * 1000)}\n\n")

        /* READ_LOGS is signature|privileged|development. Granted via
         * `pm grant` by build.sh --install; without it this silently returns
         * only this app's own lines, so say which happened rather than leaving
         * a short capture looking like a quiet system. */
        sb.append("===== logcat -T ${logcatTime(wallMs - PRE_S * 1000)} =====\n")
        val logcat = exec(arrayOf("logcat", "-d", "-T", logcatTime(wallMs - PRE_S * 1000)))
        sb.append(logcat.ifBlank { "(no output -- is READ_LOGS granted?)\n" })

        /* The single most useful thing for a rotation anomaly: what the window
         * manager thought the rotation was. Needs DUMP, same grant story. */
        sb.append("\n===== dumpsys window (rotation) =====\n")
        val wm = exec(arrayOf("sh", "-c",
            "dumpsys window | grep -iE 'mRotation|mProposedRotation|mPredictedRotation|" +
            "mCurrentRotation|mUserRotation|mLastOrientation|mSupportAutoRotation'"))
        sb.append(wm.ifBlank { "(no output -- is DUMP granted?)\n" })

        sb.append("\n===== sensor list =====\n")
        sb.append(exec(arrayOf("sh", "-c",
            "dumpsys sensorservice | grep -iE 'Rotation Vector|Active sensors|connections'"))
            .ifBlank { "(no output)\n" })

        try {
            out.writeText(sb.toString())
            setCapture(dir, id, out.name)
            Log.i(TAG, "capture written: ${out.absolutePath} (${out.length()} bytes)")
        } catch (e: Exception) {
            Log.e(TAG, "capture write failed", e)
        }
    }

    private fun exec(cmd: Array<String>): String = try {
        val p = ProcessBuilder(*cmd).redirectErrorStream(true).start()
        val text = p.inputStream.bufferedReader().use { it.readText() }
        p.waitFor()
        text
    } catch (e: Exception) {
        "(exec failed: ${e.message})\n"
    }

    fun iso(ms: Long): String =
        SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US).format(Date(ms))

    /* logcat -T wants "MM-DD hh:mm:ss.mmm" in the device's local time. */
    private fun logcatTime(ms: Long): String =
        SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US).format(Date(ms))
}
