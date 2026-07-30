import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp` for login-item registration.
/// Source of truth is the system login item state (not `config.json`).
enum LaunchAtLoginService {
    /// Toggle appears on when registered and either active or waiting for user approval.
    static var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered, .notFound:
            return false
        @unknown default:
            return false
        }
    }

    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// Human-readable hint for non-ready states; `nil` when idle/enabled.
    static var statusHint: String? {
        switch SMAppService.mainApp.status {
        case .requiresApproval:
            return "已请求开机启动，请在「系统设置 › 通用 › 登录项与扩展」中允许 AIstat"
        case .notFound:
            return "仅在安装为 .app 后可用（请用 scripts/install.sh 安装后再开启）"
        case .enabled, .notRegistered:
            return nil
        @unknown default:
            return nil
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status == .enabled {
                return
            }
            try SMAppService.mainApp.register()
        } else {
            if SMAppService.mainApp.status == .notRegistered {
                return
            }
            try SMAppService.mainApp.unregister()
        }
    }
}
