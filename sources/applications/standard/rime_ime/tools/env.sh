# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 OpenHarmony PC Image Contributors
#
# Shared environment for the hvigor (DevEco CLI) toolchain used to build the
# Rime input-method HAP.  Sourced by build_hap.sh.

_rime_root() {
    # <repo>/applications/standard/rime_ime/tools/env.sh -> <repo>
    (cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
}
export OHOS_ROOT="${OHOS_ROOT:-$(_rime_root)}"

export NODE_HOME="${NODE_HOME:-$OHOS_ROOT/prebuilts/build-tools/common/nodejs/node-v18.20.1-linux-x64}"
export DEVECO_CLI_HOME="${DEVECO_CLI_HOME:-$HOME/.local/deveco/command-line-tools}"
export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$OHOS_ROOT/prebuilts/ohos-sdk/linux}"
export OHOS_BASE_SDK_HOME="${OHOS_BASE_SDK_HOME:-$DEVECO_SDK_HOME}"
export JAVA_HOME="${JAVA_HOME:-/home/katax/.gradle/jdks/jetbrains_s_r_o_-17-amd64-linux.2}"

export PATH="$JAVA_HOME/bin:$NODE_HOME/bin:$DEVECO_CLI_HOME/bin:$PATH"
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=20000}"