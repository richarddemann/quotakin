import Foundation

enum AppResourceBundle {
    static let current: Bundle = {
        for name in ["Quotakin_UsageBar.bundle", "UsageBar_UsageBar.bundle"] {
            if let url = Bundle.main.resourceURL?.appendingPathComponent(name),
               let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return Bundle.module
    }()
}
