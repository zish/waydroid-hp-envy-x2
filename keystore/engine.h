// engine.h -- the keymaster-semantics layer over a TpmBackend.
//
// This is the part the stage-3 HIDL HAL calls. It owns the key blob format, maps
// a keymaster request (an AuthList) to a backend CreateSpec, and -- the point of
// it -- enforces the authorization tags on every operation, because a TPM does
// not. Errors use a subset of keymaster's ErrorCode so the HIDL layer can return
// them unchanged.
//
// All backend calls run under one mutex: the tools backend flushes every
// transient object when it finishes (docs/71 finding 3), so two operations must
// never be in flight at once. kMaxConcurrentOps is the hard cap the three-slot
// TPM forces on the streaming begin/update/finish model of later stages; stage 1
// is one-shot, so it is effectively one.
#ifndef WAYDROID_KEYSTORE_ENGINE_H
#define WAYDROID_KEYSTORE_ENGINE_H

#include "keystore.h"
#include <memory>
#include <mutex>

namespace wks {

enum class KmError : int {
    OK = 0,
    ROOT_OF_TRUST_ALREADY_SET = -1,
    UNSUPPORTED_PURPOSE = -4,
    INCOMPATIBLE_PURPOSE = -5,
    UNSUPPORTED_ALGORITHM = -6,
    INCOMPATIBLE_ALGORITHM = -7,
    UNSUPPORTED_KEY_SIZE = -10,
    UNSUPPORTED_DIGEST = -13,
    INVALID_KEY_BLOB = -24,
    UNSUPPORTED_KEY_FORMAT = -20,
    INVALID_ARGUMENT = -38,
    UNIMPLEMENTED = -100,
    UNKNOWN_ERROR = -1000,
};

const char* kmErrorName(KmError e);

constexpr int kMaxConcurrentOps = 1;

class Engine {
public:
    explicit Engine(std::unique_ptr<TpmBackend> backend);

    // Create the persistent primary if needed. Call once at startup.
    KmError init();

    std::string backendDescription() { return backend_->describe(); }

    // keymaster generateKey: mint a key satisfying `request`, return its blob.
    KmError generateKey(const AuthList& request, KeyBlob& out);

    // keymaster getKeyCharacteristics: the tags bound into the blob.
    KmError getKeyCharacteristics(const Bytes& blob, AuthList& out);

    // One-shot operations (stage 1). Tags are re-read from the blob and enforced
    // here; nothing the caller passes alongside the blob is trusted.
    KmError sign(const Bytes& blob, const Bytes& digest, Bytes& sigOut);
    KmError verify(const Bytes& blob, const Bytes& digest, const Bytes& sig);
    KmError encrypt(const Bytes& blob, Bytes& iv, const Bytes& in, Bytes& out);
    KmError decrypt(const Bytes& blob, Bytes& iv, const Bytes& in, Bytes& out);

    KmError getRandom(size_t n, Bytes& out);

private:
    KmError loadAndCheck(const Bytes& blob, KeyBlob& kb, Algorithm expectAlg,
                         Purpose purpose);
    std::unique_ptr<TpmBackend> backend_;
    std::mutex lock_;
};

} // namespace wks

#endif
