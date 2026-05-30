import SwiftUI

struct PermissionsPane: View {
    var body: some View {
        Form {
            // Shared with the Onboarding permissions step — and it carries the live re-check logic,
            // so this pane now updates the moment a permission is granted in System Settings (the
            // old standalone "Refresh status" section is no longer needed and has been removed).
            PermissionsSectionView(style: .settings)
        }
        .formStyle(.grouped)
    }
}
