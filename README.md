# agent-status

macOS 菜单栏工具：点击图标查看 AI 订阅账号额度（风格类似 iStats）。

## v0 目标

- 菜单栏常驻图标
- 点击展开多账号额度面板
- 数据源：CLIProxyAPI Management API
- 首版重点：xAI / Grok 周限额（weekly credit usage）

## 调试实例

- Base: `https://us1-cliproxy.fff-cake.org`
- Management key 通过本地配置注入，勿提交仓库

## 开发

SwiftUI + MenuBarExtra，macOS 13+。
