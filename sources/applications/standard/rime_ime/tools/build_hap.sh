#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 OpenHarmony PC Image Contributors
#
# Build the Rime input method HAP (bundle com.ohos.rimeime) with the DevEco CLI
# hvigor wrapper.  Not driven by ./build.sh -- see README.md.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=env.sh
. "$HERE/env.sh"
PROJ="$HERE/.."
MODULE="${MODULE:-entry}"

cd "$PROJ/hap"
if [ ! -f local.properties ]; then
    {
        echo "sdk.dir=$DEVECO_SDK_HOME"
        echo "nodejs.dir=$NODE_HOME"
    } > local.properties
    echo "generated hap/local.properties"
fi

echo "node=$(node -v) java=$(java -version 2>&1 | head -1) hvigorw=$(command -v hvigorw)"
hvigorw assembleHap --mode module -p module="$MODULE" --no-daemon \
    -p debuggable=false -p build_mode=release
rc=$?
echo "=== hvigor exit: $rc ==="
find "$PROJ/hap" -name '*.hap' -newermt '-2 hours' -exec ls -la {} \;
exit $rc