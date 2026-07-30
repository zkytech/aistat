# aistat

macOS menu bar quota viewer for AI subscription accounts via CLIProxyAPI / Sub2API.

## Stack

- Swift 5.9+ / SwiftUI
- MenuBarExtra (macOS 13+)
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
- UI families: systemSmall / systemMedium / systemLarge (list) + large-only dashboard rings (`QuotaDashboardWidget`)

## Security

- Never commit management keys.
- Store config under Application Support or user defaults with local-only file.
- Widget snapshot must stay privacy-safe (percentages / display names only).
