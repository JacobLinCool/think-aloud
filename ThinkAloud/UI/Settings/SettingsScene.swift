import SwiftUI

struct SettingsScene: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        TabView {
            GeneralPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            PermissionsPane()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            ModelPane()
                .tabItem { Label("Model", systemImage: "brain") }
            DatasetPane()
                .tabItem { Label("Dataset", systemImage: "tray.full") }
            AdvancedPane()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 580, height: 560)
        .environment(container)
    }
}
