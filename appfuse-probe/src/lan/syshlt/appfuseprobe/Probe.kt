/*
 * Copyright 2026 Jeremy Melanson
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
package lan.syshlt.appfuseprobe

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelFileDescriptor
import android.os.ProxyFileDescriptorCallback
import android.os.storage.StorageManager
import android.system.Os
import android.util.Log
import java.io.File
import java.util.Random

/**
 * Serves [Pattern] over a proxy fd and counts what the kernel asked for.
 *
 * `maxRead` and `reads` are the structural measurements: AppFuse chops a caller's read
 * into `onRead` calls of its own choosing, and the size it picks is a property of the
 * build rather than of the caller -- crippy measured 128 KiB on one OEM ROM and 64 KiB
 * on another. Recording it here means the same probe that proves the mount works also
 * says what this container's transfer granularity is.
 */
private class PatternCallback(private val fileSize: Long) : ProxyFileDescriptorCallback() {

    @Volatile var reads = 0
    @Volatile var maxRead = 0
    @Volatile var released = false

    override fun onGetSize(): Long = fileSize

    override fun onRead(offset: Long, size: Int, data: ByteArray): Int {
        reads++
        if (size > maxRead) maxRead = size
        val available = (fileSize - offset).coerceIn(0L, size.toLong()).toInt()
        Pattern.fill(data, 0, offset, available)
        return available
    }

    override fun onRelease() {
        released = true
    }
}

/**
 * The AppFuse probe: does `StorageManager.openProxyFileDescriptor()` work here, and if
 * it does, does the fd it returns behave like a file?
 *
 * Deliberately *not* a `DocumentsProvider`. crippy already has the SAF-shaped version of
 * this test and it cannot separate "AppFuse is broken" from "something in the provider or
 * the picker is broken". This calls the one API under suspicion and nothing else, so a
 * failure has exactly one possible owner.
 *
 * Every step is individually guarded and a throw is a *result*, printed with its class,
 * message and full cause chain. On a container with no working AppFuse the expected
 * outcome is `IllegalStateException: Failed to mount` at step 2, with steps 3 onward
 * skipped and the report still readable.
 *
 * **Nothing here ever `mmap`s the fd.** A page fault on a mapping whose FUSE daemon is
 * the faulting process deadlocks the whole device -- crippy hit it, took an LG G6 down
 * hard enough that `adb reboot` hung, and recorded it as an invariant rather than a ROM
 * defect. The probe reads with `read` and `pread` only.
 */
class Probe(private val context: Context) {

    private val out = StringBuilder()
    private var coldReads = -1
    private var coldMaxRead = -1

    private fun emit(line: String) {
        out.append(line).append('\n')
        Log.i(TAG, line)
    }

    private fun rule(title: String) {
        emit("")
        emit("=== $title ".padEnd(72, '='))
    }

    /** Prints a throwable and everything under it -- the message alone is rarely enough. */
    private fun fail(what: String, t: Throwable) {
        emit("  $what FAILED")
        var e: Throwable? = t
        var depth = 0
        while (e != null && depth < 8) {
            val prefix = if (depth == 0) "    throw " else "    cause " + "  ".repeat(depth)
            emit("$prefix${e.javaClass.name}: ${e.message}")
            e = e.cause
            depth++
        }
    }

    fun run(): String {
        emit("AppFuse Probe -- ${java.util.Date()}")
        environment()
        val ok = proxyFd()
        emit("")
        emit(if (ok) "RESULT: AppFuse WORKS on this container." else "RESULT: AppFuse is NOT working on this container.")
        return out.toString()
    }

    private fun environment() {
        rule("environment")
        emit("  SDK            ${Build.VERSION.SDK_INT} (${Build.VERSION.RELEASE})")
        emit("  fingerprint    ${Build.FINGERPRINT}")
        emit("  package        ${context.packageName}")
        emit("  uid            ${Os.getuid()}")

        // /dev/fuse is the device vold hands to the kernel. Absent, nothing else matters;
        // present, it rules the easy explanation out. An app cannot open it, so only its
        // existence and mode are checked -- not readability.
        val fuse = File("/dev/fuse")
        emit("  /dev/fuse      exists=${fuse.exists()}")
        runCatching { Os.stat("/dev/fuse") }
            .onSuccess { emit("  /dev/fuse mode ${Integer.toOctalString(it.st_mode)} rdev=${it.st_rdev}") }
            .onFailure { emit("  /dev/fuse stat ${it.javaClass.simpleName}: ${it.message}") }

        // The mount point vold creates per (uid, mountId). An app normally cannot list it;
        // whether it exists at all still separates "vold never got that far" from "vold
        // made the directory and the mount failed".
        val appfuse = File("/mnt/appfuse")
        emit("  /mnt/appfuse   exists=${appfuse.exists()} canRead=${appfuse.canRead()}")

        for (prop in listOf("persist.sys.fuse", "ro.build.type", "ro.boot.vendor.type")) {
            emit("  $prop = ${getprop(prop)}")
        }
    }

    /** `getprop` by exec, because `SystemProperties` is not public API on API 33. */
    private fun getprop(name: String): String = runCatching {
        val p = ProcessBuilder("/system/bin/getprop", name).redirectErrorStream(true).start()
        val text = p.inputStream.bufferedReader().readText().trim()
        p.waitFor()
        if (text.isEmpty()) "(empty)" else text
    }.getOrElse { "(${it.javaClass.simpleName})" }

    /**
     * The load-bearing step. Returns true only if the fd opened *and* every correctness
     * check on it passed.
     */
    private fun proxyFd(): Boolean {
        rule("openProxyFileDescriptor")

        val storage = context.getSystemService(StorageManager::class.java)
        if (storage == null) {
            emit("  StorageManager unavailable -- cannot proceed")
            return false
        }

        // openProxyFileDescriptor rejects the main looper outright, so this thread is a
        // hard requirement and not good manners.
        val thread = HandlerThread("appfuse-probe").apply { start() }
        val handler = Handler(thread.looper)
        val callback = PatternCallback(FILE_SIZE)

        val pfd: ParcelFileDescriptor = try {
            storage.openProxyFileDescriptor(
                ParcelFileDescriptor.MODE_READ_ONLY, callback, handler,
            ).also { emit("  opened OK -- fd=${it.fd} size=$FILE_SIZE") }
        } catch (t: Throwable) {
            fail("openProxyFileDescriptor", t)
            emit("")
            emit("  This is the AppFuse mount failing. Check what vold logged:")
            emit("    logcat -d -s vold | grep appfuse")
            emit("  A 'Failed to mount ... Invalid argument' there means vold's mount(2)")
            emit("  was rejected before FUSE was ever involved.")
            thread.quitSafely()
            return false
        }

        val passed = try {
            correctness(pfd, callback)
        } finally {
            runCatching { pfd.close() }
            // Give onRelease a moment to land before reporting whether it did.
            runCatching { Thread.sleep(200) }
            thread.quitSafely()
        }

        rule("callback accounting")
        // This count is LOW on purpose and is not a fault: FUSE caches pages, so the
        // sequential read pulled the whole file once and every later read on the same
        // fd was a cache hit. Read it as "the transfer granularity", not "the number of
        // reads the caller made".
        emit("  onRead calls       ${callback.reads}  (page cache absorbs the rest)")
        emit("  largest onRead     ${callback.maxRead} bytes")
        emit("  onRelease fired    ${callback.released}")
        emit("  cold-fd onRead     $coldReads calls, largest $coldMaxRead bytes")
        return passed
    }

    private fun correctness(pfd: ParcelFileDescriptor, callback: PatternCallback): Boolean {
        var passed = true
        fun check(name: String, body: () -> String?) {
            val problem = try {
                body()
            } catch (t: Throwable) {
                fail(name, t); passed = false; return
            }
            if (problem == null) {
                emit("  PASS  $name")
            } else {
                emit("  FAIL  $name -- $problem")
                passed = false
            }
        }

        rule("correctness")
        val fd = pfd.fileDescriptor

        check("statSize reports the size onGetSize gave") {
            val got = pfd.statSize
            if (got == FILE_SIZE) null else "expected $FILE_SIZE, got $got"
        }

        check("sequential read of the whole file matches the pattern") {
            val buf = ByteArray(64 * 1024)
            var offset = 0L
            while (offset < FILE_SIZE) {
                val want = minOf(buf.size.toLong(), FILE_SIZE - offset).toInt()
                val got = Os.pread(fd, buf, 0, want, offset)
                if (got <= 0) return@check "pread at $offset returned $got"
                val bad = Pattern.firstMismatch(buf, got, offset)
                if (bad >= 0) return@check "byte ${offset + bad} wrong"
                offset += got
            }
            null
        }

        check("pread at 200 pseudorandom offsets matches") {
            val random = Random(SEED)
            val buf = ByteArray(MAX_SPOT)
            repeat(200) {
                val length = 1 + random.nextInt(MAX_SPOT)
                val offset = (random.nextDouble() * (FILE_SIZE - length)).toLong()
                val got = Os.pread(fd, buf, 0, length, offset)
                if (got != length) return@check "pread($offset, $length) returned $got"
                val bad = Pattern.firstMismatch(buf, got, offset)
                if (bad >= 0) return@check "byte ${offset + bad} wrong (offset $offset)"
            }
            null
        }

        check("a read spanning EOF is short, not an error") {
            val buf = ByteArray(8192)
            val offset = FILE_SIZE - 100
            val got = Os.pread(fd, buf, 0, buf.size, offset)
            when {
                got != 100 -> "expected 100 bytes at EOF-100, got $got"
                Pattern.firstMismatch(buf, got, offset) >= 0 -> "tail bytes wrong"
                else -> null
            }
        }

        check("a read entirely past EOF returns 0") {
            val buf = ByteArray(64)
            val got = Os.pread(fd, buf, 0, buf.size, FILE_SIZE + 4096)
            if (got == 0) null else "expected 0, got $got"
        }

        check("lseek then read lands where it was told to") {
            ParcelFileDescriptor.AutoCloseInputStream(pfd.dup()).use { stream ->
                val offset = 517L * 1024 + 3
                Os.lseek(stream.fd, offset, android.system.OsConstants.SEEK_SET)
                val buf = ByteArray(4096)
                val got = stream.read(buf)
                if (got <= 0) return@check "read after lseek returned $got"
                val bad = Pattern.firstMismatch(buf, got, offset)
                if (bad >= 0) "byte ${offset + bad} wrong" else null
            }
        }

        check("the callback was actually consulted") {
            if (callback.reads > 0) null else "onRead was never called -- the fd is not ours"
        }

        // Everything above shares one fd, and the sequential read populated the page
        // cache for the whole 1 MiB before the random preads ran -- so those preads
        // prove the bytes are right but NOT that random access reaches FUSE at all.
        // This check exists to close that gap: a cold fd, random offsets only, and an
        // assertion that the callback was actually woken.
        check("random access on a COLD fd reaches the callback") { coldRandomAccess() }

        concurrency()
        return passed
    }

    /**
     * Random reads on a freshly opened fd, with nothing having touched it first.
     *
     * Returns null on success or a description of the problem. The point is the
     * `reads == 0` branch: if the page cache could satisfy a random pread on a brand-new
     * fd, the fd would not be serving anything and every other check above would be
     * measuring the cache instead of AppFuse.
     */
    private fun coldRandomAccess(): String? {
        val storage = context.getSystemService(StorageManager::class.java)
            ?: return "StorageManager unavailable"
        val thread = HandlerThread("appfuse-probe-cold").apply { start() }
        try {
            val cold = PatternCallback(FILE_SIZE)
            val pfd = storage.openProxyFileDescriptor(
                ParcelFileDescriptor.MODE_READ_ONLY, cold, Handler(thread.looper),
            )
            // Named, not `it`: the inner repeat(50) lambda would shadow it with the index.
            pfd.use { fd ->
                val random = Random(SEED + 1)
                val buf = ByteArray(4096)
                repeat(50) {
                    val length = 1 + random.nextInt(buf.size)
                    val offset = (random.nextDouble() * (FILE_SIZE - length)).toLong()
                    val got = Os.pread(fd.fileDescriptor, buf, 0, length, offset)
                    if (got != length) return "cold pread($offset, $length) returned $got"
                    val bad = Pattern.firstMismatch(buf, got, offset)
                    if (bad >= 0) return "cold byte ${offset + bad} wrong"
                }
            }
            coldReads = cold.reads
            coldMaxRead = cold.maxRead
            return if (cold.reads > 0) null
            else "50 cold random reads and onRead was never called -- not served by this fd"
        } catch (t: Throwable) {
            return "${t.javaClass.simpleName}: ${t.message}"
        } finally {
            thread.quitSafely()
        }
    }

    /**
     * Eight simultaneous proxy fds. Not a ceiling hunt -- crippy found no ceiling below
     * 512 on real hardware. The question here is narrower: each proxy fd is a separate
     * AppFuse *mount* keyed by mount id, so if the fix works for one and not for the
     * second the mount path is only half right.
     */
    private fun concurrency() {
        rule("simultaneous fds")
        val storage = context.getSystemService(StorageManager::class.java) ?: return
        val thread = HandlerThread("appfuse-probe-multi").apply { start() }
        val handler = Handler(thread.looper)
        val open = mutableListOf<ParcelFileDescriptor>()
        try {
            repeat(8) { i ->
                try {
                    open += storage.openProxyFileDescriptor(
                        ParcelFileDescriptor.MODE_READ_ONLY, PatternCallback(FILE_SIZE), handler,
                    )
                } catch (t: Throwable) {
                    emit("  fd #$i failed: ${t.javaClass.simpleName}: ${t.message}")
                    return@repeat
                }
            }
            emit("  opened ${open.size} of 8 concurrently")
            var verified = 0
            val buf = ByteArray(64)
            for (p in open) {
                val offset = 1024L
                if (Os.pread(p.fileDescriptor, buf, 0, buf.size, offset) == buf.size &&
                    Pattern.firstMismatch(buf, buf.size, offset) < 0
                ) verified++
            }
            emit("  ${if (verified == open.size) "PASS" else "FAIL"}  $verified of ${open.size} served correct bytes")
        } catch (t: Throwable) {
            fail("simultaneous fds", t)
        } finally {
            open.forEach { runCatching { it.close() } }
            thread.quitSafely()
        }
    }

    companion object {
        const val TAG = "APPFUSE"

        /** 1 MiB: enough to make AppFuse chop the read up, small enough to run in a second. */
        private const val FILE_SIZE = 1L shl 20

        /** Fixed, so two runs compare directly and a failing offset can be re-tried. */
        private const val SEED = 20260925L

        private const val MAX_SPOT = 8192
    }
}
