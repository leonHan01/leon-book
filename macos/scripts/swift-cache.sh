#!/bin/zsh

# Stable across reboots/TMPDIR changes, isolated across checkouts and build uses.
# Sourced after MACOS_DIR is set. This helper never creates directories.
leonbook_build_root() {
    local purpose="${1:-default}" project_key cache_base
    project_key="$(print -rn -- "${MACOS_DIR:A}" | /usr/bin/shasum -a 256)"
    project_key="${project_key[1,16]}"
    cache_base="${LEON_BOOK_BUILD_CACHE_DIR:-${HOME}/Library/Caches/leon-book}"
    print -r -- "${cache_base%/}/${project_key}/swiftpm-${purpose}"
}
