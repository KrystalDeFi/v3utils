#!/usr/bin/env bash
#
# Preflight the linked libraries of a foundry profile against the target chain.
#
#   script/check-libs.sh <profile>
#
# Libraries are reached by DELEGATECALL, so an address holding the wrong code runs the wrong logic
# silently - exactly what happened on Arc, where a stale CommonLib stayed pinned after its source
# changed. (A *missing* address is comparatively safe: solc guards library calls with an extcodesize
# check, so the call reverts.) foundry.toml's `libraries` is the single source of truth for what gets
# linked; this asserts that each pinned address actually holds the code we expect on $RPC_URL.
#
# Verdicts, per library:
#   OK      on-chain code matches our build byte for byte
#   WARN    identical once the trailing CBOR metadata is stripped - same executable code, built from
#           a different source revision or compiler settings. Deployed before some unrelated change
#           moved the metadata hash; harmless, but it means the deploy is not reproducible from HEAD.
#   FAIL    executable code differs, or nothing is deployed at that address
#
# Exits non-zero on any FAIL. WARN is loud but does not block.
set -euo pipefail

CREATE2_LIB_PREFIX="73" # PUSH20, see patch_self_address

die() { echo "check-libs: $*" >&2; exit 1; }

# A library's runtime code opens with `PUSH20 <library address>; ADDRESS; EQ; ...`, the guard that
# makes a direct (non-delegate) call revert. solc emits that operand as 20 zero bytes and the
# deploying creation code patches in the real address, so the artifact never matches the chain until
# we re-apply the same patch.
patch_self_address() {
    local code=$1 addr=$2
    local placeholder="${CREATE2_LIB_PREFIX}0000000000000000000000000000000000000000"
    [[ $code == "$placeholder"* ]] || die "expected a library artifact starting with PUSH20 <zeros>, got ${code:0:42}"
    printf '%s' "${CREATE2_LIB_PREFIX}${addr}${code:42}"
}

# Solidity appends CBOR metadata (compiler version, a hash of the sources and settings) followed by
# its own 2-byte big-endian length. Dropping it leaves just the executable code.
strip_metadata() {
    local code=$1
    local len=${#code}
    (( len >= 4 )) || { printf '%s' "$code"; return; }
    local meta_len=$(( 16#${code: -4} ))
    local end=$(( len - 4 - meta_len * 2 ))
    (( end >= 0 )) || { printf '%s' "$code"; return; }
    printf '%s' "${code:0:end}"
}

[[ $# -eq 1 ]] || die "usage: $0 <foundry profile>"
profile=$1
[[ -n ${RPC_URL:-} ]] || die "RPC_URL is not set"

# `forge config` resolves the profile the way the build does, so profile inheritance and any
# FOUNDRY_LIBRARIES override are honoured rather than re-parsed out of foundry.toml by hand.
libraries=() # not mapfile: macOS ships bash 3.2
while IFS= read -r line; do
    [[ -n $line ]] && libraries+=("$line")
done < <(FOUNDRY_PROFILE="$profile" forge config --json | jq -r '.libraries[]')
(( ${#libraries[@]} > 0 )) || die "profile '$profile' links no libraries - is that the right profile?"

# The libraries are deployed by `make deploy-nfpm|-commonlib|-structhash`, which set no profile, so
# their bytecode is whatever [profile.default] produces. Building them under a linker profile would
# never match: `libraries` is part of the compiler settings the metadata hash covers. Force the
# default profile (the caller's FOUNDRY_PROFILE is exported by the Makefile) and keep the artifacts
# out of ./out so a linked build there is neither consumed nor clobbered.
export FOUNDRY_PROFILE=default
export FOUNDRY_OUT=cache/libs-check/out
export FOUNDRY_CACHE_PATH=cache/libs-check/cache

echo "profile '$profile' links ${#libraries[@]} libraries; checking them on $RPC_URL"

failed=0
warned=0
for entry in "${libraries[@]}"; do
    # forge's format, e.g. src/CommonLib.sol:CommonLib:0xc4aee87b...
    path=${entry%%:*}
    rest=${entry#*:}
    name=${rest%%:*}
    addr=$(tr 'A-Z' 'a-z' <<<"${rest#*:}")
    addr=${addr#0x}

    expected=$(FOUNDRY_PROFILE=default forge inspect "$path:$name" deployedBytecode)
    expected=$(tr 'A-Z' 'a-z' <<<"${expected#0x}")
    [[ $expected =~ ^[0-9a-f]+$ ]] || die "$name: could not read deployedBytecode from $path"
    expected=$(patch_self_address "$expected" "$addr")

    actual=$(cast code "0x$addr" --rpc-url "$RPC_URL")
    actual=$(tr 'A-Z' 'a-z' <<<"${actual#0x}")

    if [[ -z $actual ]]; then
        echo "  FAIL $name 0x$addr - no code on this chain, deploy it first"
        failed=1
    elif [[ $actual == "$expected" ]]; then
        echo "  OK   $name 0x$addr"
    elif [[ $(strip_metadata "$actual") == "$(strip_metadata "$expected")" ]]; then
        echo "  WARN $name 0x$addr - same code, different build metadata (deployed from another revision)"
        warned=1
    else
        echo "  FAIL $name 0x$addr - bytecode mismatch, this address runs different logic"
        failed=1
    fi
done

if (( failed )); then
    echo "check-libs: fix foundry.toml's [profile.$profile] libraries, or deploy the missing ones" >&2
    exit 1
fi
if (( warned )); then
    echo "check-libs: passed with warnings"
fi
