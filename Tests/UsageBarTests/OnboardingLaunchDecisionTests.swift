import Foundation
import Testing
import UsageCore
@testable import UsageBar

@Test
func newInstallIsEligibleForOnboarding() {
    withIsolatedDefaults { defaults in
        #expect(OnboardingLaunchDecision.evaluate(defaults: defaults) == .newInstall)
    }
}

@Test @MainActor
func existingPreferencesSuppressOnboardingAndAreMigrated() {
    withIsolatedDefaults { defaults in
        defaults.set(Data("existing preferences".utf8), forKey: "UsageBar.UserPreferences.v1")

        #expect(OnboardingLaunchDecision.evaluate(defaults: defaults) == .existingInstall)

        _ = AppModel(
            defaults: defaults,
            notificationPoster: NoopOnboardingNotificationPoster()
        )

        #expect(defaults.bool(forKey: OnboardingLaunchDecision.completionKey))
    }
}

@Test
func incompleteOnboardingResumesEvenAfterPreferencesAreStored() {
    withIsolatedDefaults { defaults in
        defaults.set(true, forKey: OnboardingLaunchDecision.startedKey)
        defaults.set(Data("new preferences".utf8), forKey: "UsageBar.UserPreferences.v1")

        #expect(OnboardingLaunchDecision.evaluate(defaults: defaults) == .incomplete)
    }
}

@Test @MainActor
func completedOnboardingDoesNotAutomaticallyReappear() {
    withIsolatedDefaults { defaults in
        let model = AppModel(
            defaults: defaults,
            notificationPoster: NoopOnboardingNotificationPoster()
        )

        #expect(model.shouldAutomaticallyPresentOnboarding)

        model.completeOnboarding()

        #expect(defaults.bool(forKey: OnboardingLaunchDecision.completionKey))
        #expect(defaults.object(forKey: OnboardingLaunchDecision.startedKey) == nil)
        #expect(OnboardingLaunchDecision.evaluate(defaults: defaults) == .completed)
    }
}

@Test @MainActor
func consumingAutomaticPresentationKeepsInterruptedSetupEligible() {
    withIsolatedDefaults { defaults in
        let model = AppModel(
            defaults: defaults,
            notificationPoster: NoopOnboardingNotificationPoster()
        )

        #expect(model.consumeAutomaticOnboardingPresentation())
        #expect(!model.shouldAutomaticallyPresentOnboarding)
        #expect(defaults.bool(forKey: OnboardingLaunchDecision.startedKey))
        #expect(OnboardingLaunchDecision.evaluate(defaults: defaults) == .incomplete)
    }
}

@Test @MainActor
func completedOnboardingCanBeExplicitlyReopened() {
    withIsolatedDefaults { defaults in
        defaults.set(true, forKey: OnboardingLaunchDecision.completionKey)
        let model = AppModel(
            defaults: defaults,
            notificationPoster: NoopOnboardingNotificationPoster()
        )
        let initialRequest = model.onboardingPresentationRequest

        #expect(!model.shouldAutomaticallyPresentOnboarding)

        model.showOnboarding()

        #expect(model.onboardingPresentationRequest == initialRequest + 1)
        #expect(defaults.bool(forKey: OnboardingLaunchDecision.completionKey))
    }
}

private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
    let suiteName = "UsageBarTests.Onboarding.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    body(defaults)
}

@MainActor
private final class NoopOnboardingNotificationPoster: QuotaNotificationPosting {
    func authorizationState() async -> NotificationAuthorizationState { .unknown }
    func requestAuthorization() async {}
    func post(_ notifications: [QuotaNotification]) async -> Bool { true }
}
