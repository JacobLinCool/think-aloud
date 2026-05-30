import SwiftUI

struct PermissionsStep: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingHeader(
                    title: "Grant permissions",
                    subtitle: "ThinkAloud needs two macOS permissions. You can change these anytime in System Settings."
                )

                // Same view (and the same live re-check machinery) the Settings Permissions pane uses.
                PermissionsSectionView(style: .onboarding)
            }
            .padding(32)
        }
    }
}
