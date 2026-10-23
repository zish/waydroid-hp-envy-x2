# waydroid-ext-keystored -- docs/65, docs/73, docs/74, docs/75
#
# A StrongBox keymaster for Android, served from the host and backed by a TPM.
# Registers android.hardware.keymaster@4.0::IKeymasterDevice/strongbox on the
# container's hwbinder through libgbinder; every key it makes is a TPM object,
# wrapped under a persistent primary, and Android holds only the wrapped blob.
# The TPM is waydroid-swtpm's by default and /dev/tpmrm0 by configuration.
#
# WHAT IT GIVES ANDROID, AND WHAT IT DOES NOT
#
# EC P-256 signing and AES keys (ECB, CBC, CTR, GCM), at security level
# STRONGBOX, including keys bound to the lockscreen -- verified from an ordinary
# app on 2026-10-23 with the owner's real unlock (docs/74). Not attestation:
# that needs a chain rooted in a Google-signed key and a TPM can only self-sign,
# so it is a non-goal and always will be (docs/65). Not RSA, HMAC or 3DES keys
# yet. On swtpm, not secrecy from the host either -- the TPM's seed is a file on
# the host's disk; what it does give is keys Android itself cannot read out,
# Android root included, because the TPM is outside the container.
#
# THE LAUNCH MODEL
#
# A unit from boot, the waydroid-wifid shape: the daemon waits for a session
# without touching binder (id.waydro.Container's GetSession), registers the
# moment the session's hwservicemanager appears, and exits when the session
# ends, so systemd starts a fresh one -- a new seed and nonce -- for the next.
# The GetSession gate is not optional: before it, the daemon wrote 7,551 binder
# failure pairs to the kernel log in two hours at the greeter (docs/75).
#
# The daemon alone declares nothing; keystore2 engages only a strongbox the
# VINTF manifest declares. That is waydroid-ext-strongbox, recommended here and
# hard-requiring this package in the other direction, the wifid/wifi-hostd
# pair's shape.

VERSION=1.0.0
RELEASE=1
KIND=host
ARCH=x86_64

# keymaster@4.0 HIDL is Android 13's interface on this image; Android 16 has
# AIDL KeyMint (IKeyMintDevice, ISecureClock, ISharedSecret), which this does
# not serve. docs/65.
ANDROID="13"

SUMMARY="A TPM-backed StrongBox keymaster for Waydroid's Android, served from the host"

LICENSE="GPL-3.0-or-later"

# The same two arms as waydroid-ext-wifid, for the same reason: the daemon
# links libgbinder, which Fedora packages and Debian does not. The default arm
# is the source build a distribution runs; --prebuilt packages the binary
# keystore/hal/build.sh produced and is how the Debian dev box gets an
# installable RPM. wifid.mod explains the two %global lines.
GLOBALS='%bcond_with prebuilt

%if %{with prebuilt}
%global debug_package %{nil}
%global __brp_strip %{nil}
%endif'

# swtpm, tpm2-tools and coreutils are for %check, which runs the engine's own
# suite against a throwaway swtpm and requires it to run rather than skip.
BUILDREQUIRES="gcc-c++
pkgconfig(libgbinder) >= 1.1.47
pkgconfig(libglibutil) >= 1.0.82
pkgconfig(glib-2.0)
pkgconfig(gobject-2.0)
pkgconfig(gio-2.0)
pkgconfig(gio-unix-2.0)
systemd-rpm-macros
swtpm
tpm2-tools
coreutils"

# tpm2-tools is hard: the engine's backend today runs tpm2_* for every TPM
# operation (an ESAPI backend linking tpm2-tss directly is planned and is not
# this release). Floors on the binder libraries as sensord and wifid carry them.
REQUIRES="waydroid
systemd
tpm2-tools
libgbinder%{?_isa} >= 1.1.47
libglibutil%{?_isa} >= 1.0.82
glib2%{?_isa}"

# Weak both ways that matter: the daemon is testable and harmless without the
# manifest (Android never contacts it), and without swtpm on a host whose conf
# names a hardware TPM.
RECOMMENDS="waydroid-ext-strongbox
waydroid-ext-swtpm"

DOCS="docs/65-tpm-keystore.md
docs/73-keystore-stage1-engine.md
docs/74-keystore-stage5-auth.md
docs/75-keystore-packaging.md"

DESCRIPTION="Serves Android a StrongBox keymaster from the host, backed by a TPM 2.0:
android.hardware.keymaster@4.0 registered as the strongbox instance on the
hwbinder Waydroid shares with its container. Keys an app asks to be
StrongBox-backed are generated and used inside the TPM, and Android keeps only
a wrapped blob it cannot open -- not even as root, since the TPM is outside the
container.

It joins Android's shared-secret negotiation with the image's own keymaster,
and serves keys bound to the lockscreen. Waydroid's Android 13 gatekeeper signs
its authentication tokens with zeros, so the shipped configuration accepts an
unsigned token and reports that binding at the KEYSTORE level rather than claim
enforcement it cannot verify; everything else about the token is still checked.

Supported: EC P-256 signing, AES-128/256 in ECB, CBC, CTR and GCM. Not
supported: attestation (impossible without a Google-rooted key), RSA, HMAC and
3DES keys. The TPM is waydroid-swtpm's socket by default -- which protects keys
from Android but not from the host, its seed being a file on the host's disk --
or a hardware TPM via /etc/waydroid-keystored.conf.

Android only uses a StrongBox its manifest declares: install
waydroid-ext-strongbox for that."

# keystore/ whole, as wifid.mod carries wifi/: the daemon's sources, the
# engine's, and keystore/selftest.sh for %check. Not hand-deploy.sh or
# strongbox-manifest.sh, which are the by-hand route to what the two packages do.
SOURCES="keystore
artifacts/keystore/install.sh
artifacts/keystore/selftest.sh
artifacts/keystore/waydroid-keystored.service
artifacts/keystore/waydroid-keystored.conf"

PREBUILT_FILES="build/keystore-hal/waydroid-keystored"

# The source arm delegates to keystore/hal/build.sh --rpm, so the daemon's file
# list and link line have one home, as wifid.mod explains. bash, not sh: the
# script uses arrays.
BUILD='%if %{with prebuilt}
test -x prebuilt/waydroid-keystored
mkdir -p build/keystore-hal
cp -p prebuilt/waydroid-keystored build/keystore-hal/waydroid-keystored
%else
bash keystore/hal/build.sh --rpm
%endif'

INSTALL='DESTDIR=%{buildroot} PREFIX=%{_prefix} UNITDIR=%{_unitdir} SYSCONFDIR=%{_sysconfdir} \
    KEYSTORED_BIN=build/keystore-hal/waydroid-keystored \
    sh artifacts/keystore/install.sh'

CHECK='%check
WAYDROID_KEYSTORE_SELFTEST_LIVE=require sh artifacts/keystore/selftest.sh'

PAYLOAD_FILES='%{_bindir}/waydroid-keystored
%{_unitdir}/waydroid-keystored.service
%dir %{_unitdir}/multi-user.target.wants
%{_unitdir}/multi-user.target.wants/waydroid-keystored.service
%config(noreplace) %{_sysconfdir}/waydroid-keystored.conf'
