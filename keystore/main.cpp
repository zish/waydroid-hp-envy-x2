// main.cpp -- keystore-engine: a host CLI that exercises the engine against a
// TPM through any TCTI. No binder, no Android. Stage 1 proved the TPM semantics
// with it; stage 4 drives keymaster's begin/update/finish model through it, so
// everything but the HIDL marshalling is tested before a session restart.
//
//   keystore-engine selftest [--tcti <tcti>]
//   keystore-engine backend  [--tcti <tcti>]
//
// Default TCTI is $TPM2TOOLS_TCTI if set, else the waydroid-swtpm socket. On the
// dev box, point --tcti at a throwaway swtpm (selftest.sh does); on bigtab01, at
// the service's socket (needs group tss) or a throwaway one.
//
// The checks are against external references wherever one exists: published
// SHA-256 and GCM vectors, CBC/CTR/ECB values from a reference AES, and openssl
// verifying the ECDSA signatures with the exported public key. An engine that
// only agrees with itself is what let stage 1 ship two wrong constants.
#include "engine.h"
#include "soft_crypto.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unistd.h>

namespace wks { TpmBackend* makeToolsBackend(const std::string& tcti); }

using namespace wks;

static int g_pass = 0, g_fail = 0, g_skip = 0;
static void check(bool ok, const char* what) {
    printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what);
    if (ok) g_pass++; else g_fail++;
}
static void skip(const char* what, const char* why) {
    printf("  [SKIP] %s (%s)\n", what, why);
    g_skip++;
}

static Bytes hex(const char* s) {
    Bytes b;
    for (size_t i = 0; s[i] && s[i + 1]; i += 2) {
        unsigned v;
        sscanf(s + i, "%2x", &v);
        b.push_back(uint8_t(v));
    }
    return b;
}
static Bytes str(const char* s) { return Bytes(s, s + strlen(s)); }
template <typename E> static uint32_t u(E e) { return static_cast<uint32_t>(e); }

// One whole operation: begin, an update per chunk (AAD on the first), finish.
struct OpResult {
    KmError begin = KmError::UNKNOWN_ERROR, update = KmError::OK,
            finish = KmError::UNKNOWN_ERROR;
    AuthList beginOut;
    Bytes output;
    bool ok() const {
        return begin == KmError::OK && update == KmError::OK && finish == KmError::OK;
    }
};
static OpResult runOp(Engine& eng, Purpose p, const Bytes& blob, const AuthList& params,
                      const std::vector<Bytes>& chunks, const Bytes& aad = {}) {
    OpResult r;
    uint64_t h = 0;
    r.begin = eng.begin(p, blob, params, r.beginOut, h);
    if (r.begin != KmError::OK) return r;
    for (size_t i = 0; i + 1 < chunks.size(); i++) {   // all but the last chunk
        AuthList in, out;
        if (i == 0 && !aad.empty()) in.addBytes(Tag::ASSOCIATED_DATA, aad);
        uint32_t consumed = 0;
        Bytes o;
        r.update = eng.update(h, in, chunks[i], consumed, out, o);
        if (r.update != KmError::OK) return r;
        if (consumed != chunks[i].size()) { r.update = KmError::UNKNOWN_ERROR; return r; }
        r.output.insert(r.output.end(), o.begin(), o.end());
    }
    AuthList fin, out;
    if (chunks.size() <= 1 && !aad.empty()) fin.addBytes(Tag::ASSOCIATED_DATA, aad);
    Bytes last = chunks.empty() ? Bytes() : chunks.back(), o;
    r.finish = eng.finish(h, fin, last, Bytes(), out, o);
    r.output.insert(r.output.end(), o.begin(), o.end());
    return r;
}

static AuthList ecRequest() {
    AuthList a;
    a.addEnum(Tag::ALGORITHM, u(Algorithm::EC));
    a.addEnum(Tag::EC_CURVE, u(EcCurve::P_256));
    a.addUint(Tag::KEY_SIZE, 256);
    a.addEnum(Tag::DIGEST, u(Digest::SHA_2_256));
    a.addEnum(Tag::DIGEST, u(Digest::NONE));
    a.addEnum(Tag::PURPOSE, u(Purpose::SIGN));
    a.addEnum(Tag::PURPOSE, u(Purpose::VERIFY));
    a.addBool(Tag::NO_AUTH_REQUIRED);
    return a;
}

static AuthList aesRequest(uint32_t bits, bool callerNonce) {
    AuthList a;
    a.addEnum(Tag::ALGORITHM, u(Algorithm::AES));
    a.addUint(Tag::KEY_SIZE, bits);
    for (auto m : {BlockMode::ECB, BlockMode::CBC, BlockMode::CTR, BlockMode::GCM})
        a.addEnum(Tag::BLOCK_MODE, u(m));
    a.addEnum(Tag::PADDING, u(Padding::NONE));
    a.addEnum(Tag::PADDING, u(Padding::PKCS7));
    a.addUint(Tag::MIN_MAC_LENGTH, 96);
    a.addEnum(Tag::PURPOSE, u(Purpose::ENCRYPT));
    a.addEnum(Tag::PURPOSE, u(Purpose::DECRYPT));
    if (callerNonce) a.addBool(Tag::CALLER_NONCE);
    a.addBool(Tag::NO_AUTH_REQUIRED);
    return a;
}

static AuthList aesParams(BlockMode m, Padding p, const Bytes& nonce = {},
                          uint32_t macBits = 0) {
    AuthList a;
    a.addEnum(Tag::BLOCK_MODE, u(m));
    a.addEnum(Tag::PADDING, u(p));
    if (!nonce.empty()) a.addBytes(Tag::NONCE, nonce);
    if (macBits) a.addUint(Tag::MAC_LENGTH, macBits);
    return a;
}

static AuthList signParams(Digest d) {
    AuthList a;
    a.addEnum(Tag::DIGEST, u(d));
    return a;
}

// openssl, given the exported SubjectPublicKeyInfo, as the outside judge of an
// ECDSA signature over `msg` with SHA-256. -1 if openssl is not available.
static int opensslVerify(const Bytes& spki, const Bytes& msg, const Bytes& sig) {
    if (system("command -v openssl >/dev/null 2>&1") != 0) return -1;
    char dir[] = "/tmp/wks-ossl.XXXXXX";
    if (!mkdtemp(dir)) return -1;
    std::string d = dir;
    auto put = [&](const char* n, const Bytes& b) {
        FILE* f = fopen((d + "/" + n).c_str(), "wb");
        if (!f) return;
        fwrite(b.data(), 1, b.size(), f);
        fclose(f);
    };
    put("pub.der", spki); put("msg", msg); put("sig", sig);
    std::string cmd = "openssl dgst -sha256 -keyform DER -verify " + d +
                      "/pub.der -signature " + d + "/sig " + d + "/msg >/dev/null 2>&1";
    int rc = system(cmd.c_str());
    std::string rm = "rm -rf '" + d + "'";
    if (system(rm.c_str()) != 0) { /* ignore */ }
    return rc == 0 ? 1 : 0;
}

static bool hasTagVal(const AuthList& a, Tag t, uint32_t v) { return a.hasEnumVal(t, v); }

// Stage 5 (docs/74): the shared HMAC key and auth-bound keys, against a clock
// the test owns. The KDF and the MACs are checked against OpenSSL and the live
// TEE elsewhere (tests/cpp/test_keystore_auth.cpp, km-bench --tee-probe); what
// is checked here is the engine's use of them -- which token opens which key.
static void authSelftest(const std::string& tcti) {
    printf("-- stage 5: the shared HMAC key --\n");
    uint64_t clock = 1000000;
    EngineOptions strictOpts;
    strictOpts.clockMs = [&clock] { return clock; };
    Engine eng(std::unique_ptr<TpmBackend>(makeToolsBackend(tcti)), strictOpts);
    const HmacSharingParams& mine = eng.hmacSharingParameters();
    check(mine.nonce.size() == 32, "a 32-byte per-process nonce");
    HmacSharingParams tee{Bytes(), Bytes(32, 0x77)};
    Bytes chk;
    check(eng.computeSharedHmac({tee}, chk) == KmError::INVALID_ARGUMENT && chk.empty() &&
              !eng.hasSharedKey(),
          "computeSharedHmac without our own parameters: INVALID_ARGUMENT");
    std::vector<HmacSharingParams> all{tee, mine};
    check(eng.computeSharedHmac(all, chk) == KmError::OK &&
              chk == sharingCheck(deriveSharedHmacKey(imageKeyAgreementKey(), all)),
          "with them: OK, and the check is HMAC(H, ...) for K = 0^256");
    const Bytes h = deriveSharedHmacKey(imageKeyAgreementKey(), all);

    const uint64_t sid = 0x5151a5a5c3c3e7e7ull;
    auto token = [&](uint64_t challenge, uint32_t type, uint64_t ts) {
        HardwareAuthToken t;
        t.challenge = challenge;
        t.userId = sid;
        t.authenticatorId = 0;
        t.authenticatorType = type;
        t.timestamp = ts;
        t.mac = authTokenMac(h, t);
        return t;
    };
    const uint32_t pw = u(HwAuthType::PASSWORD), fp = u(HwAuthType::FINGERPRINT);

    printf("-- stage 5: a key with an AUTH_TIMEOUT --\n");
    AuthList req = ecRequest();
    req.remove(Tag::NO_AUTH_REQUIRED);
    req.params.emplace_back(Tag::USER_SECURE_ID, sid);
    req.addEnum(Tag::USER_AUTH_TYPE, pw);
    req.addUint(Tag::AUTH_TIMEOUT, 30);
    Bytes key, spki;
    KeyCharacteristics kc;
    check(eng.generateKey(req, key, kc) == KmError::OK &&
              kc.hardwareEnforced.has(Tag::USER_SECURE_ID) &&
              kc.hardwareEnforced.has(Tag::AUTH_TIMEOUT),
          "generates, the auth tags hardware-enforced (tokens must be signed)");
    eng.exportKey(KeyFormat::X509, key, {}, {}, spki);
    Bytes msg = str("signed only after the user authenticated");
    auto beginWith = [&](const HardwareAuthToken& t, std::string* why = nullptr) {
        AuthList out;
        uint64_t hd = 0;
        KmError e = eng.begin(Purpose::SIGN, key, signParams(Digest::SHA_2_256), out, hd, t,
                              why);
        if (e == KmError::OK) eng.abort(hd);
        return e;
    };
    std::string why;
    check(beginWith(HardwareAuthToken(), &why) == KmError::KEY_USER_NOT_AUTHENTICATED &&
              why == "no auth token",
          "begin without a token: KEY_USER_NOT_AUTHENTICATED (\"no auth token\")");
    {
        AuthList out;
        uint64_t hd = 0;
        HardwareAuthToken t = token(0, pw, clock - 5000);
        KmError e = eng.begin(Purpose::SIGN, key, signParams(Digest::SHA_2_256), out, hd, t,
                              &why);
        Bytes sig;
        AuthList fo;
        e = e == KmError::OK ? eng.finish(hd, AuthList(), msg, {}, fo, sig) : e;
        int v = e == KmError::OK ? opensslVerify(spki, msg, sig) : 0;
        check(e == KmError::OK && v != 0,
              "a signed password token 5 s old opens it, and the signature verifies");
        printf("         (%s)\n", why.c_str());
    }
    HardwareAuthToken bad = token(0, pw, clock);
    bad.userId = sid + 1;
    bad.mac = authTokenMac(h, bad);
    check(beginWith(bad) == KmError::KEY_USER_NOT_AUTHENTICATED, "another user's token: refused");
    check(beginWith(token(0, fp, clock)) == KmError::KEY_USER_NOT_AUTHENTICATED,
          "a fingerprint token on a password-only key: refused");
    check(beginWith(token(0, pw, clock - 30001)) == KmError::KEY_USER_NOT_AUTHENTICATED,
          "30.001 s old on a 30 s key: refused");
    check(beginWith(token(0, pw, clock - 30000)) == KmError::OK, "30.000 s old: accepted");
    check(beginWith(token(0, pw, clock + 1)) == KmError::KEY_USER_NOT_AUTHENTICATED,
          "dated 1 ms in the future: refused");
    bad = token(0, pw, clock);
    bad.mac[7] ^= 0x10;
    check(beginWith(bad) == KmError::KEY_USER_NOT_AUTHENTICATED, "one MAC bit flipped: refused");
    bad.mac.assign(32, 0);
    check(beginWith(bad, &why) == KmError::KEY_USER_NOT_AUTHENTICATED &&
              why == "auth token is unsigned (32 zero bytes)",
          "an unsigned token (what this image's gatekeeper sends): refused when strict");

    printf("-- stage 5: verification tokens --\n");
    {
        AuthList out, fo;
        uint64_t hd = 0;
        Bytes sig;
        eng.begin(Purpose::SIGN, key, signParams(Digest::SHA_2_256), out, hd,
                  token(0, pw, clock));
        VerificationToken vt;
        vt.challenge = hd;
        vt.timestamp = clock;
        vt.securityLevel = 1;   // km_compat's label; the MAC is over SOFTWARE
        vt.mac = verificationTokenMac(h, vt, VtForm::AOSP_SOFTWARE);
        VerificationToken wrong = vt;
        wrong.challenge = hd + 1;
        wrong.mac = verificationTokenMac(h, wrong, VtForm::AOSP_SOFTWARE);
        uint32_t c = 0;
        Bytes o;
        check(eng.update(hd, AuthList(), msg, c, out, o, HardwareAuthToken(), wrong) ==
                  KmError::KEY_USER_NOT_AUTHENTICATED &&
              eng.abort(hd) == KmError::INVALID_OPERATION_HANDLE,
              "a verification token for another operation: refused, and it ends the op");
        eng.begin(Purpose::SIGN, key, signParams(Digest::SHA_2_256), out, hd,
                  token(0, pw, clock));
        vt.challenge = hd;
        vt.mac = verificationTokenMac(h, vt, VtForm::AOSP_SOFTWARE);
        KmError e = eng.finish(hd, AuthList(), msg, {}, fo, sig, HardwareAuthToken(), vt, &why);
        check(e == KmError::OK, "the TEE's own form (machine order, SOFTWARE) is accepted");
        printf("         (%s)\n", why.c_str());
        eng.begin(Purpose::SIGN, key, signParams(Digest::SHA_2_256), out, hd,
                  token(0, pw, clock));
        vt.challenge = hd;
        vt.mac = verificationTokenMac(h, vt, VtForm::SPEC);
        check(eng.finish(hd, AuthList(), msg, {}, fo, sig, HardwareAuthToken(), vt) ==
                  KmError::OK,
              "so is the HAL's (big-endian, the level as sent)");
        eng.begin(Purpose::SIGN, key, signParams(Digest::SHA_2_256), out, hd,
                  token(0, pw, clock));
        vt.challenge = hd;
        vt.mac.assign(32, 0x42);
        check(eng.finish(hd, AuthList(), msg, {}, fo, sig, HardwareAuthToken(), vt) ==
                  KmError::KEY_USER_NOT_AUTHENTICATED,
              "a verification token with a bad MAC: refused");
    }

    printf("-- stage 5: a per-operation key --\n");
    {
        AuthList r = aesRequest(128, false);
        r.remove(Tag::NO_AUTH_REQUIRED);
        r.params.emplace_back(Tag::USER_SECURE_ID, sid);
        r.addEnum(Tag::USER_AUTH_TYPE, u(HwAuthType::ANY));
        Bytes ak;
        check(eng.generateKey(r, ak, kc) == KmError::OK, "AES-128, USER_SECURE_ID, no timeout");
        AuthList p = aesParams(BlockMode::CBC, Padding::PKCS7);
        AuthList out, fo;
        uint64_t hd = 0;
        Bytes o;
        check(eng.begin(Purpose::ENCRYPT, ak, p, out, hd) == KmError::OK,
              "begin needs no token: it is due on update and finish");
        check(eng.finish(hd, AuthList(), msg, {}, fo, o) == KmError::KEY_USER_NOT_AUTHENTICATED,
              "finish without one: refused");
        eng.begin(Purpose::ENCRYPT, ak, p, out, hd);
        check(eng.finish(hd, AuthList(), msg, {}, fo, o, token(hd ^ 1, fp, 0)) ==
                  KmError::KEY_USER_NOT_AUTHENTICATED,
              "a token issued for another operation: refused");
        eng.begin(Purpose::ENCRYPT, ak, p, out, hd);
        uint32_t c = 0;
        KmError e = eng.update(hd, AuthList(), msg, c, out, o, token(hd, fp, 0));
        e = e == KmError::OK ? eng.finish(hd, AuthList(), {}, {}, fo, o, token(hd, fp, 0)) : e;
        check(e == KmError::OK && o.size() == 48,
              "a token whose challenge is the handle, on each call: accepted");
    }

    printf("-- stage 5: --accept-unsigned-auth-tokens --\n");
    {
        EngineOptions lax = strictOpts;
        lax.acceptUnsignedAuthTokens = true;
        Engine le(std::unique_ptr<TpmBackend>(makeToolsBackend(tcti)), lax);
        Bytes lk;
        KeyCharacteristics lkc;
        check(le.generateKey(req, lk, lkc) == KmError::OK &&
                  lkc.softwareEnforced.has(Tag::USER_SECURE_ID) &&
                  !lkc.hardwareEnforced.has(Tag::USER_SECURE_ID) &&
                  lkc.softwareEnforced.has(Tag::AUTH_TIMEOUT),
              "the auth tags are reported at the KEYSTORE level, not STRONGBOX");
        HardwareAuthToken z;
        z.userId = sid;
        z.authenticatorType = pw;
        z.timestamp = clock - 1000;
        z.mac.assign(32, 0);
        AuthList out;
        uint64_t hd = 0;
        check(le.begin(Purpose::SIGN, lk, signParams(Digest::SHA_2_256), out, hd, z, &why) ==
                  KmError::OK,
              "an unsigned token opens it (no shared key needed)");
        printf("         (%s)\n", why.c_str());
        le.abort(hd);
        z.timestamp = clock - 31000;
        check(le.begin(Purpose::SIGN, lk, signParams(Digest::SHA_2_256), out, hd, z) ==
                  KmError::KEY_USER_NOT_AUTHENTICATED,
              "but the timeout still holds");
        z.timestamp = clock;
        z.mac[0] = 1;
        check(le.begin(Purpose::SIGN, lk, signParams(Digest::SHA_2_256), out, hd, z) ==
                  KmError::KEY_USER_NOT_AUTHENTICATED,
              "and a MAC that is neither zero nor valid is still refused");
    }
}

static int selftest(const std::string& tcti) {
    Engine eng(std::unique_ptr<TpmBackend>(makeToolsBackend(tcti)));
    printf("backend: %s\n", eng.backendDescription().c_str());

    printf("-- constants (the two stage-1 bugs) --\n");
    check(u(Tag::PURPOSE) == 0x20000001u, "PURPOSE is ENUM_REP|1 (0x20000001)");
    check(int(KmError::INVALID_KEY_BLOB) == -33 &&
          int(KmError::INVALID_OPERATION_HANDLE) == -28,
          "ErrorCode values are keymaster's (INVALID_KEY_BLOB -33)");

    printf("-- software primitives --\n");
    check(Sha256::hash(str("abc")) ==
          hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
          "SHA-256(\"abc\")");
    check(Sha256::hash(str("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")) ==
          hex("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
          "SHA-256 of the two-block FIPS vector");
    Bytes padded = pkcs7Pad(str("abc"));
    Bytes unp = padded;
    bool unpadOk = padded.size() == 16 && padded[15] == 13 && pkcs7Unpad(unp) &&
                   unp == str("abc");
    Bytes badPad = padded; badPad[14] = 1;
    check(unpadOk && !pkcs7Unpad(badPad), "PKCS#7 pads, unpads and rejects bad padding");

    printf("-- primary --\n");
    check(eng.init() == KmError::OK, "ensure persistent primary");

    printf("-- EC P-256 --\n");
    Bytes ec;
    KeyCharacteristics kc;
    check(eng.generateKey(ecRequest(), ec, kc) == KmError::OK, "generate EC P-256");
    check(hasTagVal(kc.hardwareEnforced, Tag::PURPOSE, u(Purpose::SIGN)) &&
          hasTagVal(kc.hardwareEnforced, Tag::ORIGIN, u(Origin::GENERATED)) &&
          hasTagVal(kc.hardwareEnforced, Tag::EC_CURVE, u(EcCurve::P_256)),
          "characteristics: PURPOSE, ORIGIN=GENERATED, EC_CURVE hardware-enforced");
    Bytes spki;
    check(eng.exportKey(KeyFormat::X509, ec, {}, {}, spki) == KmError::OK &&
          spki.size() == 91 && spki[0] == 0x30 && spki[26] == 0x04,
          "exportKey(X509) is a 91-byte P-256 SubjectPublicKeyInfo");

    Bytes msg = str("a message for the StrongBox, split across two calls");
    Bytes m1(msg.begin(), msg.begin() + 20), m2(msg.begin() + 20, msg.end());
    OpResult s = runOp(eng, Purpose::SIGN, ec, signParams(Digest::SHA_2_256), {m1, m2});
    check(s.ok() && s.output.size() >= 8 && s.output[0] == 0x30,
          "begin/update/finish SIGN SHA-256 returns a DER signature");
    int v = opensslVerify(spki, msg, s.output);
    if (v < 0) skip("openssl verifies the SHA-256 signature", "no openssl");
    else check(v == 1, "openssl verifies the SHA-256 signature with the exported key");
    Bytes tampered = msg; tampered[0] ^= 1;
    if (v >= 0)
        check(opensslVerify(spki, tampered, s.output) == 0,
              "openssl rejects it over a different message");

    OpResult n = runOp(eng, Purpose::SIGN, ec, signParams(Digest::NONE),
                       {Sha256::hash(msg)});
    v = n.ok() ? opensslVerify(spki, msg, n.output) : 0;
    if (v < 0) skip("DIGEST=NONE over a SHA-256 digest", "no openssl");
    else check(n.ok() && v == 1, "DIGEST=NONE over a caller's SHA-256 digest verifies");

    check(runOp(eng, Purpose::VERIFY, ec, signParams(Digest::SHA_2_256), {msg}).begin ==
              KmError::UNSUPPORTED_PURPOSE,
          "VERIFY is the caller's job: UNSUPPORTED_PURPOSE");
    check(runOp(eng, Purpose::SIGN, ec, signParams(Digest::SHA_2_512), {msg}).begin ==
              KmError::UNSUPPORTED_DIGEST,
          "SHA-512 is not a StrongBox digest: UNSUPPORTED_DIGEST");
    check(runOp(eng, Purpose::SIGN, ec, AuthList(), {msg}).begin ==
              KmError::UNSUPPORTED_DIGEST,
          "no DIGEST at begin: UNSUPPORTED_DIGEST");
    check(runOp(eng, Purpose::ENCRYPT, ec, AuthList(), {msg}).begin ==
              KmError::INCOMPATIBLE_PURPOSE,
          "ENCRYPT with an EC key: INCOMPATIBLE_PURPOSE");

    printf("-- the TPM enforces the blob's tags --\n");
    {
        auto kb = KeyBlob::parse(ec);
        // Drop DIGEST=NONE from the stored list: a narrower key, so the engine
        // itself would still allow SHA-256. Only the TPM can notice.
        auto& ps = kb->authorizations.params;
        for (auto it = ps.begin(); it != ps.end(); ++it)
            if (it->tag == Tag::DIGEST && it->u == u(Digest::NONE)) { ps.erase(it); break; }
        OpResult t = runOp(eng, Purpose::SIGN, kb->serialize(),
                           signParams(Digest::SHA_2_256), {msg});
        check(t.begin == KmError::OK && t.finish != KmError::OK,
              "an edited tag list passes the engine and fails TPM authorization");
        OpResult again = runOp(eng, Purpose::SIGN, ec, signParams(Digest::SHA_2_256), {msg});
        check(again.ok(), "and the real key still signs (noda: no lockout)");
    }

    printf("-- key generation refusals --\n");
    {
        Bytes b; KeyCharacteristics k;
        AuthList r = ecRequest(); r.addEnum(Tag::DIGEST, u(Digest::SHA_2_512));
        check(eng.generateKey(r, b, k) == KmError::UNSUPPORTED_DIGEST,
              "EC with SHA-512: UNSUPPORTED_DIGEST");
        r = ecRequest(); r.remove(Tag::EC_CURVE); r.remove(Tag::KEY_SIZE);
        r.addEnum(Tag::EC_CURVE, u(EcCurve::P_384));
        check(eng.generateKey(r, b, k) == KmError::UNSUPPORTED_EC_CURVE,
              "EC P-384: UNSUPPORTED_EC_CURVE");
        r = ecRequest(); r.addBool(Tag::TRUSTED_CONFIRMATION_REQUIRED);
        check(eng.generateKey(r, b, k) == KmError::UNSUPPORTED_TAG,
              "TRUSTED_CONFIRMATION_REQUIRED: UNSUPPORTED_TAG");
        r = ecRequest(); r.addBool(Tag::ROLLBACK_RESISTANCE);
        check(eng.generateKey(r, b, k) == KmError::ROLLBACK_RESISTANCE_UNAVAILABLE,
              "ROLLBACK_RESISTANCE: ROLLBACK_RESISTANCE_UNAVAILABLE");
        r = ecRequest(); r.remove(Tag::PURPOSE); r.addEnum(Tag::PURPOSE, u(Purpose::VERIFY));
        check(eng.generateKey(r, b, k) == KmError::UNSUPPORTED_PURPOSE,
              "EC without PURPOSE=SIGN: UNSUPPORTED_PURPOSE");
        r = aesRequest(128, false); r.remove(Tag::MIN_MAC_LENGTH);
        check(eng.generateKey(r, b, k) == KmError::MISSING_MIN_MAC_LENGTH,
              "AES-GCM without MIN_MAC_LENGTH: MISSING_MIN_MAC_LENGTH");
        r = aesRequest(128, false); r.remove(Tag::KEY_SIZE); r.addUint(Tag::KEY_SIZE, 192);
        check(eng.generateKey(r, b, k) == KmError::UNSUPPORTED_KEY_SIZE,
              "AES-192: UNSUPPORTED_KEY_SIZE");
    }

    printf("-- APPLICATION_ID binding --\n");
    {
        AuthList r = ecRequest(); r.addBytes(Tag::APPLICATION_ID, str("app-id"));
        Bytes b, out; KeyCharacteristics k;
        check(eng.generateKey(r, b, k) == KmError::OK &&
              !k.hardwareEnforced.has(Tag::APPLICATION_ID) &&
              !k.softwareEnforced.has(Tag::APPLICATION_ID),
              "generate bound key; APPLICATION_ID is never disclosed");
        check(eng.exportKey(KeyFormat::X509, b, {}, {}, out) == KmError::INVALID_KEY_BLOB,
              "without its APPLICATION_ID the key does not exist");
        check(eng.exportKey(KeyFormat::X509, b, str("app-id"), {}, out) == KmError::OK,
              "with it, the key exports");
    }

    printf("-- AES known answers, through an imported key --\n");
    Bytes K128 = hex("feffe9928665731c6d6a8f9467308308");
    Bytes aes;
    check(eng.importKey(aesRequest(128, true), KeyFormat::RAW, K128, aes, kc) == KmError::OK &&
          hasTagVal(kc.hardwareEnforced, Tag::ORIGIN, u(Origin::IMPORTED)),
          "import AES-128 raw, ORIGIN=IMPORTED");
    Bytes P = hex("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72"
                  "1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39");
    Bytes A = hex("feedfacedeadbeeffeedfacedeadbeefabaddad2");
    Bytes IV = hex("cafebabefacedbaddecaf888");
    Bytes CT = hex("42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e"
                   "21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091"
                   "5bc94fbc3221a5db94fae95ae7121a47");
    Bytes P1(P.begin(), P.begin() + 23), P2(P.begin() + 23, P.end());
    OpResult g = runOp(eng, Purpose::ENCRYPT, aes,
                       aesParams(BlockMode::GCM, Padding::NONE, IV, 128), {P1, P2}, A);
    check(g.ok() && g.output == CT, "GCM encrypt = SP 800-38D test case 4 (C||T)");
    OpResult gd = runOp(eng, Purpose::DECRYPT, aes,
                        aesParams(BlockMode::GCM, Padding::NONE, IV, 128), {CT}, A);
    check(gd.ok() && gd.output == P, "GCM decrypt of test case 4 recovers P");
    Bytes badTag = CT; badTag.back() ^= 1;
    OpResult gb = runOp(eng, Purpose::DECRYPT, aes,
                        aesParams(BlockMode::GCM, Padding::NONE, IV, 128), {badTag}, A);
    check(gb.finish == KmError::VERIFICATION_FAILED && gb.output.empty(),
          "a flipped tag bit: VERIFICATION_FAILED and no plaintext");
    OpResult ge = runOp(eng, Purpose::ENCRYPT, aes,
                        aesParams(BlockMode::GCM, Padding::NONE, IV, 128), {Bytes()});
    check(ge.ok() && ge.output == hex("3247184b3c4f69a44dbcd22887bbb418"),
          "GCM with empty P and A: tag only");
    OpResult g96 = runOp(eng, Purpose::ENCRYPT, aes,
                         aesParams(BlockMode::GCM, Padding::NONE, IV, 96), {P}, A);
    check(g96.ok() && g96.output.size() == P.size() + 12 &&
          Bytes(g96.output.end() - 12, g96.output.end()) ==
              Bytes(CT.end() - 16, CT.end() - 4),
          "MAC_LENGTH=96 truncates the same tag");

    Bytes iv16 = hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff");
    Bytes twenty = str("twenty bytes of text");
    OpResult cbc = runOp(eng, Purpose::ENCRYPT, aes,
                         aesParams(BlockMode::CBC, Padding::PKCS7, iv16), {twenty});
    check(cbc.ok() && cbc.output ==
          hex("1d3a903e22e6da6f436f62f844b19fda87cfa912c2de9d324a3b1c855f0dca1e"),
          "CBC/PKCS7 encrypt matches reference AES");
    OpResult cbcd = runOp(eng, Purpose::DECRYPT, aes,
                          aesParams(BlockMode::CBC, Padding::PKCS7, iv16), {cbc.output});
    check(cbcd.ok() && cbcd.output == twenty, "CBC/PKCS7 decrypt and unpad");
    OpResult ctr = runOp(eng, Purpose::ENCRYPT, aes,
                         aesParams(BlockMode::CTR, Padding::NONE, iv16), {twenty});
    check(ctr.ok() && ctr.output == hex("bb872e5aba6edee05c0c5228ea2d6066907707e6"),
          "CTR encrypt matches reference AES");
    OpResult ecb = runOp(eng, Purpose::ENCRYPT, aes,
                         aesParams(BlockMode::ECB, Padding::PKCS7), {twenty});
    check(ecb.ok() && ecb.output ==
          hex("e6690a3bf5b6a7f4bad912fdc8a29c086775181f581243c443fbe1d8a07a690b"),
          "ECB/PKCS7 encrypt matches reference AES");

    // Past tpm2_encryptdecrypt's 65535-byte input limit, so the backend has to
    // split and chain: 150000 bytes, compared by hash with a reference AES.
    Bytes huge(150000);
    for (size_t i = 0; i < huge.size(); i++) huge[i] = uint8_t(i * 31 + 7);
    struct { BlockMode m; const char* sha; const char* what; } bigs[] = {
        {BlockMode::CBC, "f3f0da1739834362e39d20158c102e4538521f767fdb28acd0222e16ec0f2cb7",
         "CBC over 150000 bytes (three tpm2 runs, IV chained) matches reference"},
        {BlockMode::CTR, "e79d9ecc813f755f482af8f1574559bb4955bd4890a3eee9a1b167e9335f8c7a",
         "CTR over 150000 bytes matches reference"},
        {BlockMode::ECB, "97b5493f4e4ed4a2b40c9f9baf17d302270f6585ef99bc3fe41ee10ba7d546da",
         "ECB over 150000 bytes matches reference"},
    };
    for (const auto& t : bigs) {
        OpResult r = runOp(eng, Purpose::ENCRYPT, aes,
                           aesParams(t.m, Padding::NONE, t.m == BlockMode::ECB ? Bytes() : iv16),
                           {huge});
        check(r.ok() && Sha256::hash(r.output) == hex(t.sha), t.what);
    }
    OpResult gh = runOp(eng, Purpose::ENCRYPT, aes,
                        aesParams(BlockMode::GCM, Padding::NONE, IV, 128), {huge}, A);
    check(gh.ok() && Sha256::hash(gh.output) ==
          hex("1e993c0adb529750bec873663215204b483f9e4341a5b26b78d634d8212296e9"),
          "GCM over 150000 bytes (C||T) matches reference");
    OpResult ghd = runOp(eng, Purpose::DECRYPT, aes,
                         aesParams(BlockMode::GCM, Padding::NONE, IV, 128), {gh.output}, A);
    check(ghd.ok() && ghd.output == huge, "and decrypts back");

    Bytes K256 = hex("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308");
    Bytes aes256;
    check(eng.importKey(aesRequest(256, true), KeyFormat::RAW, K256, aes256, kc) ==
              KmError::OK, "import AES-256 raw");
    OpResult g256 = runOp(eng, Purpose::ENCRYPT, aes256,
                          aesParams(BlockMode::GCM, Padding::NONE, IV, 128), {P}, A);
    check(g256.ok() && g256.output ==
          hex("522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa"
              "8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662"
              "76fc6ece0f4e1768cddf8853bb2d551b"),
          "AES-256 GCM = SP 800-38D test case 16");

    printf("-- AES generated in the TPM --\n");
    Bytes gen;
    check(eng.generateKey(aesRequest(256, false), gen, kc) == KmError::OK,
          "generate AES-256 (no CALLER_NONCE)");
    Bytes big(5000);
    for (size_t i = 0; i < big.size(); i++) big[i] = uint8_t(i * 31 + 7);
    Bytes b1(big.begin(), big.begin() + 1500), b2(big.begin() + 1500, big.end());
    OpResult ge2 = runOp(eng, Purpose::ENCRYPT, gen,
                         aesParams(BlockMode::GCM, Padding::NONE, {}, 128), {b1, b2}, A);
    const Bytes* nonce = ge2.beginOut.firstBytes(Tag::NONCE);
    check(ge2.ok() && nonce && nonce->size() == 12 && ge2.output.size() == big.size() + 16,
          "GCM encrypt of 5000 bytes; begin returns a 12-byte NONCE");
    OpResult gd2 = nonce ? runOp(eng, Purpose::DECRYPT, gen,
                                 aesParams(BlockMode::GCM, Padding::NONE, *nonce, 128),
                                 {ge2.output}, A)
                         : OpResult();
    check(gd2.ok() && gd2.output == big, "and decrypts back, across TPM buffer chunks");
    check(runOp(eng, Purpose::ENCRYPT, gen,
                aesParams(BlockMode::GCM, Padding::NONE, IV, 128), {P}).begin ==
              KmError::CALLER_NONCE_PROHIBITED,
          "a caller nonce without CALLER_NONCE: CALLER_NONCE_PROHIBITED");
    check(runOp(eng, Purpose::DECRYPT, gen,
                aesParams(BlockMode::GCM, Padding::NONE, {}, 128), {CT}).begin ==
              KmError::MISSING_NONCE,
          "GCM decrypt without a nonce: MISSING_NONCE");
    check(runOp(eng, Purpose::ENCRYPT, gen,
                aesParams(BlockMode::GCM, Padding::NONE), {P}).begin ==
              KmError::MISSING_MAC_LENGTH,
          "GCM without MAC_LENGTH: MISSING_MAC_LENGTH");
    check(runOp(eng, Purpose::ENCRYPT, gen,
                aesParams(BlockMode::GCM, Padding::NONE, {}, 64), {P}).begin ==
              KmError::UNSUPPORTED_MAC_LENGTH,
          "MAC_LENGTH=64: UNSUPPORTED_MAC_LENGTH");
    check(runOp(eng, Purpose::ENCRYPT, gen,
                aesParams(BlockMode::CBC, Padding::NONE), {Bytes(17, 1)}).finish ==
              KmError::INVALID_INPUT_LENGTH,
          "CBC/NONE with 17 bytes: INVALID_INPUT_LENGTH");
    {
        uint64_t h = 0;
        AuthList out, in2;
        eng.begin(Purpose::ENCRYPT, gen, aesParams(BlockMode::GCM, Padding::NONE, {}, 128),
                  out, h);
        uint32_t c = 0; Bytes o;
        eng.update(h, AuthList(), P, c, out, o);
        in2.addBytes(Tag::ASSOCIATED_DATA, A);
        check(eng.update(h, in2, P, c, out, o) == KmError::INVALID_TAG &&
              eng.abort(h) == KmError::INVALID_OPERATION_HANDLE,
              "AAD after data: INVALID_TAG, and the error ended the operation");
    }
    {
        Bytes cbcKey;
        AuthList r = aesRequest(128, false);
        r.remove(Tag::PADDING); r.addEnum(Tag::PADDING, u(Padding::NONE));
        eng.generateKey(r, cbcKey, kc);
        check(runOp(eng, Purpose::ENCRYPT, cbcKey,
                    aesParams(BlockMode::CBC, Padding::PKCS7), {P}).begin ==
                  KmError::INCOMPATIBLE_PADDING_MODE,
              "PKCS7 on a NONE-only key: INCOMPATIBLE_PADDING_MODE");
        OpResult bad = runOp(eng, Purpose::DECRYPT, aes,
                             aesParams(BlockMode::CBC, Padding::PKCS7, iv16),
                             {Bytes(cbc.output.begin(), cbc.output.begin() + 16)});
        check(bad.finish == KmError::INVALID_ARGUMENT, "CBC bad padding: INVALID_ARGUMENT");
    }

    printf("-- handles and blobs --\n");
    Bytes garbage = {1, 2, 3, 4, 5};
    check(runOp(eng, Purpose::SIGN, garbage, signParams(Digest::SHA_2_256), {msg}).begin ==
              KmError::INVALID_KEY_BLOB,
          "a non-blob: INVALID_KEY_BLOB");
    {
        AuthList out; Bytes o; uint32_t c;
        check(eng.update(12345, AuthList(), msg, c, out, o) ==
                  KmError::INVALID_OPERATION_HANDLE &&
              eng.finish(12345, AuthList(), msg, {}, out, o) ==
                  KmError::INVALID_OPERATION_HANDLE &&
              eng.abort(12345) == KmError::INVALID_OPERATION_HANDLE,
              "unknown handle: INVALID_OPERATION_HANDLE everywhere");
        std::vector<uint64_t> hs;
        KmError last = KmError::OK;
        for (size_t i = 0; i <= kMaxOperations; i++) {
            uint64_t h = 0;
            last = eng.begin(Purpose::SIGN, ec, signParams(Digest::SHA_2_256), out, h);
            if (last == KmError::OK) hs.push_back(h);
        }
        check(hs.size() == kMaxOperations && last == KmError::TOO_MANY_OPERATIONS,
              "operation table full: TOO_MANY_OPERATIONS");
        bool aborted = true;
        for (uint64_t h : hs) aborted = aborted && eng.abort(h) == KmError::OK;
        check(aborted && eng.operationCount() == 0, "abort frees them; nothing leaked");
    }

    authSelftest(tcti);

    printf("\n%d passed, %d failed, %d skipped\n", g_pass, g_fail, g_skip);
    return g_fail == 0 ? 0 : 1;
}

int main(int argc, char** argv) {
    std::string tcti;
    const char* env = getenv("TPM2TOOLS_TCTI");
    tcti = env ? env : "swtpm:path=/run/swtpm-waydroid/sock";
    std::string cmd = (argc > 1) ? argv[1] : "selftest";
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--tcti") && i + 1 < argc) tcti = argv[++i];
    }
    if (cmd == "backend") {
        Engine eng(std::unique_ptr<TpmBackend>(makeToolsBackend(tcti)));
        printf("%s\n", eng.backendDescription().c_str());
        return 0;
    }
    if (cmd == "selftest") return selftest(tcti);
    fprintf(stderr, "usage: %s {selftest|backend} [--tcti <tcti>]\n", argv[0]);
    return 2;
}
