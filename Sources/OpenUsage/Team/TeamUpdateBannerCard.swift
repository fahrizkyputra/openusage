import SwiftUI

/// Team builds: the dashboard banner shown while a newer team release exists. Same look as the Sparkle
/// update banner (`UpdateBannerCard`), but it can't be dismissed — it stays until the app is updated.
struct TeamUpdateBannerCard: View {
    let version: String
    let onUpdate: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text("New version available: \(version)")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Update now", action: onUpdate)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }
}
