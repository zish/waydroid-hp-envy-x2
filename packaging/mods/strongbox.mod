# waydroid-ext-strongbox -- docs/73, docs/74, docs/75
#
# Declares a second keymaster@4.0 instance, "strongbox", in Android's vendor
# VINTF manifest, so keystore2 engages the StrongBox waydroid-keystored serves
# and offers it to any app that asks for setIsStrongBoxBacked(true). Without
# this the daemon can run and register and keystore2 never contacts it:
# declaration is the gate (docs/73, stage 3a).
#
# WHY THE WHOLE MANIFEST, AND WHY IT IS DERIVED
#
# A manifest FRAGMENT cannot do it. One that re-declares
# android.hardware.keymaster@4.0 to add an instance is a conflict to libvintf,
# which then rejects the whole device manifest -- keymaster and keystore2
# crash-loop and the boot never completes (docs/73). So the override is the
# whole /vendor/etc/vintf/manifest.xml with two lines added inside the existing
# keymaster <hal>: an <instance>strongbox</instance> and its <fqname>.
#
# That file is the image's, so it is derived, not shipped: the row below
# carries no bytes of it, only the stock hash, the two insertions and the
# result hash, and waydroid-overlay-sync makes it out of the user's own
# vendor.img at reconcile time (docs/54). Shipping a copy would also be the
# wrong engineering: a full override silently hides whatever an image update
# changes in the manifest, where a derive row refuses and says so. Insertions
# need waydroid-overlay-sync 1.2.0.
#
# The result is byte-for-byte the manifest keystore2 bound on 2026-10-22 and
# every session since, reproduced by artifacts/keystore/strongbox-manifest.sh
# and by this row through the real reconciler (docs/75). That script's pinned
# hashes and this row's must stay one pair; artifacts/keystore/selftest.sh
# checks it.
#
# WHY THE HARD DEPENDENCY
#
# A strongbox the manifest declares with nothing serving it is the one
# combination never booted (docs/65 open question 4) -- the stage-2 boot that
# looked like an answer had the strongbox undeclared. The Requires makes it
# unreachable by package operations; the daemon registering even with no TPM
# makes it unreachable at runtime. Disabling waydroid-keystored.service by hand
# with this installed is the gap neither closes, and its unit says so.

VERSION=1.0.0
RELEASE=1
KIND=overlay

# A text file, derived; no Android ELF. The stock hash pins it to the x86_64
# image all the same, and the daemon it needs is x86_64-only.
ARCH=noarch

# keymaster@4.0 is Android 13's interface here. Android 16 has AIDL KeyMint,
# which the daemon does not serve, and its manifest is a different file.
ANDROID="13"

SUMMARY="Declares the host's StrongBox keymaster to Android, which offers it to apps"

# The derived manifest is the image's, Apache-2.0, with two lines added.
LICENSE="Apache-2.0"

REQUIRES="waydroid-ext-overlay-sync >= 1.2.0
waydroid-ext-keystored"

DOCS="docs/user/overlay.md docs/73-keystore-stage1-engine.md docs/74-keystore-stage5-auth.md docs/75-keystore-packaging.md"

DESCRIPTION="Declares the StrongBox keymaster that waydroid-keystored serves in Android's
vendor VINTF manifest, so Android's keystore engages it: apps that ask for
StrongBox-backed keys get them, generated and used inside the host's TPM.

Android only uses a StrongBox its manifest declares, and a manifest fragment
cannot add an instance to a keymaster the image already declares -- the
conflict makes Android reject its whole device manifest. So the override is
the image's own manifest with two lines added, and it is derived from the
user's vendor.img by waydroid-overlay-sync rather than shipped: the package
carries the edit and the hashes either side of it, and refuses to install
anything if the image's manifest has changed.

It does not declare FEATURE_STRONGBOX_KEYSTORE, so apps that check for that
feature before asking will not ask. Apps that ask without checking get the
StrongBox."

# derive <mode> <path in overlay> <image> <path in image> <stock> <result> <edits>
# The two edits insert, at stock offsets 0xa68 and 0xab5, the lines
#             <instance>strongbox</instance>
#         <fqname>@4.0::IKeymasterDevice/strongbox</fqname>
# after the default instance and default fqname lines of the keymaster <hal>.
FILES="
derive 0644 vendor/etc/vintf/manifest.xml vendor /etc/vintf/manifest.xml 0695403b549a7902442641adc6bc821d6787319174464bce0330b122ab16c7cc 3f2a8b70cce41e6d5b2bb1e6e11ef6c09169f4b5e3b4a0b042c0dc40feb0fc86 a68+2020202020202020202020203c696e7374616e63653e7374726f6e67626f783c2f696e7374616e63653e0a,ab5+20202020202020203c66716e616d653e40342e303a3a494b65796d61737465724465766963652f7374726f6e67626f783c2f66716e616d653e0a
"
