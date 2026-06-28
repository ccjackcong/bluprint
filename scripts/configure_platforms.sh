#!/bin/bash
# 配置平台权限（兼容 bash 3.2 和 macOS sed）
# 用法: ./configure_platforms.sh [android|macos|all]
#       默认 all

set -e

echo "🔧 开始配置平台权限..."

TARGET="${1:-all}"

# ---------- 工具函数 ----------
check_file() {
    if [ ! -f "$1" ]; then
        echo "    ⚠️  文件不存在: $1"
        return 1
    fi
    return 0
}

# ⭐ 使用 awk 在包含锚点的行之前插入内容（兼容 macOS）
insert_before() {
    local file="$1"
    local anchor="$2"
    local content="$3"
    if ! grep -Fq "$anchor" "$file"; then
        echo "    ⚠️  未找到锚点 '$anchor'，跳过插入"
        return 1
    fi

    # 将 content 中的 \n 转换为真正的换行
    local content_escaped=$(echo "$content" | sed 's/\\n/\
/g')

    # 使用 awk 在第一次包含 anchor 的行之前插入 content_escaped
    awk -v anchor="$anchor" -v content="$content_escaped" '
        {
            if (!inserted && index($0, anchor) > 0) {
                print content
                inserted = 1
            }
            print
        }
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"

    # 删除可能的备份（如果存在）
    rm -f "${file}.bak"
    return 0
}

# ---------- Android 配置 ----------
configure_android() {
    echo "  → 配置 Android 权限..."

    local ANDROID_MANIFEST="android/app/src/main/AndroidManifest.xml"
    local PERMS_FILE="platform_config/android_permissions.txt"

    if ! check_file "$ANDROID_MANIFEST"; then
        echo "    ⚠️  跳过 Android 配置（文件不存在）"
        return
    fi

    if ! check_file "$PERMS_FILE"; then
        echo "    ⚠️  跳过 Android 配置（权限文件不存在）"
        return
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        line_trimmed="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "$line_trimmed" ] && continue
        echo "$line_trimmed" | grep -q '^#' && continue

        if echo "$line_trimmed" | grep -q 'android:name="'; then
            perm_name=$(echo "$line_trimmed" | sed -n 's/.*android:name="\([^"]*\)".*/\1/p')
            if [ -n "$perm_name" ]; then
                if grep -q "android:name=\"$perm_name\"" "$ANDROID_MANIFEST"; then
                    echo "    ✅ 权限 $perm_name 已存在"
                else
                    insert_before "$ANDROID_MANIFEST" "</manifest>" "$line_trimmed"
                    echo "    ➕ 添加权限 $perm_name"
                fi
            fi
        fi
    done < "$PERMS_FILE"

    # usesCleartextTraffic
    if ! grep -q 'android:usesCleartextTraffic="true"' "$ANDROID_MANIFEST"; then
        sed -i.bak 's|<application|<application android:usesCleartextTraffic="true"|' "$ANDROID_MANIFEST"
        rm -f "${ANDROID_MANIFEST}.bak"
        echo "    ✅ usesCleartextTraffic 已启用"
    else
        echo "    ✅ usesCleartextTraffic 已存在"
    fi

    # tools namespace
    if ! grep -q 'xmlns:tools="http://schemas.android.com/tools"' "$ANDROID_MANIFEST"; then
        sed -i.bak 's|<manifest |<manifest xmlns:tools="http://schemas.android.com/tools" |' "$ANDROID_MANIFEST"
        rm -f "${ANDROID_MANIFEST}.bak"
        echo "    ✅ tools namespace 已添加"
    else
        echo "    ✅ tools namespace 已存在"
    fi
}

# ---------- macOS 配置 ----------
configure_macos() {
    echo "  → 配置 macOS entitlements..."

    local ENT_FILE="platform_config/macos_entitlements.txt"
    if ! check_file "$ENT_FILE"; then
        echo "    ⚠️  跳过 macOS 配置（entitlements 文件不存在）"
        return
    fi

    # 解析 key-value（不使用关联数组，用普通数组）
    KEYS=()
    VALUES=()
    current_key=""
    while IFS= read -r line || [ -n "$line" ]; do
        line_trimmed="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "$line_trimmed" ] && continue
        echo "$line_trimmed" | grep -q '^#' && continue

        if echo "$line_trimmed" | grep -q '^<key>'; then
            current_key=$(echo "$line_trimmed" | sed 's/^<key>\(.*\)<\/key>$/\1/')
        elif [ -n "$current_key" ] && echo "$line_trimmed" | grep -q '^<\(true\|false\)/>$'; then
            KEYS+=("$current_key")
            VALUES+=("$line_trimmed")
            current_key=""
        fi
    done < "$ENT_FILE"

    if [ ${#KEYS[@]} -eq 0 ]; then
        echo "    ⚠️  entitlements 解析失败或为空"
        return
    fi

    for ENTITLEMENTS in "macos/Runner/DebugProfile.entitlements" "macos/Runner/Release.entitlements"; do
        if check_file "$ENTITLEMENTS"; then
            for idx in "${!KEYS[@]}"; do
                key="${KEYS[$idx]}"
                value="${VALUES[$idx]}"
                if grep -q "<key>$key</key>" "$ENTITLEMENTS"; then
                    echo "    ✅ $key 已存在"
                else
                    insert_before "$ENTITLEMENTS" "</dict>" "    <key>$key</key>\n    $value"
                    echo "    ➕ 添加 entitlements: $key"
                fi
            done
        fi
    done

    # Info.plist 蓝牙说明
    local INFO_PLIST="macos/Runner/Info.plist"
    if check_file "$INFO_PLIST"; then
        echo "  → 配置 macOS Info.plist 蓝牙说明..."
        if ! grep -q 'NSBluetoothAlwaysUsageDescription' "$INFO_PLIST"; then
            insert_before "$INFO_PLIST" "</dict>" "    <key>NSBluetoothAlwaysUsageDescription</key>\n    <string>此应用需要蓝牙权限以连接标签打印机</string>\n    <key>NSBluetoothPeripheralUsageDescription</key>\n    <string>此应用需要蓝牙权限以连接标签打印机</string>"
            echo "    ✅ 蓝牙使用说明已添加"
        else
            echo "    ✅ 蓝牙使用说明已存在"
        fi
    fi
}

# ---------- 主入口 ----------
case "$TARGET" in
    android)
        configure_android
        ;;
    macos)
        configure_macos
        ;;
    all|*)
        configure_android
        configure_macos
        ;;
esac

echo "✅ 所有平台配置完成"
