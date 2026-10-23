#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 OpenHarmony PC Image Contributors
#
# Shared environment for the hvigor (DevEco CLI) toolchain used to build the
# terminal HAP.  Sourced by build_hap.sh / sign_hap.sh.
#
# All paths are overridable from the environment so the script works both on a
# developer workstation and inside CI.  Nothing here is hard coded to a
# particular user's home directory.

# ---- locate the OpenHarmony source tree -------------------------------------
_pc_terminal_root() {
    # <repo>/applications/standard/terminal/tools/env.sh -> <repo>
    (cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
}
export OHOS_ROOT="${OHOS_ROOT:-$(_pc_terminal_root)}"

# ---- toolchain locations ----------------------------------------------------
export NODE_HOME="${NODE_HOME:-$OHOS_ROOT/prebuilts/build-tools/common/nodejs/node-v18.20.1-linux-x64}"
export DEVECO_CLI_HOME="${DEVECO_CLI_HOME:-$HOME/.local/deveco/command-line-tools}"
export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$OHOS_ROOT/prebuilts/ohos-sdk/linux}"
export OHOS_BASE_SDK_HOME="${OHOS_BASE_SDK_HOME:-$DEVECO_SDK_HOME}"
export JAVA_HOME="${JAVA_HOME:-/home/katax/.gradle/jdks/jetbrains_s_r_o_-17-amd64-linux.2}"

export PATH="$JAVA_HOME/bin:$NODE_HOME/bin:$DEVECO_CLI_HOME/bin:$PATH"
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=20000}"

# ---- signing material (OpenHarmony test chain) -----------------------------
export PC_TERMINAL_SIGN_DIR="${PC_TERMINAL_SIGN_DIR:-$(dirname "${BASH_SOURCE[0]}")/../signing}"
export HAP_SIGN_TOOL="${HAP_SIGN_TOOL:-$(dirname "${JAVA_HOME}")/../lib/hap-sign-tool.jar}"
if [ ! -f "$HAP_SIGN_TOOL" ]; then
    HAP_SIGN_TOOL="$(command -v hap-sign-tool.jar 2>/dev/null || true)"
fi