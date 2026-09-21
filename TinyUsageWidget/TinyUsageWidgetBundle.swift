import SwiftUI
import WidgetKit

@main
struct TinyUsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        UsageWidget()
        UsageLiveActivityWidget()
    }
}

