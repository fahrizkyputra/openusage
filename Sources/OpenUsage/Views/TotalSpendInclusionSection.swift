import SwiftUI

/// The per-provider "Include in Total Spend" switch in a spend-capable provider's Customize detail.
/// Leaving a provider out only changes the Total Spend card's sum; its own spend rows stay as they are.
/// The switch exists for overlapping sources — e.g. Claude Code routed through a 9router gateway shows
/// up both on the Claude card (local logs) and on the gateway's card.
struct TotalSpendInclusionSection: View {
    @Environment(LayoutStore.self) private var layout
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    let providerID: String

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("Total Spend")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text("Include in Total Spend")
                    Spacer(minLength: 8)
                    Toggle("Include in Total Spend", isOn: Binding(
                        get: { layout.isIncludedInTotalSpend(providerID) },
                        set: { layout.setIncludedInTotalSpend($0, for: providerID) }
                    ))
                    .labelsHidden()
                    .settingsSwitchStyle()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, density.controlRowPadding)
                Text("Turn off when this spend is already counted by another provider, so the total isn't doubled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .cardSurface()
        }
    }
}
