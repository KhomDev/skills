#!/usr/bin/env bash
# setup_fuzz_profile.sh — Create a [profile.fuzz] in foundry.toml that disables
# via_ir when possible, falling back to via_ir with optimizer_runs=0 when the
# codebase requires IR (stack too deep).
#
# This exists because via_ir causes Medusa's branch-level coverage to be
# deflated: the IR optimizer merges/eliminates branches, so reported coverage
# is lower than actual source-level coverage.
#
# Usage: setup_fuzz_profile.sh <PROJECT_ROOT>
#
# Output (stdout, last line):
#   FUZZ_PROFILE=no-ir        — compiled without via_ir, coverage is accurate
#   FUZZ_PROFILE=ir-no-opt    — needs via_ir but optimizer_runs=0, ~10% deflation
#   FUZZ_PROFILE=default      — both attempts failed, using default profile
#
# Exit codes:
#   0 — fuzz profile created (or not needed)
#   1 — could not create a working fuzz profile, fall back to default

set -euo pipefail

# Normalize to an absolute path. The build probes below `cd "$PROJECT_ROOT"`, after which a
# relative PROJECT_ROOT would no longer resolve — the script documents `setup_fuzz_profile.sh
# <PROJECT_ROOT>` and SKILL.md Step 8.0 passes it a relative path, so this is the common case.
PROJECT_ROOT="$(cd "${1:-.}" && pwd)"

if [ ! -f "$PROJECT_ROOT/foundry.toml" ]; then
    echo "ERROR: foundry.toml not found in $PROJECT_ROOT"
    exit 1
fi

TOML="$PROJECT_ROOT/foundry.toml"

# ――――――――――――――――――――――――― Check if via_ir is enabled ―――――――――――――――――――――――――

# Match via_ir = true or via-ir = true (TOML allows both)
if ! grep -qE '^\s*via[_-]ir\s*=\s*true' "$TOML"; then
    echo "via_ir is not enabled — no fuzz profile needed."
    echo "FUZZ_PROFILE=no-ir"
    exit 0
fi

echo "via_ir = true detected in foundry.toml."

# ――――――――――――――――――――――――― Check for existing fuzz profile ―――――――――――――――――――――――――

if grep -qE '^\[profile\.fuzz\]' "$TOML"; then
    echo "[profile.fuzz] already exists in foundry.toml — skipping creation."

    # A second [profile.fuzz] table is a TOML duplicate-key error, so an existing profile can
    # never be repaired by appending another one — it can only be probed. Report what it
    # actually is, and never claim a mode that has not compiled.
    if cd "$PROJECT_ROOT" && FOUNDRY_PROFILE=fuzz forge build 2>/dev/null; then
        if grep -A5 '^\[profile\.fuzz\]' "$TOML" | grep -qE 'via[_-]ir\s*=\s*false'; then
            echo "Existing fuzz profile has via_ir = false."
            echo "FUZZ_PROFILE=no-ir"
        else
            echo "Existing fuzz profile does not disable via_ir."
            echo "FUZZ_PROFILE=ir-no-opt"
        fi
        exit 0
    fi

    echo "Existing fuzz profile does not compile — falling back to the default profile."
    echo "FUZZ_PROFILE=default"
    exit 1
fi

# ――――――――――――――――――――――――― Attempt 1: Disable via_ir ―――――――――――――――――――――――――

echo ""
echo "Attempt 1: Adding [profile.fuzz] with via_ir = false ..."

# Remove any previous fuzz profile block we may have partially written
# (defensive — only removes our marker-bounded block)
sed -i.bak '/^# >>> fizz fuzz profile/,/^# <<< fizz fuzz profile/d' "$TOML"
rm -f "$TOML.bak"

cat >> "$TOML" <<'FUZZ_BLOCK'

# >>> fizz fuzz profile
[profile.fuzz]
via_ir = false
# <<< fizz fuzz profile
FUZZ_BLOCK

echo "Trying: FOUNDRY_PROFILE=fuzz forge build ..."
cd "$PROJECT_ROOT"
BUILD_OUTPUT=$(FOUNDRY_PROFILE=fuzz forge build 2>&1) && BUILD_EXIT=0 || BUILD_EXIT=$?

if [ "$BUILD_EXIT" -eq 0 ]; then
    echo "Compilation succeeded without via_ir."
    echo "FUZZ_PROFILE=no-ir"
    exit 0
fi

# Check if it's a stack-too-deep error
if echo "$BUILD_OUTPUT" | grep -qi "stack too deep\|Stack too deep"; then
    echo "Stack too deep — codebase requires via_ir."
else
    echo "Build failed (not stack-too-deep). Output:"
    echo "$BUILD_OUTPUT" | tail -20
    echo ""
    echo "Attempting fallback anyway..."
fi

# ――――――――――――――――――――――――― Attempt 2: via_ir + optimizer_runs=0 ―――――――――――――――――――――――――

echo ""
echo "Attempt 2: [profile.fuzz] with via_ir = true, optimizer_runs = 0 ..."

# Replace the fuzz profile block
sed -i.bak '/^# >>> fizz fuzz profile/,/^# <<< fizz fuzz profile/d' "$TOML"
rm -f "$TOML.bak"

cat >> "$TOML" <<'FUZZ_BLOCK'

# >>> fizz fuzz profile
[profile.fuzz]
via_ir = true
optimizer = false
optimizer_runs = 0
# <<< fizz fuzz profile
FUZZ_BLOCK

echo "Trying: FOUNDRY_PROFILE=fuzz forge build ..."
BUILD_OUTPUT=$(FOUNDRY_PROFILE=fuzz forge build 2>&1) && BUILD_EXIT=0 || BUILD_EXIT=$?

if [ "$BUILD_EXIT" -eq 0 ]; then
    echo "Compilation succeeded with via_ir + optimizer disabled."
    echo "FUZZ_PROFILE=ir-no-opt"
    exit 0
fi

# ――――――――――――――――――――――――― Both failed ―――――――――――――――――――――――――

echo ""
echo "Both attempts failed. Removing fuzz profile block."
sed -i.bak '/^# >>> fizz fuzz profile/,/^# <<< fizz fuzz profile/d' "$TOML"
rm -f "$TOML.bak"

echo "Build output from last attempt:"
echo "$BUILD_OUTPUT" | tail -20
echo ""
echo "Falling back to default profile. Coverage numbers will be deflated."
echo "FUZZ_PROFILE=default"
exit 1
