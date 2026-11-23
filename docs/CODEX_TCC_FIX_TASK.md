# Codex：修复 macOS 已授权但 Nexus Drive 仍报告“未授权”（高优先级）

## 用户复现

用户在「系统设置 → 隐私与安全性」里已经给 Nexus Drive 开启了 **输入监控** 和 **辅助功能**，但是 Nexus Drive「设置 → 隐私与权限」仍显示「输入监控：未授权」「快速粘贴（辅助功能）：未授权」。重新刷新、点击授权、自动重启均未解决。部分情况下键鼠统计完全没有数据。

**目标是让 Codex 在用户本机的真实 app / codesign / TCC 环境中找根因并修复，不要只改“未授权”文字，也不要假装已授予权限。**

## 当前仓库

- GitHub：`qssedalto/Nexus`
- 工作分支：`feat/icloud-drive-folder-sync`（不要修改 main、不要覆盖正式 Nexus.app）
- 本机工作目录：`/Volumes/Macintosh SSD/开发/GitHub/Nexus-Drive-Local`
- 免费版 bundle ID：`com.qssedalto.nexus.drive.dev`；用户可见名称为 Nexus Drive。
- 构建：`ARCHES=arm64 NEXUS_FAST_LOCAL_BUILD=1 SIGNING_MODE=development APP_IDENTITY="<Apple Development identity>" bash Scripts/build_drive_dev.sh --debug --verify`
- 既有核心入口：
  - `Sources/Nexus/InputMonitor.swift`：`CGPreflightListenEventAccess()`，`CGEvent.tapCreate(... .listenOnly ...)`
  - `Sources/Nexus/InputStatisticsView.swift`：`InputStatisticsController`、`startIfPermitted`、`refreshPermissionStatus`、`requestPermission`
  - `Sources/Nexus/PrivacySettingsView.swift`：输入监控状态和 `AXIsProcessTrusted()`
  - `Sources/Nexus/NexusAppRelauncher.swift`：重启当前 .app
  - `Sources/Nexus/AppDelegate.swift`：监听初始化和 app became active
  - `Scripts/package_app.sh`、`Scripts/build_drive_dev.sh`、`project.yml`、`Sources/Nexus/Resources/*/InfoPlist.strings`

## 必须实际排查

1. **确认授权的是真正运行的二进制。** 检查当前进程 PID、`Bundle.main.bundlePath`、`Bundle.main.bundleIdentifier`、`Bundle.main.executableURL`、`NSRunningApplication`；区分下载的版本、本地编译版本、外置盘不同目录、旧 `Nexus.app` 与新 `Nexus Drive.app`。定位是否同时存在多份 `Nexus Drive` 或启动了旧版本。
2. **检查签名是否稳定。** 对真实运行 App 和磁盘上要启动的 App 执行只读 `codesign -dv --verbose=4`、`codesign --verify --deep --strict`、`codesign -d --entitlements :-`；确认 Apple Development 证书、Team ID、Bundle ID、designated requirement、嵌套扩展与重建时的变化。测试 Ad Hoc→Development 变化是否使 TCC 原有授权不再匹配。保证本地反复编译不意外改变身份；不要假设 InfoPlist 显示名称就是 TCC 身份。
3. **分开检查两种 macOS API。** 输入监控取 `CGPreflightListenEventAccess()` / `CGRequestListenEventAccess()`，辅助功能取 `AXIsProcessTrusted()` / `AXIsProcessTrustedWithOptions`。不要互相代替；不要仅凭 UI 的“已开启”推断进程拥有权限。
4. **检查真实事件监听。** `CGEvent.tapCreate` 可能失败，即使某个预检成功。正确区分 `permissionGranted`、tap 创建成功、tap enabled、收到事件、SQLite 已写入；给清楚的诊断而非笼统“未授权”。处理 TCC 从系统设置返回后的时序和权限刷新。不得读取普通输入字符、密码、验证码，不得绕过系统安全输入。
5. **检查重启逻辑。** `NexusAppRelauncher.restart()` 当前通过 `/bin/sh` 延迟 `open -n <bundle path>`；确保真正退出旧 PID 并重启**同一磁盘路径**的签名 App、不要启动另一个副本或因进程复用而误判。必要时采取 macOS 支持且可验证的替代方式。
6. **检查键鼠无记录是否由不同问题引起。** 统计总开关、暂停开关、输入监控权限、Event Tap 工作状态、本地 SQLite `InputStatisticsStore.shared()`。不要把数据库失败伪装成权限失败。
7. **系统授权不可自动强制。** 如果必须重新授权，在确认签名/路径问题后给出准确的人机操作说明；不要擅自执行 `tccutil reset`、删除 TCC.db、sudo 修改系统保护或清除历史。只有在用户明确同意时才考虑重置单一服务的授权。

## 必须实现的交付

- 修复能复现的真正问题；在设置中清晰区分：`系统权限已授权 / 未授权`、`监听正在运行 / 无法启动`、`辅助功能授权`，不是单纯写死绿色标签。
- 提供最小的、**不含敏感数据**的诊断能力（可显示当前运行 App 路径、Bundle ID、签名团队摘要、两项权限值、tap 状态及存储状态）；不要将这些信息上传互联网。
- 一键重启须重新打开相同签名的 Nexus Drive 应用；如果权限需要用户手动操作，要在 UI 中给出精确路径和恢复步骤。
- 增加相关单元测试/状态转换测试（用抽象权限提供者测试状态逻辑，不要在 CI 里要求 macOS 真授权），本机编译 Debug 并运行 `Scripts/test.sh` 或相关测试；不要漏掉 XcodeGen 生成的 `Nexus.xcodeproj/project.pbxproj` 一致性检查。
- 汇总根因、修改的文件、执行的命令、实际确认的运行时 API 结果，以及仍需要用户手动授权的部分。**禁止声称未做过的真机验证已完成。**
- 不要趁机重构 CloudKit、服务器同步、官网、外观，不要触碰 main 或覆盖原有 `Nexus.app`；已有用户文件、SQLite 历史和 iCloud 同步目录都必须保留。

## 立即执行

先只读诊断用户本机真实进程和两个系统权限，再修改最小必要代码。不要只给一份修复建议，直接完成源码更改和本机增量构建；遇到 TCC 系统授权必须由用户操作的地方，准确提示而不是绕过。
