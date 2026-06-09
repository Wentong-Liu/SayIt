# 发布 / CI 说明

SayIt 用 GitHub Actions 自动构建与发布：

- **`.github/workflows/ci.yml`** —— 每次推送 `main` / 提 PR：跑 `swift test` + 构建 App（不签名），持续验证能编译。无需任何 Secret。
- **`.github/workflows/release.yml`** —— 推送形如 `v1.0.0` 的 tag（或在 Actions 页手动触发）：构建 Release → **Developer ID 签名** → 打包 **DMG** → **公证（notarize）+ staple** → 创建 GitHub Release 并附上 DMG。

最低系统 macOS 14；CI 用 `macos-15` runner 构建（搭配最新稳定版 Xcode）。

> 工程文件 `SayIt.xcodeproj` 由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 从 `project.yml` 生成、不入库，所以两个工作流都会先 `cp Local.xcconfig.example Local.xcconfig`、`brew install xcodegen`、`xcodegen generate`，再调用 `xcodebuild`。

---

## 一次性准备：配置 Secrets

发布工作流需要你的 Apple 开发者凭证（**需付费 Apple Developer Program 会员**）。在仓库 **Settings → Secrets and variables → Actions → New repository secret** 添加：

| Secret | 说明 / 怎么拿到 |
|---|---|
| `DEVELOPER_ID_CERT_P12` | **Developer ID Application** 证书的 base64。先在 [Apple Developer → Certificates](https://developer.apple.com/account/resources/certificates/list) 创建「Developer ID Application」证书，在「钥匙串访问」里连同私钥一起导出为 `.p12`，再 `base64 -i cert.p12 \| pbcopy` |
| `CERT_PASSWORD` | 导出上面 `.p12` 时设置的密码 |
| `AC_API_KEY_ID` | App Store Connect API 密钥的 **Key ID** |
| `AC_API_ISSUER_ID` | App Store Connect API 的 **Issuer ID** |
| `AC_API_KEY_P8` | API 私钥 `.p8` 的 base64。在 [App Store Connect → 用户和访问 → 集成 → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api) 创建一个密钥（角色给 Developer 即可），下载 `AuthKey_XXXX.p8`，再 `base64 -i AuthKey_XXXX.p8 \| pbcopy` |

> `.p12` / `.p8` 都只能下载一次，导出时务必保存好。公证用 App Store Connect API key（比 Apple ID + 专用密码更稳）。

---

## 发布一个版本

```bash
git tag v1.0.0
git push origin v1.0.0
```

推送 tag 后，`release.yml` 会自动跑（约几分钟，公证那步要等 Apple 返回），完成后在仓库 **Releases** 页就能看到 `v1.0.0` 及附带的 `SayIt.dmg`。

产出的 DMG 里是 **Developer ID 签名 + 已公证 + 已 staple** 的 `SayIt.app`——任何 macOS 14+ 的 Mac 双击 DMG、拖进「应用程序」即可打开，不会有 Gatekeeper 警告；签名稳定，辅助功能授权也能跨版本保留。SayIt 是 macOS 菜单栏里的本地语音听写，配合你的 Codex 订阅润色。

---

## 备注

- 想每次推送都出 DMG（而非只在打 tag 时）：把 `release.yml` 的 `on:` 加上 `push: branches: [main]`。但公证有耗时与频率限制，一般只在发版时做。
- 本项目 **关闭 App Sandbox**、**开启 Hardened Runtime**（公证要求）。所用的辅助功能 / 屏幕录制 / 模拟输入都是 TCC 授权、无需额外 entitlements。
- 想手动出一版而不打 tag：Actions 页选 **Release DMG → Run workflow**（DMG 会作为 workflow artifact 上传，不创建 Release）。
