#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 OpenHarmony PC Image Contributors
#
# Shared environment for the DevEco CLI hvigor toolchain used to rebuild the
# Aira browser HAP with the OpenHarmony compatibility shim applied.
#
# Aira upstream is GPL-3.0, so anything merged into it must be GPL-3.0-or-later
# compatible -- hence the SPDX header on the shim.

_aira_root() {
    # <repo>/third_party/aira/tools/env.sh -> <repo>
    (cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
}
export OHOS_ROOT="${OHOS_ROOT:-$(_aira_root)}"

export NODE_HOME="${NODE_HOME:-$OHOS_ROOT/prebuilts/build-tools/common/nodejs/node-v18.20.1-linux-x64}"
export JAVA_HOME="${JAVA_HOME:-/home/katax/.gradle/jdks/jetbrains_s_r_o_-17-amd64-linux.2}"
export DEVECO_CLI_HOME="${DEVECO_CLI_HOME:-$HOME/.local/deveco/command-line-tools}"
export PATH="$JAVA_HOME/bin:$NODE_HOME/bin:$DEVECO_CLI_HOME/bin:$PATH"
export PATH="$DEVECO_CLI_HOME/sdk/default/openharmony/toolchains:$PATH"
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=20000}"

# HarmonyOS SDK (with the hms/ kits) is required: the ArkTS sources import
# @kit.AccountKit etc.  A pure OpenHarmony SDK will not resolve them.
export DEVECO_HMS_SDK="${DEVECO_HMS_SDK:-$DEVECO_CLI_HOME/sdk/default}"

# Upstream checkout + OpenHarmony test-chain signing material (not in tree).
export AIRA_SRC="${AIRA_SRC:-${OHOS_ROOT}/out/x86_64_virt/ohos-dbg/porting/aira_src/AiraBrowser}"
export AIRA_SIGN_DIR="${AIRA_SIGN_DIR:-$HOME/.local/share/ohos-pc-image/signing/aira}"
export AIRA_WORK="${AIRA_WORK:-$OHOS_ROOT/out/x86_64_virt/ohos-dbg/aira_build}"