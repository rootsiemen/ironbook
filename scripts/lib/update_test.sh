#!/usr/bin/env bash
# Self-test for scripts/lib/update.sh. Run: bash scripts/lib/update_test.sh
# Exits non-zero when any case fails. No network, no side effects outside
# a temporary directory.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/update.sh"

PASS=0
FAIL=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc (expected '$expected', got '$actual')"
    fi
}

# --- semver comparison (0 = newer, 1 = not newer, 2 = invalid) ---
semver_case() {
    local desc="$1" a="$2" b="$3" expected="$4"
    local code=0
    update_semver_gt "$a" "$b" >/dev/null 2>&1 || code=$?
    check "semver $desc" "$expected" "$code"
}

semver_case "patch bump" "1.2.4" "1.2.3" 0
semver_case "major bump" "2.0.0" "1.9.9" 0
semver_case "equal" "1.2.3" "1.2.3" 1
semver_case "older" "1.2.3" "1.2.4" 1
semver_case "leading v" "v1.2.4" "1.2.3" 0
semver_case "missing patch defaults to 0" "1.2" "1.1.9" 0
semver_case "release beats prerelease" "1.2.3" "1.2.3-beta" 0
semver_case "prerelease is not newer than release" "1.2.3-beta" "1.2.3" 1
semver_case "prerelease order" "1.2.3-beta" "1.2.3-alpha" 0
semver_case "invalid left" "abc" "1.2.3" 2
semver_case "invalid right" "1.2.3" "1.2.x" 2
semver_case "too many parts" "1.2.3.4" "1.2.3" 2

# --- sha256 verification ---
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT
printf 'ironbook' >"$TMPDIR_TEST/artifact.bin"
EXPECTED_HASH="$(sha256sum "$TMPDIR_TEST/artifact.bin" | cut -d' ' -f1)"

code=0
update_verify_sha256 "$TMPDIR_TEST/artifact.bin" "$EXPECTED_HASH" >/dev/null 2>&1 || code=$?
check "sha256 match" 0 "$code"

code=0
update_verify_sha256 "$TMPDIR_TEST/artifact.bin" "$(printf '%s' "$EXPECTED_HASH" | tr '[:lower:]' '[:upper:]')" >/dev/null 2>&1 || code=$?
check "sha256 uppercase expected normalizes" 0 "$code"

code=0
update_verify_sha256 "$TMPDIR_TEST/artifact.bin" "0000000000000000000000000000000000000000000000000000000000000000" >/dev/null 2>&1 || code=$?
check "sha256 mismatch fails" 1 "$code"

code=0
update_verify_sha256 "$TMPDIR_TEST/missing.bin" "$EXPECTED_HASH" >/dev/null 2>&1 || code=$?
check "sha256 missing file fails" 1 "$code"

code=0
update_verify_sha256 "$TMPDIR_TEST/artifact.bin" "not-a-hash" >/dev/null 2>&1 || code=$?
check "sha256 malformed expected fails" 1 "$code"

# --- manifest parsing + check-update command ---
cat >"$TMPDIR_TEST/manifest.json" <<'JSON'
{ "version": "1.2.0", "url": "https://example.com/ironbook-1.2.0.zip",
  "sha256": "0000000000000000000000000000000000000000000000000000000000000000" }
JSON

check "manifest version field" "1.2.0" "$(update_manifest_field "$TMPDIR_TEST/manifest.json" "version")"
check "manifest url field" "https://example.com/ironbook-1.2.0.zip" "$(update_manifest_field "$TMPDIR_TEST/manifest.json" "url")"

code=0
update_manifest_field "$TMPDIR_TEST/manifest.json" "missing" >/dev/null 2>&1 || code=$?
check "manifest missing field fails" 1 "$code"

out="$(cmd_check_update "1.0.0" "$TMPDIR_TEST/manifest.json")"
check "check-update reports newer version" "⬆ Update available: 1.0.0 -> 1.2.0" "$(printf '%s' "$out" | head -n 1)"

out="$(cmd_check_update "1.2.0" "$TMPDIR_TEST/manifest.json")"
check "check-update reports up to date" "✔ Up to date: 1.2.0 (latest: 1.2.0)" "$out"

code=0
cmd_check_update "1.0.0" "$TMPDIR_TEST/nope.json" >/dev/null 2>&1 || code=$?
check "check-update missing manifest fails" 1 "$code"

echo "update_test: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
