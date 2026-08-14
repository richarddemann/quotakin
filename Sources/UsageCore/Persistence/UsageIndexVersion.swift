import Foundation

public enum UsageIndexVersion: Int, Codable, CaseIterable, Sendable {
    case legacy = 1
    case transcriptAccountingV2 = 2
}
