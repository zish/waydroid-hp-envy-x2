// auth.cpp -- see auth.h.
#include "auth.h"
#include "soft_crypto.h"

#include <cstring>

namespace wks {

namespace {

void putMachine(Bytes& b, const void* p, size_t n) {
    const uint8_t* q = static_cast<const uint8_t*>(p);
    b.insert(b.end(), q, q + n);
}

void putBe(Bytes& b, uint64_t v, int bytes) {
    for (int s = 8 * (bytes - 1); s >= 0; s -= 8) b.push_back(uint8_t(v >> s));
}

Bytes text(const char* s) { return Bytes(s, s + strlen(s)); }

} // namespace

Bytes imageKeyAgreementKey() { return Bytes(32, 0); }

Bytes deriveSharedHmacKey(const Bytes& k, const std::vector<HmacSharingParams>& params) {
    Bytes context;
    for (const auto& p : params) {
        context.insert(context.end(), p.seed.begin(), p.seed.end());
        context.insert(context.end(), p.nonce.begin(), p.nonce.end());
    }
    return ckdf(k, text("KeymasterSharedMac"), context, 32);
}

Bytes sharingCheck(const Bytes& h) {
    return hmacSha256(h, text("Keymaster HMAC Verification"));
}

Bytes authTokenMac(const Bytes& h, const HardwareAuthToken& t) {
    Bytes m;
    m.push_back(0);   // hw_auth_token_t version
    putMachine(m, &t.challenge, sizeof t.challenge);
    putMachine(m, &t.userId, sizeof t.userId);
    putMachine(m, &t.authenticatorId, sizeof t.authenticatorId);
    putBe(m, t.authenticatorType, 4);
    putBe(m, t.timestamp, 8);
    return hmacSha256(h, m);
}

const char* vtFormName(VtForm f) {
    return f == VtForm::SPEC ? "HAL (big-endian)" : "AOSP software keymaster";
}

Bytes verificationTokenMac(const Bytes& h, const VerificationToken& t, VtForm f) {
    Bytes m = text("Auth Verification");
    if (f == VtForm::SPEC) {
        putBe(m, t.challenge, 8);
        putBe(m, t.timestamp, 8);
        putBe(m, t.securityLevel, 4);
    } else {
        const uint32_t software = 0;   // SoftKeymasterEnforcement::SecurityLevel()
        putMachine(m, &t.challenge, sizeof t.challenge);
        putMachine(m, &t.timestamp, sizeof t.timestamp);
        putMachine(m, &software, sizeof software);
    }
    return hmacSha256(h, m);
}

} // namespace wks
