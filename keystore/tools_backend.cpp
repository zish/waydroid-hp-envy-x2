// tools_backend.cpp -- a TpmBackend that drives tpm2-tools by exec.
//
// Each key's authValue is passed as -p hex:..., so it appears in this host's
// process list for the life of one tpm2 command. That is acceptable because it
// is not a secret -- it is a digest of the key's public tags (keystore.h) -- and
// the ESAPI backend will not do it at all.
//
// Zero build dependencies beyond a C++17 compiler: every TPM operation is one or
// more tpm2_* processes, selected by TCTI through TPM2TOOLS_TCTI. This is the
// stage-1 and development backend -- it proves the engine against swtpm today,
// and it is the fallback on a host with tpm2-tools but no way to link ESAPI. The
// production backend will link libtss2 directly behind this same seam; swapping
// it changes no engine code.
//
// Slot discipline (docs/71 finding 3): swtpm has no resource manager and
// tpm2-tools leave every object they load behind, so three transient slots run
// out on the third object. Every method here flushes all transient objects when
// it finishes, which also makes the backend self-healing: a leak from a crashed
// prior op is cleared on the next call. The primary is *persistent*, so a
// transient flush never touches it. Flushing all transient objects means the
// engine must serialize operations -- it does (one mutex, a hard op cap) -- and
// a concurrent second client would need tpm2-abrmd in front of swtpm.
#include "keystore.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <cerrno>
#include <fcntl.h>
#include <spawn.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/stat.h>

namespace wks {
namespace {

constexpr uint32_t kPrimaryHandle = 0x81010020;  // owner-hierarchy persistent

// Run argv with TPM2TOOLS_TCTI set, capturing stdout+stderr. Returns exit code,
// -1 on spawn failure. `out` gets the combined output.
//
// posix_spawnp, not fork+exec: in waydroid-keystored this runs beside
// libgbinder's threads, and a forked child that touches the allocator before
// exec -- setenv does -- can deadlock on a lock another thread held at fork.
// Everything the child needs is built here, before the spawn.
int run(const std::vector<std::string>& argv, const std::string& tcti,
        std::string* out) {
    std::string tctiEnv = "TPM2TOOLS_TCTI=" + tcti;
    std::vector<char*> envp;
    for (char** e = environ; e && *e; e++)
        if (strncmp(*e, "TPM2TOOLS_TCTI=", 15) != 0) envp.push_back(*e);
    envp.push_back(const_cast<char*>(tctiEnv.c_str()));
    envp.push_back(nullptr);
    std::vector<char*> cargv;
    for (const auto& a : argv) cargv.push_back(const_cast<char*>(a.c_str()));
    cargv.push_back(nullptr);

    int pipefd[2];
    if (pipe2(pipefd, O_CLOEXEC) != 0) return -1;
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, pipefd[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&fa, pipefd[1], STDERR_FILENO);
    pid_t pid;
    int rc = posix_spawnp(&pid, cargv[0], &fa, nullptr, cargv.data(), envp.data());
    posix_spawn_file_actions_destroy(&fa);
    close(pipefd[1]);
    if (rc != 0) { close(pipefd[0]); return -1; }

    std::string buf;
    char tmp[4096];
    ssize_t n;
    while ((n = read(pipefd[0], tmp, sizeof tmp)) > 0) buf.append(tmp, n);
    close(pipefd[0]);
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    if (out) *out = buf;
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

bool writeFile(const std::string& path, const Bytes& b) {
    int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return false;
    bool ok = true;
    size_t off = 0;
    while (off < b.size()) {
        ssize_t w = write(fd, b.data() + off, b.size() - off);
        if (w <= 0) { ok = false; break; }
        off += w;
    }
    close(fd);
    return ok;
}

bool readFile(const std::string& path, Bytes& out) {
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) return false;
    out.clear();
    char tmp[4096];
    ssize_t n;
    while ((n = read(fd, tmp, sizeof tmp)) > 0) out.insert(out.end(), tmp, tmp + n);
    close(fd);
    return true;
}

class ToolsTpmBackend : public TpmBackend {
public:
    explicit ToolsTpmBackend(std::string tcti) : tcti_(std::move(tcti)) {
        char tpl[] = "/tmp/wks-tools.XXXXXX";
        char* d = mkdtemp(tpl);
        scratch_ = d ? d : "/tmp/wks-tools";
        if (!d) mkdir(scratch_.c_str(), 0700);
    }
    ~ToolsTpmBackend() override {
        // best-effort scratch cleanup
        std::string cmd = "rm -rf '" + scratch_ + "'";
        if (system(cmd.c_str()) != 0) { /* ignore */ }
    }

    std::string describe() override { return "tpm2-tools exec, TCTI=" + tcti_; }

    bool ensurePrimary() override {
        // Occupied? readpublic on the persistent handle succeeds if so.
        std::string o;
        if (run({"tpm2_readpublic", "-c", handleStr()}, tcti_, &o) == 0)
            return true;
        // Create an ECC primary under the owner hierarchy and persist it.
        std::string pctx = scratch_ + "/primary.ctx";
        if (run({"tpm2_createprimary", "-C", "o", "-G", "ecc",
                 "-c", pctx}, tcti_, &o) != 0) {
            fprintf(stderr, "ensurePrimary: createprimary failed: %s\n", o.c_str());
            flushTransient();
            return false;
        }
        int rc = run({"tpm2_evictcontrol", "-C", "o", "-c", pctx,
                      handleStr()}, tcti_, &o);
        flushTransient();
        if (rc != 0) {
            fprintf(stderr, "ensurePrimary: evictcontrol failed: %s\n", o.c_str());
            return false;
        }
        return true;
    }

    bool createKey(const CreateSpec& spec, Bytes& tpmPublic,
                   Bytes& tpmPrivate) override {
        std::string pub = scratch_ + "/k.pub", priv = scratch_ + "/k.priv";
        std::string gval, attrs;
        // noda on every key: a failed authorization on a key without it counts
        // toward the TPM's dictionary-attack lockout, which is TPM-wide. A blob
        // with edited tags fails authorization by design (keystore.h), so without
        // noda one tampered blob replayed a few times would lock out every key on
        // the TPM -- on vidiot01, keys that are not ours.
        if (spec.algorithm == Algorithm::EC) {
            gval = "ecc256";
            attrs = "fixedtpm|fixedparent|sensitivedataorigin|userwithauth|noda|sign";
        } else if (spec.algorithm == Algorithm::AES) {
            // Mode NULL: the mode is chosen per call, so one key serves every
            // block mode keymaster can ask for. A key created as aes128cfb would
            // refuse ECB with TPM_RC_MODE.
            gval = (spec.keySizeBits == 256) ? "aes256null" : "aes128null";
            attrs = "fixedtpm|fixedparent|sensitivedataorigin|userwithauth|noda|decrypt|sign";
        } else {
            fprintf(stderr, "createKey: unsupported algorithm\n");
            return false;
        }
        std::string o;
        int rc = run({"tpm2_create", "-C", handleStr(), "-G", gval,
                      "-p", authArg(spec.auth), "-u", pub, "-r", priv,
                      "-a", attrs}, tcti_, &o);
        flushTransient();
        if (rc != 0) {
            fprintf(stderr, "createKey: tpm2_create failed: %s\n", o.c_str());
            return false;
        }
        return readFile(pub, tpmPublic) && readFile(priv, tpmPrivate);
    }

    bool importAes(const Bytes& raw, const Bytes& auth, Bytes& tpmPublic,
                   Bytes& tpmPrivate) override {
        std::string in = scratch_ + "/imp.key", pub = scratch_ + "/imp.pub";
        std::string priv = scratch_ + "/imp.priv", o;
        if (!writeFile(in, raw)) return false;
        int rc = run({"tpm2_import", "-C", handleStr(), "-G", "aes", "-i", in,
                      "-p", authArg(auth), "-a", "userwithauth|noda|decrypt|sign",
                      "-u", pub, "-r", priv}, tcti_, &o);
        unlink(in.c_str());
        flushTransient();
        if (rc != 0) {
            fprintf(stderr, "importAes: tpm2_import failed: %s\n", o.c_str());
            return false;
        }
        return readFile(pub, tpmPublic) && readFile(priv, tpmPrivate);
    }

    bool signEcdsa(const Bytes& tpmPublic, const Bytes& tpmPrivate,
                   const Bytes& auth, const Bytes& digest, Bytes& sigOut) override {
        std::string ctx;
        if (!loadChild(tpmPublic, tpmPrivate, ctx)) return false;
        std::string din = scratch_ + "/d.bin", sig = scratch_ + "/sig.bin", o;
        bool ok = writeFile(din, digest);
        if (ok) {
            // -f plain is the DER ECDSA-Sig-Value keymaster returns; the default
            // would be a marshalled TPMT_SIGNATURE.
            int rc = run({"tpm2_sign", "-c", ctx, "-p", authArg(auth),
                          "-g", "sha256", "-s", "ecdsa", "-d", din, "-f", "plain",
                          "-o", sig}, tcti_, &o);
            ok = (rc == 0) && readFile(sig, sigOut);
            if (rc != 0) fprintf(stderr, "sign: %s\n", o.c_str());
        }
        flushTransient();
        return ok;
    }

    bool aes(const Bytes& tpmPublic, const Bytes& tpmPrivate, const Bytes& auth,
             TpmMode mode, CipherOp op, const Bytes& iv, const Bytes& in,
             Bytes& out) override {
        static const char* names[] = {"ecb", "cbc", "ctr", "cfb"};
        // tpm2_encryptdecrypt reads at most 65535 bytes of input per run --
        // measured on bigtab01 when a 100 KB GCM message from an app failed with
        // "size is larger than buffer, got 100032". Within a run it already
        // splits over the TPM's 1024-byte buffer and chains the IV (checked
        // against a reference AES in all four modes, docs/73); across runs we
        // do the same, on a block boundary, with the TPM's own ivOut. The key
        // is loaded and flushed per run so the three transient slots never
        // fill (docs/71 finding 3).
        constexpr size_t kChunk = 65520;   // the largest multiple of 16 below 64 KiB
        std::string inf = scratch_ + "/ct_in.bin", outf = scratch_ + "/ct_out.bin";
        std::string ivf = scratch_ + "/iv.bin", ivoutf = scratch_ + "/iv_out.bin";
        Bytes ivCur = iv, piece;
        bool ok = true;
        out.clear();
        for (size_t off = 0; ok && off < in.size(); off += kChunk) {
            size_t n = in.size() - off < kChunk ? in.size() - off : kChunk;
            std::string ctx, o;
            if (!loadChild(tpmPublic, tpmPrivate, ctx)) { ok = false; break; }
            ok = writeFile(inf, Bytes(in.begin() + off, in.begin() + off + n));
            std::vector<std::string> argv = {"tpm2_encryptdecrypt", "-c", ctx,
                                             "-p", authArg(auth),
                                             "-G", names[static_cast<int>(mode)],
                                             "-o", outf};
            if (mode != TpmMode::ECB) {
                ok = ok && writeFile(ivf, ivCur);
                argv.push_back("-t");
                argv.push_back(ivf + ":" + ivoutf);
            }
            if (op == CipherOp::DECRYPT) argv.push_back("-d");
            argv.push_back(inf);
            if (ok) {
                int rc = run(argv, tcti_, &o);
                ok = (rc == 0) && readFile(outf, piece) && piece.size() == n;
                if (rc != 0) fprintf(stderr, "aes: %s\n", o.c_str());
                if (ok) out.insert(out.end(), piece.begin(), piece.end());
                if (ok && mode != TpmMode::ECB)
                    ok = readFile(ivoutf, ivCur) && ivCur.size() == 16;
            }
            flushTransient();
        }
        unlink(inf.c_str());
        unlink(outf.c_str());
        return ok;
    }

    bool getRandom(size_t n, Bytes& out) override {
        std::string rf = scratch_ + "/r.bin", o;
        int rc = run({"tpm2_getrandom", std::to_string(n), "-o", rf}, tcti_, &o);
        return rc == 0 && readFile(rf, out);
    }

private:
    static std::string authArg(const Bytes& auth) {
        static const char hex[] = "0123456789abcdef";
        std::string a = "hex:";
        for (uint8_t b : auth) { a += hex[b >> 4]; a += hex[b & 15]; }
        return a;
    }
    std::string handleStr() const {
        char b[16]; snprintf(b, sizeof b, "0x%08x", kPrimaryHandle);
        return b;
    }
    // Load a child under the persistent primary, returning its context path.
    bool loadChild(const Bytes& pub, const Bytes& priv, std::string& ctxOut) {
        std::string pf = scratch_ + "/l.pub", rf = scratch_ + "/l.priv";
        ctxOut = scratch_ + "/l.ctx";
        std::string o;
        if (!writeFile(pf, pub) || !writeFile(rf, priv)) return false;
        int rc = run({"tpm2_load", "-C", handleStr(), "-u", pf, "-r", rf,
                      "-c", ctxOut}, tcti_, &o);
        if (rc != 0) { fprintf(stderr, "loadChild: %s\n", o.c_str()); return false; }
        return true;
    }
    void flushTransient() {
        std::string o;
        run({"tpm2_flushcontext", "-t"}, tcti_, &o);
    }

    std::string tcti_;
    std::string scratch_;
};

} // namespace

TpmBackend* makeToolsBackend(const std::string& tcti) {
    return new ToolsTpmBackend(tcti);
}

} // namespace wks
