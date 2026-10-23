// soft_crypto.cpp -- see soft_crypto.h.
#include "soft_crypto.h"

#include <cstring>

namespace wks {

// --- SHA-256 (FIPS 180-4) ---------------------------------------------------
namespace {
constexpr uint32_t K256[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};
inline uint32_t rotr(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }
} // namespace

Sha256::Sha256() {
    static const uint32_t init[8] = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    };
    memcpy(h_, init, sizeof h_);
}

void Sha256::block(const uint8_t* p) {
    uint32_t w[64];
    for (int i = 0; i < 16; i++)
        w[i] = (uint32_t(p[4*i]) << 24) | (uint32_t(p[4*i+1]) << 16) |
               (uint32_t(p[4*i+2]) << 8) | p[4*i+3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = rotr(w[i-15], 7) ^ rotr(w[i-15], 18) ^ (w[i-15] >> 3);
        uint32_t s1 = rotr(w[i-2], 17) ^ rotr(w[i-2], 19) ^ (w[i-2] >> 10);
        w[i] = w[i-16] + s0 + w[i-7] + s1;
    }
    uint32_t a = h_[0], b = h_[1], c = h_[2], d = h_[3];
    uint32_t e = h_[4], f = h_[5], g = h_[6], h = h_[7];
    for (int i = 0; i < 64; i++) {
        uint32_t S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        uint32_t ch = (e & f) ^ (~e & g);
        uint32_t t1 = h + S1 + ch + K256[i] + w[i];
        uint32_t S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        uint32_t mj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t t2 = S0 + mj;
        h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    h_[0] += a; h_[1] += b; h_[2] += c; h_[3] += d;
    h_[4] += e; h_[5] += f; h_[6] += g; h_[7] += h;
}

void Sha256::update(const uint8_t* p, size_t n) {
    total_ += n;
    while (n > 0) {
        size_t take = 64 - bufLen_;
        if (take > n) take = n;
        memcpy(buf_ + bufLen_, p, take);
        bufLen_ += take; p += take; n -= take;
        if (bufLen_ == 64) { block(buf_); bufLen_ = 0; }
    }
}

Bytes Sha256::finish() {
    uint64_t bits = total_ * 8;
    uint8_t pad = 0x80;
    update(&pad, 1);
    uint8_t zero = 0;
    while (bufLen_ != 56) update(&zero, 1);
    uint8_t len[8];
    for (int i = 0; i < 8; i++) len[i] = uint8_t(bits >> (56 - 8 * i));
    update(len, 8);
    Bytes out(32);
    for (int i = 0; i < 8; i++) {
        out[4*i]   = uint8_t(h_[i] >> 24); out[4*i+1] = uint8_t(h_[i] >> 16);
        out[4*i+2] = uint8_t(h_[i] >> 8);  out[4*i+3] = uint8_t(h_[i]);
    }
    return out;
}

Bytes Sha256::hash(const Bytes& b) {
    Sha256 s;
    s.update(b);
    return s.finish();
}

// --- GHASH (NIST SP 800-38D) ------------------------------------------------
namespace {
// X <- X * Y in GF(2^128) with GCM's bit order (algorithm 1 of SP 800-38D).
void gfmul(uint8_t X[16], const uint8_t Y[16]) {
    uint8_t Z[16] = {0}, V[16];
    memcpy(V, Y, 16);
    for (int i = 0; i < 128; i++) {
        if (X[i / 8] & (0x80 >> (i % 8)))
            for (int j = 0; j < 16; j++) Z[j] ^= V[j];
        bool lsb = V[15] & 1;
        for (int j = 15; j > 0; j--) V[j] = uint8_t((V[j] >> 1) | (V[j-1] << 7));
        V[0] >>= 1;
        if (lsb) V[0] ^= 0xe1;
    }
    memcpy(X, Z, 16);
}

void ghashBlocks(uint8_t Y[16], const uint8_t H[16], const Bytes& data) {
    for (size_t off = 0; off < data.size(); off += 16) {
        uint8_t blk[16] = {0};
        size_t n = data.size() - off < 16 ? data.size() - off : 16;
        memcpy(blk, data.data() + off, n);
        for (int j = 0; j < 16; j++) Y[j] ^= blk[j];
        gfmul(Y, H);
    }
}
} // namespace

Bytes ghash(const uint8_t H[16], const Bytes& aad, const Bytes& ct) {
    uint8_t Y[16] = {0};
    ghashBlocks(Y, H, aad);
    ghashBlocks(Y, H, ct);
    uint8_t lens[16];
    uint64_t abits = uint64_t(aad.size()) * 8, cbits = uint64_t(ct.size()) * 8;
    for (int i = 0; i < 8; i++) {
        lens[i]     = uint8_t(abits >> (56 - 8 * i));
        lens[8 + i] = uint8_t(cbits >> (56 - 8 * i));
    }
    for (int j = 0; j < 16; j++) Y[j] ^= lens[j];
    gfmul(Y, H);
    return Bytes(Y, Y + 16);
}

void inc32(uint8_t block[16]) {
    for (int i = 15; i >= 12; i--)
        if (++block[i] != 0) break;
}

// --- PKCS#7 -------------------------------------------------------------------
Bytes pkcs7Pad(const Bytes& in) {
    Bytes out = in;
    uint8_t n = uint8_t(16 - (in.size() % 16));
    out.insert(out.end(), n, n);
    return out;
}

bool pkcs7Unpad(Bytes& inout) {
    if (inout.empty() || inout.size() % 16) return false;
    uint8_t n = inout.back();
    if (n == 0 || n > 16) return false;
    uint8_t bad = 0;
    for (size_t i = inout.size() - n; i < inout.size(); i++) bad |= inout[i] ^ n;
    if (bad) return false;
    inout.resize(inout.size() - n);
    return true;
}

bool ctEqual(const uint8_t* a, const uint8_t* b, size_t n) {
    uint8_t d = 0;
    for (size_t i = 0; i < n; i++) d |= a[i] ^ b[i];
    return d == 0;
}

// --- SubjectPublicKeyInfo from a TPM2B_PUBLIC ----------------------------------
namespace {
struct BeReader {
    const uint8_t* p; const uint8_t* end; bool ok = true;
    uint16_t u16() {
        if (end - p < 2) { ok = false; return 0; }
        uint16_t v = uint16_t((p[0] << 8) | p[1]); p += 2; return v;
    }
    uint32_t u32() { uint32_t hi = u16(); return (hi << 16) | u16(); }
    Bytes tpm2b() {
        uint16_t n = u16();
        if (!ok || end - p < n) { ok = false; return {}; }
        Bytes v(p, p + n); p += n; return v;
    }
};
constexpr uint16_t TPM2_ALG_ECC = 0x0023, TPM2_ALG_NULL = 0x0010;
constexpr uint16_t TPM2_ECC_NIST_P256 = 0x0003;
} // namespace

Bytes spkiFromTpmPublic(const Bytes& in) {
    BeReader r{in.data(), in.data() + in.size()};
    r.u16();                                    // TPM2B size
    if (r.u16() != TPM2_ALG_ECC) return {};     // type
    r.u16();                                    // nameAlg
    r.u32();                                    // objectAttributes
    r.tpm2b();                                  // authPolicy
    // TPMS_ECC_PARMS: symmetric, scheme, curveID, kdf.
    if (r.u16() != TPM2_ALG_NULL) { r.u16(); r.u16(); }
    if (r.u16() != TPM2_ALG_NULL) r.u16();
    if (r.u16() != TPM2_ECC_NIST_P256) return {};
    if (r.u16() != TPM2_ALG_NULL) r.u16();
    Bytes x = r.tpm2b(), y = r.tpm2b();
    if (!r.ok || x.size() > 32 || y.size() > 32) return {};

    // SEQUENCE { SEQUENCE { id-ecPublicKey, prime256v1 }, BIT STRING 04||X||Y }
    static const uint8_t prefix[] = {
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02,
        0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
        0x42, 0x00, 0x04,
    };
    Bytes out(prefix, prefix + sizeof prefix);
    out.insert(out.end(), 32 - x.size(), 0);
    out.insert(out.end(), x.begin(), x.end());
    out.insert(out.end(), 32 - y.size(), 0);
    out.insert(out.end(), y.begin(), y.end());
    return out;
}

} // namespace wks
