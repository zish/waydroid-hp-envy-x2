#!/bin/sh
# build.sh -- compile the stage-1 keystore engine CLI (keystore-engine).
#
# Stage 1 has no binder and no Android dependency: it is plain C++17 and needs
# only a compiler. The TPM is reached through tpm2-tools at runtime (the
# ToolsTpmBackend), so there is nothing to link against here. A later ESAPI
# backend will add -ltss2-esys -ltss2-mu -ltss2-tctildr and a build dep.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out=${1:-"$here/../build/keystore-engine"}
mkdir -p "$(dirname -- "$out")"

CXX=${CXX:-g++}
"$CXX" -std=c++17 -O2 -Wall -Wextra -o "$out" \
    "$here/km_blob.cpp" \
    "$here/tools_backend.cpp" \
    "$here/engine.cpp" \
    "$here/main.cpp"

echo "built $out"
