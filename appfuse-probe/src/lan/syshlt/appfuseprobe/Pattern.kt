/*
 * Copyright 2026 Jeremy Melanson
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
package lan.syshlt.appfuseprobe

/**
 * An offset-addressable byte pattern: the value of byte N depends only on N.
 *
 * That property is the whole point. A proxy fd is only useful if it supports real
 * random access, so every check here reads at some offset and compares against what
 * *that* offset should hold -- which catches a read served from the wrong place, and
 * not merely a read that returned the wrong number of bytes.
 *
 * The high term is why `ushr 12` is in there. A pattern of `offset * 31` alone repeats
 * every 256 bytes, so a result shifted by one page -- the single likeliest FUSE fault,
 * since 4096 is the transfer granularity -- would compare equal and pass. Mixing the
 * page number in makes a page-aligned shift visible.
 */
object Pattern {

    /** The byte that belongs at [offset]. */
    fun at(offset: Long): Byte = (offset * 31 + (offset ushr 12) * 131 + 17).toByte()

    /** Fills [count] bytes of [dest] from [destOffset] as if read at [fileOffset]. */
    fun fill(dest: ByteArray, destOffset: Int, fileOffset: Long, count: Int) {
        for (i in 0 until count) dest[destOffset + i] = at(fileOffset + i)
    }

    /**
     * Index of the first byte of [buf] that does not belong at [fileOffset], or -1 if
     * all [count] of them do.
     */
    fun firstMismatch(buf: ByteArray, count: Int, fileOffset: Long): Int {
        for (i in 0 until count) if (buf[i] != at(fileOffset + i)) return i
        return -1
    }
}
