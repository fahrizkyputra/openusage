import AppKit
import SwiftUI

/// Team builds: how to update. The user hands a ready-made prompt to their coding agent, which runs the
/// team installer; nothing is downloaded or run from here.
struct TeamUpdateScreen: View {
    @Environment(TeamUpdateChecker.self) private var teamUpdates
    @Environment(LayoutStore.self) private var layout
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    let horizontalPadding: CGFloat

    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    static let steps = [
        "Copy prompt",
        "Open your agent's terminal",
        "Paste and press Enter",
        "Wait for the update to finish"
    ]

    var body: some View {
        PopoverScrollView {
            VStack(alignment: .leading, spacing: density.sectionSpacing) {
                if let release = teamUpdates.available {
                    header(release)
                } else {
                    Text("You're on the latest version (\(AppInfo.version)).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                }
                if let prompt = teamUpdates.agentPrompt {
                    promptSection(prompt)
                    stepsSection
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 12)
        }
        .onChange(of: layout.screen) { _, screen in
            if screen != .teamUpdate { copied = false }
        }
    }

    // MARK: - Sections

    private func header(_ release: TeamUpdateChecker.Release) -> some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("New Version")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(release.version)")
                    .font(.headline)
                Text("You have \(AppInfo.version).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let notes = TeamUpdateChecker.summary(of: release.notes)
                if !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(notes.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }

    private func promptSection(_ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("Prompt for Your Agent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 10) {
                Text(prompt)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.fill.quinary))
                Button {
                    copy(prompt)
                } label: {
                    Label(copied ? "Copied" : "Copy prompt", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("Steps")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(step)
                            .font(.callout)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }

    // MARK: - Actions

    private func copy(_ prompt: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(prompt, forType: .string) else {
            AppLog.warn(.updates, "team build: copying the update prompt failed")
            return
        }
        withAnimation(Motion.spring) { copied = true }
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) { copied = false }
        }
    }
}
