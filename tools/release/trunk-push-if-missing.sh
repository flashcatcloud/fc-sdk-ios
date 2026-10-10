#!/bin/zsh

# Usage:
# $ ./tools/release/trunk-push-if-missing.sh <podspec file>
# Pushes the podspec to CocoaPods trunk unless trunk already has its version.
#
# A trunk push can be accepted by trunk and still fail on the client (e.g. "Calling the GitHub commit
# API timed out"). Re-running the release would then push the same version again and fail on
# "Unable to accept duplicate entry", blocking every pod after it. Skipping versions that trunk
# already has makes re-running the release safe.
#
# ENVs:
# - COCOAPODS_TRUNK_TOKEN: trunk session token used by `pod trunk push`.
# - DRY_RUN: Set to '1' to only report whether the podspec would be pushed or skipped.

set -eo pipefail

PODSPEC="$1"
if [[ -z "$PODSPEC" || ! -f "$PODSPEC" ]]; then
    echo "Usage: $(basename "$0") <podspec file>"
    exit 1
fi

POD_NAME=$(grep -E '^\s*s\.name\s*=' "$PODSPEC" | awk -F '"' '{print $2}')
POD_VERSION=$(grep -E '^\s*s\.version\s*=' "$PODSPEC" | awk -F '"' '{print $2}')
if [[ -z "$POD_NAME" || -z "$POD_VERSION" ]]; then
    echo "Error: cannot read s.name or s.version from '$PODSPEC'"
    exit 1
fi

# Prints "yes" or "no" when trunk answers, or "unknown" when it cannot be asked. An unknown answer
# never skips the push: a duplicate push fails loudly, a wrongly skipped one would go unnoticed.
trunk_has_version() {
    local body http_code
    body=$(mktemp)
    http_code=$(curl -s -o "$body" -w '%{http_code}' --max-time 30 --retry 3 \
        "https://trunk.cocoapods.org/api/v1/pods/$POD_NAME") || http_code="000"

    case "$http_code" in
        200)
            ruby -rjson -e '
                versions = JSON.parse(File.read(ARGV[0])).fetch("versions", []).map { |v| v["name"] }
                puts(versions.include?(ARGV[1]) ? "yes" : "no")
            ' "$body" "$POD_VERSION" 2>/dev/null || echo "unknown"
            ;;
        404) echo "no" ;; # the pod was never published
        *) echo "unknown" ;;
    esac
    rm -f "$body"
}

STATUS=$(trunk_has_version)
echo "▸ trunk has $POD_NAME ($POD_VERSION): $STATUS"

if [[ "$STATUS" == "yes" ]]; then
    echo "▸ $POD_NAME ($POD_VERSION) is already published, skipping the push."
    exit 0
fi

if [[ "$DRY_RUN" == "1" || "$DRY_RUN" == "true" ]]; then
    echo "▸ DRY_RUN: would run 'pod trunk push $PODSPEC --allow-warnings --synchronous'"
    exit 0
fi

OUTPUT=$(mktemp)
set +e
bundle exec pod trunk push "$PODSPEC" --allow-warnings --synchronous 2>&1 | tee "$OUTPUT"
PUSH_EXIT_CODE=${pipestatus[1]}
set -e

if [[ $PUSH_EXIT_CODE -ne 0 ]] && grep -q "Unable to accept duplicate entry" "$OUTPUT"; then
    # Trunk got this version between the check above and the push (or the check could not reach trunk).
    echo "▸ $POD_NAME ($POD_VERSION) is already published, treating the push as done."
    PUSH_EXIT_CODE=0
fi

rm -f "$OUTPUT"
exit $PUSH_EXIT_CODE
