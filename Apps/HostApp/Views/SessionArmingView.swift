import SwiftUI
import MobileCore

/// The Dictation-Session arming screen (WP10b, ARCHITECTURE §6.8 arming UX, §5 flow
/// 1.5). Presented by `openwhisp://session/arm`: it arms the session on appear, then
/// tells the user to swipe back to their app — post-iOS-26.4 there is NO sanctioned
/// auto-return, so the manual swipe-back is what ships (the market leader's flow too).
/// For the rest of the armed window the keyboard mic key starts/stops capture
/// instantly. The screen shows the idle timeout and carries an End Session button.
struct SessionArmingView: View {
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    /// A ticking clock so the "ends in …" countdown updates while the screen is up.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: session.isArmed ? "mic.circle.fill" : "mic.slash.circle")
                .font(.system(size: 72))
                .foregroundStyle(session.isArmed ? Color.accentColor : .secondary)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(session.isArmed ? "Session on" : "Session ended")
                    .font(.largeTitle.weight(.bold))
                Text(session.isArmed
                     ? "Swipe back to your app. Your keyboard's mic key now starts and stops dictation instantly \u{2014} no more app switching."
                     : "Re-arm from your keyboard's mic key whenever you want to dictate again.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            if session.isArmed {
                timeoutLabel
            }

            if let failure = session.failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()

            // The mic-privacy story, owned honestly (D11/R10c).
            Label("The mic stays available while a session is on \u{2014} iOS shows the "
                  + "orange indicator the whole time.",
                  systemImage: "circle.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .padding(.horizontal)

            Button(role: .destructive) {
                session.endSession()
                dismiss()
            } label: {
                Text("End Session")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .padding(.horizontal)
            .accessibilityIdentifier("session.endButton")
        }
        .padding(.vertical, 40)
        .accessibilityIdentifier("session.arming")
        .onAppear {
            // Arm on appear (idempotent-ish: re-arming a live session refreshes its
            // idle window). This is the one foreground hop that opens the window.
            if !session.isArmed { session.arm() }
        }
        .onReceive(tick) { now = $0 }
    }

    @ViewBuilder private var timeoutLabel: some View {
        switch settings.sessionIdleTimeout {
        case .never:
            Label("Stays on until you end it.", systemImage: "infinity")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        default:
            if let expires = session.expiresAt {
                let remaining = max(0, expires.timeIntervalSince(now))
                Label("Ends in \(Self.format(remaining)) if idle.", systemImage: "timer")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityIdentifier("session.timeout")
            }
        }
    }

    /// mm:ss countdown of the remaining idle window.
    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
