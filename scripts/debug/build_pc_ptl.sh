#!/bin/bash
# build_pc_ptl.sh - wrapper to build the pc_ptl (Intel Panther Lake real HW) product
# with the host prerequisites that this tree needs.
#
# Known prerequisites (see AGENTS.md / verify_kernel2/SUMMARY.md):
#   * RUBYOPT erb compat shim (host ruby 4)
#   * JAVA_HOME -> valid JDK 17 (HAP packaging)
#   * CLANG_HOST_TOOLCHAIN -> host clang >= 17 (linux-7.2 refuses the in-tree
#     prebuilt clang 15); /usr/lib/llvm-21 on this host.
#   * prebuilts/libtool/bin on PATH (libtoolize for third_party/libtiff) - the
#     build framework now adds it, but export it anyway for robustness.
#
# Usage:
#   build_pc_ptl.sh full                       # full images build (background it yourself)
#   build_pc_ptl.sh --build-target linux_kernel
#
set -e
ROOT=/home/katax/Public/OHOS
cd "$ROOT"

export RUBYOPT="-r$ROOT/build/compat/erb_compat.rb"
export JAVA_HOME=/home/katax/.gradle/jdks/jetbrains_s_r_o_-17-amd64-linux.2
export PATH="$JAVA_HOME/bin:$ROOT/prebuilts/libtool/bin:$PATH"
export CLANG_HOST_TOOLCHAIN=/usr/lib/llvm-21/bin

if [ "$1" = "full" ]; then
  shift
  EXTRA=""
else
  EXTRA="$*"
fi

exec ./build.sh --product-name pc_ptl --jobs 8 --keep-ninja-going \
  --device-type 2in1 --deps-guard=false \
  --gn-args linux_kernel_version='"linux-7.2"' \
  $EXTRA
