// auth.h -- keymaster's shared HMAC key, and the two tokens it authenticates.
// Stage 5, docs/74.
//
// Every keymaster@4.0 instance on a device joins one negotiation per boot.
// keystore2 asks each for its HmacSharingParameters (a seed and a 32-byte
// nonce), sorts them, and hands the whole list to each instance's
// computeSharedHmac, which derives the shared HMAC key
//
//     H = CKDF(K, "KeymasterSharedMac", seed1 || nonce1 || ... || seedN || nonceN)
//
// and answers HMAC(H, "Keymaster HMAC Verification") so keystore2 can compare
// the answers (IKeymasterDevice.hal; the names are the HAL's: K is the
// pre-shared key, H the derived one). On a phone K is provisioned into each
// secure environment. This image's TEE keymaster is AOSP's software one, whose
// K is kFakeKeyAgreementKey -- 32 zero bytes, read out of its own
// libpuresoftkeymasterdevice.so -- so H follows from public values. Agreeing on
// it buys interoperability with that TEE, not secrecy, and docs/74 says so.
//
// H authenticates two tokens:
//
//   HardwareAuthToken -- "a user authenticated". HMAC(H, 0x00 || challenge ||
//     userId || authenticatorId || authenticatorType || timestamp), the first
//     three in machine order and the last two big-endian: hw_auth_token_t's
//     layout. This image's gatekeeper never computes it -- its ComputeSignature
//     is a memset to zero -- so every password token here carries 32 zero bytes,
//     which only EngineOptions::acceptUnsignedAuthTokens lets through.
//
//   VerificationToken -- "another instance's clock said this". The HAL says
//     HMAC(H, "Auth Verification" || be64 challenge || be64 timestamp ||
//     be32 securityLevel). AOSP's software keymaster writes all three in machine
//     order and over its own level, SOFTWARE; and km_compat then relabels every
//     token it forwards to a StrongBox as TRUSTED_ENVIRONMENT. So both forms are
//     checked, and the software one ignores the level field it was handed.
#ifndef WAYDROID_KEYSTORE_AUTH_H
#define WAYDROID_KEYSTORE_AUTH_H

#include "keystore.h"

namespace wks {

// android.hardware.keymaster@4.0::HardwareAuthenticatorType, a bit mask.
enum class HwAuthType : uint32_t {
    NONE = 0, PASSWORD = 1u << 0, FINGERPRINT = 1u << 1, ANY = 0xffffffffu,
};

constexpr size_t kAuthMacLength = 32;
constexpr size_t kSharingNonceLength = 32;

struct HmacSharingParams {
    Bytes seed;
    Bytes nonce;   // kSharingNonceLength bytes
};

// A token is "empty" -- the caller had none to give -- when its mac is empty;
// keymaster says the other fields are then zero.
struct HardwareAuthToken {
    uint64_t challenge = 0;
    uint64_t userId = 0;
    uint64_t authenticatorId = 0;
    uint32_t authenticatorType = 0;
    uint64_t timestamp = 0;          // ms, the authenticator's CLOCK_BOOTTIME
    Bytes mac;
    bool present() const { return !mac.empty(); }
};

struct VerificationToken {
    uint64_t challenge = 0;
    uint64_t timestamp = 0;
    uint32_t securityLevel = 0;
    bool parametersVerified = false; // non-empty list: not something we can MAC
    Bytes mac;
    bool present() const { return !mac.empty(); }
};

// The pre-shared key K this image's TEE keymaster uses (see the header comment).
Bytes imageKeyAgreementKey();

// H, from K and the parameters in the order keystore2 sent them.
Bytes deriveSharedHmacKey(const Bytes& k, const std::vector<HmacSharingParams>& params);

// HMAC(H, "Keymaster HMAC Verification"): what computeSharedHmac answers.
Bytes sharingCheck(const Bytes& h);

Bytes authTokenMac(const Bytes& h, const HardwareAuthToken& t);

enum class VtForm {
    SPEC,           // IKeymasterDevice.hal: big-endian, the token's own level
    AOSP_SOFTWARE,  // system/keymaster's SoftKeymasterEnforcement
};
const char* vtFormName(VtForm f);
Bytes verificationTokenMac(const Bytes& h, const VerificationToken& t, VtForm f);

} // namespace wks

#endif
