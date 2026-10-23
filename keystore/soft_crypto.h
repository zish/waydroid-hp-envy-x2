// soft_crypto.h -- the non-secret software half of the keystore engine.
//
// Everything keyed happens in the TPM. What is left is arithmetic a TPM 2.0
// either cannot do in the shape keymaster asks for, or would only do at the cost
// of another round trip per call:
//
//   - SHA-256, for keymaster's DIGEST=SHA_2_256 (the TPM signs a digest, not a
//     stream) and for the key blob's authDigest.
//   - GHASH and the GCM framing. A TPM 2.0 has no GCM, so GCM is built from the
//     TPM's ECB: every block cipher call runs in the TPM, and only GHASH runs
//     here. That means H = E_K(0^128), GHASH's subkey, is in host memory for the
//     length of a GCM operation. H allows forging tags for that key, not
//     decrypting with it, and anything that can read this daemon's memory can
//     already drive the TPM socket directly -- so it is no weaker than the
//     daemon itself, but it is not "never leaves the TPM" either, and docs/73
//     says so.
//   - PKCS#7 padding, and DER for the EC public key keymaster exports.
//
// Plain C++17, no OpenSSL, so the engine keeps its zero-build-dependency
// property. The selftest checks each against published vectors.
#ifndef WAYDROID_KEYSTORE_SOFT_CRYPTO_H
#define WAYDROID_KEYSTORE_SOFT_CRYPTO_H

#include "keystore.h"

namespace wks {

class Sha256 {
public:
    Sha256();
    void update(const uint8_t* p, size_t n);
    void update(const Bytes& b) { update(b.data(), b.size()); }
    Bytes finish();
    static Bytes hash(const Bytes& b);
private:
    void block(const uint8_t* p);
    uint32_t h_[8];
    uint8_t buf_[64];
    size_t bufLen_ = 0;
    uint64_t total_ = 0;
};

// GHASH_H over (A, C) exactly as GCM defines it: A and C each zero-padded to a
// block, then the 64-bit bit lengths of A and C. Returns the 16-byte S.
Bytes ghash(const uint8_t H[16], const Bytes& aad, const Bytes& ct);

// Increment the low 32 bits of a counter block, big-endian (GCM's inc32).
void inc32(uint8_t block[16]);

// PKCS#7 for a 16-byte block cipher. unpad returns false on malformed padding.
Bytes pkcs7Pad(const Bytes& in);
bool pkcs7Unpad(Bytes& inout);

// Constant-time comparison of two equal-length buffers.
bool ctEqual(const uint8_t* a, const uint8_t* b, size_t n);

// X.509 SubjectPublicKeyInfo DER for an EC P-256 key, read out of the TPM's own
// TPM2B_PUBLIC. Returns empty if the public area is not a P-256 ECC key.
Bytes spkiFromTpmPublic(const Bytes& tpm2bPublic);

} // namespace wks

#endif
