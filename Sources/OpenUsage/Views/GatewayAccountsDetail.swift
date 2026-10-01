import SwiftUI

/// The hover list behind a gateway card's "Accounts" row: every upstream account with its plan windows,
/// 30-day cost, and status, tightest window first. Same panel chrome as `ModelUsageDetail`.
struct GatewayAccountsDetail: View {
    let accounts: [GatewayAccount]
    var onHoverChange: (Bool) -> Void

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    private static let width: CGFloat = 290

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accounts")
                .font(.system(size: density.headerPointSize, weight: .semibold))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(accounts, id: \.id) { account in
                    row(account)
                }
            }
            PopoverSourceNote(text: "Session / Weekly from each account's plan · cost over the last 30 days")
        }
        .padding(14)
        .frame(width: Self.width)
        .onContinuousHover { phase in
            switch phase {
            case .active: onHoverChange(true)
            case .ended: onHoverChange(false)
            }
        }
    }

    private func row(_ account: GatewayAccount) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(account.name)
                    .font(.system(size: density.supportingPointSize, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let provider = account.provider {
                    Text(Self.providerLabel(provider))
                        .font(.system(size: density.supportingPointSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(MetricFormatter.number(account.cost30dUSD, kind: .dollars, style: .row))
                    .font(.system(size: density.supportingPointSize))
                    .monospacedDigit()
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(windowsText(account))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                statusLabel(account.status)
            }
            .font(.system(size: density.supportingPointSize))

            if let tightest = account.tightestPercent {
                GeometryReader { proxy in
                    Capsule()
                        .fill(.quaternary)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Theme.meterFill(Self.severity(tightest)))
                                .frame(width: proxy.size.width * min(max(tightest / 100, 0), 1))
                        }
                }
                .frame(height: density.meterHeight)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, density.textRowPadding)
        .accessibilityElement(children: .combine)
    }

    private func windowsText(_ account: GatewayAccount) -> String {
        func percent(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))%" } ?? "—" }
        guard account.sessionPercent != nil || account.weeklyPercent != nil else { return "No plan quota" }
        return "Session \(percent(account.sessionPercent)) · Weekly \(percent(account.weeklyPercent))"
    }

    @ViewBuilder
    private func statusLabel(_ status: GatewayAccount.Status) -> some View {
        if status.isProblem {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: density.supportingPointSize - 2))
                Text(status.label)
            }
            .foregroundStyle(Theme.notice)
        } else {
            Text(status.label)
                .foregroundStyle(.secondary)
        }
    }

    /// 9router's custom endpoints carry a long generated id (`openai-compatible-chat-<uuid>`).
    static func providerLabel(_ provider: String) -> String {
        if provider.hasPrefix("openai-compatible") { return "openai-compatible" }
        return provider
    }

    static func severity(_ percent: Double) -> WidgetData.MeterSeverity {
        percent >= 90 ? .critical : percent >= 80 ? .warning : .normal
    }
}
