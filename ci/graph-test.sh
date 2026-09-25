#!/usr/bin/env bash
# graph.sh passes on the tree as it is, and fails on each kind of edge it
# exists to refuse: one a feature-free manifest line adds, one only an
# Android build resolves, and a phone that prints. Each runs on a disposable
# copy of the tracked tree with its locks refreshed for the edit.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
die() { echo "graph-test.sh: $*" >&2; exit 1; }

staged() {
    local stage
    stage="$(mktemp -d)"
    (cd "$root" && git ls-files -z | xargs -0 tar cf -) | tar xf - -C "$stage"
    echo "$stage"
}

relock() {
    cargo metadata --format-version 1 >/dev/null
    cargo metadata --format-version 1 --manifest-path example-android-app/rust/Cargo.toml >/dev/null
}

expect_refusal() {
    local name="$1" message="$2" edit="$3" stage out
    stage="$(staged)"
    (
        cd "$stage"
        eval "$edit"
        relock
        if out="$(ci/graph.sh 2>&1)"; then
            die "$name: graph.sh passed"
        fi
        grep -qF "$message" <<<"$out" || die "$name: graph.sh failed without \"$message\": $out"
    )
    rm -rf "$stage"
    echo "graph-test.sh: $name is refused"
}

stage="$(staged)"
(cd "$stage" && ci/graph.sh >/dev/null) || die "graph.sh fails on the tree as it is"
rm -rf "$stage"

expect_refusal "a word crate under the Penlock pipeline" "penlock-scan reaches bitcoin-vision-words" \
    'printf "\n[target.%s.dependencies]\nbitcoin-vision-words = { path = \"../words\", version = \"0.1.0\", default-features = false }\n" "'"'"'cfg(target_os = \"android\")'"'"'" >>penlock-scan/Cargo.toml'
expect_refusal "a Penlock crate under the word pipeline" "bitcoin-vision-words reaches penlock" \
    'sed -i.bak "s|^\[dependencies\]$|[dependencies]\npenlock = { path = \"../penlock\", version = \"0.1.0\" }|" words/Cargo.toml'
expect_refusal "a phone that prints" "bitcoin-vision-mobile reaches svg2pdf" \
    'sed -i.bak "s|features = \[\"onnx\"\] }|features = [\"onnx\", \"print\"] }|" example-android-app/rust/bitcoin-vision-mobile/Cargo.toml'
expect_refusal "a switch that turns a pipeline on" "bitcoin-vision reaches penlock-scan" \
    'sed -i.bak "s|^onnx = \[\"bitcoin-vision-words?/onnx\", \"penlock-scan?/onnx\"\]|onnx = [\"bitcoin-vision-words?/onnx\", \"penlock-scan/onnx\"]|" Cargo.toml'
