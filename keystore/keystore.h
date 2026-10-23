// keystore.h -- the TPM-backed keyblob engine of docs/65, stages 1 and 4. See
// docs/73.
//
// Three things live here: a compact keymaster tag model (Tag/KeyParam/AuthList),
// the on-disk key blob format the engine mints and parses, and the narrow
// TpmBackend seam every TPM op goes through. The seam is the docs/29 WifiBackend
// idea applied to the TPM: everything above it is algorithm-agnostic engine
// logic reused unchanged by the HIDL HAL, and everything below it is one
// implementation of "do this on a TPM 2.0" -- ToolsTpmBackend today (tpm2-tools
// exec, zero build deps), an ESAPI backend next, each selected at construction.
//
// Scope: EC P-256 signing keys and AES-128/256 cipher keys (ECB, CBC, CTR, GCM),
// generated in the TPM or imported raw (AES), driven through keymaster's
// begin/update/finish operation model with tag enforcement on every call. RSA,
// HMAC, auth-bound keys and computeSharedHmac are later stages.
#ifndef WAYDROID_KEYSTORE_H
#define WAYDROID_KEYSTORE_H

#include <cstdint>
#include <string>
#include <vector>
#include <optional>

namespace wks {

using Bytes = std::vector<uint8_t>;

// --- keymaster tags (subset) -------------------------------------------------
// Values match android.hardware.keymaster@4.0 types::Tag, so the HIDL layer
// copies them rather than translating. The top 4 bits of a tag are its value
// type; a tag's number is meaningless without them, which is exactly the bug
// stage 1 had: PURPOSE is ENUM_REP (0x20000001), and stage 1 encoded it as ENUM
// (0x10000001), which no Android request would ever have matched. Its selftest
// could not see that, because it only ever compared the engine to itself.
enum class TagType : uint32_t {
    INVALID  = 0u << 28,
    ENUM     = 1u << 28,
    ENUM_REP = 2u << 28,
    UINT     = 3u << 28,
    UINT_REP = 4u << 28,
    ULONG    = 5u << 28,
    DATE     = 6u << 28,
    BOOL     = 7u << 28,
    BIGNUM   = 8u << 28,
    BYTES    = 9u << 28,
    ULONG_REP= 10u << 28,
};

constexpr uint32_t kTagTypeMask = 0xf0000000u;

enum class Tag : uint32_t {
    INVALID                 = 0,
    PURPOSE                 = (2u<<28) | 1,    // ENUM_REP
    ALGORITHM               = (1u<<28) | 2,    // ENUM
    KEY_SIZE                = (3u<<28) | 3,    // UINT
    BLOCK_MODE              = (2u<<28) | 4,    // ENUM_REP
    DIGEST                  = (2u<<28) | 5,    // ENUM_REP
    PADDING                 = (2u<<28) | 6,    // ENUM_REP
    CALLER_NONCE            = (7u<<28) | 7,    // BOOL
    MIN_MAC_LENGTH          = (3u<<28) | 8,    // UINT
    EC_CURVE                = (1u<<28) | 10,   // ENUM
    ROLLBACK_RESISTANCE     = (7u<<28) | 303,  // BOOL
    USER_SECURE_ID          = (10u<<28) | 502, // ULONG_REP
    NO_AUTH_REQUIRED        = (7u<<28) | 503,  // BOOL
    USER_AUTH_TYPE          = (1u<<28) | 504,  // ENUM
    AUTH_TIMEOUT            = (3u<<28) | 505,  // UINT
    TRUSTED_USER_PRESENCE_REQUIRED = (7u<<28) | 507, // BOOL
    TRUSTED_CONFIRMATION_REQUIRED  = (7u<<28) | 508, // BOOL
    UNLOCKED_DEVICE_REQUIRED       = (7u<<28) | 509, // BOOL
    APPLICATION_ID          = (9u<<28) | 601,  // BYTES
    APPLICATION_DATA        = (9u<<28) | 700,  // BYTES
    CREATION_DATETIME       = (6u<<28) | 701,  // DATE
    ORIGIN                  = (1u<<28) | 702,  // ENUM
    ROOT_OF_TRUST           = (9u<<28) | 704,  // BYTES
    OS_VERSION              = (3u<<28) | 705,  // UINT
    OS_PATCHLEVEL           = (3u<<28) | 706,  // UINT
    ATTESTATION_CHALLENGE   = (9u<<28) | 708,  // BYTES
    ASSOCIATED_DATA         = (9u<<28) | 1000, // BYTES
    NONCE                   = (9u<<28) | 1001, // BYTES
    MAC_LENGTH              = (3u<<28) | 1003, // UINT
};

inline TagType tagType(Tag t) {
    return static_cast<TagType>(static_cast<uint32_t>(t) & kTagTypeMask);
}
inline bool tagIsBytes(Tag t) {
    TagType y = tagType(t);
    return y == TagType::BYTES || y == TagType::BIGNUM;
}

enum class Algorithm : uint32_t { RSA = 1, EC = 3, AES = 32, TRIPLE_DES = 33, HMAC = 128 };
enum class Purpose   : uint32_t { ENCRYPT = 0, DECRYPT = 1, SIGN = 2, VERIFY = 3, WRAP_KEY = 5 };
enum class Digest    : uint32_t { NONE = 0, MD5 = 1, SHA1 = 2, SHA_2_224 = 3,
                                  SHA_2_256 = 4, SHA_2_384 = 5, SHA_2_512 = 6 };
enum class BlockMode : uint32_t { ECB = 1, CBC = 2, CTR = 3, GCM = 32 };
enum class Padding   : uint32_t { NONE = 1, RSA_OAEP = 2, RSA_PSS = 3,
                                  RSA_PKCS1_1_5_ENCRYPT = 4, RSA_PKCS1_1_5_SIGN = 5,
                                  PKCS7 = 64 };
enum class EcCurve   : uint32_t { P_224 = 0, P_256 = 1, P_384 = 2, P_521 = 3 };
enum class Origin    : uint32_t { GENERATED = 0, DERIVED = 1, IMPORTED = 2, UNKNOWN = 3 };
enum class KeyFormat : uint32_t { X509 = 0, PKCS8 = 1, RAW = 3 };

// One key parameter. Numeric tags carry `u`; byte tags carry `blob`.
struct KeyParam {
    Tag      tag = Tag::INVALID;
    uint64_t u = 0;
    Bytes    blob;
    KeyParam() = default;
    KeyParam(Tag t, uint64_t v) : tag(t), u(v) {}
    KeyParam(Tag t, Bytes b) : tag(t), blob(std::move(b)) {}
};

// An authorization list: the tags that describe and constrain a key, or the
// parameters of one operation. The engine enforces a key's list on every
// operation; the TPM does not do it for us.
struct AuthList {
    std::vector<KeyParam> params;

    void addEnum(Tag t, uint32_t v) { params.emplace_back(t, v); }
    void addUint(Tag t, uint32_t v) { params.emplace_back(t, v); }
    void addBool(Tag t)             { params.emplace_back(t, 1); }
    void addBytes(Tag t, Bytes b)   { params.emplace_back(t, std::move(b)); }

    std::optional<uint64_t> first(Tag t) const;
    const Bytes* firstBytes(Tag t) const;
    bool has(Tag t) const;
    bool hasEnumVal(Tag t, uint32_t v) const;   // for repeated enums (PURPOSE, DIGEST)
    std::vector<uint64_t> all(Tag t) const;
    void remove(Tag t);
};

// --- key blob ---------------------------------------------------------------
// What Android stores and hands back on every call. It is opaque to Android: the
// TPM-wrapped key material (TPM2B_PRIVATE) is confidential at rest because it is
// encrypted under the persistent primary, whose seed lives in the TPM.
//
// The authorization list travels in the clear, so on its own a caller could edit
// it -- add PURPOSE=SIGN to an encryption key, say -- and the engine would
// enforce the edited list. Version 2 closes that: each TPM object's authValue is
// authDigest() of the list it was created with, and every use presents the
// digest of the list in the blob it was handed. An edited list yields a
// different digest and the TPM refuses the key. The digest is not a secret and
// does not need to be: what matters is that only the TPM can compare it to the
// value sealed inside the private area, and Android cannot reach the TPM.
struct KeyBlob {
    static constexpr uint32_t MAGIC = 0x574b5331; // "WKS1"
    static constexpr uint32_t VERSION = 2;
    uint32_t version = VERSION;
    Algorithm algorithm = Algorithm::EC;
    AuthList  authorizations;
    Bytes     tpmPublic;   // TPM2B_PUBLIC  (marshalled)
    Bytes     tpmPrivate;  // TPM2B_PRIVATE (marshalled, wrapped by the primary)

    Bytes serialize() const;
    static std::optional<KeyBlob> parse(const Bytes& in);
};

// SHA-256 over a domain separator and the serialized list. The TPM authValue of
// every key; see KeyBlob.
Bytes authDigest(const AuthList& a);

// --- TpmBackend: the narrow seam --------------------------------------------
// A TPM 2.0 abstraction. The contract is intentionally the smallest thing that
// supports a native-TPM keystore: ensure a primary, create or import a child key
// under it, and run a primitive on a child loaded per call. "Load + flush per
// op" lives inside each implementation because the swtpm slot leak (docs/71
// finding 3) is a property of the backend, not the engine.
//
// A future hybrid backend (TPM protects a wrapping key, crypto runs in
// software) would satisfy a narrower seal/unseal/wrap/unwrap contract instead --
// the path to a TPM-1.2, smartcard or Yubikey backend (docs/65).
enum class CipherOp { ENCRYPT, DECRYPT };
enum class TpmMode  { ECB, CBC, CTR, CFB };

struct CreateSpec {
    Algorithm algorithm = Algorithm::EC;
    uint32_t  keySizeBits = 0;   // 256 for EC P-256; 128/256 for AES
    Bytes     auth;              // the new object's authValue (authDigest)
};

class TpmBackend {
public:
    virtual ~TpmBackend() = default;

    // Human-readable identity of the TCTI/backend, for logs and the selftest.
    virtual std::string describe() = 0;

    // Create (if absent) a persistent ECC primary under the owner hierarchy at
    // this backend's fixed handle. Idempotent. Returns false on failure.
    virtual bool ensurePrimary() = 0;

    // Create a child key of the primary. AES keys are created with mode NULL,
    // so one key serves every block mode the TPM implements.
    virtual bool createKey(const CreateSpec& spec, Bytes& tpmPublic,
                           Bytes& tpmPrivate) = 0;

    // Import raw AES key bytes as a child of the primary.
    virtual bool importAes(const Bytes& raw, const Bytes& auth, Bytes& tpmPublic,
                           Bytes& tpmPrivate) = 0;

    // ECDSA-sign a 32-byte digest. `sigOut` is DER (ECDSA-Sig-Value), which is
    // what keymaster returns.
    virtual bool signEcdsa(const Bytes& tpmPublic, const Bytes& tpmPrivate,
                           const Bytes& auth, const Bytes& digest,
                           Bytes& sigOut) = 0;

    // AES in one TPM mode. `iv` is ignored for ECB. `in` must already be a whole
    // number of blocks for ECB and CBC; the engine pads.
    virtual bool aes(const Bytes& tpmPublic, const Bytes& tpmPrivate,
                     const Bytes& auth, TpmMode mode, CipherOp op,
                     const Bytes& iv, const Bytes& in, Bytes& out) = 0;

    virtual bool getRandom(size_t n, Bytes& out) = 0;
};

} // namespace wks

#endif
