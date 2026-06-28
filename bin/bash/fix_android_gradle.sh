#!/bin/bash
# 修复 Android Gradle 配置，确保 compileSdkVersion 等属性正确
set -e

echo "🔧 修复 Android Gradle 配置..."

APP_GRADLE="android/app/build.gradle"
ROOT_GRADLE="android/build.gradle"

# 1. 设置 app/build.gradle 中的 compileSdkVersion 和 targetSdkVersion
if [ -f "$APP_GRADLE" ]; then
    echo "  设置 compileSdkVersion=34, targetSdkVersion=34"
    if grep -q 'compileSdkVersion' "$APP_GRADLE"; then
        sed -i 's/compileSdkVersion [0-9]*/compileSdkVersion 34/' "$APP_GRADLE"
    else
        sed -i '/android {/a \    compileSdkVersion 34' "$APP_GRADLE"
    fi
    if grep -q 'targetSdkVersion' "$APP_GRADLE"; then
        sed -i 's/targetSdkVersion [0-9]*/targetSdkVersion 34/' "$APP_GRADLE"
    else
        sed -i '/android {/a \    targetSdkVersion 34' "$APP_GRADLE"
    fi
    if ! grep -q 'minSdkVersion' "$APP_GRADLE"; then
        sed -i '/android {/a \    minSdkVersion 21' "$APP_GRADLE"
    fi
    echo "  ✅ app/build.gradle 已更新"
else
    echo "  ⚠️  $APP_GRADLE 不存在，跳过"
fi

# 2. 在根 build.gradle 中添加 ext 属性（如果不存在）
if [ -f "$ROOT_GRADLE" ]; then
    if ! grep -q 'ext {' "$ROOT_GRADLE"; then
        echo "  在根 build.gradle 中添加 ext 属性"
        sed -i '/buildscript {/i \
ext {\n\
    compileSdkVersion = 34\n\
    targetSdkVersion = 34\n\
    minSdkVersion = 21\n\
}\n' "$ROOT_GRADLE"
        echo "  ✅ 根 build.gradle 已更新"
    else
        echo "  ✅ ext 属性已存在"
    fi
else
    echo "  ⚠️  $ROOT_GRADLE 不存在，跳过"
fi

echo "✅ Android Gradle 配置修复完成"
