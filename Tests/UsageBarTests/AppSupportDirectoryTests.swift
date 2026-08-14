import Foundation
import Testing
@testable import UsageBar

@Test
func newInstallUsesQuotakinApplicationSupportDirectory() {
    let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)

    #expect(
        AppSupportDirectory.resolved(homeDirectory: home, legacyDirectoryExists: false).path
            == "/Users/example/Library/Application Support/Quotakin"
    )
}

@Test
func renamedInstallReusesLegacyUsageBarApplicationSupportDirectory() {
    let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)

    #expect(
        AppSupportDirectory.resolved(homeDirectory: home, legacyDirectoryExists: true).path
            == "/Users/example/Library/Application Support/UsageBar"
    )
}
