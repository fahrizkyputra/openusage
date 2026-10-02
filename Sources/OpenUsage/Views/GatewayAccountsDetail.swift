import SwiftUI

/// The hover list behind a gateway card's "Accounts" row: every upstream account with its own Session and
/// Weekly meters, 30-day cost, and any routing problem, tightest window first. Same panel chrome as
/// `ModelUsageDetail`.
///
/// The meters read exactly like the card's Session / Weekly rows — same Used/Left direction, reset
/// format, pacing colors and tick — because they're built from the card row's own `WidgetData`
/// (`GatewayAccount.meterData(_:like:)`), which carries the global settings. Clicking a reading flips the
/// same global setting the card's does, so card and panel never disagree.
struct GatewayAccountsDetail: View {
    /// The card's Accounts row; its `gatewayAccounts` are listed, its display settings are reused.
    let row: WidgetData
    var onToggleMeterStyle: (() -> Void)?
    var onToggleResetDisplay: (() -> Void)?
    var onHoverChange: (Bool) -> Void

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @Environment(\.popoverPartyMode) private var partyMode

    private static let width: CGFloat = 320
    private static let windowLabelWidth: CGFloat = 54
    private static let paceTickWidth: CGFloat = 2
    private static let paceTickOverhang: CGFloat = 4

    private var accounts: [GatewayAccount] { row.gatewayAccounts }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accounts")
                .font(.system(size: density.headerPointSize, weight: .semibold))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(accounts, id: \.id) { account in
                    accountRow(account)
                }
            }
            PopoverSourceNote(text: footnote)
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

    private func accountRow(_ account: GatewayAccount) -> some View {
        VStack(alignment: .leading, spacing: density.rowInnerSpacing) {
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

            if account.status.isProblem {
                statusBadge(account)
            }

            let meters = GatewayAccount.Window.allCases.compactMap { account.meterData($0, like: row) }
            if meters.isEmpty {
                Text("No plan quota")
                    .font(.system(size: density.supportingPointSize))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(meters, id: \.title) { data in
                    windowRow(data)
                }
            }
        }
        .padding(.vertical, density.textRowPadding)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Window meter

    /// "Session ███████░ 92% left · 3h 40m": label, the card's capsule meter, then the reading and reset.
    private func windowRow(_ data: WidgetData) -> some View {
        let state = data.meterState()
        return HStack(spacing: 8) {
            Text(data.title)
                .foregroundStyle(.secondary)
                .frame(width: Self.windowLabelWidth, alignment: .leading)
            meter(data, state: state)
            reading(data)
        }
        .font(.system(size: density.supportingPointSize))
        .monospacedDigit()
    }

    @ViewBuilder
    private func reading(_ data: WidgetData) -> some View {
        HStack(spacing: 3) {
            toggle(onToggleMeterStyle, tooltip: data.meterStyleTooltip) {
                Text(data.headline).foregroundStyle(.primary)
            }
            if let reset = resetText(data) {
                Text("·").foregroundStyle(.tertiary)
                toggle(onToggleResetDisplay, tooltip: data.resetTooltip()) {
                    Text(reset).foregroundStyle(.secondary)
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    /// The reset time without the card's "Resets" verb ("in 3h 40m" / "today at 2:00 PM"); the panel row
    /// has no room for it and the window label already says what resets.
    private func resetText(_ data: WidgetData) -> String? {
        guard let resetsAt = data.resetsAt else { return nil }
        guard let when = Formatters.whenLabel(at: resetsAt, mode: data.resetDisplayMode) else { return nil }
        return data.resetDisplayMode == .relative && when != Formatters.imminent ? "in \(when)" : when
    }

    @ViewBuilder
    private func toggle<Label: View>(_ action: (() -> Void)?, tooltip: String?,
                                     @ViewBuilder label: () -> Label) -> some View {
        if let action {
            Button(action: action, label: label)
                .buttonStyle(.plain)
                .hoverTooltip(tooltip)
        } else {
            label()
        }
    }

    /// The card row's capsule meter (`WidgetRowView.meter`): pace-colored fill, minimum-visible width,
    /// and the even-pace tick on amber/red bars (and blue with "always show pacing").
    private func meter(_ data: WidgetData, state: WidgetData.MeterState) -> some View {
        let tick = data.paceTick(for: state)
        let height = density.meterHeight
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(partyMode ? PartyMode.meterFill
                          : state.severity.map(Theme.meterFill) ?? AnyShapeStyle(Color.secondary))
                    .frame(width: data.fraction > 0 ? max(height, proxy.size.width * data.fraction) : 0)
            }
            .overlay(alignment: .leading) {
                if let tick {
                    let track = proxy.size.width
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: Self.paceTickWidth, height: height + Self.paceTickOverhang)
                        .offset(x: min(max(track * tick - Self.paceTickWidth / 2, 0),
                                       max(track - Self.paceTickWidth, 0)))
                }
            }
        }
        .frame(height: height)
        .frame(minWidth: 40)
        .animation(Motion.spring, value: data.fraction)
        .accessibilityHidden(true)
        .hoverTooltip(state.tooltip)
    }

    // MARK: - Status

    private func statusBadge(_ account: GatewayAccount) -> some View {
        HStack(spacing: 3) {
            Image(systemName: account.status == .coolingDown ? "clock" : "pause.circle.fill")
                .font(.system(size: density.supportingPointSize - 2))
            Text(account.status.label)
        }
        .font(.system(size: density.supportingPointSize))
        .foregroundStyle(Theme.notice)
        .accessibilityHint(account.statusDetail ?? "")
    }

    /// Explains every non-OK state on screen once, so a paused account is never read as "quota used up".
    private var footnote: String {
        var parts = ["Session / Weekly from each account's plan · cost over the last 30 days"]
        let states = Set(accounts.map(\.status))
        if states.contains(.paused) {
            parts.append("Paused: 9router stopped routing to it after an error; plan quota is unaffected. Test the connection in the 9router dashboard to resume.")
        }
        if states.contains(.coolingDown) {
            parts.append("Cooling down: 9router skips one model on it for a short while.")
        }
        return parts.joined(separator: "\n")
    }

    /// 9router's custom endpoints carry a long generated id (`openai-compatible-chat-<uuid>`).
    static func providerLabel(_ provider: String) -> String {
        if provider.hasPrefix("openai-compatible") { return "openai-compatible" }
        return provider
    }
}
