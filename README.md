# agent-status

macOS 菜单栏工具：点击图标查看 AI 订阅账号额度（风格类似 iStats）。

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

```bash
cd /path/to/agent-status
swift build
swift run agent-status
```

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
- 账号列表：邮箱截断、状态点、周限额进度条、已用/剩余、重置时间
- 手动刷新防抖 1.5 秒
- 自动刷新默认 5 分钟
- `TaskGroup` 并发拉取；单账号失败不影响其他账号
- 可选月度额度（失败静默忽略）

## 测试

```bash
swift test
```

## 安全

- 不要提交 management key
- 仅本地 Application Support / 应用内 Settings 保存密钥
