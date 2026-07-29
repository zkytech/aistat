# agent-status

macOS 菜单栏工具：点击图标查看 AI 订阅账号额度（风格类似 iStats）。

## 界面预览

菜单栏面板：多账号周额度剩余、状态点、重置倒计时；底部可刷新 / 打开设置。

![菜单栏账号额度面板](docs/screenshots/menu-panel.png)

悬停账号详情：周额度、月度额度与账号状态（Auth Index 已打码）。

![账号悬停详情面板](docs/screenshots/account-detail.png)

设置：配置 CLIProxyAPI / Sub2API 数据源（API Host 已打码，密钥以密文显示）。

![设置 - CLIProxyAPI](docs/screenshots/settings-cliproxy.png)

> 截图中的邮箱、Auth Index、API Host 均已打码，不代表真实凭据。

## v0 目标

- 菜单栏常驻图标
- 点击展开多账号额度面板
- 数据源：CLIProxyAPI Management API
- 首版重点：xAI / Grok 周限额（weekly credit usage）

## 要求

- macOS 13+
- Apple Silicon / arm64
- Swift 5.9+（本机 Xcode 自带 toolchain 即可）

## 运行

开发调试：

```bash
cd /path/to/agent-status
swift build
swift run agent-status
```

打包安装到本机菜单栏应用（推荐日常使用）：

```bash
./scripts/install.sh
```

默认安装到：

```text
~/Applications/Agent Status.app
```

常用选项：

```bash
./scripts/install.sh --no-launch
./scripts/install.sh --app-path "$HOME/Applications/Agent Status.app"
./scripts/install.sh --debug
```

仅打包（生成 `.app` 与 zip，不安装/启动）：

```bash
./scripts/package.sh
# 输出: dist/Agent Status.app  与  dist/Agent-Status-macos-arm64.zip
```

说明：

- 脚本会 `swift build -c release`，安装可执行文件与菜单栏图标
- 图标安装到 `Contents/Resources/*.png`（`Bundle.main`，可 codesign）
- `swift run` 仍走 SPM `Bundle.module` 回退路径
- 安装后 ad-hoc 签名并启动
- `main` 分支推送后由 GitHub Actions 自动打包并发布 Release（标题格式：`yyyyMMdd HH:mm:ss`，时区 Asia/Shanghai）

首次启动若未配置，会提示打开 Settings。

## 配置

应用内 Settings 可填写：

- `Base URL`
- `Management Key`
- 自动刷新间隔（默认 300 秒）

配置写入：

```text
~/Library/Application Support/agent-status/config.json
```

示例（**不要**把真实 key 提交到 git）：

```json
{
  "baseURL": "https://your-cliproxy-host",
  "managementKey": "<management-key>",
  "refreshIntervalSeconds": 300
}
```

文件权限会尽量设为 `600`。

## 功能

- 菜单栏摘要：最紧账号剩余百分比，如 `Grok 34%`
- 账号列表：邮箱截断、状态点、周限额进度条（剩余为主）、已用/剩余、重置时间 `yyyy-MM-dd HH:mm:ss`
- 手动刷新最短间隔 1 分钟；自动刷新默认 5 分钟且不低于 1 分钟
- 按重置时间临近程度排序，并同步 CLIProxyAPI 账号 priority（越近越高）
- `TaskGroup` 并发拉取；单账号失败不影响其他账号
- 可选月度额度（失败静默忽略）
- 设置窗口支持多平台侧栏（CLIProxyAPI 已接入，Sub2API 预留）

## 测试

```bash
swift test
```

## 安全

- 不要提交 management key
- 仅本地 Application Support / 应用内 Settings 保存密钥
