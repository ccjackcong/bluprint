#!/bin/bash
# 修复 Android Gradle 配置（解决 flutter_blue_plus 插件报错）
set -e

echo "🔧 修复 Android Gradle 配置..."

APP_GRADLE="android/app/build.gradle"
ROOT_GRADLE="android/build.gradle"

if [ -f "$APP_GRADLE" ]; then
    echo "设置 compileSdkVersion=34, targetSdkVersion=34"
    sed -i 's/compileSdkVersion [0-9]*/compileSdkVersion 34/' "$APP_GRADLE" || true
    if ! grep -q 'compileSdkVersion' "$APP_GRADLE"; then
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
    echo "✅ app/build.gradle 已更新"
fi

if [ -f "$ROOT_GRADLE" ]; then
    if ! grep -q 'ext {' "$ROOT_GRADLE"; then
        echo "在根 build.gradle 中添加 ext 属性"
        sed -i '/buildscript {/i \
ext {\
    compileSdkVersion = 34\
    targetSdkVersion = 34\
    minSdkVersion = 21\
}\n' "$ROOT_GRADLE"
        echo "✅ 根 build.gradle 已更新"
    else
        echo "✅ ext 属性已存在"
    fi
fi

echo "✅ Android Gradle 配置修复完成"
