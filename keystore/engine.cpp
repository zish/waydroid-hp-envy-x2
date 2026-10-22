// engine.cpp -- see engine.h.
#include "engine.h"

namespace wks {

const char* kmErrorName(KmError e) {
    switch (e) {
        case KmError::OK: return "OK";
        case KmError::UNSUPPORTED_PURPOSE: return "UNSUPPORTED_PURPOSE";
        case KmError::INCOMPATIBLE_PURPOSE: return "INCOMPATIBLE_PURPOSE";
        case KmError::UNSUPPORTED_ALGORITHM: return "UNSUPPORTED_ALGORITHM";
        case KmError::INCOMPATIBLE_ALGORITHM: return "INCOMPATIBLE_ALGORITHM";
        case KmError::UNSUPPORTED_KEY_SIZE: return "UNSUPPORTED_KEY_SIZE";
        case KmError::UNSUPPORTED_DIGEST: return "UNSUPPORTED_DIGEST";
        case KmError::INVALID_KEY_BLOB: return "INVALID_KEY_BLOB";
        case KmError::UNSUPPORTED_KEY_FORMAT: return "UNSUPPORTED_KEY_FORMAT";
        case KmError::INVALID_ARGUMENT: return "INVALID_ARGUMENT";
        case KmError::UNIMPLEMENTED: return "UNIMPLEMENTED";
        case KmError::ROOT_OF_TRUST_ALREADY_SET: return "ROOT_OF_TRUST_ALREADY_SET";
        default: return "UNKNOWN_ERROR";
    }
}

Engine::Engine(std::unique_ptr<TpmBackend> backend) : backend_(std::move(backend)) {}

KmError Engine::init() {
    std::lock_guard<std::mutex> g(lock_);
    return backend_->ensurePrimary() ? KmError::OK : KmError::UNKNOWN_ERROR;
}

KmError Engine::generateKey(const AuthList& request, KeyBlob& out) {
    std::lock_guard<std::mutex> g(lock_);

    auto alg = request.first(Tag::ALGORITHM);
    if (!alg) return KmError::UNSUPPORTED_ALGORITHM;

    CreateSpec spec;
    spec.algorithm = static_cast<Algorithm>(*alg);

    if (spec.algorithm == Algorithm::EC) {
        // Stage 1: P-256 only. Accept either EC_CURVE=P_256 or KEY_SIZE=256.
        auto curve = request.first(Tag::EC_CURVE);
        auto ksize = request.first(Tag::KEY_SIZE);
        if (curve && static_cast<EcCurve>(*curve) != EcCurve::P_256)
            return KmError::UNSUPPORTED_KEY_SIZE;
        if (!curve && ksize && *ksize != 256)
            return KmError::UNSUPPORTED_KEY_SIZE;
        if (!request.hasEnumVal(Tag::PURPOSE, static_cast<uint32_t>(Purpose::SIGN)))
            return KmError::UNSUPPORTED_PURPOSE;
        spec.keySizeBits = 256;
        spec.curve = EcCurve::P_256;
        spec.forSign = true;
    } else if (spec.algorithm == Algorithm::AES) {
        auto ksize = request.first(Tag::KEY_SIZE);
        if (!ksize) return KmError::UNSUPPORTED_KEY_SIZE;
        if (*ksize != 128 && *ksize != 256) return KmError::UNSUPPORTED_KEY_SIZE;
        bool enc = request.hasEnumVal(Tag::PURPOSE, (uint32_t)Purpose::ENCRYPT);
        bool dec = request.hasEnumVal(Tag::PURPOSE, (uint32_t)Purpose::DECRYPT);
        if (!enc && !dec) return KmError::UNSUPPORTED_PURPOSE;
        spec.keySizeBits = static_cast<uint32_t>(*ksize);
        spec.forCipher = true;
    } else {
        return KmError::UNSUPPORTED_ALGORITHM;  // RSA/HMAC are later stages
    }

    Bytes pub, priv, pubKey;
    if (!backend_->createKey(spec, pub, priv, pubKey))
        return KmError::UNKNOWN_ERROR;

    out = KeyBlob{};
    out.algorithm = spec.algorithm;
    out.authorizations = request;
    // Record provenance the caller cannot assert for itself.
    out.authorizations.addEnum(Tag::ORIGIN, static_cast<uint32_t>(Origin::GENERATED));
    out.tpmPublic = std::move(pub);
    out.tpmPrivate = std::move(priv);
    return KmError::OK;
}

KmError Engine::getKeyCharacteristics(const Bytes& blob, AuthList& out) {
    auto kb = KeyBlob::parse(blob);
    if (!kb) return KmError::INVALID_KEY_BLOB;
    out = kb->authorizations;
    return KmError::OK;
}

// Parse the blob and enforce that it may be used for `purpose` with `expectAlg`.
KmError Engine::loadAndCheck(const Bytes& blob, KeyBlob& kb, Algorithm expectAlg,
                             Purpose purpose) {
    auto parsed = KeyBlob::parse(blob);
    if (!parsed) return KmError::INVALID_KEY_BLOB;
    kb = std::move(*parsed);
    if (kb.algorithm != expectAlg) return KmError::INCOMPATIBLE_ALGORITHM;
    if (!kb.authorizations.hasEnumVal(Tag::PURPOSE,
                                      static_cast<uint32_t>(purpose)))
        return KmError::INCOMPATIBLE_PURPOSE;
    return KmError::OK;
}

KmError Engine::sign(const Bytes& blob, const Bytes& digest, Bytes& sigOut) {
    std::lock_guard<std::mutex> g(lock_);
    KeyBlob kb;
    KmError e = loadAndCheck(blob, kb, Algorithm::EC, Purpose::SIGN);
    if (e != KmError::OK) return e;
    // Stage 1 signs a SHA-256 digest; if a DIGEST tag is present it must agree.
    if (kb.authorizations.has(Tag::DIGEST) &&
        !kb.authorizations.hasEnumVal(Tag::DIGEST,
                                      static_cast<uint32_t>(Digest::SHA_2_256)))
        return KmError::UNSUPPORTED_DIGEST;
    if (digest.size() != 32) return KmError::INVALID_ARGUMENT;
    return backend_->sign(kb.tpmPublic, kb.tpmPrivate, SignAlgo::ECDSA_SHA256,
                          digest, sigOut)
               ? KmError::OK : KmError::UNKNOWN_ERROR;
}

KmError Engine::verify(const Bytes& blob, const Bytes& digest, const Bytes& sig) {
    std::lock_guard<std::mutex> g(lock_);
    KeyBlob kb;
    KmError e = loadAndCheck(blob, kb, Algorithm::EC, Purpose::VERIFY);
    // A sign-only key verifying is a purpose mismatch; the selftest makes keys
    // with both PURPOSE SIGN and VERIFY so this path is exercisable.
    if (e != KmError::OK) return e;
    return backend_->verify(kb.tpmPublic, kb.tpmPrivate, SignAlgo::ECDSA_SHA256,
                            digest, sig)
               ? KmError::OK : KmError::UNKNOWN_ERROR;
}

KmError Engine::encrypt(const Bytes& blob, Bytes& iv, const Bytes& in, Bytes& out) {
    std::lock_guard<std::mutex> g(lock_);
    KeyBlob kb;
    KmError e = loadAndCheck(blob, kb, Algorithm::AES, Purpose::ENCRYPT);
    if (e != KmError::OK) return e;
    return backend_->cipher(kb.tpmPublic, kb.tpmPrivate, CipherOp::ENCRYPT,
                            iv, in, out) ? KmError::OK : KmError::UNKNOWN_ERROR;
}

KmError Engine::decrypt(const Bytes& blob, Bytes& iv, const Bytes& in, Bytes& out) {
    std::lock_guard<std::mutex> g(lock_);
    KeyBlob kb;
    KmError e = loadAndCheck(blob, kb, Algorithm::AES, Purpose::DECRYPT);
    if (e != KmError::OK) return e;
    return backend_->cipher(kb.tpmPublic, kb.tpmPrivate, CipherOp::DECRYPT,
                            iv, in, out) ? KmError::OK : KmError::UNKNOWN_ERROR;
}

KmError Engine::getRandom(size_t n, Bytes& out) {
    std::lock_guard<std::mutex> g(lock_);
    return backend_->getRandom(n, out) ? KmError::OK : KmError::UNKNOWN_ERROR;
}

} // namespace wks
