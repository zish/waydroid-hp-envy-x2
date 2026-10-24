# waydroid-ext-swtpm -- docs/65-tpm-keystore.md, docs/71-swtpm-host.md
#
# A software TPM 2.0 on a unix socket, run by systemd, for a host without a
# usable hardware TPM -- bigtab01, whose TPM 1.2 is hidden in firmware. It is
# docs/65's stage 0: the backend a TPM-backed keystore HAL will talk to, through
# the same TCTI interface it would use for /dev/tpmrm0 on a machine that has one.
#
# WHAT THIS IS NOT. Nothing inside Android speaks TPM 2.0, so installing this
# changes nothing Android can see. Its client is a host-side keystore backend
# that does not exist yet. Nor does it buy any security property over the
# software keymaster already in the image: the TPM's state is a file on the same
# disk, protected by file permissions. Its value is as the development and
# regression rig for a TPM-backed HAL, and as a fallback backend on hosts with no
# TPM at all.

VERSION=1.0.0
RELEASE=1
KIND=host

# Two POSIX shell scripts and a unit. swtpm itself is Fedora's and is a
# dependency, not payload -- docs/54.
ARCH=noarch

# Host-side only and speaks no Android interface, so no image can invalidate it.
# A claim about content, per gen-spec.sh, not about having been booted against
# every image.
ANDROID="any"

SUMMARY="A software TPM 2.0 for Waydroid's keystore backend, as a systemd service"

LICENSE="GPL-3.0-or-later"

# systemd-rpm-macros for %{_unitdir}. swtpm and tpm2-tools because %check runs
# the selftest's live half -- swtpm through the wrapper, waydroid-tpm-check
# against it, a restart on the same state -- and requires it to run rather than
# skip. tpm2-tools pulls in tpm2-tss, which is what ships tcti-swtpm. The rest
# is what the check and the selftest run, named because CI's Fedora container
# starts from a minimal image and gets only what is listed here.
BUILDREQUIRES="systemd-rpm-macros
swtpm
tpm2-tools
coreutils
gawk
grep
sed"

# swtpm is the whole point. On a targeted-policy host it drags in swtpm-selinux
# by its own rich dependency, and that is what makes the unit's bin_t wrapper
# necessary rather than decorative -- see artifacts/swtpm/waydroid-swtpm.
#
# user(tss)/group(tss) rather than a package name: the unit runs as tss, and
# rpm generates these provides from whichever package's sysusers.d creates the
# account (tpm2-tss on Fedora 44). Naming the account says what is needed.
#
# Everything else is what waydroid-tpm-check runs besides tpm2-tools: coreutils
# (mktemp, sha256sum, date, tr -- the wrapper's tr too), gawk for the getcap
# parser, grep and sed. And systemd for StateDirectory=/RuntimeDirectory=
# (240) and LogFilterPatterns= (253) -- an older systemd ignores the latter with a
# warning and the journal gets one line per TPM command, so it is not a floor.
REQUIRES="swtpm
systemd
user(tss)
group(tss)
coreutils
gawk
grep
sed"

# waydroid-tpm-check is the only thing here that runs tpm2-tools, and the service
# works without it -- docs/47's test, the package without the dependency is not
# worse than stock. The keystore backend will link libtss2 directly.
RECOMMENDS="tpm2-tools"

DOCS="docs/65-tpm-keystore.md
docs/71-swtpm-host.md"

DESCRIPTION="Runs swtpm as a TPM 2.0 on a unix socket at /run/swtpm-waydroid/sock, as the
systemd service waydroid-swtpm, with its state in /var/lib/swtpm-waydroid.
It is the TPM a host-side keystore backend for Waydroid talks to when the
host has no usable hardware TPM, through the same tpm2-tss interface it
would use for /dev/tpmrm0 on a machine that has one.

Installing it changes nothing inside Android: no Android interface speaks
TPM, and the keystore backend that will use this is not written yet. Nor is
it a security improvement on the software keymaster Android already uses --
the TPM's seeds are a file on the same disk. It is the development and
regression rig for that backend, and its fallback on hosts with no TPM.

Also ships waydroid-tpm-check, which proves a TPM 2.0 does the operations
the backend needs -- random, a primary under the owner hierarchy, ECDSA sign
and verify, seal and unseal -- through any TCTI: the default is this
service's socket, and --tcti device:/dev/tpmrm0 runs the same sequence
against hardware. It uses transient objects only, never writes NV, never
clears, and flushes what it loads, which matters: swtpm has no resource
manager and tpm2-tools leave every object they load behind, so without the
flush three transient slots run out on the third object. --save and
--verify-saved prove the state survives a restart.

swtpm runs as unconfined_service_t, entered through a wrapper in
/usr/libexec, because Fedora's swtpm-selinux confines swtpm only for libvirt
to launch and closes every route by which systemd could start it directly.
No policy module is installed. The state and socket directories are named
swtpm-waydroid rather than waydroid-swtpm so that Fedora's waydroid policy,
which claims those prefixes, does not label the TPM's seeds as Waydroid
data.

Removing the package leaves /var/lib/swtpm-waydroid in place: it holds the
seed every key sealed under this TPM depends on."

SOURCES="artifacts/swtpm/install.sh
artifacts/swtpm/selftest.sh
artifacts/swtpm/waydroid-swtpm
artifacts/swtpm/waydroid-swtpm.service
artifacts/swtpm/waydroid-tpm-check"

# LIBEXECDIR is passed even though %{_libexecdir} is the installer's own default
# under PREFIX=/usr, because @LIBEXECDIR@ is substituted into the unit and has to
# be the directory %files claims -- the docs/25 lesson mdns.mod records.
INSTALL='DESTDIR=%{buildroot} PREFIX=%{_prefix} LIBEXECDIR=%{_libexecdir} \
    UNITDIR=%{_unitdir} sh artifacts/swtpm/install.sh'

# require, so a build host missing the tools fails here instead of skipping --
# BuildRequires guarantees them, and a skip in %check would be a test quietly
# not running.
CHECK='%check
WAYDROID_SWTPM_SELFTEST_LIVE=require sh artifacts/swtpm/selftest.sh'

# The state directory is deliberately not in %files. systemd creates it, owned by
# tss, on first start, and rpm must never remove it: erasing the TPM's seed
# orphans every blob sealed under it, which is a decision for the administrator
# rather than for an uninstall.
#
# The .wants directory is ours to declare, the same situation mdns.mod records.
PAYLOAD_FILES='%{_libexecdir}/waydroid-swtpm
%{_bindir}/waydroid-tpm-check
%{_unitdir}/waydroid-swtpm.service
%dir %{_unitdir}/multi-user.target.wants
%{_unitdir}/multi-user.target.wants/waydroid-swtpm.service'

# Says what is left behind and why, and does nothing else. $1 -eq 0 because
# %preun also runs on upgrade. Inert on an rpm-ostree host like every scriptlet,
# where it simply does not print.
SCRIPTLETS='%preun
if [ $1 -eq 0 ] && [ -d /var/lib/swtpm-waydroid ]; then
    echo "swtpm: /var/lib/swtpm-waydroid is kept. It holds the seed every key sealed" >&2
    echo "  under this TPM depends on; delete it yourself to discard them all." >&2
fi'
