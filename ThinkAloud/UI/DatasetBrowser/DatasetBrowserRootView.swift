import SwiftUI

struct DatasetBrowserRootView: View {
    @Bindable var controller: DatasetBrowserController
    let player: AudioPlayerController
    @Bindable var benchmark: BenchmarkController
    @Bindable var pushController: HFPushController
    @Bindable var tokenStore: HFTokenStore

    @State private var mode: BrowserMode = .records

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
            Picker("", selection: $mode) {
                ForEach(BrowserMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
    }
}
