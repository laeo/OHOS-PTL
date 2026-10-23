#!/bin/bash
# Copyright (c) 2026 OpenHarmony community
# SPDX-License-Identifier: GPL-2.0
#
# Restore the OpenHarmony/Android ashmem driver (/dev/ashmem) onto a vanilla
# kernel tree.  ashmem lived in drivers/staging/android until it was removed
# upstream; the OpenHarmony graphics/UI userland (c_utils Ashmem,
# graphic_2d typefaces, image_framework, ...) still opens /dev/ashmem.
#
# Usage:
#   apply_ashmem.sh <OHOS_SOURCE_ROOT> <KERNEL_BUILD_ROOT>
#
set -e

OHOS_SOURCE_ROOT=$1
KERNEL_BUILD_ROOT=$2

if [ -z "$OHOS_SOURCE_ROOT" ] || [ -z "$KERNEL_BUILD_ROOT" ]; then
    echo "usage: $0 <OHOS_SOURCE_ROOT> <KERNEL_BUILD_ROOT>"
    exit 1
fi

ASHMEM_DIR=$(cd "$(dirname "$0")" && pwd)

if [ -f "$KERNEL_BUILD_ROOT/drivers/android/ashmem.c" ]; then
    echo "ashmem already applied"
    exit 0
fi

echo "applying ashmem driver to $KERNEL_BUILD_ROOT"

cp "$ASHMEM_DIR/ashmem.c" "$KERNEL_BUILD_ROOT/drivers/android/ashmem.c"
cp "$ASHMEM_DIR/ashmem.h" "$KERNEL_BUILD_ROOT/include/linux/ashmem.h"
cp "$ASHMEM_DIR/uapi_ashmem.h" "$KERNEL_BUILD_ROOT/include/uapi/linux/ashmem.h"

# Kconfig: add ASHMEM inside the existing "Android" menu
if ! grep -q '^config ASHMEM$' "$KERNEL_BUILD_ROOT/drivers/android/Kconfig"; then
    python3 - "$KERNEL_BUILD_ROOT/drivers/android/Kconfig" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = 'menu "Android"\n'
add = anchor + '''
config ASHMEM
	bool "Enable the Anonymous Shared Memory Subsystem"
	depends on SHMEM
	help
	  The ashmem subsystem is a new shared memory allocator, similar to
	  POSIX SHM but with different behavior and sporting a simpler
	  file-based API.

	  It is provided for the OpenHarmony userland which opens /dev/ashmem.
'''
assert anchor in s, "Android menu not found"
open(p, 'w').write(s.replace(anchor, add, 1))
PYEOF
fi

# Makefile
if ! grep -q 'CONFIG_ASHMEM' "$KERNEL_BUILD_ROOT/drivers/android/Makefile"; then
    printf 'obj-$(CONFIG_ASHMEM)\t\t\t+= ashmem.o\n' >> "$KERNEL_BUILD_ROOT/drivers/android/Makefile"
fi

echo "ashmem driver applied"
