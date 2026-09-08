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
 *
 * Stage 4 adds two more, both required by *stable* AIDL specifically -- the
 * wificond interfaces above are platform-internal AIDL and need neither:
 *
 *   exceptions     A stable-AIDL method reports failure as a service-specific
 *                  exception rather than by returning a status.  The layout is
 *                  int32(-8), the message as a String16, int32(0), and then
 *                  int32(errorCode) -- FOUR fields, and the third one is the
 *                  trap.  It is an empty remote-stack-trace header, written
 *                  unconditionally by libbinder's Status::writeToParcel and
 *                  read unconditionally by Parcel.readException(int, String)
 *                  before it ever gets to the error code.  Omit it and the
 *                  error code is consumed as a stack-trace payload SIZE, so a
 *                  non-zero code sends Java off reading a string past the end
 *                  of the parcel and the exception surfaces as "(code 0)".
 *                  writeNoException() above is the same function's zero case,
 *                  which is why the two live together -- and it needs none of
 *                  this, because readException() returns early on 0, which is
 *                  why every reply in Stages 2 and 3 was correct without it.
 *
 *   meta codes     Every stable-AIDL interface answers two transactions the
 *                  .aidl file does not declare: getInterfaceVersion at
 *                  0x00ffffff and getInterfaceHash at 0x00fffffe.  They are
 *                  numbered downwards from the top of the code space precisely
 *                  so that adding methods can never collide with them.
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

inline int32_t
readInt32(GBinderReader* r)
{
    gint32 v = 0;
    gbinder_reader_read_int32(r, &v);
    return v;
}

inline bool
readBool(GBinderReader* r)
{
    return readInt32(r) != 0;
}

/* byte[] argument.  Empty and absent both come back as an empty vector. */
inline std::vector<uint8_t>
readByteArray(GBinderReader* r)
{
    gsize len = 0;
    const void* p = gbinder_reader_read_byte_array(r, &len);
    const uint8_t* b = (const uint8_t*) p;

    return p ? std::vector<uint8_t>(b, b + len) : std::vector<uint8_t>();
}

/*
 * Status::EX_SERVICE_SPECIFIC.  See the note at the top of this file for the
 * empty stack-trace header: it is not optional, and leaving it out mislabels
 * the error AND desynchronises the parcel.
 */
#define AIDL_EX_SERVICE_SPECIFIC (-8)

inline void
writeServiceSpecificError(GBinderWriter* w, int32_t code, const char* message)
{
    gbinder_writer_append_int32(w, AIDL_EX_SERVICE_SPECIFIC);
    gbinder_writer_append_string16(w, message);
    gbinder_writer_append_int32(w, 0);      /* empty remote stack trace */
    gbinder_writer_append_int32(w, code);
}

/*
 * The two transactions every stable-AIDL interface answers without declaring
 * them.  Numbered down from the top of the code space, so they never collide
 * with a declared method however many get added.
 */
#define AIDL_TRANSACTION_getInterfaceVersion    (0x00ffffff)
#define AIDL_TRANSACTION_getInterfaceHash       (0x00fffffe)

} /* namespace aidl */
} /* namespace wifi */
} /* namespace waydroid */
