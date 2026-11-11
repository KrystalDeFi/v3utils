#!/usr/bin/env bash
#
# Refuse to build with any forge other than the pinned v1.8.3 release.
#
#   script/check-forge.sh        (or: make forge-check)
#
# With the default bytecode_hash = "ipfs", solc appends a metadata hash to the creation code that
# covers settings.remappings - and the remappings list is computed by forge, not read from the
# repo. Every forge version emits a different list, so identical sources, salt and factory land at
# different CREATE2 addresses with each toolchain, even though the runtime code is byte-identical:
#   <= v1.7.1   13 relative remappings                 (the Jul 27 and Nov 10 v1.7.1 deploys)
#   v1.8.x      18 remappings incl. absolute build-dir contexts (the Nov 3 4663 deploys - THIS pin)
#   v1.9.0      15 deduped remappings                  (the Nov 10 v1.9.0 deploys)
# v1.8.3 (commit cae51ad) reproduces all five deployed 4663 addresses byte for byte, so both the
# version and the commit SHA are pinned: a nightly or custom build that merely reports "1.8.3" is
# still rejected. Same failure class as PR #60, where one added remappings.txt line moved every
# address - here the line count moves with the toolchain instead.
#
# v1.8.x also writes the absolute build directory into three remapping contexts, so the pinned
# class is only reproducible from this checkout's own path: building from a worktree or another
# clone moves the addresses even with the right forge. No portable check can catch that.
#
# Wired as a prerequisite of make build/test/deploy-*, so any drift blocks the deploy before
# anything is sent.
set -euo pipefail

PINNED_VERSION="1.8.3"
PINNED_COMMIT="cae51ad458f6abb64852b7709eb784352429825d"

die() { echo "check-forge: $*" >&2; exit 1; }

forge_bin=$(command -v forge) || die "forge is not on PATH - install the pinned toolchain: foundryup -i v${PINNED_VERSION}"
forge_real=$(readlink -f "$forge_bin" 2>/dev/null) || forge_real=$forge_bin

ver_out=$(forge --version 2>/dev/null) || die "could not run $forge_bin --version"
ver=$(sed -nE 's/^forge Version: +([^ ]+).*/\1/p' <<<"$ver_out" | head -1)
commit=$(sed -nE 's/^Commit SHA: +([0-9a-f]+).*/\1/p' <<<"$ver_out" | head -1)
[[ -n $ver ]] || die "could not read a version out of: ${ver_out//$'\n'/ }"
# A release whose internal version string went stale prints "<internal>-<tag>"; the tag is the identity.
ver=${ver##*-}; ver=${ver#v}

[[ $ver == "$PINNED_VERSION" ]] ||
    die "forge $ver is not the pinned v${PINNED_VERSION} - every CREATE2 address would move. Fix: foundryup -u v${PINNED_VERSION}"
[[ -n $commit ]] ||
    die "forge reports v${PINNED_VERSION} but no commit SHA - not the official release build. Fix: foundryup -i v${PINNED_VERSION}"
[[ $commit == "$PINNED_COMMIT" ]] ||
    die "forge v${PINNED_VERSION} was built from $commit, not the release commit ${PINNED_COMMIT} - a nightly or custom build. Fix: foundryup -i v${PINNED_VERSION}"

# Belt and suspenders: a foundryup-managed forge must come from the v1.8.3 tag directory, not an
# alias (stable, nightly, ...) that happens to point at the right commit today.
case $forge_real in
    "$HOME"/.foundry/versions/*)
        case $forge_real in
            */v${PINNED_VERSION}/forge | */${PINNED_VERSION}/forge) ;;
            *) die "$forge_bin resolves to $forge_real, which is not the v${PINNED_VERSION} install. Fix: foundryup -u v${PINNED_VERSION}" ;;
        esac ;;
esac

echo "OK   forge $ver ($commit) at $forge_real"
