#!/bin/bash
set -e

echo "🔍 开始验证 Flashcat CocoaPods 配置..."
echo ""

# 检查 Ruby 版本
RUBY_VERSION_MAJOR=$(ruby -e "puts RUBY_VERSION.split('.').first.to_i")
if [ "$RUBY_VERSION_MAJOR" -ge 4 ]; then
  echo "⚠️  检测到 Ruby 4.0+，需要添加 benchmark gem"
  echo "   已自动添加到 Gemfile，请运行: bundle install"
fi

# 检查 bundler 是否可用
if ! command -v bundle &> /dev/null; then
  echo "❌ 未找到 bundle 命令"
  echo "   请先安装 bundler: gem install bundler"
  exit 1
fi

# 检查 bundler 版本（尝试运行，如果失败则更新 bundler）
if ! bundle --version &> /dev/null; then
  echo "⚠️  Bundler 版本不匹配"
  echo "   正在尝试更新 bundler..."
  if command -v gem &> /dev/null; then
    bundle update --bundler 2>/dev/null || {
      echo "   请运行以下命令之一："
      echo "   - bundle update --bundler  (推荐，更新到兼容版本)"
      echo "   - gem install bundler  (安装最新版本)"
      exit 1
    }
  else
    echo "   请先安装 gem，然后运行: bundle update --bundler"
    exit 1
  fi
fi

# 检查是否已安装依赖
if [ ! -d ".bundle" ] || [ ! -f "Gemfile.lock" ]; then
  echo "📦 安装 Ruby 依赖..."
  bundle install || {
    echo "❌ 依赖安装失败"
    exit 1
  }
fi

# 1. 验证 podspecs（使用 --quick 模式跳过下载检查）
echo "1️⃣ 验证 Podspecs..."
echo "   注意：使用 --quick 模式验证语法，跳过下载和构建检查"
echo "   这对于未发布的 pod 是合适的"
echo ""

# 验证所有 podspecs（--quick 会跳过依赖下载和构建检查）
for podspec in Flashcat*.podspec; do
  if [ -f "$podspec" ]; then
    echo "  - 验证 $podspec..."
    bundle exec pod spec lint "$podspec" --allow-warnings --quick || {
      echo "❌ $podspec 验证失败"
      echo "   提示：--quick 模式会跳过依赖检查，主要验证语法和配置"
      exit 1
    }
  fi
done

echo "✅ Podspecs 验证通过"
echo ""

# 2. 检查 Git URL
echo "2️⃣ 检查 Git URL..."
if grep -r "DataDog/dd-sdk-ios" *.podspec SmokeTests/cocoapods/Podfile.src tools/release/build.sh 2>/dev/null | grep -v "^Binary"; then
  echo "❌ 发现旧的 DataDog URL"
  exit 1
fi
echo "✅ Git URL 检查通过"
echo ""

# 3. 检查依赖名称
echo "3️⃣ 检查依赖名称..."
if grep -E "DatadogCore|DatadogRUM|DatadogTrace|DatadogCrashReporting|DatadogWebViewTracking" TestUtilities.podspec 2>/dev/null | grep -v "^Binary"; then
  echo "❌ 发现旧的 Datadog 依赖名称"
  exit 1
fi
echo "✅ 依赖名称检查通过"
echo ""

# 4. 检查元数据
echo "4️⃣ 检查元数据..."
if grep "s.homepage" Flashcat*.podspec | grep -v "flashcat.cloud"; then
  echo "❌ 发现错误的 homepage"
  exit 1
fi
if grep "s.summary" Flashcat*.podspec | grep -i "datadog"; then
  echo "❌ Summary 中包含 'Datadog'"
  exit 1
fi
echo "✅ 元数据检查通过"
echo ""

# 5. 检查版本一致性（CocoaPods 和 SPM 版本对齐）
echo "5️⃣ 检查版本一致性..."

# 获取所有 podspec 的版本
echo "  - 检查所有 podspec 版本号是否一致..."
VERSIONS=$(grep "s.version" *.podspec | grep -v "s.version.to_s" | grep -v "#{s.version}" | sed 's/.*"\(.*\)".*/\1/' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -u)
VERSION_COUNT=$(echo "$VERSIONS" | wc -l | tr -d ' ')

if [ "$VERSION_COUNT" -ne 1 ]; then
  echo "❌ 发现版本号不一致："
  for podspec in *.podspec; do
    VERSION=$(grep "s.version" "$podspec" | grep -v "s.version.to_s" | grep -v "#{s.version}" | head -1 | sed 's/.*"\(.*\)".*/\1/')
    echo "   - $podspec: $VERSION"
  done
  exit 1
fi

PODSPEC_VERSION=$(echo "$VERSIONS" | head -1)
echo "  ✓ 所有 podspec 版本一致: $PODSPEC_VERSION"

# 检查是否存在对应的 git tag
GIT_TAG="v$PODSPEC_VERSION"
if git rev-parse "$GIT_TAG" >/dev/null 2>&1; then
  echo "  ✓ Git tag 存在: $GIT_TAG"
  echo "  ✓ CocoaPods 和 SPM 版本已对齐"
else
  echo "  ⚠️  Git tag 不存在: $GIT_TAG"
  echo "  提示：发布前需要创建 tag："
  echo "      git tag $GIT_TAG"
  echo "      git push origin $GIT_TAG"
  echo "  注意：SPM 通过 git tag 识别版本，必须创建 tag"
fi

echo "✅ 版本一致性检查完成"
echo ""

echo "🎉 所有验证通过！可以安全发布。"