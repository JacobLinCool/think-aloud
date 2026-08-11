import SwiftUI

struct PermissionsPane: View {
    var body: some View {
        Form {
            // Shared with onboarding so both surfaces use the same live permission state.
            PermissionsSectionView(style: .settings)
        }
        .formStyle(.grouped)
    }
}
