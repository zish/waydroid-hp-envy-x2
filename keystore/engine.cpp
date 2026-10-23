// engine.cpp -- see engine.h.
#include "engine.h"
#include "soft_crypto.h"

#include <cstring>
#include <sys/random.h>
#include <time.h>

namespace wks {

const char* kmErrorName(KmError e) {
    switch (e) {
    case KmError::OK: return "OK";
    case KmError::UNSUPPORTED_PURPOSE: return "UNSUPPORTED_PURPOSE";
    case KmError::INCOMPATIBLE_PURPOSE: return "INCOMPATIBLE_PURPOSE";
    case KmError::UNSUPPORTED_ALGORITHM: return "UNSUPPORTED_ALGORITHM";
    case KmError::INCOMPATIBLE_ALGORITHM: return "INCOMPATIBLE_ALGORITHM";
    case KmError::UNSUPPORTED_KEY_SIZE: return "UNSUPPORTED_KEY_SIZE";
    case KmError::UNSUPPORTED_BLOCK_MODE: return "UNSUPPORTED_BLOCK_MODE";
    case KmError::INCOMPATIBLE_BLOCK_MODE: return "INCOMPATIBLE_BLOCK_MODE";
    case KmError::UNSUPPORTED_MAC_LENGTH: return "UNSUPPORTED_MAC_LENGTH";
    case KmError::UNSUPPORTED_PADDING_MODE: return "UNSUPPORTED_PADDING_MODE";
    case KmError::INCOMPATIBLE_PADDING_MODE: return "INCOMPATIBLE_PADDING_MODE";
    case KmError::UNSUPPORTED_DIGEST: return "UNSUPPORTED_DIGEST";
    case KmError::INCOMPATIBLE_DIGEST: return "INCOMPATIBLE_DIGEST";
    case KmError::UNSUPPORTED_KEY_FORMAT: return "UNSUPPORTED_KEY_FORMAT";
    case KmError::INVALID_INPUT_LENGTH: return "INVALID_INPUT_LENGTH";
    case KmError::KEY_USER_NOT_AUTHENTICATED: return "KEY_USER_NOT_AUTHENTICATED";
    case KmError::INVALID_OPERATION_HANDLE: return "INVALID_OPERATION_HANDLE";
    case KmError::VERIFICATION_FAILED: return "VERIFICATION_FAILED";
    case KmError::TOO_MANY_OPERATIONS: return "TOO_MANY_OPERATIONS";
    case KmError::INVALID_KEY_BLOB: return "INVALID_KEY_BLOB";
    case KmError::INVALID_ARGUMENT: return "INVALID_ARGUMENT";
    case KmError::UNSUPPORTED_TAG: return "UNSUPPORTED_TAG";
    case KmError::INVALID_TAG: return "INVALID_TAG";
    case KmError::IMPORT_PARAMETER_MISMATCH: return "IMPORT_PARAMETER_MISMATCH";
    case KmError::SECURE_HW_COMMUNICATION_FAILED: return "SECURE_HW_COMMUNICATION_FAILED";
    case KmError::MISSING_NONCE: return "MISSING_NONCE";
    case KmError::INVALID_NONCE: return "INVALID_NONCE";
    case KmError::MISSING_MAC_LENGTH: return "MISSING_MAC_LENGTH";
    case KmError::CALLER_NONCE_PROHIBITED: return "CALLER_NONCE_PROHIBITED";
    case KmError::INVALID_MAC_LENGTH: return "INVALID_MAC_LENGTH";
    case KmError::MISSING_MIN_MAC_LENGTH: return "MISSING_MIN_MAC_LENGTH";
    case KmError::UNSUPPORTED_MIN_MAC_LENGTH: return "UNSUPPORTED_MIN_MAC_LENGTH";
    case KmError::UNSUPPORTED_EC_CURVE: return "UNSUPPORTED_EC_CURVE";
    case KmError::ROLLBACK_RESISTANCE_UNAVAILABLE: return "ROLLBACK_RESISTANCE_UNAVAILABLE";
    case KmError::UNIMPLEMENTED: return "UNIMPLEMENTED";
    default: return "UNKNOWN_ERROR";
    }
}

struct Engine::Operation {
    KeyBlob key;
    Bytes auth;                       // authDigest(key.authorizations)
    Purpose purpose = Purpose::SIGN;
    Digest digest = Digest::NONE;
    BlockMode mode = BlockMode::ECB;
    Padding padding = Padding::NONE;
    Bytes nonce;
    uint32_t macBytes = 0;
    Bytes aad;
    Bytes data;
    bool authBound = false;           // the key has a USER_SECURE_ID
    bool perOpAuth = false;           // ... and no AUTH_TIMEOUT
};

namespace {

bool fillRandom(void* p, size_t n) {
    uint8_t* b = static_cast<uint8_t*>(p);
    while (n > 0) {
        size_t take = n > 256 ? 256 : n;
        if (getentropy(b, take) != 0) return false;
        b += take; n -= take;
    }
    return true;
}

// Every value of a repeated enum tag must be in `allowed`.
bool allIn(const AuthList& a, Tag t, std::initializer_list<uint32_t> allowed) {
    for (uint64_t v : a.all(t)) {
        bool ok = false;
        for (uint32_t x : allowed) if (v == x) ok = true;
        if (!ok) return false;
    }
    return true;
}

template <typename E> uint32_t u(E e) { return static_cast<uint32_t>(e); }

// Tags whose meaning this engine checks on every use, and so reports as
// hardware-enforced. Everything else in a request is stored but not claimed.
// The auth tags are checked either way; whether that is worth claiming depends
// on whether the tokens they rest on are authenticated (EngineOptions).
bool engineEnforces(Tag t, bool authInHardware) {
    switch (t) {
    case Tag::PURPOSE: case Tag::ALGORITHM: case Tag::KEY_SIZE:
    case Tag::BLOCK_MODE: case Tag::DIGEST: case Tag::PADDING:
    case Tag::CALLER_NONCE: case Tag::MIN_MAC_LENGTH: case Tag::EC_CURVE:
    case Tag::NO_AUTH_REQUIRED: case Tag::ORIGIN:
        return true;
    case Tag::USER_SECURE_ID: case Tag::USER_AUTH_TYPE: case Tag::AUTH_TIMEOUT:
        return authInHardware;
    default:
        return false;
    }
}

// Requests asking for something this engine cannot honour. Trusted user
// presence and trusted confirmation each need a token from hardware this
// machine does not have; claiming them would be a lie keystore2 would believe.
KmError refuseUnsupported(const AuthList& req) {
    if (req.has(Tag::ROLLBACK_RESISTANCE))
        return KmError::ROLLBACK_RESISTANCE_UNAVAILABLE;
    if (req.has(Tag::TRUSTED_USER_PRESENCE_REQUIRED) ||
        req.has(Tag::TRUSTED_CONFIRMATION_REQUIRED))
        return KmError::UNSUPPORTED_TAG;
    return KmError::OK;
}

const Bytes kEmpty;

} // namespace

KeyCharacteristics characteristicsOf(const AuthList& stored, bool authInHardware) {
    KeyCharacteristics kc;
    for (const auto& p : stored.params) {
        if (p.tag == Tag::APPLICATION_ID || p.tag == Tag::APPLICATION_DATA)
            continue;
        (engineEnforces(p.tag, authInHardware) ? kc.hardwareEnforced
                                               : kc.softwareEnforced)
            .params.push_back(p);
    }
    return kc;
}

Engine::Engine(std::unique_ptr<TpmBackend> backend, EngineOptions options)
    : backend_(std::move(backend)), opts_(std::move(options)) {
    // The seed is ours to choose (a TEE sends an empty one, a StrongBox may
    // send anything); both are random so a restarted daemon is a new party.
    mine_.seed.resize(32);
    mine_.nonce.resize(kSharingNonceLength);
    if (!fillRandom(mine_.seed.data(), mine_.seed.size()) ||
        !fillRandom(mine_.nonce.data(), mine_.nonce.size()))
        mine_.nonce.clear();   // computeSharedHmac then never finds us
}
Engine::~Engine() {
    std::fill(sharedKey_.begin(), sharedKey_.end(), 0);
}

uint64_t Engine::nowMs() const {
    if (opts_.clockMs) return opts_.clockMs();
    struct timespec ts;
    if (clock_gettime(CLOCK_BOOTTIME, &ts) != 0) return 0;
    return uint64_t(ts.tv_sec) * 1000 + uint64_t(ts.tv_nsec) / 1000000;
}

KmError Engine::ensurePrimary() {
    if (primaryReady_) return KmError::OK;
    if (!backend_->ensurePrimary()) return KmError::SECURE_HW_COMMUNICATION_FAILED;
    primaryReady_ = true;
    return KmError::OK;
}

KmError Engine::init() {
    std::lock_guard<std::mutex> g(lock_);
    return ensurePrimary();
}

// --- key creation -------------------------------------------------------------

KmError Engine::mint(const AuthList& requestIn, Algorithm alg, Origin origin,
                     const Bytes* rawAes, Bytes& blobOut, KeyCharacteristics& kc) {
    KmError e = refuseUnsupported(requestIn);
    if (e != KmError::OK) return e;

    AuthList req = requestIn;
    // Provenance is ours to state, never the caller's.
    req.remove(Tag::ORIGIN);
    req.remove(Tag::ROOT_OF_TRUST);
    req.remove(Tag::OS_VERSION);
    req.remove(Tag::OS_PATCHLEVEL);

    CreateSpec spec;
    spec.algorithm = alg;

    if (alg == Algorithm::EC) {
        auto curve = req.first(Tag::EC_CURVE);
        auto ksize = req.first(Tag::KEY_SIZE);
        if (curve && *curve != u(EcCurve::P_256)) return KmError::UNSUPPORTED_EC_CURVE;
        if (ksize && *ksize != 256) return KmError::UNSUPPORTED_KEY_SIZE;
        if (!curve && !ksize) return KmError::UNSUPPORTED_KEY_SIZE;
        if (!curve) req.addEnum(Tag::EC_CURVE, u(EcCurve::P_256));
        if (!ksize) req.addUint(Tag::KEY_SIZE, 256);
        if (!req.hasEnumVal(Tag::PURPOSE, u(Purpose::SIGN)) ||
            !allIn(req, Tag::PURPOSE, {u(Purpose::SIGN), u(Purpose::VERIFY)}))
            return KmError::UNSUPPORTED_PURPOSE;
        if (!allIn(req, Tag::DIGEST, {u(Digest::NONE), u(Digest::SHA_2_256)}))
            return KmError::UNSUPPORTED_DIGEST;
        spec.keySizeBits = 256;
    } else if (alg == Algorithm::AES) {
        auto ksize = req.first(Tag::KEY_SIZE);
        if (rawAes) {
            uint64_t have = uint64_t(rawAes->size()) * 8;
            if (ksize && *ksize != have) return KmError::IMPORT_PARAMETER_MISMATCH;
            if (!ksize) { req.addUint(Tag::KEY_SIZE, uint32_t(have)); ksize = have; }
        }
        if (!ksize || (*ksize != 128 && *ksize != 256))
            return KmError::UNSUPPORTED_KEY_SIZE;
        if (req.all(Tag::PURPOSE).empty() ||
            !allIn(req, Tag::PURPOSE, {u(Purpose::ENCRYPT), u(Purpose::DECRYPT)}))
            return KmError::UNSUPPORTED_PURPOSE;
        if (!allIn(req, Tag::BLOCK_MODE, {u(BlockMode::ECB), u(BlockMode::CBC),
                                          u(BlockMode::CTR), u(BlockMode::GCM)}))
            return KmError::UNSUPPORTED_BLOCK_MODE;
        if (!allIn(req, Tag::PADDING, {u(Padding::NONE), u(Padding::PKCS7)}))
            return KmError::UNSUPPORTED_PADDING_MODE;
        if (req.hasEnumVal(Tag::BLOCK_MODE, u(BlockMode::GCM))) {
            auto minMac = req.first(Tag::MIN_MAC_LENGTH);
            if (!minMac) return KmError::MISSING_MIN_MAC_LENGTH;
            if (*minMac % 8 || *minMac < 96 || *minMac > 128)
                return KmError::UNSUPPORTED_MIN_MAC_LENGTH;
        }
        spec.keySizeBits = uint32_t(*ksize);
    } else {
        return KmError::UNSUPPORTED_ALGORITHM;  // RSA/HMAC/3DES are later stages
    }

    req.remove(Tag::ALGORITHM);   // exactly one, the one we acted on
    req.addEnum(Tag::ALGORITHM, u(alg));
    req.addEnum(Tag::ORIGIN, u(origin));

    e = ensurePrimary();
    if (e != KmError::OK) return e;

    KeyBlob kb;
    kb.algorithm = alg;
    kb.authorizations = req;
    spec.auth = authDigest(req);
    bool ok = rawAes ? backend_->importAes(*rawAes, spec.auth, kb.tpmPublic, kb.tpmPrivate)
                     : backend_->createKey(spec, kb.tpmPublic, kb.tpmPrivate);
    if (!ok) return KmError::SECURE_HW_COMMUNICATION_FAILED;

    blobOut = kb.serialize();
    kc = characteristicsOf(kb.authorizations, !opts_.acceptUnsignedAuthTokens);
    return KmError::OK;
}

KmError Engine::generateKey(const AuthList& request, Bytes& blobOut,
                            KeyCharacteristics& kc) {
    std::lock_guard<std::mutex> g(lock_);
    auto alg = request.first(Tag::ALGORITHM);
    if (!alg) return KmError::UNSUPPORTED_ALGORITHM;
    return mint(request, static_cast<Algorithm>(*alg), Origin::GENERATED, nullptr,
                blobOut, kc);
}

KmError Engine::importKey(const AuthList& request, KeyFormat format,
                          const Bytes& keyData, Bytes& blobOut,
                          KeyCharacteristics& kc) {
    std::lock_guard<std::mutex> g(lock_);
    auto alg = request.first(Tag::ALGORITHM);
    if (!alg) return KmError::UNSUPPORTED_ALGORITHM;
    if (static_cast<Algorithm>(*alg) != Algorithm::AES)
        return KmError::UNIMPLEMENTED;  // EC PKCS#8 import is a later stage
    if (format != KeyFormat::RAW) return KmError::UNSUPPORTED_KEY_FORMAT;
    if (keyData.size() != 16 && keyData.size() != 32)
        return KmError::UNSUPPORTED_KEY_SIZE;
    return mint(request, Algorithm::AES, Origin::IMPORTED, &keyData, blobOut, kc);
}

// --- key inspection ------------------------------------------------------------

// Parse a blob and check the caller presented the APPLICATION_ID/APPLICATION_DATA
// it was bound to. A mismatch is INVALID_KEY_BLOB, as keymaster specifies: the
// key does not exist for a caller who cannot name it.
KmError Engine::parseBound(const Bytes& blob, const Bytes& clientId,
                           const Bytes& appData, KeyBlob& kb) {
    auto parsed = KeyBlob::parse(blob);
    if (!parsed) return KmError::INVALID_KEY_BLOB;
    const Bytes* id = parsed->authorizations.firstBytes(Tag::APPLICATION_ID);
    const Bytes* data = parsed->authorizations.firstBytes(Tag::APPLICATION_DATA);
    if ((id ? *id : kEmpty) != clientId) return KmError::INVALID_KEY_BLOB;
    if ((data ? *data : kEmpty) != appData) return KmError::INVALID_KEY_BLOB;
    kb = std::move(*parsed);
    return KmError::OK;
}

KmError Engine::getKeyCharacteristics(const Bytes& blob, const Bytes& clientId,
                                      const Bytes& appData, KeyCharacteristics& kc) {
    std::lock_guard<std::mutex> g(lock_);
    KeyBlob kb;
    KmError e = parseBound(blob, clientId, appData, kb);
    if (e != KmError::OK) return e;
    kc = characteristicsOf(kb.authorizations, !opts_.acceptUnsignedAuthTokens);
    return KmError::OK;
}

KmError Engine::exportKey(KeyFormat format, const Bytes& blob, const Bytes& clientId,
                          const Bytes& appData, Bytes& out) {
    std::lock_guard<std::mutex> g(lock_);
    KeyBlob kb;
    KmError e = parseBound(blob, clientId, appData, kb);
    if (e != KmError::OK) return e;
    if (kb.algorithm != Algorithm::EC) return KmError::UNSUPPORTED_KEY_FORMAT;
    if (format != KeyFormat::X509) return KmError::UNSUPPORTED_KEY_FORMAT;
    out = spkiFromTpmPublic(kb.tpmPublic);
    return out.empty() ? KmError::INVALID_KEY_BLOB : KmError::OK;
}

// --- the shared HMAC key and tokens (stage 5, docs/74) ---------------------------

KmError Engine::computeSharedHmac(const std::vector<HmacSharingParams>& params,
                                  Bytes& check) {
    std::lock_guard<std::mutex> g(lock_);
    check.clear();
    bool mine = false;
    for (const auto& p : params)
        mine = mine || (p.seed == mine_.seed && p.nonce == mine_.nonce);
    if (!mine || mine_.nonce.empty()) return KmError::INVALID_ARGUMENT;
    Bytes h = deriveSharedHmacKey(opts_.keyAgreementKey, params);
    if (h.size() != 32) return KmError::UNKNOWN_ERROR;
    std::fill(sharedKey_.begin(), sharedKey_.end(), 0);
    sharedKey_ = std::move(h);
    check = sharingCheck(sharedKey_);
    return KmError::OK;
}

bool Engine::hasSharedKey() {
    std::lock_guard<std::mutex> g(lock_);
    return !sharedKey_.empty();
}

namespace {
KmError deny(std::string* why, const std::string& reason) {
    if (why) *why = reason;
    return KmError::KEY_USER_NOT_AUTHENTICATED;
}
bool allZero(const Bytes& b) {
    uint8_t acc = 0;
    for (uint8_t x : b) acc |= x;
    return acc == 0;
}
} // namespace

// The HardwareAuthToken checks of IKeymasterDevice::begin and ::update: the MAC,
// a USER_SECURE_ID in common, the auth type, and then either the challenge (a
// per-operation key) or the age (a timeout key). Called with the lock held.
KmError Engine::authorize(const AuthList& key, const HardwareAuthToken& t,
                          const uint64_t* challenge, std::string* why) {
    if (!t.present()) return deny(why, "no auth token");
    if (t.mac.size() != kAuthMacLength) return deny(why, "auth token MAC is not 32 bytes");

    const char* how;
    if (!sharedKey_.empty() &&
        ctEqual(authTokenMac(sharedKey_, t).data(), t.mac.data(), kAuthMacLength)) {
        how = "signed with the shared key";
    } else if (opts_.acceptUnsignedAuthTokens && allZero(t.mac)) {
        how = "unsigned, accepted by --accept-unsigned-auth-tokens";
    } else if (sharedKey_.empty()) {
        return deny(why, "auth token cannot be verified: no shared key was negotiated");
    } else {
        return deny(why, allZero(t.mac) ? "auth token is unsigned (32 zero bytes)"
                                        : "auth token MAC is invalid");
    }

    bool sid = false;
    for (uint64_t s : key.all(Tag::USER_SECURE_ID))
        sid = sid || s == t.userId || s == t.authenticatorId;
    if (!sid) return deny(why, "auth token's secure IDs match none of the key's");
    auto type = key.first(Tag::USER_AUTH_TYPE);
    if (!type || (uint32_t(*type) & t.authenticatorType) == 0)
        return deny(why, "auth token's authenticator type is not one the key allows");

    char buf[128];
    if (challenge) {
        if (t.challenge != *challenge)
            return deny(why, "auth token was issued for another operation");
        snprintf(buf, sizeof buf, "%s, for this operation", how);
    } else {
        // Both clocks are CLOCK_BOOTTIME on one kernel (docs/74 measured it to
        // the millisecond), so a token from the future is not skew; it is
        // something that did not come from the authenticator.
        uint64_t now = nowMs(), limit = key.first(Tag::AUTH_TIMEOUT).value_or(0) * 1000;
        if (t.timestamp > now) return deny(why, "auth token is dated in the future");
        if (now - t.timestamp > limit) {
            snprintf(buf, sizeof buf, "auth token is %llu ms old, the key allows %llu",
                     (unsigned long long) (now - t.timestamp), (unsigned long long) limit);
            return deny(why, buf);
        }
        snprintf(buf, sizeof buf, "%s, %llu ms old of %llu allowed", how,
                 (unsigned long long) (now - t.timestamp), (unsigned long long) limit);
    }
    if (why) *why = buf;
    return KmError::OK;
}

// A VerificationToken is another instance vouching for its clock at this
// operation. Both MAC forms are a MAC under H; see auth.h.
KmError Engine::checkVerificationToken(const VerificationToken& vt, uint64_t handle,
                                       std::string* why) {
    if (vt.parametersVerified)
        return deny(why, "verification token carries parametersVerified, which is not MACed here");
    if (vt.challenge != handle)
        return deny(why, "verification token was issued for another operation");
    if (sharedKey_.empty())
        return deny(why, "verification token cannot be verified: no shared key was negotiated");
    if (vt.mac.size() == kAuthMacLength) {
        for (VtForm f : {VtForm::SPEC, VtForm::AOSP_SOFTWARE}) {
            if (ctEqual(verificationTokenMac(sharedKey_, vt, f).data(), vt.mac.data(),
                        kAuthMacLength)) {
                if (why) *why += std::string("; verification token valid (") +
                                 vtFormName(f) + " form)";
                return KmError::OK;
            }
        }
    }
    return deny(why, "verification token MAC is invalid");
}

// The per-call half: a per-operation key's token on every update and finish,
// and any verification token handed to an auth-bound operation.
KmError Engine::authorizeStep(Operation& op, uint64_t handle, const HardwareAuthToken& hat,
                              const VerificationToken& vt, std::string* why) {
    if (!op.authBound) return KmError::OK;
    if (op.perOpAuth) {
        KmError e = authorize(op.key.authorizations, hat, &handle, why);
        if (e != KmError::OK) return e;
    } else if (why) {
        *why = "authorized at begin";
    }
    return vt.present() ? checkVerificationToken(vt, handle, why) : KmError::OK;
}

// --- operations ------------------------------------------------------------------

KmError Engine::begin(Purpose purpose, const Bytes& blob, const AuthList& in,
                      AuthList& outParams, uint64_t& handle,
                      const HardwareAuthToken& authToken, std::string* why) {
    std::lock_guard<std::mutex> g(lock_);
    outParams.params.clear();
    handle = 0;
    if (why) why->clear();

    if (ops_.size() >= kMaxOperations) return KmError::TOO_MANY_OPERATIONS;

    auto op = std::make_unique<Operation>();
    const Bytes* id = in.firstBytes(Tag::APPLICATION_ID);
    const Bytes* ad = in.firstBytes(Tag::APPLICATION_DATA);
    KmError e = parseBound(blob, id ? *id : kEmpty, ad ? *ad : kEmpty, op->key);
    if (e != KmError::OK) return e;
    const AuthList& key = op->key.authorizations;
    op->purpose = purpose;
    op->auth = authDigest(key);

    if (!key.hasEnumVal(Tag::PURPOSE, u(purpose))) return KmError::INCOMPATIBLE_PURPOSE;

    // A USER_SECURE_ID binds the key to an authentication whatever else the
    // list says, NO_AUTH_REQUIRED included: the safe reading of a contradiction.
    if (key.has(Tag::USER_SECURE_ID)) {
        op->authBound = true;
        if (key.has(Tag::AUTH_TIMEOUT)) {
            e = authorize(key, authToken, nullptr, why);
            if (e != KmError::OK) return e;
        } else {
            op->perOpAuth = true;   // the token comes with each update and finish
            if (why) *why = "per-operation key: a token is due on each update and finish";
        }
    }

    if (op->key.algorithm == Algorithm::EC) {
        // Public-key operations belong to the caller (KeyMint dropped them, and
        // the framework verifies with the exported key), so only SIGN reaches us.
        if (purpose != Purpose::SIGN) return KmError::UNSUPPORTED_PURPOSE;
        auto d = in.first(Tag::DIGEST);
        if (!d) return KmError::UNSUPPORTED_DIGEST;
        if (*d != u(Digest::NONE) && *d != u(Digest::SHA_2_256))
            return KmError::UNSUPPORTED_DIGEST;
        if (!key.hasEnumVal(Tag::DIGEST, uint32_t(*d))) return KmError::INCOMPATIBLE_DIGEST;
        op->digest = static_cast<Digest>(*d);
    } else if (op->key.algorithm == Algorithm::AES) {
        if (purpose != Purpose::ENCRYPT && purpose != Purpose::DECRYPT)
            return KmError::UNSUPPORTED_PURPOSE;
        auto m = in.first(Tag::BLOCK_MODE);
        if (!m) return KmError::UNSUPPORTED_BLOCK_MODE;
        if (*m != u(BlockMode::ECB) && *m != u(BlockMode::CBC) &&
            *m != u(BlockMode::CTR) && *m != u(BlockMode::GCM))
            return KmError::UNSUPPORTED_BLOCK_MODE;
        if (!key.hasEnumVal(Tag::BLOCK_MODE, uint32_t(*m)))
            return KmError::INCOMPATIBLE_BLOCK_MODE;
        op->mode = static_cast<BlockMode>(*m);

        uint64_t p = in.first(Tag::PADDING).value_or(u(Padding::NONE));
        if (p != u(Padding::NONE) && p != u(Padding::PKCS7))
            return KmError::UNSUPPORTED_PADDING_MODE;
        if (p == u(Padding::PKCS7) &&
            (op->mode == BlockMode::CTR || op->mode == BlockMode::GCM))
            return KmError::INCOMPATIBLE_PADDING_MODE;
        if (!key.hasEnumVal(Tag::PADDING, uint32_t(p))) return KmError::INCOMPATIBLE_PADDING_MODE;
        op->padding = static_cast<Padding>(p);

        if (op->mode == BlockMode::GCM) {
            auto mac = in.first(Tag::MAC_LENGTH);
            if (!mac) return KmError::MISSING_MAC_LENGTH;
            if (*mac % 8 || *mac < 96 || *mac > 128) return KmError::UNSUPPORTED_MAC_LENGTH;
            if (*mac < key.first(Tag::MIN_MAC_LENGTH).value_or(128))
                return KmError::INVALID_MAC_LENGTH;
            op->macBytes = uint32_t(*mac / 8);
        }

        if (op->mode != BlockMode::ECB) {
            size_t nonceLen = op->mode == BlockMode::GCM ? 12 : 16;
            const Bytes* n = in.firstBytes(Tag::NONCE);
            if (n) {
                if (purpose == Purpose::ENCRYPT && !key.has(Tag::CALLER_NONCE))
                    return KmError::CALLER_NONCE_PROHIBITED;
                if (n->size() != nonceLen) return KmError::INVALID_NONCE;
                op->nonce = *n;
            } else if (purpose == Purpose::DECRYPT) {
                return KmError::MISSING_NONCE;
            } else {
                op->nonce.resize(nonceLen);
                if (!fillRandom(op->nonce.data(), nonceLen)) return KmError::UNKNOWN_ERROR;
                outParams.addBytes(Tag::NONCE, op->nonce);
            }
        }
    } else {
        return KmError::INCOMPATIBLE_ALGORITHM;
    }

    do {
        if (!fillRandom(&handle, sizeof handle)) return KmError::UNKNOWN_ERROR;
    } while (handle == 0 || ops_.count(handle));
    ops_[handle] = std::move(op);
    return KmError::OK;
}

// Take one call's parameters and input into an operation's buffers.
KmError Engine::absorb(Operation& op, const AuthList& in, const Bytes& input) {
    for (const auto& p : in.params) {
        if (p.tag != Tag::ASSOCIATED_DATA) continue;
        // AAD is GCM's alone, and must all arrive before the first data byte.
        if (op.mode != BlockMode::GCM || op.key.algorithm != Algorithm::AES ||
            !op.data.empty())
            return KmError::INVALID_TAG;
        if (op.aad.size() + p.blob.size() > kMaxOperationBytes)
            return KmError::INVALID_INPUT_LENGTH;
        op.aad.insert(op.aad.end(), p.blob.begin(), p.blob.end());
    }
    if (op.data.size() + input.size() > kMaxOperationBytes)
        return KmError::INVALID_INPUT_LENGTH;
    op.data.insert(op.data.end(), input.begin(), input.end());
    return KmError::OK;
}

KmError Engine::update(uint64_t handle, const AuthList& in, const Bytes& input,
                       uint32_t& inputConsumed, AuthList& outParams, Bytes& output,
                       const HardwareAuthToken& authToken,
                       const VerificationToken& verificationToken, std::string* why) {
    std::lock_guard<std::mutex> g(lock_);
    inputConsumed = 0;
    outParams.params.clear();
    output.clear();
    if (why) why->clear();
    auto it = ops_.find(handle);
    if (it == ops_.end()) return KmError::INVALID_OPERATION_HANDLE;
    KmError e = authorizeStep(*it->second, handle, authToken, verificationToken, why);
    if (e != KmError::OK) { ops_.erase(it); return e; }
    e = absorb(*it->second, in, input);
    if (e != KmError::OK) { ops_.erase(it); return e; }  // an error ends the op
    inputConsumed = uint32_t(input.size());
    return KmError::OK;
}

KmError Engine::finish(uint64_t handle, const AuthList& in, const Bytes& input,
                       const Bytes& /*signature*/, AuthList& outParams, Bytes& output,
                       const HardwareAuthToken& authToken,
                       const VerificationToken& verificationToken, std::string* why) {
    std::lock_guard<std::mutex> g(lock_);
    outParams.params.clear();
    output.clear();
    if (why) why->clear();
    auto it = ops_.find(handle);
    if (it == ops_.end()) return KmError::INVALID_OPERATION_HANDLE;
    std::unique_ptr<Operation> op = std::move(it->second);
    ops_.erase(it);  // finish ends the op whatever happens next

    KmError e = authorizeStep(*op, handle, authToken, verificationToken, why);
    if (e != KmError::OK) return e;
    e = absorb(*op, in, input);
    if (e != KmError::OK) return e;
    e = ensurePrimary();
    if (e != KmError::OK) return e;
    if (op->key.algorithm == Algorithm::EC) return finishSign(*op, output);
    if (op->mode == BlockMode::GCM) return finishGcm(*op, output);
    return finishAes(*op, output);
}

KmError Engine::abort(uint64_t handle) {
    std::lock_guard<std::mutex> g(lock_);
    return ops_.erase(handle) ? KmError::OK : KmError::INVALID_OPERATION_HANDLE;
}

KmError Engine::finishSign(Operation& op, Bytes& output) {
    Bytes digest;
    if (op.digest == Digest::SHA_2_256) {
        digest = Sha256::hash(op.data);
    } else {
        // DIGEST=NONE: the input is the digest. ECDSA uses its leftmost bits up
        // to the order's length, and a shorter one is the same integer when
        // left-padded, which the TPM needs because it insists on 32 bytes.
        digest.assign(32, 0);
        size_t n = op.data.size() < 32 ? op.data.size() : 32;
        memcpy(digest.data() + (32 - n), op.data.data(), n);
    }
    return backend_->signEcdsa(op.key.tpmPublic, op.key.tpmPrivate, op.auth, digest,
                               output)
               ? KmError::OK : KmError::UNKNOWN_ERROR;
}

KmError Engine::finishAes(Operation& op, Bytes& output) {
    const bool enc = op.purpose == Purpose::ENCRYPT;
    TpmMode mode = op.mode == BlockMode::ECB ? TpmMode::ECB
                 : op.mode == BlockMode::CBC ? TpmMode::CBC : TpmMode::CTR;
    Bytes in = std::move(op.data);

    if (op.mode == BlockMode::ECB || op.mode == BlockMode::CBC) {
        if (enc && op.padding == Padding::PKCS7) in = pkcs7Pad(in);
        if (in.size() % 16) return KmError::INVALID_INPUT_LENGTH;
        if (!enc && op.padding == Padding::PKCS7 && in.empty())
            return KmError::INVALID_INPUT_LENGTH;
    }
    if (in.empty()) return KmError::OK;  // nothing to send the TPM

    if (!backend_->aes(op.key.tpmPublic, op.key.tpmPrivate, op.auth, mode,
                       enc ? CipherOp::ENCRYPT : CipherOp::DECRYPT, op.nonce, in,
                       output))
        return KmError::UNKNOWN_ERROR;
    if (output.size() != in.size()) return KmError::UNKNOWN_ERROR;
    if (!enc && op.padding == Padding::PKCS7 && !pkcs7Unpad(output)) {
        output.clear();
        return KmError::INVALID_ARGUMENT;
    }
    return KmError::OK;
}

// GCM from the TPM's ECB. One TPM call encrypts, in order, the zero block (H),
// J0 (for the tag) and every counter block the data needs; GHASH runs here.
KmError Engine::finishGcm(Operation& op, Bytes& output) {
    const bool enc = op.purpose == Purpose::ENCRYPT;
    Bytes text = std::move(op.data), tag;
    if (!enc) {
        if (text.size() < op.macBytes) return KmError::INVALID_INPUT_LENGTH;
        tag.assign(text.end() - op.macBytes, text.end());
        text.resize(text.size() - op.macBytes);
    }
    size_t blocks = (text.size() + 15) / 16;

    uint8_t ctr[16];
    memcpy(ctr, op.nonce.data(), 12);
    ctr[12] = 0; ctr[13] = 0; ctr[14] = 0; ctr[15] = 1;   // J0 for a 96-bit IV
    Bytes in(16 * (2 + blocks), 0);
    memcpy(in.data() + 16, ctr, 16);
    for (size_t i = 0; i < blocks; i++) {
        inc32(ctr);
        memcpy(in.data() + 16 * (2 + i), ctr, 16);
    }
    Bytes ks;
    if (!backend_->aes(op.key.tpmPublic, op.key.tpmPrivate, op.auth, TpmMode::ECB,
                       CipherOp::ENCRYPT, Bytes(), in, ks) ||
        ks.size() != in.size())
        return KmError::UNKNOWN_ERROR;

    Bytes body(text.size());
    for (size_t i = 0; i < text.size(); i++) body[i] = text[i] ^ ks[32 + i];
    const Bytes& ct = enc ? body : text;
    Bytes s = ghash(ks.data(), op.aad, ct);
    for (int i = 0; i < 16; i++) s[i] ^= ks[16 + i];
    std::fill(ks.begin(), ks.end(), 0);   // H and the keystream

    if (enc) {
        output = std::move(body);
        output.insert(output.end(), s.begin(), s.begin() + op.macBytes);
        return KmError::OK;
    }
    if (!ctEqual(s.data(), tag.data(), op.macBytes)) {
        std::fill(body.begin(), body.end(), 0);
        return KmError::VERIFICATION_FAILED;
    }
    output = std::move(body);
    return KmError::OK;
}

KmError Engine::getRandom(size_t n, Bytes& out) {
    std::lock_guard<std::mutex> g(lock_);
    return backend_->getRandom(n, out) ? KmError::OK : KmError::UNKNOWN_ERROR;
}

size_t Engine::operationCount() {
    std::lock_guard<std::mutex> g(lock_);
    return ops_.size();
}

} // namespace wks
