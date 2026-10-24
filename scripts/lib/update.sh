#!/usr/bin/env bash
#
# Update-check helpers (Phase-1 slice of #28).
#
# This library covers only the safe, side-effect-free part of the updater:
# comparing versions, reading a server-generated update manifest, and
# verifying a downloaded artifact's checksum. It deliberately does NOT
# download, replace, or roll back anything — download/apply is a later
# phase, and per the maintainer's note on #28 auto-updating only applies
# to the desktop and Android apps (other components update via Docker).
#
# Manifest contract: a flat JSON object with string values, e.g.
#   { "version": "1.2.0", "url": "https://example.com/ironbook-1.2.0.zip",
#     "sha256": "<64 hex chars>" }
# Nested objects are not parsed; `update_manifest_field` reads only
# top-level string fields. No `jq` dependency is assumed.
#
# Sourced by scripts/ironbook.sh; also sourceable standalone for tests:
#   source scripts/lib/update.sh

# update_semver_gt <a> <b>
# Returns 0 if version <a> is strictly newer than <b>, 1 if not, 2 if
# either version is malformed. A leading `v` is accepted, missing minor /
# patch parts default to 0, and a release beats its own prerelease
# (1.2.3 > 1.2.3-beta). Two prereleases compare lexically.
update_semver_gt() {
    local a_raw="${1:-}" b_raw="${2:-}"
    local a_parts b_parts a_pre b_pre

    _update_semver_split() {
        local raw="${1#v}"
        local core="${raw%%-*}"
        local pre=""
        if [[ "$raw" == *-* ]]; then
            pre="${raw#*-}"
        fi
        if [[ -z "$core" ]]; then
            return 1
        fi
        if [[ -n "$pre" && ! "$pre" =~ ^[0-9A-Za-z.-]+$ ]]; then
            return 1
        fi
        local IFS='.'
        local -a parts
        read -ra parts <<<"$core"
        if [[ "${#parts[@]}" -gt 3 ]]; then
            return 1
        fi
        local part
        for part in "${parts[@]}"; do
            if [[ ! "$part" =~ ^[0-9]+$ ]]; then
                return 1
            fi
        done
        while [[ "${#parts[@]}" -lt 3 ]]; do
            parts+=(0)
        done
        printf '%s %s %s %s' "${parts[0]}" "${parts[1]}" "${parts[2]}" "$pre"
    }

    local a_split b_split
    a_split="$(_update_semver_split "$a_raw")" || {
        echo "❌ Invalid version: $a_raw"
        return 2
    }
    b_split="$(_update_semver_split "$b_raw")" || {
        echo "❌ Invalid version: $b_raw"
        return 2
    }
    read -ra a_parts <<<"$a_split"
    read -ra b_parts <<<"$b_split"
    a_pre="${a_parts[3]:-}"
    b_pre="${b_parts[3]:-}"

    local i
    for i in 0 1 2; do
        if [[ "$((10#${a_parts[$i]}))" -gt "$((10#${b_parts[$i]}))" ]]; then
            return 0
        fi
        if [[ "$((10#${a_parts[$i]}))" -lt "$((10#${b_parts[$i]}))" ]]; then
            return 1
        fi
    done

    # Cores are equal: a release beats its prerelease.
    if [[ -z "$a_pre" && -n "$b_pre" ]]; then
        return 0
    fi
    if [[ -n "$a_pre" && -z "$b_pre" ]]; then
        return 1
    fi
    if [[ -z "$a_pre" && -z "$b_pre" ]]; then
        return 1
    fi
    if [[ "$a_pre" > "$b_pre" ]]; then
        return 0
    fi
    return 1
}

# update_verify_sha256 <file> <expected-sha256>
# Returns 0 only when the file exists and its SHA-256 matches <expected>
# (exactly 64 lowercase hex chars; uppercase input is normalized).
update_verify_sha256() {
    local file="${1:-}" expected="${2:-}"
    expected="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')"
    if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
        echo "❌ Expected SHA-256 must be 64 hex characters."
        return 1
    fi
    if [[ ! -f "$file" ]]; then
        echo "❌ File not found: $file"
        return 1
    fi
    if ! command -v sha256sum >/dev/null 2>&1; then
        echo "❌ sha256sum is not available."
        return 1
    fi
    local actual
    actual="$(sha256sum "$file" | cut -d' ' -f1)"
    if [[ "$actual" == "$expected" ]]; then
        return 0
    fi
    echo "❌ SHA-256 mismatch for $file"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    return 1
}

# update_manifest_field <manifest> <field>
# Prints the value of a top-level string field from a flat JSON manifest.
# Returns 1 when the file is missing or the field is absent.
update_manifest_field() {
    local manifest="${1:-}" field="${2:-}"
    if [[ ! -f "$manifest" ]]; then
        echo "❌ Manifest not found: $manifest"
        return 1
    fi
    local match
    match="$(grep -o "\"$field\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$manifest" | head -n 1 || true)"
    if [[ -z "$match" ]]; then
        return 1
    fi
    printf '%s' "$match" | sed -E 's/^"[^"]*"[[:space:]]*:[[:space:]]*"([^"]*)"$/\1/'
}

# cmd_check_update <current-version> <manifest>
# Reports whether the manifest's version is newer than <current-version>.
# Exit 0 for both "update available" and "up to date"; exit 1 on bad input.
# Never downloads or installs anything.
cmd_check_update() {
    local current="${1:-}" manifest="${2:-}"
    if [[ -z "$current" || -z "$manifest" ]]; then
        echo "❌ Usage: ironbook check-update <current-version> <manifest>"
        return 1
    fi
    local latest
    latest="$(update_manifest_field "$manifest" "version")" || {
        echo "❌ Manifest has no version field: $manifest"
        return 1
    }
    local cmp=0
    update_semver_gt "$latest" "$current" || cmp=$?
    if [[ "$cmp" -eq 2 ]]; then
        echo "❌ Cannot compare versions: current='$current' latest='$latest'"
        return 1
    fi
    if [[ "$cmp" -eq 0 ]]; then
        echo "⬆ Update available: $current -> $latest"
        local url
        url="$(update_manifest_field "$manifest" "url" || true)"
        if [[ -n "$url" ]]; then
            echo "  Download: $url"
        fi
        return 0
    fi
    echo "✔ Up to date: $current (latest: $latest)"
    return 0
}
