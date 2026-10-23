#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 OpenHarmony PC Image Contributors
#
# Sign the terminal HAP as a preinstalled system application so that BMS
# accepts it during the first-boot pre-install pass.
#
# Required material (OpenHarmony test chain, NOT part of this repository):
#   $PC_TERMINAL_SIGN_DIR/OpenHarmony.p12          keystore
#   $PC_TERMINAL_SIGN_DIR/OpenHarmonyProfileRelease.pem
#   $PC_TERMINAL_SIGN_DIR/AppCertChain.cer
#   $PC_TERMINAL_SIGN_DIR/terminal-profile.json    profile (bundle com.ohos.terminal)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=env.sh
. "$HERE/env.sh"

SIG="$PC_TERMINAL_SIGN_DIR"
IN_HAP="${1:-$HERE/../hap/entry/build/default/outputs/default/entry-default-unsigned.hap}"
OUT_HAP="${2:-$HERE/../terminal-signed.hap}"
KEY_PWD="${KEY_PWD:-123456}"

if [ ! -f "$IN_HAP" ]; then
    echo "unsigned HAP not found: $IN_HAP (run tools/build_hap.sh first)" >&2
    exit 1
fi

java -jar "$HAP_SIGN_TOOL" sign-profile \
    -keyAlias "openharmony application profile release" \
    -signAlg SHA256withECDSA -mode localSign \
    -profileCertFile "$SIG/OpenHarmonyProfileRelease.pem" \
    -inFile "$SIG/terminal-profile.json" \
    -keystoreFile "$SIG/OpenHarmony.p12" \
    -outFile "$SIG/terminal.p7b" -keyPwd "$KEY_PWD" -keystorePwd "$KEY_PWD"

java -jar "$HAP_SIGN_TOOL" sign-app \
    -keyAlias "openharmony application release" \
    -signAlg SHA256withECDSA -mode localSign \
    -appCertFile "$SIG/AppCertChain.cer" \
    -profileFile "$SIG/terminal.p7b" \
    -inFile "$IN_HAP" -outFile "$OUT_HAP" \
    -keystoreFile "$SIG/OpenHarmony.p12" -keyPwd "$KEY_PWD" -keystorePwd "$KEY_PWD"

java -jar "$HAP_SIGN_TOOL" verify-app -inFile "$OUT_HAP"
ls -la "$OUT_HAP"
sha256sum "$OUT_HAP"