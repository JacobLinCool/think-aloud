import SwiftUI

struct DatasetBrowserRootView: View {
    @Bindable var controller: DatasetBrowserController
    let player: AudioPlayerController
    @Bindable var benchmark: BenchmarkController
    @Bindable var pushController: HFPushController
    @Bindable var tokenStore: HFTokenStore

    @State private var mode: BrowserMode = .records
    @State private var pendingMode: BrowserMode?

    enum BrowserMode: String, CaseIterable, Identifiable {
        case records, benchmark
        var id: String { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .records: return "Records"
            case .benchmark: return "Benchmark"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(String(localized: "Dataset Browser Section"), selection: modeBinding) {
                ForEach(BrowserMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(String(localized: "Dataset Browser Section"))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 360)

            Divider()

            switch mode {
            case .records:
                DatasetBrowserView(controller: controller, player: player, pushController: pushController, tokenStore: tokenStore)
            case .benchmark:
                BenchmarkView(controller: benchmark)
            }
        }
        .frame(minWidth: 880, minHeight: 560)
        .confirmationDialog(
            String(localized: "Save changes before leaving Records?"),
            isPresented: Binding(
                get: { pendingMode != nil },
                set: { if !$0 { pendingMode = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Save")) {
                guard let destination = pendingMode else { return }
                Task {
                    if await controller.saveDraft() {
                        mode = destination
                    }
                    pendingMode = nil
                }
            }
            Button(String(localized: "Discard Changes"), role: .destructive) {
                guard let destination = pendingMode else { return }
                controller.discardDraft()
                mode = destination
                pendingMode = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                pendingMode = nil
            }
        } message: {
            Text("Your edited transcript has unsaved changes.")
        }
    }

    private var modeBinding: Binding<BrowserMode> {
        Binding(
            get: { mode },
            set: { destination in
                if controller.hasUnsavedDraft, destination != mode {
                    pendingMode = destination
                } else {
                    if controller.isEditing, destination != mode {
                        controller.discardDraft()
                    }
                    mode = destination
                }
            }
        )
    }
}
