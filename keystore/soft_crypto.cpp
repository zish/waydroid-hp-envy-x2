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

// --- AES (FIPS 197), forward cipher only -------------------------------------
namespace {
constexpr uint8_t kSbox[256] = {
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
};
inline uint8_t xtime(uint8_t x) { return uint8_t((x << 1) ^ ((x & 0x80) ? 0x1b : 0)); }
} // namespace

Aes::Aes(const uint8_t* key, size_t keyLen) {
    const size_t nk = keyLen / 4;           // 4 or 8 words
    rounds_ = int(nk) + 6;                  // 10 or 14
    const size_t words = 4 * size_t(rounds_ + 1);
    memcpy(rk_, key, keyLen);
    uint8_t rcon = 1;
    for (size_t i = nk; i < words; i++) {
        uint8_t t[4];
        memcpy(t, rk_ + 4 * (i - 1), 4);
        if (i % nk == 0) {
            uint8_t first = t[0];
            t[0] = uint8_t(kSbox[t[1]] ^ rcon);
            t[1] = kSbox[t[2]];
            t[2] = kSbox[t[3]];
            t[3] = kSbox[first];
            rcon = xtime(rcon);
        } else if (nk > 6 && i % nk == 4) {
            for (auto& b : t) b = kSbox[b];
        }
        for (int j = 0; j < 4; j++) rk_[4 * i + j] = uint8_t(rk_[4 * (i - nk) + j] ^ t[j]);
    }
}

Aes::~Aes() { memset(rk_, 0, sizeof rk_); }

void Aes::encryptBlock(const uint8_t in[16], uint8_t out[16]) const {
    uint8_t s[16];   // column-major: s[4*c + r]
    for (int i = 0; i < 16; i++) s[i] = in[i] ^ rk_[i];
    for (int round = 1; round <= rounds_; round++) {
        uint8_t t[16];
        for (int c = 0; c < 4; c++)           // SubBytes and ShiftRows
            for (int r = 0; r < 4; r++) t[4 * c + r] = kSbox[s[4 * ((c + r) % 4) + r]];
        if (round != rounds_) {               // MixColumns, all but the last round
            for (int c = 0; c < 4; c++) {
                uint8_t* a = t + 4 * c;
                uint8_t all = a[0] ^ a[1] ^ a[2] ^ a[3], a0 = a[0];
                a[0] ^= all ^ xtime(uint8_t(a[0] ^ a[1]));
                a[1] ^= all ^ xtime(uint8_t(a[1] ^ a[2]));
                a[2] ^= all ^ xtime(uint8_t(a[2] ^ a[3]));
                a[3] ^= all ^ xtime(uint8_t(a[3] ^ a0));
            }
        }
        for (int i = 0; i < 16; i++) s[i] = t[i] ^ rk_[16 * round + i];
    }
    memcpy(out, s, 16);
}

// --- AES-CMAC (SP 800-38B) ---------------------------------------------------
namespace {
void cmacDouble(uint8_t b[16]) {   // multiply by x in GF(2^128), msb first
    uint8_t carry = b[0] >> 7;
    for (int i = 0; i < 15; i++) b[i] = uint8_t((b[i] << 1) | (b[i + 1] >> 7));
    b[15] = uint8_t((b[15] << 1) ^ (carry ? 0x87 : 0));
}
} // namespace

Bytes aesCmac(const Bytes& key, const Bytes& msg) {
    if (key.size() != 16 && key.size() != 32) return {};
    Aes aes(key.data(), key.size());
    uint8_t k1[16] = {0}, k2[16];
    aes.encryptBlock(k1, k1);                 // L = E_K(0^128)
    cmacDouble(k1);                           // K1
    memcpy(k2, k1, 16);
    cmacDouble(k2);                           // K2

    // The last block is whole only for a non-empty message of whole blocks;
    // anything else, the empty message included, is padded.
    const size_t rem = msg.size() % 16;
    const bool complete = !msg.empty() && rem == 0;
    const size_t tail = complete ? 16 : rem;
    const size_t lastOff = msg.size() - tail;
    uint8_t x[16] = {0}, last[16] = {0};
    for (size_t off = 0; off < lastOff; off += 16) {
        for (int j = 0; j < 16; j++) x[j] ^= msg[off + j];
        aes.encryptBlock(x, x);
    }
    if (tail) memcpy(last, msg.data() + lastOff, tail);   // an empty msg has no data()
    if (complete) {
        for (int j = 0; j < 16; j++) last[j] ^= k1[j];
    } else {
        last[tail] = 0x80;
        for (int j = 0; j < 16; j++) last[j] ^= k2[j];
    }
    for (int j = 0; j < 16; j++) x[j] ^= last[j];
    aes.encryptBlock(x, x);
    memset(k1, 0, 16);
    memset(k2, 0, 16);
    return Bytes(x, x + 16);
}

Bytes ckdf(const Bytes& key, const Bytes& label, const Bytes& context, size_t outLen) {
    const uint32_t bits = uint32_t(outLen * 8);
    Bytes out;
    for (uint32_t i = 1; out.size() < outLen; i++) {
        Bytes m;
        for (int s = 24; s >= 0; s -= 8) m.push_back(uint8_t(i >> s));
        m.insert(m.end(), label.begin(), label.end());
        m.push_back(0);
        m.insert(m.end(), context.begin(), context.end());
        for (int s = 24; s >= 0; s -= 8) m.push_back(uint8_t(bits >> s));
        Bytes block = aesCmac(key, m);
        if (block.empty()) return {};
        out.insert(out.end(), block.begin(), block.end());
    }
    out.resize(outLen);
    return out;
}

// --- HMAC-SHA256 (RFC 2104) ----------------------------------------------------
Bytes hmacSha256(const Bytes& key, const Bytes& msg) {
    uint8_t k[64] = {0};
    if (key.size() > 64) {
        Bytes h = Sha256::hash(key);
        memcpy(k, h.data(), h.size());
    } else if (!key.empty()) {
        memcpy(k, key.data(), key.size());
    }
    uint8_t pad[64];
    Sha256 inner, outer;
    for (int i = 0; i < 64; i++) pad[i] = k[i] ^ 0x36;
    inner.update(pad, 64);
    inner.update(msg);
    Bytes ih = inner.finish();
    for (int i = 0; i < 64; i++) pad[i] = k[i] ^ 0x5c;
    outer.update(pad, 64);
    outer.update(ih);
    memset(k, 0, sizeof k);
    memset(pad, 0, sizeof pad);
    return outer.finish();
}

} // namespace wks
