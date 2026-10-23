// km_parcel.h -- keymaster@4.0 HIDL marshalling shared by waydroid-keystored
// and km-bench: KeyParameter vectors, KeyCharacteristics and byte vectors, read
// from a libgbinder request or reply and written into one.
//
// Header-only and static, because it is two translation units' worth of code
// and the two binaries share nothing else at link time.
#ifndef WAYDROID_KM_PARCEL_H
#define WAYDROID_KM_PARCEL_H

#include "km_hidl_types.h"
#include "../engine.h"

#include <gbinder.h>
#include <linux/android/binder.h>
#include <string.h>

using namespace wks;

static const GBinderWriterField km_key_parameter_f[] = {
    GBINDER_WRITER_FIELD_HIDL_VEC_BYTE(km_key_parameter, blob),
    GBINDER_WRITER_FIELD_END()
};
static const GBinderWriterType km_key_parameter_t = {
    GBINDER_WRITER_STRUCT_NAME_AND_SIZE(km_key_parameter), km_key_parameter_f
};
static const GBinderWriterField km_key_characteristics_f[] = {
    GBINDER_WRITER_FIELD_HIDL_VEC(km_key_characteristics, softwareEnforced,
        &km_key_parameter_t),
    GBINDER_WRITER_FIELD_HIDL_VEC(km_key_characteristics, hardwareEnforced,
        &km_key_parameter_t),
    GBINDER_WRITER_FIELD_END()
};
static const GBinderWriterType km_key_characteristics_t = {
    GBINDER_WRITER_STRUCT_NAME_AND_SIZE(km_key_characteristics),
    km_key_characteristics_f
};
static const GBinderWriterField km_verification_token_f[] = {
    GBINDER_WRITER_FIELD_HIDL_VEC(km_verification_token, parametersVerified,
        &km_key_parameter_t),
    GBINDER_WRITER_FIELD_HIDL_VEC_BYTE(km_verification_token, mac),
    GBINDER_WRITER_FIELD_END()
};
static const GBinderWriterType km_verification_token_t = {
    GBINDER_WRITER_STRUCT_NAME_AND_SIZE(km_verification_token),
    km_verification_token_f
};

/* Read one child buffer object -- a vector's data, or an element's blob.
 *
 * libhwbinder registers a BINDER_TYPE_PTR object in the parcel's offsets only
 * when its buffer is non-null (Parcel::writeObject). So an empty vector's child
 * arrives as 40 bytes of object the kernel never saw: untranslated, still NULL,
 * and invisible to libgbinder's reader, which steps through registered objects
 * only and stops dead at the first one of these. Measured on bigtab01: a
 * keystore2 generateKey with seven parameters, every blob empty, was 412 bytes
 * of data and 16 bytes of offsets -- two objects registered where nine were
 * written. Every KeyParameter of a non-bytes tag carries such a blob, and so
 * does every empty clientId, appData and inParams.
 *
 * So each child is read here: a registered one through libgbinder, a null one
 * recognised by peeking at the cursor and stepped over as plain data, which
 * leaves libgbinder's object index exactly where it should be. The pointer
 * returned stays valid for the life of the request. */
static inline bool
km_read_child(
    GBinderReader* r,
    const guint8** data,
    gsize* size)
{
    gsize total = 0;
    const guint8* base = (const guint8*) gbinder_reader_get_data(r, &total);
    const gsize remaining = gbinder_reader_bytes_remaining(r);
    struct binder_buffer_object obj;
    GBinderBuffer* b;

    if (!base || remaining < sizeof(obj) || remaining > total) {
        return false;
    }
    memcpy(&obj, base + (total - remaining), sizeof(obj));
    if (obj.hdr.type != BINDER_TYPE_PTR) {
        return false;
    }
    if (!obj.buffer) {
        guint64 skip;

        if (obj.length) {
            return false;
        }
        for (gsize i = 0; i < sizeof(obj) / sizeof(skip); i++) {
            if (!gbinder_reader_read_uint64(r, &skip)) {
                return false;
            }
        }
        *data = NULL;
        *size = 0;
        return true;
    }
    b = gbinder_reader_read_buffer(r);
    if (!b) {
        return false;
    }
    /* The request holds the transaction buffer; this only drops the view. */
    *data = (const guint8*) b->data;
    *size = b->size;
    gbinder_buffer_free(b);
    return true;
}

/* A top-level vec<T>: its descriptor (always registered -- it points at the
 * caller's hidl_vec, never null) and then its data. */
static inline bool
km_read_vec(
    GBinderReader* r,
    gsize elemSize,
    const guint8** data,
    gsize* count)
{
    const guint8 *hdr, *d;
    gsize hsize, dsize;
    GBinderHidlVec v;

    if (!km_read_child(r, &hdr, &hsize) || !hdr || hsize != sizeof(v)) {
        return false;
    }
    memcpy(&v, hdr, sizeof(v));
    if (!km_read_child(r, &d, &dsize) || dsize != (gsize) v.count * elemSize ||
        (v.count && (const void*) d != v.data.ptr)) {
        return false;
    }
    *data = d;
    *count = v.count;
    return true;
}

/* Read a vec<KeyParameter>: the vector, then one child per element for its
 * blob, registered or null. */
static inline bool
km_read_params(
    GBinderReader* r,
    AuthList& out)
{
    const guint8* raw;
    gsize count = 0;

    out.params.clear();
    if (!km_read_vec(r, sizeof(km_key_parameter), &raw, &count)) {
        return false;
    }
    for (gsize i = 0; i < count; i++) {
        km_key_parameter kp;
        const guint8* blob;
        gsize blobSize;
        KeyParam p;

        memcpy(&kp, raw + i * sizeof(kp), sizeof(kp));
        if (!km_read_child(r, &blob, &blobSize) || blobSize != kp.blob.count ||
            (blobSize && (const void*) blob != kp.blob.data.ptr)) {
            return false;
        }
        p.tag = static_cast<Tag>(kp.tag);
        switch (tagType(p.tag)) {
        case TagType::ULONG:
        case TagType::ULONG_REP:
        case TagType::DATE:
            p.u = kp.f;
            break;
        case TagType::BOOL:
            p.u = (kp.f & 0xff) ? 1 : 0;
            break;
        case TagType::BYTES:
        case TagType::BIGNUM:
            if (blobSize) p.blob.assign(blob, blob + blobSize);
            break;
        default:
            p.u = (guint32) kp.f;   /* enums and uint32: the low four bytes */
            break;
        }
        out.params.push_back(std::move(p));
    }
    return true;
}

static inline bool
km_read_bytes(
    GBinderReader* r,
    Bytes& out)
{
    const guint8* d;
    gsize count = 0;

    out.clear();
    if (!km_read_vec(r, 1, &d, &count)) {
        return false;
    }
    if (count) out.assign(d, d + count);
    return true;
}

/* A KeyParameter array in the transaction's own memory, blobs included. */
static inline km_key_parameter*
km_params_array(
    GBinderWriter* w,
    const AuthList& a)
{
    const gsize n = a.params.size();
    km_key_parameter* arr;

    if (!n) {
        return NULL;
    }
    arr = (km_key_parameter*) gbinder_writer_malloc0(w, n * sizeof(*arr));
    for (gsize i = 0; i < n; i++) {
        const KeyParam& p = a.params[i];

        arr[i].tag = static_cast<guint32>(p.tag);
        arr[i].blob.owns_buffer = TRUE;
        if (tagIsBytes(p.tag)) {
            arr[i].blob.data.ptr = p.blob.empty() ? NULL :
                gbinder_writer_memdup(w, p.blob.data(), p.blob.size());
            arr[i].blob.count = p.blob.size();
        } else if (tagType(p.tag) == TagType::BOOL) {
            arr[i].f = 1;
        } else {
            arr[i].f = p.u;
        }
    }
    return arr;
}

static inline void
km_set_vec(
    GBinderHidlVec* v,
    const void* ptr,
    gsize count)
{
    v->data.ptr = ptr;
    v->count = count;
    v->owns_buffer = TRUE;
}

static inline void
km_append_params(
    GBinderWriter* w,
    const AuthList& a)
{
    gbinder_writer_append_struct_vec(w, km_params_array(w, a),
        a.params.size(), &km_key_parameter_t);
}

static inline void
km_append_characteristics(
    GBinderWriter* w,
    const KeyCharacteristics& kc)
{
    km_key_characteristics* c = gbinder_writer_new0(w, km_key_characteristics);

    km_set_vec(&c->softwareEnforced, km_params_array(w, kc.softwareEnforced),
        kc.softwareEnforced.params.size());
    km_set_vec(&c->hardwareEnforced, km_params_array(w, kc.hardwareEnforced),
        kc.hardwareEnforced.params.size());
    gbinder_writer_append_struct(w, c, &km_key_characteristics_t, NULL);
}

static inline void
km_append_bytes(
    GBinderWriter* w,
    const Bytes& b)
{
    gbinder_writer_append_hidl_vec(w, b.empty() ? NULL : b.data(), b.size(), 1);
}

#endif
