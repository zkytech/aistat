import AppKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct AIstatWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuotaWidget()
        QuotaDashboardWidget()
    }
}
