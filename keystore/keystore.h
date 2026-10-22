// keystore.h -- stage 1 of docs/65: the TPM-backed keyblob engine, with no
// binder and no Android interface yet. See keystore/README.md.
//
// Three things live here: a compact keymaster tag model (Tag/KeyParam/AuthList),
// the on-disk key blob format the engine mints and parses, and the narrow
// TpmBackend seam every TPM op goes through. The seam is the docs/29 WifiBackend
// idea applied to the TPM: everything above it is algorithm-agnostic engine
// logic reused unchanged by the stage-3 HIDL HAL, and everything below it is one
// implementation of "do this on a TPM 2.0" -- ToolsTpmBackend today (tpm2-tools
// exec, zero build deps), an ESAPI backend next, each selected at construction.
//
// Stage 1 is deliberately small: EC P-256 signing keys and AES-128/256 cipher
// keys, generate / sign / verify / encrypt / decrypt, blob round-trip and tag
// enforcement. RSA, HMAC, streaming update(), auth-bound keys and
// computeSharedHmac are later stages; the types here leave room for them.
#ifndef WAYDROID_KEYSTORE_H
#define WAYDROID_KEYSTORE_H

#include <cstdint>
#include <string>
#include <vector>
#include <optional>

namespace wks {

using Bytes = std::vector<uint8_t>;

// --- keymaster tags (subset) -------------------------------------------------
// Values match android.hardware.keymaster@4.0 types::Tag so the stage-3 HIDL
// marshalling is a straight copy rather than a translation. The top 4 bits of a
// tag encode its value type (enum/uint/ulong/bool/bytes); we keep the real
// encoding so the enum numbers are the familiar ones.
enum class TagType : uint32_t {
    INVALID = 0u << 28,
    ENUM    = 1u << 28,
    ENUM_REP= 2u << 28,
    UINT    = 3u << 28,
    UINT_REP= 4u << 28,
    ULONG   = 5u << 28,
    DATE    = 6u << 28,
    BOOL    = 7u << 28,
    BIGNUM  = 8u << 28,
    BYTES   = 9u << 28,
    ULONG_REP=10u<< 28,
};

enum class Tag : uint32_t {
    PURPOSE            = (1u<<28) | 1,   // ENUM_REP in km; we store repeated
    ALGORITHM          = (1u<<28) | 2,   // ENUM
    KEY_SIZE           = (3u<<28) | 3,   // UINT
    BLOCK_MODE         = (2u<<28) | 4,   // ENUM_REP
    DIGEST             = (2u<<28) | 5,   // ENUM_REP
    PADDING            = (2u<<28) | 6,   // ENUM_REP
    EC_CURVE           = (1u<<28) | 10,  // ENUM
    NO_AUTH_REQUIRED   = (7u<<28) | 503, // BOOL
    USER_AUTH_TYPE     = (1u<<28) | 504, // ENUM
    ORIGIN             = (1u<<28) | 702, // ENUM
};

enum class Algorithm : uint32_t { RSA = 1, EC = 3, AES = 32, HMAC = 128 };
enum class Purpose   : uint32_t { ENCRYPT = 0, DECRYPT = 1, SIGN = 2, VERIFY = 3 };
enum class Digest    : uint32_t { NONE = 0, SHA_2_256 = 4 };
enum class BlockMode : uint32_t { ECB = 1, CBC = 2, CTR = 3, GCM = 32, CFB = 64 };
enum class EcCurve   : uint32_t { P_224 = 0, P_256 = 1, P_384 = 2, P_521 = 3 };
enum class Origin    : uint32_t { GENERATED = 0, IMPORTED = 2 };

// One key parameter. Numeric tags carry `u`; byte tags carry `blob`.
struct KeyParam {
    Tag      tag;
    uint64_t u = 0;
    Bytes    blob;
    KeyParam() = default;
    KeyParam(Tag t, uint64_t v) : tag(t), u(v) {}
};

// An authorization list: the tags that describe and constrain a key. The engine
// enforces these on every operation; the TPM does not do it for us.
struct AuthList {
    std::vector<KeyParam> params;

    void addEnum(Tag t, uint32_t v) { params.emplace_back(t, v); }
    void addUint(Tag t, uint32_t v) { params.emplace_back(t, v); }
    void addBool(Tag t)             { params.emplace_back(t, 1); }

    std::optional<uint64_t> first(Tag t) const;
    bool has(Tag t) const { return first(t).has_value(); }
    bool hasEnumVal(Tag t, uint32_t v) const;   // for repeated enums (PURPOSE, DIGEST)
    std::vector<uint64_t> all(Tag t) const;
};

// --- key blob ---------------------------------------------------------------
// What Android stores and hands back on every call. It is opaque to Android: the
// TPM-wrapped key material (TPM2B_PRIVATE) is confidential-at-rest because it is
// encrypted under the persistent primary, whose seed lives in the TPM. The
// authorization list travels in the clear inside the blob -- tags are not
// secret, and the engine must re-read them from the blob on every use rather
// than trust anything Android passes alongside.
struct KeyBlob {
    static constexpr uint32_t MAGIC = 0x574b5331; // "WKS1"
    uint32_t version = 1;
    Algorithm algorithm;
    AuthList  authorizations;
    Bytes     tpmPublic;   // TPM2B_PUBLIC  (marshalled)
    Bytes     tpmPrivate;  // TPM2B_PRIVATE (marshalled, wrapped by the primary)

    Bytes serialize() const;
    static std::optional<KeyBlob> parse(const Bytes& in);
};

// --- TpmBackend: the narrow seam --------------------------------------------
// A TPM 2.0 abstraction. The contract is intentionally the smallest thing that
// supports a native-TPM keystore: ensure a primary, create a child key under it,
// and run the primitive on a child loaded per-call. "load+flush per op" lives
// inside each implementation because the swtpm slot-leak (docs/71 finding 3) is
// a property of the backend, not the engine.
//
// A future hybrid backend (TPM protects a wrapping key, crypto runs in OpenSSL)
// would satisfy a narrower seal/unseal/wrap/unwrap contract instead -- that is
// the path to a TPM-1.2, smartcard or Yubikey backend (docs/65). This seam is
// TPM-2.0-shaped on purpose for stage 1; the hybrid split is a later refactor.
enum class SignAlgo { ECDSA_SHA256 };
enum class CipherOp { ENCRYPT, DECRYPT };

struct CreateSpec {
    Algorithm algorithm;
    uint32_t  keySizeBits = 0;   // 256 for EC P-256; 128/256 for AES
    EcCurve   curve = EcCurve::P_256;
    bool      forSign = false;   // EC/RSA signing
    bool      forCipher = false; // AES encrypt/decrypt
};

class TpmBackend {
public:
    virtual ~TpmBackend() = default;

    // Human-readable identity of the TCTI/backend, for logs and the selftest.
    virtual std::string describe() = 0;

    // Create (if absent) a persistent ECC primary under the owner hierarchy at
    // this backend's fixed handle. Idempotent. Returns false on failure.
    virtual bool ensurePrimary() = 0;

    // Create a child key of the primary. Fills tpmPublic/tpmPrivate and, for
    // asymmetric keys, the DER/raw public key in `pubKeyOut` (empty for AES).
    virtual bool createKey(const CreateSpec& spec, Bytes& tpmPublic,
                           Bytes& tpmPrivate, Bytes& pubKeyOut) = 0;

    // Sign `digest` (already hashed) with the child described by the blob.
    virtual bool sign(const Bytes& tpmPublic, const Bytes& tpmPrivate,
                      SignAlgo algo, const Bytes& digest, Bytes& sigOut) = 0;

    // Verify a signature in-TPM (used by the selftest; Android verifies itself).
    virtual bool verify(const Bytes& tpmPublic, const Bytes& tpmPrivate,
                        SignAlgo algo, const Bytes& digest, const Bytes& sig) = 0;

    // Symmetric cipher one-shot (CFB) with the AES child. `iv` in/out.
    virtual bool cipher(const Bytes& tpmPublic, const Bytes& tpmPrivate,
                        CipherOp op, Bytes& iv, const Bytes& in, Bytes& out) = 0;

    virtual bool getRandom(size_t n, Bytes& out) = 0;
};

} // namespace wks

#endif
