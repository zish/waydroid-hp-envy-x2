/*
 * Known-answer tests for the keystore's shared-secret arithmetic (docs/74):
 * AES, AES-CMAC, keymaster's CKDF, HMAC-SHA256, and the MACs over keymaster's
 * HardwareAuthToken and VerificationToken. No TPM, no binder.
 *
 * sources: keystore/soft_crypto.cpp keystore/auth.cpp
 * includes: keystore
 *
 * Every expected value comes from somewhere other than this code, because an
 * engine that agrees only with itself is how stage 1 shipped two wrong
 * constants (docs/73): FIPS 197 C.1/C.3, RFC 4493 and SP 800-38B for CMAC,
 * RFC 4231 for HMAC, and OpenSSL 3.5 for the rest -- `openssl kdf ... KBKDF`
 * in counter mode with CMAC is SP 800-108 with exactly the i || label || 0x00
 * || context || L framing keymaster's ckdf() uses, and `openssl mac HMAC` over
 * token bytes packed by Python's struct module. The commands are in docs/74.
 */
#include "auth.h"
#include "soft_crypto.h"

#include <cstdio>
#include <cstring>

using namespace wks;

static int failures;
static int checks;

static Bytes hex(const char* s) {
    Bytes b;
    for (size_t i = 0; s[i] && s[i + 1]; i += 2) {
        unsigned v;
        std::sscanf(s + i, "%2x", &v);
        b.push_back(uint8_t(v));
    }
    return b;
}
static Bytes text(const char* s) { return Bytes(s, s + std::strlen(s)); }

static void check(bool ok, const char* what) {
    ++checks;
    if (!ok) {
        ++failures;
        std::fprintf(stderr, "FAIL: %s\n", what);
    }
}

int main() {
    // FIPS 197, appendix C.1 and C.3.
    {
        Bytes pt = hex("00112233445566778899aabbccddeeff"), ct(16);
        Aes a128(hex("000102030405060708090a0b0c0d0e0f").data(), 16);
        a128.encryptBlock(pt.data(), ct.data());
        check(ct == hex("69c4e0d86a7b0430d8cdb78070b4c55a"), "AES-128 FIPS 197 C.1");
        Aes a256(hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f").data(), 32);
        a256.encryptBlock(pt.data(), ct.data());
        check(ct == hex("8ea2b7ca516745bfeafc49904b496089"), "AES-256 FIPS 197 C.3");
    }

    // RFC 4493 (AES-128) and SP 800-38B appendix D (AES-256), all four lengths:
    // empty, one whole block, a partial last block, and whole blocks only.
    {
        Bytes m = hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51"
                      "30c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710");
        Bytes k128 = hex("2b7e151628aed2a6abf7158809cf4f3c");
        Bytes k256 = hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4");
        const size_t lens[4] = {0, 16, 40, 64};
        const char* want128[4] = {"bb1d6929e95937287fa37d129b756746",
                                  "070a16b46b4d4144f79bdd9dd04a287c",
                                  "dfa66747de9ae63030ca32611497c827",
                                  "51f0bebf7e3b9d92fc49741779363cfe"};
        const char* want256[4] = {"028962f61b7bf89efc6b551f4667d983",
                                  "28a7023f452e8f82bd4bf28d8c37c35c",
                                  "aaf3d8f1de5640c232f5b169b9c911e6",
                                  "e1992190549f6ed5696a2c056c315410"};
        for (int i = 0; i < 4; i++) {
            Bytes mi(m.begin(), m.begin() + lens[i]);
            check(aesCmac(k128, mi) == hex(want128[i]), "AES-128-CMAC, RFC 4493");
            check(aesCmac(k256, mi) == hex(want256[i]), "AES-256-CMAC, SP 800-38B");
        }
        check(aesCmac(Bytes(24, 0), m).empty(), "CMAC refuses a 24-byte key");
    }

    // RFC 4231 test cases 1, 2 and 6 (a key longer than the block).
    check(hmacSha256(Bytes(20, 0x0b), text("Hi There")) ==
              hex("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"),
          "HMAC-SHA256 RFC 4231 #1");
    check(hmacSha256(text("Jefe"), text("what do ya want for nothing?")) ==
              hex("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"),
          "HMAC-SHA256 RFC 4231 #2");
    check(hmacSha256(Bytes(131, 0xaa),
                     text("Test Using Larger Than Block-Size Key - Hash Key First")) ==
              hex("60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"),
          "HMAC-SHA256 RFC 4231 #6");

    // The negotiation, against OpenSSL's KBKDF: two participants as keystore2
    // sorts them -- the TEE's empty seed first, then a StrongBox's 32-byte one.
    HmacSharingParams tee{Bytes(), hex("000102030405060708090a0b0c0d0e0f"
                                       "101112131415161718191a1b1c1d1e1f")};
    HmacSharingParams sb{Bytes(32, 0xa5), hex("202122232425262728292a2b2c2d2e2f"
                                              "303132333435363738393a3b3c3d3e3f")};
    Bytes h = deriveSharedHmacKey(imageKeyAgreementKey(), {tee, sb});
    check(h == hex("7e362aeba13366b3c935fa700509f55a0c962279fc4b1d26a17304cfc4c74492"),
          "H = CKDF(0^256, KeymasterSharedMac, seed||nonce...) = OpenSSL KBKDF");
    check(sharingCheck(h) ==
              hex("aa7de46396235e0e78cd8fad10cd77ec915f77e401bda1048bcf2e8c41ad26b4"),
          "sharingCheck = HMAC(H, Keymaster HMAC Verification)");
    Bytes ctx;
    for (const auto* p : {&tee, &sb}) {
        ctx.insert(ctx.end(), p->seed.begin(), p->seed.end());
        ctx.insert(ctx.end(), p->nonce.begin(), p->nonce.end());
    }
    check(ckdf(imageKeyAgreementKey(), text("KeymasterSharedMac"), ctx, 40) ==
              hex("0a2787d00bcc0f4380871915d7c49c58431f1e2dd3b0937bfa989a8bb1927d0b"
                  "73276c7eed45f0e9"),
          "CKDF puts L in every block: a 40-byte output is not a 32-byte one extended");
    check(deriveSharedHmacKey(imageKeyAgreementKey(), {sb, tee}) != h,
          "the order of the participants matters");

    // Token MACs. The byte layouts were packed with Python's struct module.
    HardwareAuthToken hat;
    hat.challenge = 0x1122334455667788ull;
    hat.userId = 0x0102030405060708ull;
    hat.authenticatorId = 0xa1a2a3a4a5a6a7a8ull;
    hat.authenticatorType = uint32_t(HwAuthType::PASSWORD);
    hat.timestamp = 123456789;
    check(authTokenMac(h, hat) ==
              hex("03c8c5ad2c3cc28009f08a249143b114c13b38c5c3cc8048b0fbf1e8870688cb"),
          "HardwareAuthToken MAC: hw_auth_token_t layout, mixed byte order");

    VerificationToken vt;
    vt.challenge = 0x1122334455667788ull;
    vt.timestamp = 987654321;
    vt.securityLevel = 1;   // what km_compat stamps on every forwarded token
    check(verificationTokenMac(h, vt, VtForm::SPEC) ==
              hex("4a2d4b78718472ad7a0676d4933e60e8ab0c3b995dbdc3c84f4fc533113a4426"),
          "VerificationToken MAC, HAL form: big-endian, the token's own level");
    check(verificationTokenMac(h, vt, VtForm::AOSP_SOFTWARE) ==
              hex("f83337413b24aa254692b32cb794ae9717911298680b79ed47ce3a685c638789"),
          "VerificationToken MAC, AOSP software form: machine order, level SOFTWARE");

    std::printf("test_keystore_auth: %d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
