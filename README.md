# SANJOY 打印中转 App

> 接收企业微信自建应用 Web 端编码后的打印字节流，通过 BLE 发送到标签打印机。

## 为什么需要这个 App？

企业微信（以及微信）自建应用运行在内置 WebView 中，**不支持 WebBLE 标准 API**，无法直接从 H5 页面调用蓝牙打印机。这个 App 充当 HTTP → BLE 的桥接层：

```
┌─ 企业微信 ───────────────────┐         ┌─ 打印中转 App ────────────┐
│                               │         │                           │
│  自建应用 Web 页面              │  HTTP   │  本地 HTTP Server          │
│  (企微内置浏览器, 无 WebBLE)    │◄──────►│  (127.0.0.1:15987)         │
│                               │         │           ↓               │
│  点击"打印"→ base64 数据 ──────►│────────►│   BLE 分包写入(20字节/包)  │
│                               │         │           ↓               │
│                               │         │   🏷️ 标签打印机            │
└───────────────────────────────┘         └───────────────────────────┘
```

**API 端点：**

| 方法 | 路径 | 说明 |
|------|------|------|
| `POST` | `/print` | 发送打印任务 `{"data":"<base64>", "copies":1}` |
| `GET` | `/status` | 查询打印机连接状态 |
| `GET` | `/health` | 健康检查 |

---

## 1. 安装 Flutter 开发环境（macOS）

### 1.1 安装 Flutter SDK

```bash
# 方式一：Homebrew 安装（推荐）
brew install --cask flutter

# 方式二：手动下载
# 访问 https://docs.flutter.dev/get-started/install/macos
# 下载最新稳定版 flutter_macos_*.zip
# 解压到你想要的目录，例如 ~/development/flutter
# 添加到 PATH：
export PATH="$PATH:$HOME/development/flutter/bin"
```

### 1.2 验证环境

```bash
flutter doctor
```

确保以下项目为 ✅：
- Flutter SDK
- Android toolchain（如果打包 APK）
- Xcode（如果打包 macOS app）
- Chrome（用于 Web 调试）

### 1.3 常见问题

| 问题 | 解决 |
|------|------|
| `Android toolchain` ❌ | `flutter doctor --android-licenses` 并同意所有条款 |
| `Xcode installation is incomplete` ❌ | 打开 Xcode → Preferences → Locations → Command Line Tools 选择 Xcode 版本 |
| `CocoaPods` ❌ | `sudo gem install cocoapods` |

---

## 2. 克隆 & 初始化项目

```bash
cd /path/to/sanjoyapp/bluprint

# 安装 Flutter 依赖
flutter pub get

# 验证项目能正确编译
flutter analyze
```

---

## 3. 平台配置

### 3.1 Android

#### 权限配置

编辑 `android/app/src/main/AndroidManifest.xml`，在 `<manifest>` 标签内添加：

```xml
<!-- 蓝牙相关权限 -->
<uses-permission android:name="android.permission.BLUETOOTH" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />

<!-- BLE 扫描需要定位权限（Android < 12） -->
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />

<!-- 网络权限（HTTP Server） -->
<uses-permission android:name="android.permission.INTERNET" />

<!-- Android 12+ 声明不需要位置信息来扫描蓝牙 -->
<uses-permission
    android:name="android.permission.BLUETOOTH_SCAN"
    android:usesPermissionFlags="neverForLocation"
    tools:targetApi="s" />
<uses-permission
    android:name="android.permission.BLUETOOTH_CONNECT"
    tools:targetApi="s" />
```

并在 `<application>` 标签中添加：

```xml
android:usesCleartextTraffic="true"
```

> 详细配置参见 `platform_config/android_permissions.txt`

#### 构建配置

编辑 `android/app/build.gradle`，确保：
- `minSdkVersion` >= 21（BLE 最低要求）
- 如需 64 位支持：在 `android/defaultConfig` 下已自动包含

### 3.2 macOS

#### 权限配置

编辑 `macos/Runner/DebugProfile.entitlements` 和 `macos/Runner/Release.entitlements`：

```xml
<key>com.apple.security.device.bluetooth</key>
<true/>
<key>com.apple.security.network.server</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

#### Info.plist 蓝牙权限说明

编辑 `macos/Runner/Info.plist`，添加：

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>此应用需要蓝牙权限以连接标签打印机</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>此应用需要蓝牙权限以连接标签打印机</string>
```

> 首次运行时会弹出"允许蓝牙访问"系统对话框，点击允许。

> Mac 需 2012 年及之后机型（内置 BLE 4.0 模块）

---

## 4. 测试运行

### 4.1 在 Chrome 中调试（最快）

```bash
flutter run -d chrome
```

> Web 模式下 **BLE 不可用**，仅用于 UI 调试。真实打印需要在真机/模拟器上运行。

### 4.2 在 Android 真机上调试

```bash
# 1. 手机开启"开发者选项"和"USB 调试"
# 2. USB 连接 Mac
# 3. 检查设备是否识别
flutter devices

# 4. 运行
flutter run -d <device_id>
```

### 4.3 在 macOS 上调试

```bash
flutter run -d macos
```

App 启动后：
1. 底部导航切换到「设置」→ 点击「扫描设备」
2. 从列表中选择你的标签打印机，点击「连接」
3. 切换到「打印」标签页 → 底部显示连接状态
4. 用 curl 测试：

```bash
# 健康检查
curl http://127.0.0.1:15987/health

# 发送打印
curl -X POST http://127.0.0.1:15987/print \
  -H "Content-Type: application/json" \
  -d '{"data":"SGVsbG8gV29ybGQ=", "copies":1}'
```

---

## 5. GitHub Actions 自动打包（推荐）

> 无需本地安装 Flutter，直接在 GitHub 云端完成编译打包。

### 5.1 配置流程

```bash
# 1. 在 GitHub 创建私人仓库（Private）
# 2. 推送代码
git init
git add .
git commit -m "feat: SANJOY 打印中转 App 初始版本"
git remote add origin https://github.com/YOUR_USERNAME/sanjoyapp-bluprint.git
git branch -M main
git push -u origin main

# 3. 打 tag 触发自动构建
git tag v1.0.0
git push --tags
```

### 5.2 触发方式

| 方式 | 操作 | 构建内容 |
|------|------|---------|
| **推送代码** | `git push` | Android APK + macOS App（需在 main 分支） |
| **打标签** | `git push --tags` v1.0.0 | 同上 + 自动创建 GitHub Release |
| **手动触发** | GitHub → Actions → Build Flutter App → Run workflow | 可选择平台（android / macos） |

### 5.3 下载产物

1. 打开 GitHub → **Actions** 页面
2. 点击最新一次运行 → 底部 **Artifacts**
3. 下载：
   - `android-apk` → APK 安装包
   - `macos-app` → macOS .app（zip 包）

> 如果是 **tag 触发**，GitHub Release 页面也会自动附上安装包。

### 5.4 流水线做了哪些工作

```
git push / tag → GitHub Actions (macos-latest)
  ├── 安装 Flutter SDK
  ├── flutter create .          (自动生成 android/ + macos/ 目录)
  ├── configure_platforms.sh    (注入蓝牙 + 网络权限)
  ├── flutter pub get           (安装依赖)
  ├── flutter analyze           (静态检查)
  ├── flutter build apk --release  → 上传为 artifact
  ├── flutter build macos --release → 打包 zip 上传
  └── 打 tag → 创建 GitHub Release 并附安装包
```

### 5.5 工作流文件

`.github/workflows/build.yml` 已预置在项目根目录，无需手动创建。

### 5.6 注意事项

- 云构建使用的是 **公共 GitHub Runner**（macos-latest），免费额度每月 2000 分钟，对小项目完全够用
- 构建产物签名为 **debug 签名**，正式发布前仍需配置 Android keystore 签名
- macOS 产物未经公证（notarization），首次运行需右键 → 打开，绕过 Gatekeeper
- 如需定制（如只构建 Android），可在手动触发时选择 `android` 平台

---

## 6. 本地打包发布（手动方式）

> 以下方式需要在本地安装 Flutter 开发环境。如果不确定本地是否有 Flutter，请优先使用上面的 GitHub Actions 云构建。

### 6.1 Android APK

```bash
# 构建 release APK
flutter build apk --release

# APK 位于：
# build/app/outputs/flutter-apk/app-release.apk
```

**安装到手机：**

```bash
# 方式一：通过 adb 安装
adb install build/app/outputs/flutter-apk/app-release.apk

# 方式二：传输到手机后手动安装
# AirDroid / 微信文件传输 / USB 复制 均可
```

**首次安装后**：
1. 打开 App → 允许「蓝牙」和「位置」权限
2. 设置 → 扫描设备 → 连接打印机
3. App 保持在后台运行即可（HTTP Server 持续监听）

> ⚠️ **已知问题**：部分 Android 厂商（如小米、华为）后台会杀死 HTTP Server。
> 解决：在系统设置中将此 App 加入「自启动」白名单 / 锁定后台任务。

### 6.2 macOS app

```bash
# 构建 release app
flutter build macos --release

# App 位于：
# build/macos/Build/Products/Release/sanjoyapp_print.app
```

**安装方式：**

```bash
# 拖到 Applications 文件夹
cp -R build/macos/Build/Products/Release/sanjoyapp_print.app /Applications/

# 或者直接用 Finder 拖放
open build/macos/Build/Products/Release/
```

**首次打开**：
- 右键点击 app → 打开（绕过 Gatekeeper）
- 允许蓝牙权限
- 允许网络权限（接收 HTTP 请求）

### 6.3 分发签名（可选）

- **Android 正式签名**：生成 keystore → 配置 `android/key.properties` → `flutter build apk --release`
- **macOS 公证**：需要 Apple Developer 账号，Xcode → Archive → Distribute App → Notarize

---

## 7. Web 端配合

Web 端（sanjoyapp 管理系统）通过 HTTP 与本 App 通信：

```javascript
// 打印标签
async function printLabel(base64Data, copies = 1) {
  try {
    const resp = await fetch('http://127.0.0.1:15987/print', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ data: base64Data, copies }),
    });
    const result = await resp.json();
    if (result.success) {
      console.log('打印成功');
    } else {
      console.error('打印失败:', result.error);
      alert('打印失败: ' + result.error);
    }
    return result;
  } catch (e) {
    console.error('连接失败:', e);
    // 提示用户检查打印中转 App 是否运行
    alert('无法连接打印服务，请确保「SANJOY 打印中转」App 已启动');
  }
}

// 查询打印机状态
async function checkPrinterStatus() {
  try {
    const resp = await fetch('http://127.0.0.1:15987/status');
    return await resp.json();
  } catch (e) {
    return { connected: false, error: '服务不可用' };
  }
}

// 打印前检查状态
async function safePrint(base64Data, copies) {
  const status = await checkPrinterStatus();
  if (!status.connected) {
    alert('打印机未连接，请打开「SANJOY 打印中转」App 连接打印机');
    return;
  }
  return printLabel(base64Data, copies);
}
```

---

## 8. 项目结构

```
bluprint/
├── lib/
│   ├── main.dart                 # 入口 + 底部导航（打印/设置）
│   ├── models/
│   │   └── print_task.dart       # 打印任务数据模型
│   ├── services/
│   │   ├── ble_service.dart      # BLE 扫描/连接/分包写入（20字节/包）
│   │   └── http_server.dart      # 本地 HTTP 打印服务器（127.0.0.1:15987）
│   └── pages/
│       ├── print_page.dart        # 打印日志/状态页面
│       └── settings_page.dart     # BLE 设备扫描/选择/连接
├── platform_config/
│   └── android_permissions.txt   # Android 权限配置参考
├── pubspec.yaml                  # Flutter 依赖声明
└── README.md                     # 本文件
```

### 技术栈

| 功能 | 库 | 说明 |
|------|-----|------|
| BLE 通信 | `flutter_blue_plus` ^1.32.0 | 跨平台蓝牙低功耗，iOS/Android/macOS |
| HTTP 服务 | `shelf` + `shelf_router` | 轻量级 Dart HTTP Server |
| 本地存储 | `shared_preferences` | 保存上次连接的打印机 MAC 地址 |
| UI | Flutter Material 3 | Amber (琥珀色) 主题 |

### 核心逻辑

- **BLE 分包发送**：标签打印机 MTU 通常为 20 字节，数据自动按 20 字节分包写入特性
- **HTTP → BLE**：Web 端 POST base64 → App 解码为 `Uint8List` → BLE 逐包发送
- **自动重连**：记住上次设备 MAC，启动时自动尝试连接
- **状态实时更新**：BLE 连接状态变化 → UI 自动刷新

---

## 9. 常见问题排查

| 问题 | 可能原因 | 解决 |
|------|---------|------|
| Web 端 curl 连不上 | App 未启动 / HTTP Server 未运行 | 确认 App 已打开且在前台（或已加入后台白名单） |
| 扫描不到打印机 | 蓝牙未开启 / 权限未授予 | Android：检查蓝牙和位置权限；macOS：系统设置→隐私→蓝牙 |
| 连接打印机动不动就断 | BLE 信号弱 / Android 后台限制 | 打印机和手机靠近；在系统设置中把 App 加入白名单 |
| 打印乱码 | 打印数据编码不对 | 确认 Web 端发送的是**打印机原生指令**的 base64 |
| `flutter build apk` 报错 | Android SDK 未配置 | 运行 `flutter doctor` 检查 Android toolchain |
| macOS 打不开 app | Gatekeeper 拦截 | 右键点击 → 打开，或在 系统设置→隐私→安全性 中允许 |
| APK 安装失败 | 签名冲突 / 架构不匹配 | 确保手机 CPU 架构是 arm64-v8a 或 armeabi-v7a |

---

## 10. 开发命令速查

```bash
# 安装依赖
flutter pub get

# 静态分析
flutter analyze

# 格式化代码
flutter format lib/

# 运行测试
flutter test

# 在 Android 真机运行
flutter run -d <android_device_id>

# 在 macOS 运行
flutter run -d macos

# 构建 Android APK
flutter build apk --release

# 构建 macOS app
flutter build macos --release

# 清理构建缓存
flutter clean
flutter pub get
```

---

## 11. 后续展望

### 11.1 Flutter 原生能力扩展

当前 App 使用 Flutter 框架开发，未来可在同一代码基础上扩展更多原生能力：

| 方向 | 用途 |
|------|------|
| 本地 SQLite 存储 | 缓存打印任务历史、打印机设备列表 |
| 本地推送通知 | 后台打印完成后弹出系统通知 |
| 文件分享 | 支持从系统分享菜单直接发送图片到打印中转 |
| 前台服务（Android） | 解决部分厂商后台杀死 HTTP Server 的问题 |
| 快捷键 / Menu Bar（macOS） | 方便快速切换打印机或查看任务队列 |

### 11.2 仓库管理（可选）

如果未来需要管理多个打印中转 App 的版本分发给不同门店，可以：
- 在此仓库基础上增加版本号管理
- 通过 GitHub Releases 分发不同门店渠道包
- 配合后端管理系统的 `printer_config` 推送 App 更新提醒

### 11.3 非 Flutter 备选方案

如果后续条件限制（如不需要跨平台、设备环境变化），仍可通过其他语言实现类似 HTTP → BLE 桥接：

| 方案 | 优点 | 缺点 |
|------|------|------|
| **原生 Android (Kotlin/Java)** | 直接使用 Android BLE API，体积小 | 需单独维护 macOS 版本 |
| **原生 macOS (Swift)** | 原生体验好 | 需单独维护 Android 版本 |
| **Python + bleak + Flask** | 快速原型 | 依赖 Python 运行环境，打包麻烦 |
| **Node.js + noble + express** | 可复用于其他 IoT 场景 | BLE 兼容性问题较多 |

> **当前选择 Flutter 的理由**：一份代码同时覆盖 Android + macOS 两个平台，跨平台蓝牙库 `flutter_blue_plus` 成熟稳定，企业可以快速响应两端需求变化。
