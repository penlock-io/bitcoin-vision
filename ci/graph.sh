#!/usr/bin/env bash
# The layers as resolved, not as declared: core under forms, forms under both
# pipelines, neither pipeline under the other, and the facade over both with
# nothing under it reaching back. A manifest can look right
# while a feature, a platform-specific table or a transitive dependency pulls a
# sibling in, so each check reads the dependency tree cargo resolves with every
# feature on, for every target.
#
# The phone is checked with the features it is built with: it reads forms and
# never prints them, so no PDF writer may reach it.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

reaches() {
    cargo tree --locked --edges normal,build --prefix none --format '{p}' "$@" |
        sed 's/ .*//' | sort -u
}

# The crate must appear in its own tree: a cargo tree that failed prints
# nothing, and nothing reaches no forbidden crate.
refuse() {
    local what="$1" found="$2"
    shift 2
    if ! grep -qx "$what" <<<"$found"; then
        echo "graph.sh: could not read the tree of $what" >&2
        fail=1
        return
    fi
    for crate in "$@"; do
        if grep -qx "$crate" <<<"$found"; then
            echo "graph.sh: $what reaches $crate" >&2
            fail=1
        fi
    done
}

cd "$root"
refuse "bitcoin-vision-core" "$(reaches --target all --all-features -p bitcoin-vision-core)" \
    bitcoin-vision-forms bitcoin-vision-words penlock penlock-scan bitcoin-vision
refuse "bitcoin-vision-forms" "$(reaches --target all --all-features -p bitcoin-vision-forms)" \
    bitcoin-vision-words penlock penlock-scan bitcoin-vision
refuse "bitcoin-vision-words" "$(reaches --target all --all-features -p bitcoin-vision-words)" \
    penlock penlock-scan bitcoin-vision
refuse "penlock-scan" "$(reaches --target all --all-features -p penlock-scan)" \
    bitcoin-vision-words bitcoin-vision
refuse "penlock" "$(reaches --target all --all-features -p penlock)" \
    bitcoin-vision-words bitcoin-vision-core bitcoin-vision-forms penlock-scan bitcoin-vision

# The facade's shared switches forward to whichever pipelines are on and
# turn neither on themselves.
refuse "bitcoin-vision" "$(reaches --target all --no-default-features --features onnx,print,bundled-models -p bitcoin-vision)" \
    bitcoin-vision-words penlock-scan

phone="$(reaches --manifest-path example-android-app/rust/Cargo.toml \
    --target aarch64-linux-android -p bitcoin-vision-mobile)"
refuse "bitcoin-vision-mobile" "$phone" svg2pdf pdf-writer

[ "$fail" = 0 ] && echo "graph.sh: core, forms, two sibling pipelines under one facade, and a phone that does not print"
exit "$fail"
