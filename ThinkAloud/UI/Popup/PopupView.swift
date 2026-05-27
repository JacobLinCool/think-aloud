import SwiftUI

struct PopupRootView: View {
    @Bindable var viewModel: PopupViewModel
    let coordinator: PopupCoordinator
    @Bindable var modelManager: ModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            content
        }
        .padding(18)
        .frame(width: 460, height: 280)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .foregroundStyle(.tint)
            Text("ThinkAloud")
                .font(.headline)
            Spacer()
            Text(modelManager.runtimeStatus.displayLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle:
            IdlePopupView()
        case .recording:
            RecordingPopupView(viewModel: viewModel, coordinator: coordinator)
        case .transcribing:
            TranscribingPopupView(coordinator: coordinator, modelManager: modelManager)
        case .review:
            ReviewPopupView(viewModel: viewModel, coordinator: coordinator)
        case .error(let message):
            ErrorPopupView(message: message, coordinator: coordinator)
        }
    }
}
