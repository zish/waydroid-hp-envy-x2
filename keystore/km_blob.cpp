// km_blob.cpp -- AuthList queries, KeyBlob (de)serialization and authDigest.
//
// The blob format is our own, little-endian, length-prefixed, versioned. It is
// NOT the HIDL hidl_vec<KeyParameter> wire format -- that marshalling belongs to
// the stage-3 binder layer, which converts HIDL KeyParameter[] to/from this
// AuthList. Keeping stage 1's at-rest format independent of the binder ABI means
// a blob minted now survives a change of interface (keymaster@4.0 -> KeyMint).
#include "keystore.h"
#include "soft_crypto.h"
#include <algorithm>
#include <cstring>

namespace wks {

std::optional<uint64_t> AuthList::first(Tag t) const {
    for (const auto& p : params)
        if (p.tag == t) return p.u;
    return std::nullopt;
}

const Bytes* AuthList::firstBytes(Tag t) const {
    for (const auto& p : params)
        if (p.tag == t) return &p.blob;
    return nullptr;
}

bool AuthList::has(Tag t) const {
    for (const auto& p : params)
        if (p.tag == t) return true;
    return false;
}

void AuthList::remove(Tag t) {
    params.erase(std::remove_if(params.begin(), params.end(),
                                [t](const KeyParam& p) { return p.tag == t; }),
                 params.end());
}

bool AuthList::hasEnumVal(Tag t, uint32_t v) const {
    for (const auto& p : params)
        if (p.tag == t && p.u == v) return true;
    return false;
}

std::vector<uint64_t> AuthList::all(Tag t) const {
    std::vector<uint64_t> out;
    for (const auto& p : params)
        if (p.tag == t) out.push_back(p.u);
    return out;
}

// --- little-endian append/read helpers --------------------------------------
namespace {
void putU32(Bytes& b, uint32_t v) {
    b.push_back(v & 0xff); b.push_back((v >> 8) & 0xff);
    b.push_back((v >> 16) & 0xff); b.push_back((v >> 24) & 0xff);
}
void putU64(Bytes& b, uint64_t v) {
    for (int i = 0; i < 8; i++) b.push_back((v >> (8 * i)) & 0xff);
}
void putBlob(Bytes& b, const Bytes& v) {
    putU32(b, static_cast<uint32_t>(v.size()));
    b.insert(b.end(), v.begin(), v.end());
}

struct Reader {
    const uint8_t* p; const uint8_t* end; bool ok = true;
    Reader(const Bytes& b) : p(b.data()), end(b.data() + b.size()) {}
    uint32_t u32() {
        if (end - p < 4) { ok = false; return 0; }
        uint32_t v = p[0] | (p[1] << 8) | (p[2] << 16) | (uint32_t(p[3]) << 24);
        p += 4; return v;
    }
    uint64_t u64() {
        if (end - p < 8) { ok = false; return 0; }
        uint64_t v = 0; for (int i = 0; i < 8; i++) v |= uint64_t(p[i]) << (8 * i);
        p += 8; return v;
    }
    Bytes blob() {
        uint32_t n = u32();
        if (!ok || end - p < static_cast<long>(n)) { ok = false; return {}; }
        Bytes v(p, p + n); p += n; return v;
    }
};
} // namespace

namespace {
void putAuthList(Bytes& b, const AuthList& a) {
    putU32(b, static_cast<uint32_t>(a.params.size()));
    for (const auto& prm : a.params) {
        putU32(b, static_cast<uint32_t>(prm.tag));
        putU64(b, prm.u);
        putBlob(b, prm.blob);
    }
}
} // namespace

Bytes authDigest(const AuthList& a) {
    static const char domain[] = "waydroid-keystore authorizations v2";
    Bytes b(domain, domain + sizeof domain);   // includes the NUL, as a separator
    putAuthList(b, a);
    return Sha256::hash(b);
}

Bytes KeyBlob::serialize() const {
    Bytes b;
    putU32(b, MAGIC);
    putU32(b, version);
    putU32(b, static_cast<uint32_t>(algorithm));
    putAuthList(b, authorizations);
    putBlob(b, tpmPublic);
    putBlob(b, tpmPrivate);
    return b;
}

std::optional<KeyBlob> KeyBlob::parse(const Bytes& in) {
    Reader r(in);
    KeyBlob kb;
    if (r.u32() != MAGIC) return std::nullopt;
    kb.version = r.u32();
    // Version 1 (stage 1) encoded PURPOSE wrongly and bound nothing to the TPM
    // object; no such blob ever reached Android, so it is refused, not migrated.
    if (kb.version != VERSION) return std::nullopt;
    kb.algorithm = static_cast<Algorithm>(r.u32());
    uint32_t n = r.u32();
    if (!r.ok || n > 4096) return std::nullopt;
    for (uint32_t i = 0; i < n; i++) {
        KeyParam prm;
        prm.tag = static_cast<Tag>(r.u32());
        prm.u = r.u64();
        prm.blob = r.blob();
        if (!r.ok) return std::nullopt;
        kb.authorizations.params.push_back(std::move(prm));
    }
    kb.tpmPublic = r.blob();
    kb.tpmPrivate = r.blob();
    if (!r.ok || r.p != r.end) return std::nullopt;
    return kb;
}

} // namespace wks
