/*
 * Copyright 2026 Jeremy Melanson
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
package com.systemhalted.appfuseprobe

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
 *
 * [salt] makes one file distinguishable from another. With every file serving the same
 * bytes, the simultaneous-fds check could not tell a read answered by its own mount from
 * one answered by another's -- crossed mounts passed. Each salt step adds 53, and 0..7
 * times 53 are eight different residues mod 256, so for salts 0..7 two files differ at
 * EVERY offset, and a crossed read fails on its first byte. Salt 0 is the original
 * pattern, byte for byte.
 */
object Pattern {

    /** The byte that belongs at [offset] of the file with [salt]. */
    fun at(offset: Long, salt: Int = 0): Byte =
        (offset * 31 + (offset ushr 12) * 131 + 17 + salt * 53L).toByte()

    /** Fills [count] bytes of [dest] from [destOffset] as if read at [fileOffset]. */
    fun fill(dest: ByteArray, destOffset: Int, fileOffset: Long, count: Int, salt: Int = 0) {
        for (i in 0 until count) dest[destOffset + i] = at(fileOffset + i, salt)
    }

    /**
     * Index of the first byte of [buf] that does not belong at [fileOffset], or -1 if
     * all [count] of them do.
     */
    fun firstMismatch(buf: ByteArray, count: Int, fileOffset: Long, salt: Int = 0): Int {
        for (i in 0 until count) if (buf[i] != at(fileOffset + i, salt)) return i
        return -1
    }
}
