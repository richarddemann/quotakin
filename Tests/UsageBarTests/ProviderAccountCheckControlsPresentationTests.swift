import Testing
@testable import UsageBar

@Test
func authorizedAccountChecksExposeAReversibleStopAction() {
    let presentation = AccountCheckControlsPresentation(isAuthorized: true)

    #expect(presentation.showsStopAction)
    #expect(AccountCheckControlsPresentation.stopDetail.contains("Local history keeps updating"))
    #expect(AccountCheckControlsPresentation.stopDetail.contains("remain visible until"))
}

@Test
func stoppedAccountChecksHideTheStopAction() {
    let presentation = AccountCheckControlsPresentation(isAuthorized: false)

    #expect(!presentation.showsStopAction)
}
