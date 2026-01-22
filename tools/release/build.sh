#!/bin/zsh

# Usage:
# $ ./tools/release/build.sh -h
# Builds artifacts for specified tag.

# Options:
#   --tag: The tag to release.
#   --artifacts-path: Path to store artifacts.
#   --platforms: Comma-separated platforms to build xcframeworks for ('iOS' | 'tvOS' | 'iOS,tvOS').

set -eo pipefail
source ./tools/utils/argparse.sh
source ./tools/utils/echo-color.sh

set_description "Builds artifacts for specified tag."
define_arg "tag" "" "The tag to release." "string" "true" 
define_arg "artifacts-path" "" "Path to store artifacts." "string" "true"
define_arg "platforms" "iOS,tvOS" "Comma-separated platforms to build xcframeworks for ('iOS' | 'tvOS' | 'iOS,tvOS')." "string" "false"

check_for_help "$@"
parse_args "$@"

ARTIFACTS_PATH="$artifacts_path"
REPO_CLONE_PATH="$ARTIFACTS_PATH/fc-sdk-ios"
XCF_DIR_WITH_ARM64E="Flashcat-with-arm64e.xcframework"
XCF_DIR_WITHOUT_ARM64E="Flashcat.xcframework"
XCF_ZIP_NAME_WITH_ARM64E="Flashcat-with-arm64e.xcframework.zip"
XCF_ZIP_NAME="Flashcat.xcframework.zip"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Clone a fresh version of the repo to the artifacts path to ensure that release tools
# operate on a clean version of the repo, unaltered by any configuration changes.
clone_repo () {
    echo_subtitle "Clone repo for '$tag' into '$ARTIFACTS_PATH'"
    # Use HTTPS URL instead of SSH to avoid authentication issues
    git clone --depth 1 --branch $tag --single-branch https://github.com/flashcatcloud/fc-sdk-ios.git $REPO_CLONE_PATH
}

# Create XCFrameworks for the repo clone using release tools from the current repo.
create_xcframeworks () {
    echo_subtitle "Create XCFramework in '$ARTIFACTS_PATH'"
    local platform_args=()
    if [[ "$platforms" == *"iOS"* ]]; then
        platform_args+=(--ios)
    fi
    if [[ "$platforms" == *"tvOS"* ]]; then
        platform_args+=(--tvos)
    fi

    "$SCRIPT_DIR/build-xcframeworks.sh" --repo-path "$REPO_CLONE_PATH" \
        ${platform_args[@]} \
        --output-path "$ARTIFACTS_PATH/$XCF_DIR_WITH_ARM64E"

    echo_info "Contents of '$ARTIFACTS_PATH/$XCF_DIR_WITH_ARM64E':"
    ls "$ARTIFACTS_PATH/$XCF_DIR_WITH_ARM64E"
}

# Creates zip archive of the original XCFramework (with arm64e).
create_zip_with_arm64e () {
    echo_subtitle "Create archive with arm64e"
    (cd "$ARTIFACTS_PATH" && zip -r -q "$XCF_ZIP_NAME_WITH_ARM64E" "$XCF_DIR_WITH_ARM64E")
    echo_info "Created:" "$XCF_ZIP_NAME_WITH_ARM64E"
}

# Removes arm64e slices from the XCFramework and creates a new version without arm64e.
remove_arm64e_slices () {
    echo_subtitle "Remove arm64e slices"

    # Copy XCFramework to new directory
    cp -R "$ARTIFACTS_PATH/$XCF_DIR_WITH_ARM64E" "$ARTIFACTS_PATH/$XCF_DIR_WITHOUT_ARM64E"

    # Process the copy to remove arm64e
    "$SCRIPT_DIR/remove-arm64e-from-xcframework.sh" \
        --xcframework "$ARTIFACTS_PATH/$XCF_DIR_WITHOUT_ARM64E"

    # Create zip without arm64e
    (cd "$ARTIFACTS_PATH" && zip -r -q "$XCF_ZIP_NAME" "$XCF_DIR_WITHOUT_ARM64E")
    echo_info "Created:" "$XCF_ZIP_NAME"
}

rm -rf "$ARTIFACTS_PATH"
mkdir -p "$ARTIFACTS_PATH"

clone_repo
create_xcframeworks
create_zip_with_arm64e
remove_arm64e_slices

# Cleanup:
rm -rf "$ARTIFACTS_PATH/$XCF_DIR_WITH_ARM64E"
rm -rf "$ARTIFACTS_PATH/$XCF_DIR_WITHOUT_ARM64E"

echo ""
echo_succ "Success. Artifacts ready in '$ARTIFACTS_PATH':"
echo ""
echo_info "Original (with arm64e):" "$XCF_ZIP_NAME_WITH_ARM64E"
echo_info "Modified (without arm64e):" "$XCF_ZIP_NAME"
echo ""
ls -lh "$ARTIFACTS_PATH"
