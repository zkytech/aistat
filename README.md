# AIstat

macOS 菜单栏工具，用来查看 AI 订阅账号的额度使用情况。

点击菜单栏图标即可展开面板，同时查看多个账号的周额度剩余、重置时间与状态；悬停账号可看更详细的周/月额度信息。数据源支持 [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) 与 Sub2API。

## 截图

![菜单栏额度面板](docs/screenshots/menu-panel.png)

![账号详情](docs/screenshots/account-detail.png)

![设置](docs/screenshots/settings-cliproxy.png)

## 功能

- 菜单栏摘要：显示最紧账号的剩余百分比，例如 `Grok 34%`
- 多账号列表：状态点、周额度进度条（以剩余为主）、重置倒计时
- 悬停详情：周额度、月度额度、账号状态
- 自动刷新（默认 5 分钟，最短 1 分钟）；手动刷新最短间隔 1 分钟
- 按重置时间临近程度排序，并同步 CLIProxyAPI 账号 priority
- 并发拉取账号数据，单账号失败不影响其他账号
- 多数据源设置：CLIProxyAPI、Sub2API

## 系统要求

- macOS 13+
- Apple Silicon（arm64）
- Swift 5.9+（Xcode 自带 toolchain 即可）

## 安装

### 从 Release 下载

在 [Releases](https://github.com/zkytech/aistat/releases) 下载最新的 `AIstat-macos-arm64.zip`，解压后将 `AIstat.app` 移到 `~/Applications` 并打开。

首次打开若被 Gatekeeper 拦截，可在 Finder 中右键 → 打开。

### 从源码安装

```bash
git clone https://github.com/zkytech/aistat.git
cd aistat
./scripts/install.sh
```

默认安装到 `~/Applications/AIstat.app`。

常用选项：

```bash
./scripts/install.sh --no-launch
./scripts/install.sh --app-path "$HOME/Applications/AIstat.app"
./scripts/install.sh --debug
```

仅打包不安装：

```bash
./scripts/package.sh
# 输出 dist/AIstat.app 与 dist/AIstat-macos-arm64.zip
```

推送到 `main` 后，GitHub Actions 会自动测试、打包，并以 `yyyyMMdd HH:mm:ss`（Asia/Shanghai）为标题发布 Release。

## 配置

首次启动若未配置，可通过面板底部的「设置」填写：

| 数据源 | 需要配置 |
|--------|----------|
| CLIProxyAPI | Base URL、Management Key |
| Sub2API | Base URL、API Key |

共享设置：

- 自动刷新间隔（默认 300 秒，最短 60 秒）

配置保存在本机：

```text
~/Library/Application Support/aistat/config.json
```

示例：

```json
{
  "baseURL": "https://your-cliproxy-host",
  "managementKey": "<management-key>",
  "refreshIntervalSeconds": 300
}
```

密钥只保存在本机，文件权限会尽量设为 `600`。请勿把真实 key 提交到 git。

## 开发

```bash
swift build
swift run aistat
swift test
```

## License

MIT
