#!/bin/bash
# Copyright (c) 2026 OpenHarmony community
# SPDX-License-Identifier: GPL-2.0
#
# Apply OpenHarmony private kernel modules (not upstream) onto a vanilla
# kernel source tree. These modules are shipped directly inside the
# OpenHarmony linux-5.10 / linux-6.6 repositories and are therefore absent
# from the vanilla stable kernel used for a newer version.
#
# Usage:
#   apply_ohos_modules.sh <OHOS_SOURCE_ROOT> <KERNEL_BUILD_ROOT> <KERNEL_VERSION>
#
# Example:
#   ./apply_ohos_modules.sh /path/to/ohos /path/to/ohos/kernel/linux/linux-6.18 linux-6.18
#
set -e

OHOS_SOURCE_ROOT=$1
KERNEL_BUILD_ROOT=$2
KERNEL_VERSION=$3

if [ -z "$OHOS_SOURCE_ROOT" ] || [ -z "$KERNEL_BUILD_ROOT" ] || [ -z "$KERNEL_VERSION" ]; then
    echo "usage: $0 <OHOS_SOURCE_ROOT> <KERNEL_BUILD_ROOT> <KERNEL_VERSION>"
    exit 1
fi

KERNEL_MODULES_DIR=$(cd "$(dirname "$0")" && pwd)
# Source of the OpenHarmony private modules: prefer the newest in-tree
# OpenHarmony kernel that carries them.
for candidate in linux-6.6 linux-5.10; do
    if [ -d "$OHOS_SOURCE_ROOT/kernel/linux/$candidate/drivers/accesstokenid" ]; then
        SRC_KERNEL="$OHOS_SOURCE_ROOT/kernel/linux/$candidate"
        break
    fi
done

if [ -z "$SRC_KERNEL" ]; then
    echo "error: no OpenHarmony kernel with private modules found"
    exit 1
fi

echo "porting OpenHarmony private modules from $SRC_KERNEL to $KERNEL_BUILD_ROOT"

# --- access token id (/dev/access_token_id, SPM ioctl base) ---
if [ ! -d "$KERNEL_BUILD_ROOT/drivers/accesstokenid" ]; then
    cp -a "$SRC_KERNEL/drivers/accesstokenid" "$KERNEL_BUILD_ROOT/drivers/"
fi

# Register in drivers/Kconfig
if ! grep -q 'drivers/accesstokenid/Kconfig' "$KERNEL_BUILD_ROOT/drivers/Kconfig"; then
    sed -i 's|source "drivers/accessibility/Kconfig"|source "drivers/accessibility/Kconfig"\n\nsource "drivers/accesstokenid/Kconfig"|' \
        "$KERNEL_BUILD_ROOT/drivers/Kconfig"
fi

# Register in drivers/Makefile
if ! grep -q 'accesstokenid/' "$KERNEL_BUILD_ROOT/drivers/Makefile"; then
    sed -i 's|^obj-$(CONFIG_ACCESSIBILITY)\t+= accessibility/|obj-$(CONFIG_ACCESSIBILITY)\t+= accessibility/\nobj-$(CONFIG_ACCESS_TOKENID)\t+= accesstokenid/|' \
        "$KERNEL_BUILD_ROOT/drivers/Makefile"
fi

# --- task_struct token/ftoken/userid fields ---
SCHED_H="$KERNEL_BUILD_ROOT/include/linux/sched.h"
if ! grep -q 'CONFIG_ACCESS_TOKENID' "$SCHED_H"; then
    python3 - "$SCHED_H" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = """	/* CPU-specific state of this task: */
	struct thread_struct		thread;"""
add = """#ifdef CONFIG_ACCESS_TOKENID
	u64				token;
	u64				ftoken;
	u32				token_userid;
#endif

""" + anchor
assert anchor in s, "sched.h anchor not found"
open(p, 'w').write(s.replace(anchor, add, 1))
PYEOF
fi
# Existing build trees may already carry token/ftoken without token_userid
# (used by SET_USERID/GET_USERID, cmd 12/13). Add it in place if missing.
if grep -q 'CONFIG_ACCESS_TOKENID' "$SCHED_H" && ! grep -q 'token_userid' "$SCHED_H"; then
    python3 - "$SCHED_H" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = """	u64				ftoken;
#endif"""
add = """	u64				ftoken;
	u32				token_userid;
#endif"""
assert anchor in s, "sched.h token_userid anchor not found"
open(p, 'w').write(s.replace(anchor, add, 1))
PYEOF
fi

# --- NWEBSPAWN_UID ---
UIDGID_H="$KERNEL_BUILD_ROOT/include/linux/uidgid.h"
if ! grep -q 'NWEBSPAWN_UID' "$UIDGID_H"; then
    python3 - "$UIDGID_H" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = """#define GLOBAL_ROOT_GID KGIDT_INIT(0)
"""
add = anchor + """
#ifdef CONFIG_ACCESS_TOKENID
#define NWEBSPAWN_UID KUIDT_INIT(3081)
#endif
"""
assert anchor in s, "uidgid.h anchor not found"
open(p, 'w').write(s.replace(anchor, add, 1))
PYEOF
fi

# --- binder access token pass-through (BINDER_FEATURE_SET / GET_ACCESS_TOKEN) ---
BINDER_PATCH="$KERNEL_MODULES_DIR/binder_access_token.patch"
if [ ! -f "$BINDER_PATCH" ]; then
    BINDER_PATCH="$OHOS_SOURCE_ROOT/kernel/linux/patches/$KERNEL_VERSION/common_patch/binder_access_token.patch"
fi
if [ -f "$BINDER_PATCH" ] && ! grep -q 'BINDER_GET_ACCESS_TOKEN' "$KERNEL_BUILD_ROOT/include/uapi/linux/android/binder.h"; then
    patch -d "$KERNEL_BUILD_ROOT" -p1 -s < "$BINDER_PATCH"
fi

# --- ashmem (/dev/ashmem) for the OpenHarmony graphics/UI userland ---
if [ -x "$KERNEL_MODULES_DIR/ashmem/apply_ashmem.sh" ]; then
    "$KERNEL_MODULES_DIR/ashmem/apply_ashmem.sh" "$OHOS_SOURCE_ROOT" "$KERNEL_BUILD_ROOT"
fi

echo "OpenHarmony private modules applied"
