# aistat

macOS menu bar quota viewer for AI subscription accounts via CLIProxyAPI / Sub2API.

## Stack

- Swift 5.9+ / SwiftUI
- MenuBarExtra / WidgetKit App Intents (macOS 14+)
- URLSession for Management API

## Key APIs (CLIProxyAPI)

Auth header: `Authorization: Bearer <management_key>` (also accepts `X-Management-Key`)

1. `GET /v0/management/auth-files` → account list (`provider`, `email`, `auth_index`, `status`, `unavailable`, `status_message`)
2. `POST /v0/management/api-call` body:
   ```json
   {
     "authIndex": "<auth_index>",
     "method": "GET",
     "url": "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
     "header": {
       "Authorization": "Bearer $TOKEN$",
       "x-xai-token-auth": "xai-grok-cli",
       "x-grok-client-version": "0.2.91",
       "accept": "*/*",
       "user-agent": "grok-pager/0.2.91 grok-shell/0.2.91 (macos; aarch64)"
     }
   }
   ```
   Response body contains `config.creditUsagePercent` (weekly used %), period start/end, productUsage.
3. Optional monthly: same api-call with url `https://cli-chat-proxy.grok.com/v1/billing` → `config.monthlyLimit.val` / `config.used.val` (cents).

Filter first version to `provider == "xai"` (Grok) accounts.

## Desktop Widgets (WidgetKit)

- Extension product: `aistat-widget` → packaged as `AIstat.app/Contents/PlugIns/AIstatWidget.appex`
- Shared snapshot models live in `AIstatShared` (`WidgetSnapshot`, `WidgetDataStore`)
- Main app publishes after each refresh via `WidgetBridge` (no secrets in snapshot)
- Widget entitlements **must** include `com.apple.security.app-sandbox` or `pluginkit` ignores the extension
- Do **not** declare App Groups without a real provisioning profile (chronod hangs on descriptor fetch)
- Host (unsandboxed) writes snapshot into the widget container:
  `~/Library/Containers/app.aistat.widget/Data/Library/Application Support/aistat/widget-snapshot.json`
- Sign with Apple Development identity when available (`package.sh` auto-detects)
- **App Intents metadata**: SwiftPM does not emit `Metadata.appintents`. `package.sh` re-compiles widget sources with `-emit-const-values-path` and runs `appintentsmetadataprocessor` into the appex `Resources/`. Without this, desktop right-click never shows **Edit Widget**.
- UI families: systemSmall / systemMedium / systemLarge (list) + large-only dashboard rings (`QuotaDashboardWidget`)

## Multi-connection config

- `AppConfiguration` holds arrays: `cliProxyConnections` / `sub2APIConnections` (each with `id`, `name`, credentials).
- Settings UX: single **添加账号** sheet (pick type → form); each connection is its own sidebar tab.
- Per CLIProxy connection: `preferNearRefreshAccounts` (priority write-back is host-local).
- Menu bar always shows **all** connections (CLIProxy grouped by name; Sub2 balances prefix name).
- Desktop widgets: per-instance `AIstatWidgetConfigurationIntent` (App Intents) selects CLIProxy / Sub2 sources from snapshot `sources` catalog — not global config flags.
- Host publishes full privacy-safe snapshot; widget timeline filters by intent selection.
- Legacy single-field config migrates to one named connection (`默认`) on load.

## Security

- Never commit management keys.
- Store config under Application Support or user defaults with local-only file.
- Widget snapshot must stay privacy-safe (percentages / display names only).

