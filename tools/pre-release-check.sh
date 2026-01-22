#!/bin/bash

# 发布前最终检查
# 执行: ./tools/pre-release-check.sh

set -e

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀 Flashcat iOS SDK 发布前检查"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 1. 检查版本号
echo "1️⃣ 版本号检查"
VERSION=$(grep "^\s*s\.version" FlashcatCore.podspec | sed 's/.*"\([^"]*\)".*/\1/')
SDK_VERSION=$(grep "internal let __sdkVersion" FlashcatCore/Sources/Versioning.swift | sed 's/.*"\([^"]*\)".*/\1/')
TAG="v$VERSION"

echo "   📦 Podspec 版本: $VERSION"
echo "   📱 SDK 版本: $SDK_VERSION"
echo "   🏷️  Git tag: $TAG"

if [ "$VERSION" = "$SDK_VERSION" ]; then
    echo "   ✅ 版本号一致"
else
    echo "   ❌ 版本号不一致！"
    exit 1
fi
echo ""

# 2. 检查 Git tag
echo "2️⃣ Git Tag 检查"
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "   ⚠️  Tag $TAG 已存在（将触发发布）"
else
    echo "   ✅ Tag $TAG 不存在（准备创建）"
fi
echo ""

# 3. 检查 CocoaPods Trunk
echo "3️⃣ CocoaPods Trunk 检查"
if pod trunk me >/dev/null 2>&1; then
    echo "   ✅ 已登录 CocoaPods Trunk"
    echo ""
    pod trunk me | head -5
else
    echo "   ❌ 未登录 CocoaPods Trunk"
    echo ""
    echo "   请运行以下命令注册："
    echo "   pod trunk register support@flashcat.com 'Flashcat'"
    echo ""
    exit 1
fi
echo ""

# 4. 检查 Git 状态
echo "4️⃣ Git 状态检查"
if [ -n "$(git status --porcelain)" ]; then
    echo "   ⚠️  有未提交的更改："
    git status --short
    echo ""
    echo "   建议提交后再发布"
else
    echo "   ✅ 工作区干净"
fi
echo ""

# 5. 检查当前分支
echo "5️⃣ 分支检查"
CURRENT_BRANCH=$(git branch --show-current)
echo "   当前分支: $CURRENT_BRANCH"

if [ "$CURRENT_BRANCH" = "publish" ]; then
    echo "   ✅ 在发布分支"
else
    echo "   ⚠️  不在发布分支（建议切换到 publish）"
fi
echo ""

# 6. 运行验证脚本
echo "6️⃣ 运行完整验证"
echo "   执行: ./tools/validate-release.sh"
echo ""
if ./tools/validate-release.sh > /tmp/validate-output.log 2>&1; then
    echo "   ✅ 所有验证通过"
else
    echo "   ❌ 验证失败，查看详情："
    tail -30 /tmp/validate-output.log
    exit 1
fi
echo ""

# 7. 检查 GitHub Secrets
echo "7️⃣ GitHub Secrets 检查"
echo "   请确认已在 GitHub 仓库配置 Secret："
echo "   https://github.com/flashcatcloud/fc-sdk-ios/settings/secrets/actions"
echo ""
echo "   Required Secret:"
echo "   - COCOAPODS_TRUNK_TOKEN"
echo ""
read -p "   已配置 GitHub Secrets? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "   ❌ 请先配置 GitHub Secrets"
    echo ""
    echo "   获取 token:"
    echo "   cat ~/.netrc | grep -A 2 trunk.cocoapods.org"
    exit 1
fi
echo "   ✅ GitHub Secrets 已确认"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 所有检查通过！准备发布"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📋 发布步骤："
echo ""
echo "1. 提交代码（如果有未提交的更改）："
echo "   git add *.podspec FlashcatCore/Sources/Versioning.swift Makefile"
echo "   git commit -m \"chore: bump version to $VERSION\""
echo "   git push origin $CURRENT_BRANCH"
echo ""
echo "2. 创建并推送 tag（自动触发发布）："
echo "   git tag $TAG"
echo "   git push origin $TAG"
echo ""
echo "3. 监控 GitHub Actions："
echo "   https://github.com/flashcatcloud/fc-sdk-ios/actions"
echo ""
echo "   预计耗时: 40-45 分钟"
echo "   - Validate Podspecs: 5 分钟"
echo "   - Build Artifacts: 10 分钟"
echo "   - Publish GitHub Release: 3 分钟"
echo "   - Publish FlashcatInternal: 2 分钟"
echo "   - Wait for CDN sync: 20 分钟 ⏰"
echo "   - Publish other modules: 5 分钟"
echo ""
echo "4. 发布后验证："
echo "   pod search FlashcatCore"
echo "   pod trunk info FlashcatCore"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
