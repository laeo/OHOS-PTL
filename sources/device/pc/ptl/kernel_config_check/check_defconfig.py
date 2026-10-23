#!/usr/bin/env python3
"""Fail-fast kernel config audit for the pc_ptl (PTL) OHOS port.

Two independent checks:

1. Required symbols: every entry of the required-symbols file must be present
   in the generated .config with the exact expected value.  This catches the
   "driver silently dropped by olddefconfig" class of bug (e.g. a non-visible
   CONFIG_PINCTRL_INTEL=y that no longer has a visible selector).

2. Dropped/changed defconfig entries (optional): every symbol the maintained
   defconfig sets (y/m/n/value) that is absent from, or different in, the
   final .config is reported.  Hidden/compiler-detected symbols are expected
   to show up here and are listed for review.

Usage:
  check_defconfig.py --required required_symbols.txt --config .config \
                     [--defconfig ptl_standard_defconfig] [--ignore pattern]

Exit status: 0 if all *required* symbols match, 1 otherwise.
"""
import argparse
import re
import sys

SET_RE = re.compile(r"^(CONFIG_[A-Za-z0-9_]+)=(.*)$")
NONE_RE = re.compile(r"^# (CONFIG_[A-Za-z0-9_]+) is not set$")


def parse_config(path):
    out = {}
    order = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            m = SET_RE.match(line)
            if m:
                out[m.group(1)] = m.group(2)
                order.append(m.group(1))
                continue
            m = NONE_RE.match(line)
            if m:
                out[m.group(1)] = "n"
                order.append(m.group(1))
    return out, order


def parse_required(path):
    req = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                print(f"required-symbols: malformed line: {line}")
                continue
            name, val = line.split("=", 1)
            req[name.strip()] = val.strip()
    return req


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--required", required=True)
    ap.add_argument("--config", required=True)
    ap.add_argument("--defconfig")
    ap.add_argument("--ignore", action="append", default=[])
    args = ap.parse_args()

    cfg, _ = parse_config(args.config)
    req = parse_required(args.required)

    failures = []
    for name, want in req.items():
        got = cfg.get(name)
        if got is None:
            failures.append(f"  MISSING  {name} (required {want})")
        elif got != want:
            failures.append(f"  CHANGED  {name}: required {want} -> got {got}")

    if failures:
        print(f"FAIL: {len(failures)} required symbol(s) not satisfied:")
        print("\n".join(failures))
    else:
        print(f"OK: all {len(req)} required symbols present with expected values.")

    if args.defconfig:
        defc, deforder = parse_config(args.defconfig)
        dropped = []
        changed = []
        for sym in deforder:
            want = defc[sym]
            got = cfg.get(sym)
            if got is None:
                dropped.append((sym, want))
            elif got != want:
                changed.append((sym, want, got))

        def ignored(sym):
            return any(re.search(p, sym) for p in args.ignore)

        dropped = [d for d in dropped if not ignored(d[0])]
        changed = [c for c in changed if not ignored(c[0])]

        print()
        print("--- defconfig vs .config (review; not a hard failure) ---")
        print(f"defconfig-set symbols ABSENT from .config: {len(dropped)}")
        for sym, want in dropped:
            print(f"  DROPPED  {sym} (defconfig={want})")
        print(f"defconfig-set symbols CHANGED in .config : {len(changed)}")
        for sym, want, got in changed:
            print(f"  CHANGED  {sym}: defconfig={want} -> got={got}")

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
