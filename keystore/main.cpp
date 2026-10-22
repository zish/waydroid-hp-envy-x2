// main.cpp -- keystore-engine: a host CLI that exercises the stage-1 engine
// against a TPM through any TCTI. No binder, no Android. It is docs/65 stage 1's
// deliverable: the TPM semantics settled and proven before a line of HIDL.
//
//   keystore-engine selftest [--tcti <tcti>]
//   keystore-engine backend  [--tcti <tcti>]
//
// Default TCTI is $TPM2TOOLS_TCTI if set, else the waydroid-swtpm socket. On the
// dev box, point --tcti at a throwaway swtpm; on bigtab01, at the service's
// socket (needs group tss) or a throwaway one.
#include "engine.h"
#include <cstdio>
#include <cstring>
#include <string>

namespace wks { TpmBackend* makeToolsBackend(const std::string& tcti); }

using namespace wks;

static int g_pass = 0, g_fail = 0;
static void check(bool ok, const char* what) {
    printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what);
    if (ok) g_pass++; else g_fail++;
}

static AuthList ecRequest(bool withSign = true) {
    AuthList a;
    a.addEnum(Tag::ALGORITHM, static_cast<uint32_t>(Algorithm::EC));
    a.addEnum(Tag::EC_CURVE, static_cast<uint32_t>(EcCurve::P_256));
    a.addUint(Tag::KEY_SIZE, 256);
    a.addEnum(Tag::DIGEST, static_cast<uint32_t>(Digest::SHA_2_256));
    if (withSign) {
        a.addEnum(Tag::PURPOSE, static_cast<uint32_t>(Purpose::SIGN));
        a.addEnum(Tag::PURPOSE, static_cast<uint32_t>(Purpose::VERIFY));
    }
    a.addBool(Tag::NO_AUTH_REQUIRED);
    return a;
}

static AuthList aesRequest(uint32_t bits) {
    AuthList a;
    a.addEnum(Tag::ALGORITHM, static_cast<uint32_t>(Algorithm::AES));
    a.addUint(Tag::KEY_SIZE, bits);
    a.addEnum(Tag::BLOCK_MODE, static_cast<uint32_t>(BlockMode::CFB));
    a.addEnum(Tag::PURPOSE, static_cast<uint32_t>(Purpose::ENCRYPT));
    a.addEnum(Tag::PURPOSE, static_cast<uint32_t>(Purpose::DECRYPT));
    a.addBool(Tag::NO_AUTH_REQUIRED);
    return a;
}

static int selftest(const std::string& tcti) {
    Engine eng(std::unique_ptr<TpmBackend>(makeToolsBackend(tcti)));
    printf("backend: %s\n", eng.backendDescription().c_str());

    printf("-- primary --\n");
    check(eng.init() == KmError::OK, "ensure persistent primary");

    printf("-- getRandom --\n");
    Bytes rnd;
    bool r = (eng.getRandom(16, rnd) == KmError::OK) && rnd.size() == 16;
    bool nonzero = false; for (auto b : rnd) if (b) nonzero = true;
    check(r && nonzero, "16 random bytes, not all zero");

    printf("-- EC P-256 sign/verify --\n");
    KeyBlob ec;
    KmError e = eng.generateKey(ecRequest(), ec);
    check(e == KmError::OK, "generate EC P-256 signing key");
    Bytes ecBlob = ec.serialize();

    auto reparsed = KeyBlob::parse(ecBlob);
    check(reparsed.has_value() &&
          reparsed->authorizations.params.size() == ec.authorizations.params.size(),
          "blob serialize/parse round-trip");
    check(reparsed && reparsed->authorizations.hasEnumVal(
              Tag::ORIGIN, static_cast<uint32_t>(Origin::GENERATED)),
          "ORIGIN=GENERATED bound into blob");

    Bytes digest(32, 0); for (int i = 0; i < 32; i++) digest[i] = i * 7 + 1;
    Bytes sig;
    check(eng.sign(ecBlob, digest, sig) == KmError::OK && !sig.empty(),
          "sign a SHA-256 digest");
    check(eng.verify(ecBlob, digest, sig) == KmError::OK,
          "verify the signature");
    Bytes bad = digest; bad[0] ^= 0xff;
    check(eng.verify(ecBlob, bad, sig) != KmError::OK,
          "verify rejects a tampered digest");

    printf("-- tag enforcement --\n");
    KeyBlob ecNoSign;
    check(eng.generateKey(ecRequest(false), ecNoSign) == KmError::UNSUPPORTED_PURPOSE,
          "EC key without PURPOSE=SIGN is refused");

    printf("-- AES-128 encrypt/decrypt --\n");
    KeyBlob aes;
    check(eng.generateKey(aesRequest(128), aes) == KmError::OK,
          "generate AES-128 key");
    Bytes aesBlob = aes.serialize();
    Bytes iv, pt = {'s','e','c','r','e','t',' ','m','e','s','s','a','g','e','!','!'};
    Bytes ct, pt2;
    check(eng.encrypt(aesBlob, iv, pt, ct) == KmError::OK && ct != pt,
          "encrypt differs from plaintext");
    check(eng.decrypt(aesBlob, iv, ct, pt2) == KmError::OK && pt2 == pt,
          "decrypt round-trips to plaintext");

    printf("-- cross-algorithm refusal --\n");
    check(eng.sign(aesBlob, digest, sig) == KmError::INCOMPATIBLE_ALGORITHM,
          "signing with an AES blob is refused");
    check(eng.encrypt(ecBlob, iv, pt, ct) == KmError::INCOMPATIBLE_ALGORITHM,
          "encrypting with an EC blob is refused");
    Bytes garbage = {1,2,3,4,5};
    check(eng.sign(garbage, digest, sig) == KmError::INVALID_KEY_BLOB,
          "a non-blob is refused as INVALID_KEY_BLOB");

    printf("\n%d passed, %d failed\n", g_pass, g_fail);
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
