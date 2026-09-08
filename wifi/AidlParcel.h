/*
 * The handful of AIDL parcel shapes this daemon needs, on top of libgbinder's
 * reader/writer.
 *
 * libgbinder gives us the transport and the RPC header (aidl3: strict-mode
 * flags, work source, the 'SYST' header, then the String16 interface token --
 * see gbinder_rpc_protocol.c) but not the AIDL *body* conventions.  Those are
 * few and they are all here so that Wificond.cpp reads as protocol rather than
 * as byte-pushing:
 *
 *   reply header   Java's reply.writeNoException() is literally writeInt32(0).
 *                  Every non-oneway reply starts with it; the caller's
 *                  Parcel.readException() reads it back.
 *   int[]          writeInt32(count) then the values.  count == -1 means null.
 *   byte[]         writeInt32(count) then bytes padded to 4.  Note libgbinder's
 *                  gbinder_writer_append_byte_array() writes -1 (i.e. NULL) for
 *                  a zero-length array, which is NOT the same thing as an empty
 *                  array to Java, so empty is written by hand here.
 *   T[]            writeInt32(count) then each element inline.  Typed arrays
 *                  carry no per-element null flag, unlike typed *objects*.
 *   @nullable T    writeInt32(0) for null, writeInt32(1) then the body for
 *                  non-null.  (Binders are the exception: a null binder is a
 *                  flat_binder_object with a zero handle, not a 0 int.)
 */

#pragma once

#include <gbinder.h>

#include <cstdint>
#include <string>
#include <vector>

namespace waydroid {
namespace wifi {
namespace aidl {

/* Status::EX_NONE -- the AIDL "no exception" reply header. */
inline void
writeNoException(GBinderWriter* w)
{
    gbinder_writer_append_int32(w, 0);
}

inline void
writeBool(GBinderWriter* w, bool v)
{
    gbinder_writer_append_int32(w, v ? 1 : 0);
}

inline void
writeInt32Array(GBinderWriter* w, const std::vector<int32_t>& v)
{
    gbinder_writer_append_int32(w, (gint32) v.size());
    for (int32_t x : v) {
        gbinder_writer_append_int32(w, x);
    }
}

inline void
writeNullArray(GBinderWriter* w)
{
    gbinder_writer_append_int32(w, -1);
}

/* Empty and null are different to Java; see the note at the top. */
inline void
writeByteArray(GBinderWriter* w, const void* data, int32_t len)
{
    if (len > 0) {
        gbinder_writer_append_byte_array(w, data, len);
    } else {
        gbinder_writer_append_int32(w, 0);
    }
}

inline void
writeString(GBinderWriter* w, const std::string& s)
{
    gbinder_writer_append_string16(w, s.c_str());
}

/* @nullable parcelable, null case. */
inline void
writeNullParcelable(GBinderWriter* w)
{
    gbinder_writer_append_int32(w, 0);
}

/* Read a @utf8InCpp String argument.  Java still puts a String16 on the wire. */
inline std::string
readString(GBinderReader* r)
{
    char* s = gbinder_reader_read_string16(r);
    std::string out = s ? s : "";
    g_free(s);
    return out;
}

} /* namespace aidl */
} /* namespace wifi */
} /* namespace waydroid */
