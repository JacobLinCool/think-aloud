import SwiftUI

/// Settings → Model: pick the transcription engine and manage its files in one place. The everyday
/// output shaping moved to Output; memory tuning and the model self-test moved to Advanced.
struct ModelPane: View {
    var body: some View {
        Form {
            ModelDownloadList()
        }
        .formStyle(.grouped)
    }
}
