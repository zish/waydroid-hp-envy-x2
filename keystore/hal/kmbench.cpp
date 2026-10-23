/*
 * km-bench -- drive a running waydroid-keystored over real binder from the host,
 * with requests laid out the way libhwbinder lays them out.
 *
 *   km-bench [--name INSTANCE] [BINDER_DEVICE]
 *
 * Why it exists: keystore2 binds the strongbox instance once per Waydroid
 * session and cannot rebind, so every daemon build tested through Android costs
 * a logout. A second daemon registered under another instance name (start it
 * with --name strongbox-bench) is invisible to keystore2, and this client
 * drives it end to end -- generate, export, sign, GCM both ways -- in seconds.
 *
 * The one thing that matters about how it writes: libhwbinder registers a
 * buffer object with the kernel only when its pointer is non-null, so an empty
 * vector's child goes out as 40 bytes of unregistered data (docs/73). libgbinder
 * registers everything it writes, so a plain libgbinder client would never
 * exercise the case that broke stage 4's first bench run. Every empty child
 * here is written the libhwbinder way, as raw bytes.
 *
 * Signatures are checked with openssl against the exported key, and the GCM
 * output is decrypted back; it does not take the daemon's word for anything.
 */
#include "km_parcel.h"

#include <glib.h>
#include <gutil_log.h>
#include <stdio.h>
#include <stdlib.h>
#include <string>
#include <unistd.h>

#define KM_IFACE "android.hardware.keymaster@4.0::IKeymasterDevice"

static int g_pass = 0, g_fail = 0;
static void check(bool ok, const char* what) {
    printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what);
    if (ok) g_pass++; else g_fail++;
}

/* ------------------------------------------------- libhwbinder-style writing */

/* A child the way libhwbinder writes it: registered if it has bytes, raw
 * unregistered data if it is empty. */
static void
hw_child(GBinderWriter* w, const void* data, gsize size, const GBinderParent* parent)
{
    if (size) {
        gbinder_writer_append_buffer_object_with_parent(w, data, size, parent);
    } else {
        struct binder_buffer_object obj;
        memset(&obj, 0, sizeof(obj));
        obj.hdr.type = BINDER_TYPE_PTR;
        obj.flags = BINDER_BUFFER_FLAG_HAS_PARENT;
        obj.parent = parent->index;
        obj.parent_offset = parent->offset;
        gbinder_writer_append_bytes(w, &obj, sizeof(obj));
    }
}

static void
hw_bytes(GBinderWriter* w, const Bytes& b)
{
    GBinderHidlVec* v = gbinder_writer_new0(w, GBinderHidlVec);
    void* copy = b.empty() ? NULL : gbinder_writer_memdup(w, b.data(), b.size());
    GBinderParent parent;

    v->data.ptr = copy;
    v->count = b.size();
    v->owns_buffer = TRUE;
    parent.index = gbinder_writer_append_buffer_object(w, v, sizeof(*v));
    parent.offset = GBINDER_HIDL_VEC_BUFFER_OFFSET;
    hw_child(w, copy, b.size(), &parent);
}

static void
hw_params(GBinderWriter* w, const AuthList& a)
{
    GBinderHidlVec* v = gbinder_writer_new0(w, GBinderHidlVec);
    km_key_parameter* arr = km_params_array(w, a);
    GBinderParent parent, child;

    v->data.ptr = arr;
    v->count = a.params.size();
    v->owns_buffer = TRUE;
    parent.index = gbinder_writer_append_buffer_object(w, v, sizeof(*v));
    parent.offset = GBINDER_HIDL_VEC_BUFFER_OFFSET;
    if (!arr) {
        hw_child(w, NULL, 0, &parent);
        return;
    }
    child.index = gbinder_writer_append_buffer_object_with_parent(w, arr,
        a.params.size() * sizeof(*arr), &parent);
    for (gsize i = 0; i < a.params.size(); i++) {
        child.offset = i * sizeof(*arr) + G_STRUCT_OFFSET(km_key_parameter, blob);
        hw_child(w, arr[i].blob.data.ptr, arr[i].blob.count, &child);
    }
}

/* HardwareAuthToken: 56 bytes, mac at offset 40. Always empty here. */
static void
hw_auth_token(GBinderWriter* w)
{
    guint8* tok = (guint8*) gbinder_writer_malloc0(w, 56);
    GBinderParent parent;

    parent.index = gbinder_writer_append_buffer_object(w, tok, 56);
    parent.offset = 40;
    hw_child(w, NULL, 0, &parent);
}

/* VerificationToken: 56 bytes, parametersVerified at 16, mac at 40. */
static void
hw_verification_token(GBinderWriter* w)
{
    km_verification_token* tok = gbinder_writer_new0(w, km_verification_token);
    GBinderParent parent;

    parent.index = gbinder_writer_append_buffer_object(w, tok, sizeof(*tok));
    parent.offset = G_STRUCT_OFFSET(km_verification_token, parametersVerified);
    hw_child(w, NULL, 0, &parent);
    parent.offset = G_STRUCT_OFFSET(km_verification_token, mac);
    hw_child(w, NULL, 0, &parent);
}

/* ------------------------------------------------------------ transactions */

struct Bench {
    GBinderClient* client;
};

/* Send, and leave the reader at the first return value after ErrorCode. */
static GBinderRemoteReply*
call(Bench& b, int code, GBinderLocalRequest* req, GBinderReader* rd, KmError* err)
{
    int status = 0;
    gint32 hidlStatus = -1, e = 0;
    GBinderRemoteReply* reply = gbinder_client_transact_sync_reply(b.client, code,
        req, &status);

    gbinder_local_request_unref(req);
    *err = KmError::UNKNOWN_ERROR;
    if (!reply || status != GBINDER_STATUS_OK) {
        fprintf(stderr, "    transaction %d failed: status %d\n", code, status);
        if (reply) gbinder_remote_reply_unref(reply);
        return NULL;
    }
    gbinder_remote_reply_init_reader(reply, rd);
    if (!gbinder_reader_read_int32(rd, &hidlStatus) || hidlStatus != 0 ||
        !gbinder_reader_read_int32(rd, &e)) {
        fprintf(stderr, "    transaction %d: bad reply header\n", code);
        gbinder_remote_reply_unref(reply);
        return NULL;
    }
    *err = static_cast<KmError>(e);
    return reply;
}

static bool
read_characteristics(GBinderReader* rd, KeyCharacteristics& kc)
{
    const guint8* s;
    gsize n;
    /* The struct, then each vector's data and its elements' blobs in turn. */
    if (!km_read_child(rd, &s, &n) || n != sizeof(km_key_characteristics)) return false;
    km_key_characteristics c;
    memcpy(&c, s, sizeof(c));
    AuthList* lists[2] = { &kc.softwareEnforced, &kc.hardwareEnforced };
    const GBinderHidlVec* vecs[2] = { &c.softwareEnforced, &c.hardwareEnforced };
    for (int l = 0; l < 2; l++) {
        const guint8* d;
        gsize dn;
        if (!km_read_child(rd, &d, &dn) || dn != vecs[l]->count * sizeof(km_key_parameter))
            return false;
        for (guint i = 0; i < vecs[l]->count; i++) {
            km_key_parameter kp;
            const guint8* blob;
            gsize bn;
            memcpy(&kp, d + i * sizeof(kp), sizeof(kp));
            if (!km_read_child(rd, &blob, &bn)) return false;
            KeyParam p;
            p.tag = static_cast<Tag>(kp.tag);
            if (tagIsBytes(p.tag)) { if (bn) p.blob.assign(blob, blob + bn); }
            else p.u = tagType(p.tag) == TagType::BOOL ? 1 :
                       (tagType(p.tag) == TagType::ULONG || tagType(p.tag) == TagType::DATE)
                       ? kp.f : (guint32) kp.f;
            lists[l]->params.push_back(p);
        }
    }
    return true;
}

static GBinderLocalRequest*
new_req(Bench& b, GBinderWriter* w)
{
    GBinderLocalRequest* req = gbinder_client_new_request(b.client);
    gbinder_local_request_init_writer(req, w);
    return req;
}

static KmError
generate(Bench& b, const AuthList& params, Bytes& blob, KeyCharacteristics& kc)
{
    GBinderWriter w;
    GBinderReader rd;
    KmError e;
    GBinderLocalRequest* req = new_req(b, &w);
    hw_params(&w, params);
    GBinderRemoteReply* r = call(b, KM_GENERATE_KEY, req, &rd, &e);
    if (!r) return KmError::UNKNOWN_ERROR;
    bool ok = km_read_bytes(&rd, blob) && read_characteristics(&rd, kc);
    gbinder_remote_reply_unref(r);
    return ok ? e : KmError::UNKNOWN_ERROR;
}

static KmError
export_x509(Bench& b, const Bytes& blob, Bytes& out)
{
    GBinderWriter w;
    GBinderReader rd;
    KmError e;
    GBinderLocalRequest* req = new_req(b, &w);
    gbinder_writer_append_int32(&w, static_cast<gint32>(KeyFormat::X509));
    hw_bytes(&w, blob);
    hw_bytes(&w, Bytes());
    hw_bytes(&w, Bytes());
    GBinderRemoteReply* r = call(b, KM_EXPORT_KEY, req, &rd, &e);
    if (!r) return KmError::UNKNOWN_ERROR;
    bool ok = km_read_bytes(&rd, out);
    gbinder_remote_reply_unref(r);
    return ok ? e : KmError::UNKNOWN_ERROR;
}

static KmError
characteristics(Bench& b, const Bytes& blob, KeyCharacteristics& kc)
{
    GBinderWriter w;
    GBinderReader rd;
    KmError e;
    GBinderLocalRequest* req = new_req(b, &w);
    hw_bytes(&w, blob);
    hw_bytes(&w, Bytes());
    hw_bytes(&w, Bytes());
    GBinderRemoteReply* r = call(b, KM_GET_KEY_CHARACTERISTICS, req, &rd, &e);
    if (!r) return KmError::UNKNOWN_ERROR;
    bool ok = read_characteristics(&rd, kc);
    gbinder_remote_reply_unref(r);
    return ok ? e : KmError::UNKNOWN_ERROR;
}

static KmError
begin(Bench& b, Purpose p, const Bytes& blob, const AuthList& in, AuthList& out,
      guint64& handle)
{
    GBinderWriter w;
    GBinderReader rd;
    KmError e;
    GBinderLocalRequest* req = new_req(b, &w);
    gbinder_writer_append_int32(&w, static_cast<gint32>(p));
    hw_bytes(&w, blob);
    hw_params(&w, in);
    hw_auth_token(&w);
    GBinderRemoteReply* r = call(b, KM_BEGIN, req, &rd, &e);
    if (!r) return KmError::UNKNOWN_ERROR;
    bool ok = km_read_params(&rd, out) && gbinder_reader_read_uint64(&rd, &handle);
    gbinder_remote_reply_unref(r);
    return ok ? e : KmError::UNKNOWN_ERROR;
}

static KmError
update(Bench& b, guint64 handle, const AuthList& in, const Bytes& input,
       guint32& consumed, Bytes& output)
{
    GBinderWriter w;
    GBinderReader rd;
    KmError e;
    AuthList out;
    GBinderLocalRequest* req = new_req(b, &w);
    gbinder_writer_append_int64(&w, handle);
    hw_params(&w, in);
    hw_bytes(&w, input);
    hw_auth_token(&w);
    hw_verification_token(&w);
    GBinderRemoteReply* r = call(b, KM_UPDATE, req, &rd, &e);
    if (!r) return KmError::UNKNOWN_ERROR;
    bool ok = gbinder_reader_read_uint32(&rd, &consumed) && km_read_params(&rd, out) &&
              km_read_bytes(&rd, output);
    gbinder_remote_reply_unref(r);
    return ok ? e : KmError::UNKNOWN_ERROR;
}

static KmError
finish(Bench& b, guint64 handle, const AuthList& in, const Bytes& input, Bytes& output)
{
    GBinderWriter w;
    GBinderReader rd;
    KmError e;
    AuthList out;
    GBinderLocalRequest* req = new_req(b, &w);
    gbinder_writer_append_int64(&w, handle);
    hw_params(&w, in);
    hw_bytes(&w, input);
    hw_bytes(&w, Bytes());          /* signature */
    hw_auth_token(&w);
    hw_verification_token(&w);
    GBinderRemoteReply* r = call(b, KM_FINISH, req, &rd, &e);
    if (!r) return KmError::UNKNOWN_ERROR;
    bool ok = km_read_params(&rd, out) && km_read_bytes(&rd, output);
    gbinder_remote_reply_unref(r);
    return ok ? e : KmError::UNKNOWN_ERROR;
}

static KmError
abort_op(Bench& b, guint64 handle)
{
    GBinderWriter w;
    GBinderReader rd;
    KmError e;
    GBinderLocalRequest* req = new_req(b, &w);
    gbinder_writer_append_int64(&w, handle);
    GBinderRemoteReply* r = call(b, KM_ABORT, req, &rd, &e);
    if (r) gbinder_remote_reply_unref(r);
    return e;
}

/* ------------------------------------------------------------------- checks */

static Bytes str(const char* s) { return Bytes(s, s + strlen(s)); }
template <typename E> static uint32_t u(E e) { return static_cast<uint32_t>(e); }

static int
openssl_verify(const Bytes& spki, const Bytes& msg, const Bytes& sig)
{
    char dir[] = "/tmp/km-bench.XXXXXX";
    if (system("command -v openssl >/dev/null 2>&1") != 0 || !mkdtemp(dir)) return -1;
    std::string d = dir;
    auto put = [&](const char* n, const Bytes& v) {
        FILE* f = fopen((d + "/" + n).c_str(), "wb");
        if (f) { fwrite(v.data(), 1, v.size(), f); fclose(f); }
    };
    put("pub.der", spki); put("msg", msg); put("sig", sig);
    std::string cmd = "openssl dgst -sha256 -keyform DER -verify " + d + "/pub.der"
        " -signature " + d + "/sig " + d + "/msg >/dev/null 2>&1";
    int rc = system(cmd.c_str());
    cmd = "rm -rf '" + d + "'";
    if (system(cmd.c_str())) { /* ignore */ }
    return rc == 0 ? 1 : 0;
}

static void
run(Bench& b)
{
    printf("-- EC P-256 --\n");
    AuthList ec;
    ec.addEnum(Tag::ALGORITHM, u(Algorithm::EC));
    ec.addUint(Tag::KEY_SIZE, 256);
    ec.addEnum(Tag::EC_CURVE, u(EcCurve::P_256));
    ec.addEnum(Tag::PURPOSE, u(Purpose::SIGN));
    ec.addEnum(Tag::PURPOSE, u(Purpose::VERIFY));
    ec.addEnum(Tag::DIGEST, u(Digest::SHA_2_256));
    ec.addBool(Tag::NO_AUTH_REQUIRED);
    Bytes blob, spki;
    KeyCharacteristics kc;
    KmError e = generate(b, ec, blob, kc);
    check(e == KmError::OK && !blob.empty(), "generateKey EC over binder");
    check(kc.hardwareEnforced.hasEnumVal(Tag::PURPOSE, u(Purpose::SIGN)) &&
          kc.hardwareEnforced.hasEnumVal(Tag::ORIGIN, u(Origin::GENERATED)),
          "KeyCharacteristics come back hardware-enforced");
    check(export_x509(b, blob, spki) == KmError::OK && spki.size() == 91,
          "exportKey X509 with empty clientId/appData (null children)");
    KeyCharacteristics kc2;
    check(characteristics(b, blob, kc2) == KmError::OK &&
          kc2.hardwareEnforced.params.size() == kc.hardwareEnforced.params.size(),
          "getKeyCharacteristics agrees");

    AuthList sp;
    sp.addEnum(Tag::DIGEST, u(Digest::SHA_2_256));
    AuthList out;
    guint64 h = 0;
    Bytes msg = str("signed over real binder, in two pieces");
    Bytes m1(msg.begin(), msg.begin() + 10), m2(msg.begin() + 10, msg.end()), o, sig;
    guint32 consumed = 0;
    e = begin(b, Purpose::SIGN, blob, sp, out, h);
    check(e == KmError::OK && h != 0, "begin SIGN");
    e = update(b, h, AuthList(), m1, consumed, o);
    check(e == KmError::OK && consumed == m1.size(), "update with empty inParams (null children)");
    e = finish(b, h, AuthList(), m2, sig);
    check(e == KmError::OK && !sig.empty(), "finish returns a signature");
    int v = openssl_verify(spki, msg, sig);
    check(v == 1, v < 0 ? "openssl verifies (no openssl!)" : "openssl verifies it with the exported key");

    printf("-- AES-256-GCM --\n");
    AuthList aes;
    aes.addEnum(Tag::ALGORITHM, u(Algorithm::AES));
    aes.addUint(Tag::KEY_SIZE, 256);
    aes.addEnum(Tag::BLOCK_MODE, u(BlockMode::GCM));
    aes.addEnum(Tag::PADDING, u(Padding::NONE));
    aes.addUint(Tag::MIN_MAC_LENGTH, 128);
    aes.addEnum(Tag::PURPOSE, u(Purpose::ENCRYPT));
    aes.addEnum(Tag::PURPOSE, u(Purpose::DECRYPT));
    aes.addBool(Tag::NO_AUTH_REQUIRED);
    Bytes ablob;
    check(generate(b, aes, ablob, kc) == KmError::OK, "generateKey AES-GCM over binder");
    AuthList gp;
    gp.addEnum(Tag::BLOCK_MODE, u(BlockMode::GCM));
    gp.addEnum(Tag::PADDING, u(Padding::NONE));
    gp.addUint(Tag::MAC_LENGTH, 128);
    out.params.clear();
    e = begin(b, Purpose::ENCRYPT, ablob, gp, out, h);
    const Bytes* nonce = out.firstBytes(Tag::NONCE);
    check(e == KmError::OK && nonce && nonce->size() == 12,
          "begin ENCRYPT returns a NONCE in outParams (a bytes tag over binder)");
    AuthList aad;
    aad.addBytes(Tag::ASSOCIATED_DATA, str("header"));
    Bytes pt = str("plaintext that crosses binder twice"), ct, back;
    e = finish(b, h, aad, pt, ct);
    check(e == KmError::OK && ct.size() == pt.size() + 16, "finish ENCRYPT with AAD");
    if (nonce) {
        AuthList dp = gp;
        dp.addBytes(Tag::NONCE, *nonce);
        e = begin(b, Purpose::DECRYPT, ablob, dp, out, h);
        e = e == KmError::OK ? finish(b, h, aad, ct, back) : e;
        check(e == KmError::OK && back == pt, "and decrypts back");
    }
    /* Past tpm2_encryptdecrypt's 65535-byte input limit -- the size an app
     * first hit it with. */
    Bytes big(100000), bigCt, bigBack;
    for (size_t i = 0; i < big.size(); i++) big[i] = (guint8) (i * 31 + 7);
    out.params.clear();
    e = begin(b, Purpose::ENCRYPT, ablob, gp, out, h);
    nonce = out.firstBytes(Tag::NONCE);
    e = e == KmError::OK ? finish(b, h, aad, big, bigCt) : e;
    check(e == KmError::OK && bigCt.size() == big.size() + 16, "GCM encrypt 100000 bytes");
    if (nonce) {
        AuthList dp = gp;
        dp.addBytes(Tag::NONCE, *nonce);
        e = begin(b, Purpose::DECRYPT, ablob, dp, out, h);
        e = e == KmError::OK ? finish(b, h, aad, bigCt, bigBack) : e;
        check(e == KmError::OK && bigBack == big, "and decrypts back");
    }
    check(abort_op(b, 0x1234) == KmError::INVALID_OPERATION_HANDLE,
          "abort of an unknown handle: INVALID_OPERATION_HANDLE");
}

int main(int argc, char** argv)
{
    const char* device = "/dev/hwbinder";
    const char* name = "strongbox-bench";

    gutil_log_set_type(GLOG_TYPE_STDERR, "km-bench");
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--name") && i + 1 < argc) name = argv[++i];
        else device = argv[i];
    }
    GBinderServiceManager* sm = gbinder_servicemanager_new2(device, "hidl", "hidl");
    if (!sm) { fprintf(stderr, "no service manager on %s\n", device); return 2; }
    std::string fq = std::string(KM_IFACE) + "/" + name;
    int status = 0;
    GBinderRemoteObject* remote = gbinder_servicemanager_get_service_sync(sm,
        fq.c_str(), &status);
    if (!remote) { fprintf(stderr, "%s not found (%d)\n", fq.c_str(), status); return 2; }
    Bench b;
    b.client = gbinder_client_new(remote, KM_IFACE);
    printf("km-bench against %s\n", fq.c_str());
    run(b);
    printf("\n%d passed, %d failed\n", g_pass, g_fail);
    gbinder_client_unref(b.client);
    gbinder_servicemanager_unref(sm);
    return g_fail ? 1 : 0;
}
