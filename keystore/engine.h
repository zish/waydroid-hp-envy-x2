// engine.h -- the keymaster-semantics layer over a TpmBackend.
//
// This is the part the HIDL HAL calls. It owns the key blob format, validates a
// keymaster request against what a TPM 2.0 can honour, and -- the point of it --
// enforces a key's authorization tags on every operation, because a TPM does
// not. It also owns keymaster's operation model: begin() returns a handle,
// update() buffers, finish() runs the primitive. Errors are keymaster@4.0
// ErrorCode values, so the HIDL layer returns them unchanged.
//
// Operations hold no TPM state between calls. A key is loaded, used and flushed
// inside one backend call (docs/71 finding 3), so the op limit is a memory bound,
// not the TPM's three transient slots, and every call into the backend is still
// serialized under one mutex because the tools backend flushes all transient
// objects when it finishes.
//
// Buffering is deliberate: update() consumes everything and returns nothing, and
// finish() produces the whole result. keymaster allows it, the framework copes
// with it, and it is the only correct shape for GCM decryption, which must not
// release plaintext before the tag has been checked.
#ifndef WAYDROID_KEYSTORE_ENGINE_H
#define WAYDROID_KEYSTORE_ENGINE_H

#include "keystore.h"
#include <map>
#include <memory>
#include <mutex>

namespace wks {

// android.hardware.keymaster@4.0::ErrorCode, the subset this engine returns.
// Stage 1 numbered these by hand and got most of them wrong (INVALID_KEY_BLOB
// was -24; it is -33). They are checked against the framework in docs/73.
enum class KmError : int {
    OK = 0,
    UNSUPPORTED_PURPOSE = -2,
    INCOMPATIBLE_PURPOSE = -3,
    UNSUPPORTED_ALGORITHM = -4,
    INCOMPATIBLE_ALGORITHM = -5,
    UNSUPPORTED_KEY_SIZE = -6,
    UNSUPPORTED_BLOCK_MODE = -7,
    INCOMPATIBLE_BLOCK_MODE = -8,
    UNSUPPORTED_MAC_LENGTH = -9,
    UNSUPPORTED_PADDING_MODE = -10,
    INCOMPATIBLE_PADDING_MODE = -11,
    UNSUPPORTED_DIGEST = -12,
    INCOMPATIBLE_DIGEST = -13,
    UNSUPPORTED_KEY_FORMAT = -17,
    INVALID_INPUT_LENGTH = -21,
    INVALID_OPERATION_HANDLE = -28,
    VERIFICATION_FAILED = -30,
    TOO_MANY_OPERATIONS = -31,
    INVALID_KEY_BLOB = -33,
    INVALID_ARGUMENT = -38,
    UNSUPPORTED_TAG = -39,
    INVALID_TAG = -40,
    IMPORT_PARAMETER_MISMATCH = -44,
    SECURE_HW_COMMUNICATION_FAILED = -49,
    MISSING_NONCE = -51,
    INVALID_NONCE = -52,
    MISSING_MAC_LENGTH = -53,
    CALLER_NONCE_PROHIBITED = -55,
    INVALID_MAC_LENGTH = -57,
    MISSING_MIN_MAC_LENGTH = -58,
    UNSUPPORTED_MIN_MAC_LENGTH = -59,
    UNSUPPORTED_EC_CURVE = -61,
    ROLLBACK_RESISTANCE_UNAVAILABLE = -67,
    UNIMPLEMENTED = -100,
    UNKNOWN_ERROR = -1000,
};

const char* kmErrorName(KmError e);

// keymaster@4.0 KeyCharacteristics. A StrongBox puts what it enforces itself in
// hardwareEnforced; km_compat maps that list to the STRONGBOX level and ignores
// softwareEnforced, adding the keystore-enforced tags from the request itself.
struct KeyCharacteristics {
    AuthList softwareEnforced;
    AuthList hardwareEnforced;
};

constexpr size_t kMaxOperations = 16;
constexpr size_t kMaxOperationBytes = 16u << 20;

class Engine {
public:
    explicit Engine(std::unique_ptr<TpmBackend> backend);
    ~Engine();

    // Create the persistent primary if needed. Idempotent; every key operation
    // calls it, so a TPM that comes up after the daemon is picked up then.
    KmError init();

    std::string backendDescription() { return backend_->describe(); }

    KmError generateKey(const AuthList& request, Bytes& blobOut,
                        KeyCharacteristics& kc);
    // AES in KeyFormat::RAW only, for now.
    KmError importKey(const AuthList& request, KeyFormat format,
                      const Bytes& keyData, Bytes& blobOut,
                      KeyCharacteristics& kc);
    KmError getKeyCharacteristics(const Bytes& blob, const Bytes& clientId,
                                  const Bytes& appData, KeyCharacteristics& kc);
    // EC keys in KeyFormat::X509 (SubjectPublicKeyInfo DER) only.
    KmError exportKey(KeyFormat format, const Bytes& blob, const Bytes& clientId,
                      const Bytes& appData, Bytes& out);

    KmError begin(Purpose purpose, const Bytes& blob, const AuthList& inParams,
                  AuthList& outParams, uint64_t& handle);
    KmError update(uint64_t handle, const AuthList& inParams, const Bytes& input,
                   uint32_t& inputConsumed, AuthList& outParams, Bytes& output);
    KmError finish(uint64_t handle, const AuthList& inParams, const Bytes& input,
                   const Bytes& signature, AuthList& outParams, Bytes& output);
    KmError abort(uint64_t handle);

    KmError getRandom(size_t n, Bytes& out);
    size_t operationCount();

private:
    struct Operation;

    KmError ensurePrimary();
    KmError mint(const AuthList& request, Algorithm alg, Origin origin,
                 const Bytes* rawAes, Bytes& blobOut, KeyCharacteristics& kc);
    KmError parseBound(const Bytes& blob, const Bytes& clientId,
                       const Bytes& appData, KeyBlob& kb);
    KmError absorb(Operation& op, const AuthList& inParams, const Bytes& input);
    KmError finishSign(Operation& op, Bytes& output);
    KmError finishAes(Operation& op, Bytes& output);
    KmError finishGcm(Operation& op, Bytes& output);

    std::unique_ptr<TpmBackend> backend_;
    std::mutex lock_;
    bool primaryReady_ = false;
    std::map<uint64_t, std::unique_ptr<Operation>> ops_;
};

// Split a key's stored list into what this engine enforces and the rest, minus
// APPLICATION_ID/APPLICATION_DATA, which keymaster never discloses.
KeyCharacteristics characteristicsOf(const AuthList& stored);

} // namespace wks

#endif
