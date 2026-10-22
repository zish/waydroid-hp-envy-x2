// tools_backend.cpp -- a TpmBackend that drives tpm2-tools by exec.
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
#include <fcntl.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/stat.h>

namespace wks {
namespace {

constexpr uint32_t kPrimaryHandle = 0x81010020;  // owner-hierarchy persistent

// Run argv with TPM2TOOLS_TCTI set, capturing stdout+stderr. Returns exit code,
// -1 on spawn failure. `out` gets the combined output.
int run(const std::vector<std::string>& argv, const std::string& tcti,
        std::string* out) {
    int pipefd[2];
    if (pipe(pipefd) != 0) return -1;
    pid_t pid = fork();
    if (pid < 0) { close(pipefd[0]); close(pipefd[1]); return -1; }
    if (pid == 0) {
        dup2(pipefd[1], STDOUT_FILENO);
        dup2(pipefd[1], STDERR_FILENO);
        close(pipefd[0]); close(pipefd[1]);
        setenv("TPM2TOOLS_TCTI", tcti.c_str(), 1);
        std::vector<char*> cargv;
        for (const auto& a : argv) cargv.push_back(const_cast<char*>(a.c_str()));
        cargv.push_back(nullptr);
        execvp(cargv[0], cargv.data());
        _exit(127);
    }
    close(pipefd[1]);
    std::string buf;
    char tmp[4096];
    ssize_t n;
    while ((n = read(pipefd[0], tmp, sizeof tmp)) > 0) buf.append(tmp, n);
    close(pipefd[0]);
    int status = 0;
    waitpid(pid, &status, 0);
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

    bool createKey(const CreateSpec& spec, Bytes& tpmPublic, Bytes& tpmPrivate,
                   Bytes& pubKeyOut) override {
        std::string pub = scratch_ + "/k.pub", priv = scratch_ + "/k.priv";
        std::string gval, attrs;
        if (spec.algorithm == Algorithm::EC) {
            gval = "ecc256";  // stage 1: P-256 only
            attrs = "fixedtpm|fixedparent|sensitivedataorigin|userwithauth|sign";
        } else if (spec.algorithm == Algorithm::AES) {
            gval = (spec.keySizeBits == 256) ? "aes256cfb" : "aes128cfb";
            attrs = "fixedtpm|fixedparent|sensitivedataorigin|userwithauth|decrypt|sign";
        } else {
            fprintf(stderr, "createKey: unsupported algorithm (stage 1)\n");
            return false;
        }
        std::string o;
        int rc = run({"tpm2_create", "-C", handleStr(), "-G", gval,
                      "-u", pub, "-r", priv, "-a", attrs}, tcti_, &o);
        flushTransient();
        if (rc != 0) {
            fprintf(stderr, "createKey: tpm2_create failed: %s\n", o.c_str());
            return false;
        }
        if (!readFile(pub, tpmPublic) || !readFile(priv, tpmPrivate)) return false;
        pubKeyOut.clear();
        if (spec.algorithm == Algorithm::EC) {
            // Export the SubjectPublicKeyInfo DER for Android/verification use.
            std::string pem = scratch_ + "/k.pem";
            std::string ctx;
            if (loadChild(tpmPublic, tpmPrivate, ctx)) {
                if (run({"tpm2_readpublic", "-c", ctx, "-f", "der",
                         "-o", pem}, tcti_, &o) == 0)
                    readFile(pem, pubKeyOut);
                flushTransient();
            }
        }
        return true;
    }

    bool sign(const Bytes& tpmPublic, const Bytes& tpmPrivate, SignAlgo,
              const Bytes& digest, Bytes& sigOut) override {
        std::string ctx;
        if (!loadChild(tpmPublic, tpmPrivate, ctx)) return false;
        std::string din = scratch_ + "/d.bin", sig = scratch_ + "/sig.bin", o;
        bool ok = writeFile(din, digest);
        if (ok) {
            int rc = run({"tpm2_sign", "-c", ctx, "-g", "sha256", "-s", "ecdsa",
                          "-d", din, "-o", sig}, tcti_, &o);
            ok = (rc == 0) && readFile(sig, sigOut);
            if (rc != 0) fprintf(stderr, "sign: %s\n", o.c_str());
        }
        flushTransient();
        return ok;
    }

    bool verify(const Bytes& tpmPublic, const Bytes& tpmPrivate, SignAlgo,
                const Bytes& digest, const Bytes& sig) override {
        std::string ctx;
        if (!loadChild(tpmPublic, tpmPrivate, ctx)) return false;
        std::string din = scratch_ + "/d.bin", sfile = scratch_ + "/sig.bin";
        std::string tk = scratch_ + "/tk.bin", o;
        bool ok = writeFile(din, digest) && writeFile(sfile, sig);
        if (ok) {
            // No -g here: tpm2_verifysignature rejects --halg together with a
            // pre-hashed --digest, and the hash is carried in the signature.
            int rc = run({"tpm2_verifysignature", "-c", ctx,
                          "-d", din, "-s", sfile, "-t", tk}, tcti_, &o);
            ok = (rc == 0);
        }
        flushTransient();
        return ok;
    }

    bool cipher(const Bytes& tpmPublic, const Bytes& tpmPrivate, CipherOp op,
                Bytes& /*iv*/, const Bytes& in, Bytes& out) override {
        std::string ctx;
        if (!loadChild(tpmPublic, tpmPrivate, ctx)) return false;
        std::string inf = scratch_ + "/ct_in.bin", outf = scratch_ + "/ct_out.bin", o;
        bool ok = writeFile(inf, in);
        if (ok) {
            std::vector<std::string> argv = {"tpm2_encryptdecrypt", "-c", ctx,
                                             "-o", outf};
            if (op == CipherOp::DECRYPT) argv.push_back("-d");
            argv.push_back(inf);
            int rc = run(argv, tcti_, &o);
            ok = (rc == 0) && readFile(outf, out);
            if (rc != 0) fprintf(stderr, "cipher: %s\n", o.c_str());
        }
        flushTransient();
        return ok;
    }

    bool getRandom(size_t n, Bytes& out) override {
        std::string rf = scratch_ + "/r.bin", o;
        int rc = run({"tpm2_getrandom", std::to_string(n), "-o", rf}, tcti_, &o);
        return rc == 0 && readFile(rf, out);
    }

private:
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
