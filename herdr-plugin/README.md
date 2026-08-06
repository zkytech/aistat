# AIstat Quota（Herdr 插件）

在 Herdr 终端内查看 **AIstat 账号额度 / 余额**，信息架构对齐 macOS 菜单栏主面板（`MenuBarContentView`），不是桌面 Widget 仪表盘。

| | |
|---|---|
| **Plugin id** | `aistat.quota` |
| **版本** | `0.1.0` |
| **最低 Herdr** | `0.7.0`（本机验证：`0.8.0`） |
| **平台** | macOS、Linux |
| **实现** | Python 3.9+ 标准库（无第三方依赖） |

## 安装

本地开发 link（推荐）：

```bash
herdr plugin link /Users/zkytech/Projects/gitea/agent-status/herdr-plugin
herdr plugin list
herdr plugin action list --plugin aistat.quota
```

将来若发布到 GitHub 可用：

```bash
herdr plugin install <owner>/<repo>/herdr-plugin
```

卸载 / 取消 link：

```bash
herdr plugin unlink aistat.quota
# 或
herdr plugin uninstall aistat.quota
```

## 依赖

- **Herdr** ≥ 0.7.0
- **Python 3**（`python3` 在 `PATH` 中；建议 3.9+）
- **已配置的 AIstat**（或兼容的 `config.json`）

插件 **不要求** 安装 AIstat.app 才能运行；它直接读同一份配置并自行拉取 API。  
若你已在 AIstat 菜单栏应用中配好账号，插件会复用，无需重配。

## 打开面板

```bash
# Action
herdr plugin action invoke aistat.quota.open

# 或直接打开 pane
herdr plugin pane open --plugin aistat.quota --entrypoint main
```

也可在插件根目录手动运行：

```bash
cd /Users/zkytech/Projects/gitea/agent-status/herdr-plugin
python3 -m aistat_quota panel
python3 -m aistat_quota show          # 非交互摘要
python3 -m aistat_quota refresh       # 强制刷新缓存
```

## 快捷键与鼠标（主面板）

| 操作 | 作用 |
|------|------|
| `↑` / `k` | 上一条（余额或账号） |
| `↓` / `j` | 下一条 |
| `Enter` | 查看详情 |
| 单击行 | 选中该行 |
| 双击行 | 打开详情 |
| 单击底部 `[r]` 区域 | 刷新（后台，不阻塞操作） |
| 单击底部 `[q]` 区域 | 退出 |
| `r` | **触发后台刷新**（独立进程，面板不等待；下次打开见新数据） |
| `o` | 打开配置文件（macOS：`open` 配置路径） |
| `q` / `Esc` | 退出面板 |

账号名默认截断约 16 字符；进度条在账号名**左侧**。

### 刷新模型（重要）

- 面板**只读磁盘缓存**，打开瞬间不阻塞网络。
- 打开面板 / 按 `r` 只会 **spawn 独立进程** 去拉数写缓存，**当前面板不合并结果**。
- 要看最新数据：关掉面板再打开（或再按一次 open）。
- CLI：`python3 -m aistat_quota refresh` 为阻塞刷新；`show` 默认只读缓存（`--force` 才联网）。

## Actions / Pane

| 类型 | id | 说明 |
|------|-----|------|
| action | `open` | 打开额度主面板（优先 `plugin.pane.open`） |
| action | `refresh` | 后台刷新并写入插件缓存 |
| action | `show` | 打印文本摘要到 stdout |
| pane | `main` | 交互主面板（`placement = popup`） |

## 与菜单栏主面板能力对照

| 能力 | AIstat 菜单栏 | 本插件 |
|------|---------------|--------|
| Header「账号额度」+ 刷新中 | ✅ | ✅ |
| Sub2API / DeepSeek 余额 + 今日用量 | ✅ | ✅ |
| CLIProxy 按连接名分组 | ✅ | ✅ |
| 账号行：provider / 状态 / 进度条 / 剩余% / 重置倒计时 | ✅ | ✅（文本进度条） |
| 颜色阈值（≤0 红 / ≤20 橙） | ✅ | ✅（ANSI） |
| 详情：周/月额度、productUsage、账号状态 | 悬停卡 | Enter 详情页 |
| 读 `~/Library/Application Support/aistat/config.json` | ✅ | ✅ |
| 自动刷新（默认 300s，最短 60s） | ✅ | ✅（pane 内） |
| 并发拉取、单点失败不影响其他 | ✅ | ✅ |
| 全量展示已配置连接 | ✅ | ✅ |
| Widget / 登录项 / priority 写回 | ✅（部分） | ❌ 本阶段不做 |
| 设置 UI | 原生窗 | 打开 config 路径 |

## 配置路径与安全

| 路径 | 用途 |
|------|------|
| `~/Library/Application Support/aistat/config.json` | **主配置**（与 AIstat 共享，含密钥） |
| `$HERDR_PLUGIN_STATE_DIR/quota-cache.json` | 插件展示缓存（无密钥） |
| `$HERDR_PLUGIN_CONFIG_DIR` | 预留给插件私有覆盖（当前未写密钥） |

安全约定：

- **不要**把 management key / API key 写进日志、README、截图或 git
- 配置文件建议权限 `600`（AIstat 保存时会设置）
- 缓存与摘要只含展示字段（百分比、余额文本、显示名）
- 可用环境变量 `AISTAT_CONFIG_DIR` 覆盖配置目录（测试用）

## 实现说明

采用 **路径 B**：插件内用 Python 标准库重实现客户端逻辑，严格对齐 `AGENTS.md` 与 Swift `CLIProxyClient` / `Sub2APIClient` / `DeepSeekClient` / `QuotaStore` 的解析与状态优先级。

未走「抽取 Swift headless 导出」是为了：

1. `herdr plugin link` 即可用，无需编译 AIstat
2. 零第三方依赖，跨 macOS/Linux
3. 不改动主应用构建链路

## 验收清单

```bash
herdr plugin link /Users/zkytech/Projects/gitea/agent-status/herdr-plugin
herdr plugin list
herdr plugin action list --plugin aistat.quota
herdr plugin pane open --plugin aistat.quota --entrypoint main
# 或无 server 时：
cd /Users/zkytech/Projects/gitea/agent-status/herdr-plugin && python3 -m aistat_quota show --force
```

- [x] 可 link 成功  
- [x] 主面板信息架构对齐菜单栏（余额 + CLIProxy 分组 + footer）  
- [x] 周剩余%、进度、重置倒计时、状态、余额  
- [x] 可刷新；Enter 看详情  
- [x] 读现有 AIstat config；密钥不落日志/不进 git  

## 已知限制

- 不写回 CLIProxy `preferNearRefreshAccounts` priority（只读排序）
- 无原生 macOS 悬浮窗几何；详情为 TUI 全屏页
- 无 Widget / 开机启动
- Linux 上默认配置路径仍指向 `~/Library/Application Support/aistat/`；可用 `AISTAT_CONFIG_DIR` 覆盖
- Grok / Codex / Claude 上游字段若变更，需与 Swift 侧同步解析
