#!/usr/bin/env bash
# Packages every crate of this workspace and tests each package as it would
# be installed: from its own extracted archive, offline, with nothing of the
# app tree beside it.
#
# The crates carry `publish = false`, so that nothing here can be pushed to
# crates.io by accident, and `cargo package --workspace` — the one way to
# package crates that depend on each other — refuses any crate so marked. So
# the packaging runs on a disposable copy of the tracked tree in which that
# line, and only that line, is dropped from each manifest. The checked-in
# manifests keep the guard; this script fails if one has lost it, or if the
# copy differs from the tree in any other way.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
die() { echo "package.sh: $*" >&2; exit 1; }

members=$(cd "$root" && cargo metadata --no-deps --format-version 1 --locked |
    python3 -c 'import json, sys, os
m = json.load(sys.stdin)
root = m["workspace_root"]
for p in m["packages"]:
    print(os.path.relpath(p["manifest_path"], root))')
[ -n "$members" ] || die "no workspace members found"

(cd "$root" && git ls-files -z | xargs -0 tar cf -) | tar xf - -C "$stage"
for manifest in $members; do
    grep -qx 'publish = false' "$root/$manifest" || die "$manifest has lost publish = false"
    grep -vx 'publish = false' "$root/$manifest" >"$stage/$manifest"
done
# Tracked files only, and the manifests differ from the tree by that one line.
for manifest in $members; do
    diff <(grep -vx 'publish = false' "$root/$manifest") "$stage/$manifest" >/dev/null ||
        die "the staged $manifest differs from the tree beyond the publish line"
done

cd "$stage"
cargo package --locked --workspace
cd target/package
for crate in *.crate; do
    for licence in LICENSE LICENSE-APACHE; do
        tar tzf "$crate" | grep -qx "${crate%.crate}/$licence" || die "$crate does not carry $licence"
    done
    tar xzf "$crate"
done

(cd bitcoin-vision-core-0.1.0 && cargo test --offline --locked --all-features)

# A packaged lock names this workspace's other crates as registry crates; the
# patches point them at the packages just built instead, and may drop those
# entries' registry source and checksum and nothing else.
siblings="bitcoin-vision-core bitcoin-vision-forms bitcoin-vision-words penlock penlock-scan"
test_on_siblings() {
    (
        cd "$1"
        cp Cargo.lock Cargo.lock.packaged
        patches=()
        for sibling in $siblings; do
            grep -qx "name = \"$sibling\"" Cargo.lock || continue
            patches+=(--config "patch.crates-io.$sibling.path='../$sibling-0.1.0'")
        done
        cargo test --offline --all-features "${patches[@]}"
        awk -v siblings=" $siblings " '/^name = /{name = $3; gsub(/"/, "", name); ours = index(siblings, " " name " ")}
             !(ours && /^(source|checksum) = /)' Cargo.lock.packaged >Cargo.lock.expected
        diff Cargo.lock.expected Cargo.lock || die "$1: the patches moved more of the lock than the siblings' entries"
    )
}
test_on_siblings bitcoin-vision-forms-0.1.0
test_on_siblings bitcoin-vision-words-0.1.0
test_on_siblings penlock-0.1.0
test_on_siblings penlock-scan-0.1.0
test_on_siblings bitcoin-vision-0.1.0
echo "package.sh: every crate packages, carries its licences, and passes its own tests"
