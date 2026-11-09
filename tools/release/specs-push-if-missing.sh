#!/bin/zsh

# Usage:
# $ ./tools/release/specs-push-if-missing.sh <podspec file>
# Pushes the podspec to the Flashcat CocoaPods specs repository unless it already has that version.
#
# Customers add the repository as a source next to the CocoaPods CDN:
#   source 'https://github.com/flashcatcloud/fc-sdk-ios-specs.git'
#   source 'https://cdn.cocoapods.org/'
# Dependencies that are not ours (KSCrash, ...) still resolve from the CDN, so lint uses both sources.
#
# Skipping versions that are already in the repository makes re-running a release safe.
#
# ENVs:
# - SPECS_REPO_URL: git URL of the specs repository (default: the GitHub repository over SSH).
#   The job must be able to push to it, e.g. with a deploy key in GIT_SSH_COMMAND.
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

REPO_NAME="fc-sdk-ios-specs"
SPECS_REPO_URL="${SPECS_REPO_URL:-git@github.com:flashcatcloud/fc-sdk-ios-specs.git}"
REPO_DIR="${CP_HOME_DIR:-$HOME/.cocoapods}/repos/$REPO_NAME"

if [[ -d "$REPO_DIR" ]]; then
    bundle exec pod repo update "$REPO_NAME"
else
    bundle exec pod repo add "$REPO_NAME" "$SPECS_REPO_URL"
fi

if [[ -d "$REPO_DIR/$POD_NAME/$POD_VERSION" ]]; then
    echo "▸ $POD_NAME ($POD_VERSION) is already in $REPO_NAME, skipping the push."
    exit 0
fi

if [[ "$DRY_RUN" == "1" || "$DRY_RUN" == "true" ]]; then
    echo "▸ DRY_RUN: would push $PODSPEC to $REPO_NAME"
    exit 0
fi

bundle exec pod repo push "$REPO_NAME" "$PODSPEC" \
    --allow-warnings \
    --use-json \
    --sources="$REPO_NAME,https://cdn.cocoapods.org/"
