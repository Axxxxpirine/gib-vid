import SwiftUI

struct ContentView: View {
    @Environment(DownloadModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            BigButton(phase: model.phase, armed: model.clipboardHasLink) {
                model.tapBigButton()
            }

            status
                .frame(height: 96, alignment: .top)
                .padding(.top, 40)
                .padding(.horizontal, 40)

            Spacer()

            footer
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .sensoryFeedback(trigger: model.phase) { _, phase in
            switch phase {
            case .done: .success
            case .failed: .error
            case .analyzing: .impact(weight: .medium)
            default: nil
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        VStack(spacing: 14) {
            Text(statusText)
                .font(.body.weight(.medium))
                .foregroundStyle(isError ? .primary : .secondary)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: statusText)

            if model.phase.isBusy, model.phase != .saving {
                Button("Annuler", action: model.cancel)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            } else if case .done = model.phase {
                Button("Ouvrir Photos") {
                    UIApplication.shared.open(URL(string: "photos-redirect://")!)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            }
        }
    }

    private var statusText: String {
        switch model.phase {
        case .idle:
            model.clipboardHasLink ? "Appuie pour télécharger" : "Copie un lien, puis appuie"
        case .analyzing:
            "Analyse du lien…"
        case .downloading:
            "Téléchargement…"
        case .saving:
            "Enregistrement dans Photos…"
        case .done(let count):
            count > 1 ? "\(count) vidéos dans tes Photos" : "Dans tes Photos"
        case .failed(let message):
            message
        }
    }

    private var isError: Bool {
        if case .failed = model.phase { true } else { false }
    }

    private var footer: some View {
        Button(action: model.updateEngine) {
            Text(model.engineNote ?? model.engineVersion.map { "yt-dlp \($0)" } ?? "Préparation…")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .contentTransition(.opacity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mettre à jour yt-dlp")
    }
}

private struct BigButton: View {
    let phase: DownloadModel.Phase
    let armed: Bool
    let action: () -> Void

    private let diameter: CGFloat = 232
    private let ring: CGFloat = 5

    var body: some View {
        Button(action: action) {
            ZStack {
                if phase.isBusy {
                    progressRing
                } else {
                    Circle()
                        .fill(.primary)
                        .opacity(armed || phase != .idle ? 1 : 0.88)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                icon
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .animation(.spring(duration: 0.45, bounce: 0.25), value: phase.isBusy)
        }
        .buttonStyle(PressStyle())
        .disabled(phase.isBusy)
        .accessibilityLabel("Télécharger le lien copié")
    }

    @ViewBuilder
    private var progressRing: some View {
        Circle()
            .stroke(.primary.opacity(0.1), lineWidth: ring)
        switch phase {
        case .downloading(let fraction):
            Circle()
                .trim(from: 0, to: max(fraction, 0.004))
                .stroke(.primary, style: StrokeStyle(lineWidth: ring, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.15), value: fraction)
        case .saving:
            Circle()
                .stroke(.primary, lineWidth: ring)
        default:
            SpinningArc(lineWidth: ring)
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch phase {
        case .idle:
            Image(systemName: "arrow.down")
                .font(.system(size: 76, weight: .semibold))
                .foregroundStyle(Color(.systemBackground))
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 72, weight: .semibold))
                .foregroundStyle(Color(.systemBackground))
                .transition(.scale.combined(with: .opacity))
        case .failed:
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(Color(.systemBackground))
        case .downloading(let fraction):
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(Int(fraction * 100))")
                    .font(.system(size: 64, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.snappy, value: Int(fraction * 100))
                Text("%")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        case .analyzing:
            EmptyView()
        case .saving:
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct SpinningArc: View {
    let lineWidth: CGFloat
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.22)
            .stroke(.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
    }
}
