import AppKit
import SwiftUI

struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 6) {
                Text("Welcome to ThinkAloud")
                    .font(.largeTitle.bold())
                Text("Speak anywhere on your Mac and ThinkAloud turns it into text — instantly, and entirely on-device.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                OnboardingFeatureRow(icon: "lock.fill", text: "100% local. Your audio never leaves your Mac.")
                OnboardingFeatureRow(icon: "bolt.fill", text: "One hotkey to record, transcribe, and insert.")
                OnboardingFeatureRow(icon: "character.bubble", text: "Tuned for Mandarin and English.")
            }
            .frame(maxWidth: 440)
            .padding(.top, 4)

            Spacer()

            Text("This quick setup takes about a minute.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }
}
