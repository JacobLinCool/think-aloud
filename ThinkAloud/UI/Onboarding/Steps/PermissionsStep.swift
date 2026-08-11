import SwiftUI

struct PermissionsStep: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingHeader(
                    title: "Grant permissions",
                    subtitle: "Microphone access is required to dictate. Accessibility is optional and lets ThinkAloud paste for you."
                )

                // Same view (and the same live re-check machinery) the Settings Permissions pane uses.
                PermissionsSectionView(style: .onboarding)
            }
            .padding(32)
        }
    }
}
