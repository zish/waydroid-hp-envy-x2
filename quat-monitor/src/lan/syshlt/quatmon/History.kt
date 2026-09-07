package lan.syshlt.quatmon

import android.util.Log
import java.io.File
import java.util.zip.GZIPInputStream

/*
 * Refills the ring from disk when sampling starts, so opening the app shows a
 * populated graph instead of an empty one that fills in over the next hour.
 *
 * Reads oldest-first and simply pushes everything into the ring: it overwrites
 * as it wraps, so the last RING_CAP samples survive without this needing to
 * know how many that is, and nothing is buffered in memory. Reading newest-
 * first would need a deque of ~144k strings -- tens of megabytes -- to end up
 * at the same place.
 *
 * Bounded to the newest FILES hours so that a long-running log does not turn
 * service start into a minutes-long parse.
 */
object History {

    private const val TAG = "quatmon"
    private const val FILES = 3

    fun loadInto(dir: File, ring: Ring) {
        val files = dir.listFiles { f ->
            f.name.startsWith("quat-") &&
                (f.name.endsWith(".csv") || f.name.endsWith(".csv.gz"))
        }?.sortedBy { it.name } ?: return
        if (files.isEmpty()) return

        var loaded = 0
        for (f in files.takeLast(FILES)) {
            try {
                val stream = if (f.name.endsWith(".gz"))
                    GZIPInputStream(f.inputStream(), 64 * 1024) else f.inputStream()
                stream.bufferedReader().useLines { lines ->
                    for (line in lines) {
                        val s = parse(line) ?: continue
                        ring.add(s)
                        loaded++
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "history: ${f.name} unreadable", e)
            }
        }
        Log.i(TAG, "history: loaded $loaded samples from ${files.size} file(s)")
    }

    private fun parse(line: String): Sample? {
        if (line.isEmpty() || line[0] == 'w') return null      // header
        val c = line.split(',')
        if (c.size < 30) return null
        return try {
            Sample(
                c[0].toLong(), c[1].toLong(),
                c[2].f(), c[3].f(), c[4].f(), c[5].f(), c[6].f(),
                c[7].f(), c[8].f(), c[9].f(), c[10].f(), c[11].f(),
                c[12].f(), c[13].f(), c[14].f(), c[15].f(), c[16].f(),
                c[17].f(), c[18].f(), c[19].f(),
                c[20].f(), c[21].f(), c[22].f(),
                c[23].f(), c[24].f(), c[25].f(),
                c[26].toIntOrNull() ?: -1, c[27].f(),
                c[28].f(), c[29].f()
            )
        } catch (e: NumberFormatException) {
            null
        }
    }

    /* Empty fields are written for NaN, so restore them as NaN rather than
     * letting a parse failure discard the whole row. */
    private fun String.f(): Float = if (isEmpty()) Float.NaN else toFloat()
}
