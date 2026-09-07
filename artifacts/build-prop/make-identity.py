#!/usr/bin/env python3
"""
Rewrite the device identity in Waydroid's build.prop files.

WHY THIS DEVICE. The target is the ChromeOS `nissa` board running ARCVM Android 13,
which is deliberate on three counts:

  1. It is genuinely x86_64. Impersonating an arm64 phone (a Pixel, say) would leave
     ro.product.cpu.abilist saying x86_64 while the fingerprint claimed otherwise --
     an inconsistency a server-side check would spot immediately, and Netflix already
     delivers this device its x86_64 splits.
  2. It runs Android 13 / SDK 33, matching this container exactly.
  3. It is the *same device the installed Widevine CDM was extracted from*
     (docs/22). The CDM's device certificate and the build identity therefore agree,
     which matters because Netflix derives its ESN from both.

WHY NOT waydroid_base.prop. Read-only properties cannot be re-set once a build.prop
has defined them -- that file already sets ro.hardware.gralloc=gbm while the live
value is minigbm_gbm_mesa, the image having won. The build.prop files are the only
lever, reached through the overlay so no image is modified.

WHY EVERY PARTITION FILE. ro.product.<name> is *derived*: init reads ro.product.<partition>.<name>
from every partition and picks by ro.product.property_source_order, which is unset here,
so the default `odm,vendor,product,system_ext,system` applies and **odm wins**. Changing
only /system/build.prop would therefore change nothing observable. All partitions are set
to the same values so the result does not depend on that order at all.

ro.build.fingerprint itself is absent from every build.prop -- init derives it from
brand/name/device/release/id/incremental/type/tags. Set those and the fingerprint follows:

    google/nissa/nissa_cheets:13/R130-16033.58.0/12608590:user/release-keys

Only keys that already exist are rewritten; nothing is appended, so no duplicate-property
warnings and no new properties appear.

Usage:  artifacts/build-prop/make-identity.py            # write modified/ from original/
        artifacts/build-prop/make-identity.py --revert   # copy original/ through unchanged
"""
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
SRC = HERE / "original"
DST = HERE / "modified"

# ---------------------------------------------------------------- target identity
BRAND = "google"
NAME = "nissa"
DEVICE = "nissa_cheets"
MANUFACTURER = "Google"
MODEL = "nissa"
BUILD_ID = "R130-16033.58.0"
INCREMENTAL = "12608590"
BUILD_TYPE = "user"
BUILD_TAGS = "release-keys"
RELEASE = "13"

FINGERPRINT = f"{BRAND}/{NAME}/{DEVICE}:{RELEASE}/{BUILD_ID}/{INCREMENTAL}:{BUILD_TYPE}/{BUILD_TAGS}"
DESCRIPTION = f"{NAME}-{BUILD_TYPE} {RELEASE} {BUILD_ID} {INCREMENTAL} {BUILD_TAGS}"

# Which build.prop belongs to which partition prefix.
# EVERY partition that defines ro.<part>.build.fingerprint must be here.
# Build.isBuildConsistent() compares them all, and ActivityManagerService puts up
# "There's an internal problem with your device. Contact your manufacturer for
# details." the moment one disagrees. Missing vendor_dlkm on the first attempt
# produced exactly that dialog -- and it is a system dialog, easily mistaken for
# an app fault. `find / -xdev -name build.prop` inside the container lists them.
FILES = {
    "system_build.prop": "system",
    "system_system_ext_etc_build.prop": "system_ext",
    "system_system_dlkm_etc_build.prop": "system_dlkm",
    "vendor_build.prop": "vendor",
    "vendor_odm_dlkm_etc_build.prop": "odm_dlkm",
    "vendor_vendor_dlkm_etc_build.prop": "vendor_dlkm",
    "odm_etc_build.prop": "odm",
}


def replacements(part):
    r = {
        f"ro.product.{part}.brand": BRAND,
        f"ro.product.{part}.device": DEVICE,
        f"ro.product.{part}.manufacturer": MANUFACTURER,
        f"ro.product.{part}.model": MODEL,
        f"ro.product.{part}.name": NAME,
        f"ro.{part}.build.fingerprint": FINGERPRINT,
        f"ro.{part}.build.id": BUILD_ID,
        f"ro.{part}.build.tags": BUILD_TAGS,
        f"ro.{part}.build.type": BUILD_TYPE,
        f"ro.{part}.build.version.incremental": INCREMENTAL,
    }
    # The un-prefixed build properties live only in /system/build.prop.
    if part == "system":
        r.update({
            "ro.build.id": BUILD_ID,
            "ro.build.display.id": DESCRIPTION,
            "ro.build.version.incremental": INCREMENTAL,
            "ro.build.type": BUILD_TYPE,
            "ro.build.tags": BUILD_TAGS,
            "ro.build.flavor": f"{NAME}-{BUILD_TYPE}",
            "ro.build.product": DEVICE,
            "ro.build.description": DESCRIPTION,
        })
    return r


def main():
    revert = "--revert" in sys.argv
    if revert:
        print("revert mode: modified/ will be a byte-for-byte copy of original/")
    DST.mkdir(exist_ok=True)
    for fname, part in FILES.items():
        src = SRC / fname
        if not src.exists():
            sys.exit(f"missing {src} -- pull the originals first")
        lines = src.read_text().splitlines(keepends=True)
        if revert:
            (DST / fname).write_text("".join(lines))
            print(f"  {fname}: restored")
            continue
        rep = replacements(part)
        out, changed = [], 0
        for line in lines:
            key = line.split("=", 1)[0].strip()
            if key in rep and not line.lstrip().startswith("#"):
                out.append(f"{key}={rep[key]}\n")
                changed += 1
            else:
                out.append(line)
        (DST / fname).write_text("".join(out))
        present = {l.split("=", 1)[0].strip() for l in lines}
        missing = sorted(set(rep) - present)
        print(f"  {fname}: {changed} properties rewritten"
              + (f"  (absent, not added: {', '.join(missing)})" if missing else ""))
    if not revert:
        print(f"\nderived fingerprint will be:\n  {FINGERPRINT}")


if __name__ == "__main__":
    main()
