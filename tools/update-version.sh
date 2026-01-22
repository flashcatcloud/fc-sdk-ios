#!/bin/bash

# Update version across all podspecs and SDK version file
# Usage: ./tools/update-version.sh <new_version>
# Example: ./tools/update-version.sh 0.2.0

set -eo pipefail

if [ $# -eq 0 ]; then
    echo "❌ Error: Version number required"
    echo ""
    echo "Usage: $0 <version>"
    echo "Example: $0 0.2.0"
    exit 1
fi

NEW_VERSION="$1"

# Validate version format (semantic versioning)
if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?$ ]]; then
    echo "❌ Error: Invalid version format"
    echo "   Expected: MAJOR.MINOR.PATCH (e.g., 0.2.0, 1.0.0-beta)"
    exit 1
fi

echo "📦 Updating version to $NEW_VERSION"
echo ""

# Count podspec files
PODSPEC_COUNT=$(find . -maxdepth 1 -name "*.podspec" | wc -l | tr -d ' ')
echo "Found $PODSPEC_COUNT podspec files"
echo ""

# Verify all podspecs have valid format before updating
echo "🔍 Validating podspec format..."
INVALID_PODSPECS=()
for podspec in *.podspec; do
    if [ -f "$podspec" ]; then
        # Check if podspec has valid s.version line
        if ! grep -q "^\s*s\.version\s*=\s*\"" "$podspec"; then
            INVALID_PODSPECS+=("$podspec")
        fi
    fi
done

if [ ${#INVALID_PODSPECS[@]} -gt 0 ]; then
    echo "❌ Error: Found podspecs with invalid format:"
    for podspec in "${INVALID_PODSPECS[@]}"; do
        echo "   - $podspec (missing or malformed 's.version = \"...\"')"
        echo "     Current content:"
        grep -A 1 "s.name" "$podspec" | head -3
    done
    echo ""
    echo "Please fix these files manually before running this script."
    echo "Expected format: s.version      = \"0.1.0\""
    exit 1
fi

echo "✅ All podspecs have valid format"
echo ""

# Update each podspec
UPDATED_COUNT=0
SKIPPED_COUNT=0

for podspec in *.podspec; do
    if [ -f "$podspec" ]; then
        # Get current version (more robust extraction)
        CURRENT_VERSION=$(grep "^\s*s\.version\s*=" "$podspec" | sed 's/.*"\([^"]*\)".*/\1/')
        
        if [ -z "$CURRENT_VERSION" ]; then
            echo "  ⚠️  Warning: Could not extract version from $podspec, skipping"
            continue
        fi
        
        if [ "$CURRENT_VERSION" != "$NEW_VERSION" ]; then
            echo "  📝 $podspec: $CURRENT_VERSION → $NEW_VERSION"
            
            # Use more specific regex that requires s.version at start of line
            perl -i -pe 's/^(\s*s\.version\s*=\s*")[^"]*("\s*)$/${1}'"$NEW_VERSION"'${2}/' "$podspec"
            
            # Verify the update
            UPDATED_VERSION=$(grep "^\s*s\.version\s*=" "$podspec" | sed 's/.*"\([^"]*\)".*/\1/')
            if [ "$UPDATED_VERSION" = "$NEW_VERSION" ]; then
                UPDATED_COUNT=$((UPDATED_COUNT + 1))
            else
                echo "     ❌ Update failed! Current version: $UPDATED_VERSION"
                exit 1
            fi
        else
            echo "  ✓ $podspec: already $NEW_VERSION"
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        fi
    fi
done

echo ""
echo "📊 Updated $UPDATED_COUNT file(s), skipped $SKIPPED_COUNT file(s)"
echo ""

# Update Versioning.swift
VERSIONING_FILE="FlashcatCore/Sources/Versioning.swift"
if [ -f "$VERSIONING_FILE" ]; then
    echo "📝 Updating SDK version in $VERSIONING_FILE..."
    
    # Check if file has valid format
    if ! grep -q "internal let __sdkVersion = \"" "$VERSIONING_FILE"; then
        echo "❌ Error: $VERSIONING_FILE has invalid format"
        echo "   Expected: internal let __sdkVersion = \"0.1.0\""
        echo "   Current content:"
        cat "$VERSIONING_FILE"
        exit 1
    fi
    
    # Update with more specific pattern
    perl -i -pe 's/(internal let __sdkVersion = ")[^"]*("\s*)$/${1}'"$NEW_VERSION"'${2}/' "$VERSIONING_FILE"
    
    # Verify the update
    SDK_VERSION=$(grep 'internal let __sdkVersion = "' "$VERSIONING_FILE" | sed 's/.*"\([^"]*\)".*/\1/')
    if [ "$SDK_VERSION" = "$NEW_VERSION" ]; then
        echo "  ✓ SDK version updated to $NEW_VERSION"
    else
        echo "  ❌ Failed to update SDK version (found: $SDK_VERSION)"
        exit 1
    fi
    echo ""
else
    echo "⚠️  Warning: $VERSIONING_FILE not found, skipping SDK version update"
    echo ""
fi

echo "✅ Version updated successfully!"
echo ""
echo "📋 Next steps:"
echo ""
echo "1. Verify changes:"
echo "   grep \"s.version\" *.podspec | grep -v \"s.version.to_s\""
echo "   cat FlashcatCore/Sources/Versioning.swift"
echo ""
echo "2. Test a podspec:"
echo "   pod spec lint FlashcatCore.podspec --allow-warnings --quick"
echo ""
echo "3. Commit changes:"
echo "   git add *.podspec FlashcatCore/Sources/Versioning.swift"
echo "   git commit -m \"chore: bump version to $NEW_VERSION\""
echo ""
echo "4. Create and push tag:"
echo "   git tag v$NEW_VERSION"
echo "   git push origin main"
echo "   git push origin v$NEW_VERSION"
echo ""
echo "5. Monitor GitHub Actions:"
echo "   https://github.com/flashcatcloud/fc-sdk-ios/actions"
echo ""
echo "💡 Both CocoaPods and SPM will use version $NEW_VERSION through git tag v$NEW_VERSION"
