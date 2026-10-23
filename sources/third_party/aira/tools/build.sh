#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 OpenHarmony PC Image Contributors
#
# Build + repack + sign the Aira browser HAP for the pc_ptl image.
#
#   1. apply  patches/0001-openhms-login-component-shim.patch to the upstream
#      checkout (the shim source itself lives in shim/, the patch only rewires
#      the ten `@kit.AccountKit` import sites);
#   2. build with DevEco hvigor (HarmonyOS SDK 26, release, native build off);
#   3. strip libs/ -- the device pre-install code-sign check
#      (BMSInstaller -> EnforceCodeSignForAppWithPluginId -> IsSupportFsVerity)
#      rejects ANY pre-installed HAP that ships native .so files;
#   4. re-sign with the in-tree OpenHarmony test chain, whose distribution
#      certificate is the trust anchor baked into
#      vendor/ohemu/virt/preinstall-config/install_list_capability.json.
#
# usage: build.sh [--apply-patches]
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=env.sh
. "$HERE/env.sh"

APPLY=0
[ "${1:-}" = "--apply-patches" ] && APPLY=1

PATCH="$REPO/third_party/aira/patches/0001-openhms-login-component-shim.patch"
if [ "$APPLY" = 1 ]; then
    cd "$AIRA_SRC/.."
    git apply --check "$PATCH" && git apply "$PATCH"
    echo "patch applied"
fi

[ -f "$AIRA_SRC/local.properties" ] || {
    echo "sdk.dir=$DEVECO_HMS_SDK" > "$AIRA_SRC/local.properties"
    echo "nodejs.dir=$NODE_HOME" >> "$AIRA_SRC/local.properties"
}

mkdir -p "$AIRA_WORK"
cd "$AIRA_SRC"
hvigorw assembleHap --mode module -p module=entry@default -p product=default \
    -p buildMode=release --no-daemon "$@" 2>&1 | tee "$AIRA_WORK/build.log"
rc=${PIPESTATUS[0]}
echo "=== hvigor exit: $rc ==="
[ "$rc" = 0 ] || exit "$rc"

SRC="$AIRA_SRC/entry/build/default/outputs/default/entry-default-unsigned.hap"
WORKHAP="$AIRA_WORK/Aira-work.hap"
OUT="$AIRA_WORK/Aira-nolibs-signed.hap"
cp -f "$SRC" "$WORKHAP"
zip -q -d "$WORKHAP" 'libs/*' || true
echo "libs entries left: $(unzip -l "$WORKHAP" | grep -cE 'libs/')"

java -jar "$HAP_SIGN_TOOL" sign-app -keyAlias "openharmony application release" \
    -signAlg SHA256withECDSA -mode localSign \
    -appCertFile "$AIRA_SIGN_DIR/AppCertChain.cer" \
    -profileFile "$AIRA_SIGN_DIR/aira.p7b" \
    -inFile "$WORKHAP" -outFile "$OUT" \
    -keystoreFile "$AIRA_SIGN_DIR/OpenHarmony.p12" \
    -keyPwd "${KEY_PWD:-123456}" -keystorePwd "${KEY_PWD:-123456}"

java -jar "$HAP_SIGN_TOOL" verify-app -inFile "$OUT"
ls -la "$OUT"; sha256sum "$OUT"