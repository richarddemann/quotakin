import SwiftUI

enum OnboardingWindow {
    static let id = "onboarding"
    static let title = "Welcome to Quotakin"
}

private struct OnboardingPresentationModifier: ViewModifier {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .task {
                if model.consumeAutomaticOnboardingPresentation() {
                    present()
                }
            }
            .onChange(of: model.onboardingPresentationRequest) {
                present()
            }
    }

    private func present() {
        openWindow(id: OnboardingWindow.id)
        WindowFocus.bringForward(title: OnboardingWindow.title)
    }
}

extension View {
    func handlesOnboardingPresentation(model: AppModel) -> some View {
        modifier(OnboardingPresentationModifier(model: model))
    }
}
