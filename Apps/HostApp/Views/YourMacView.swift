import SwiftUI
import SyncCore

/// Settings → "Your Mac": pair with a Mac (QR scan), see the paired-device card
/// (name, last synced, Sync Now, Unpair), and a small sync journal. LAN-only, per
/// the Privacy screen — the copy links back to it (ARCHITECTURE §6.5/§7).
struct YourMacView: View {
    @EnvironmentObject private var sync: SyncCoordinator
    @State private var showScanner = false

    var body: some View {
        Form {
            introSection

            if sync.pairedPeers.isEmpty {
                pairSection
            } else {
                ForEach(sync.pairedPeers) { peer in
                    pairedCard(peer)
                }
                // Drive controls (WP7) as top-level Form sections — kept OUT of the
                // paired-card ForEach so the Form flattens each Section correctly.
                ForEach(sync.pairedPeers) { peer in
                    RemoteMacDriveView(peer: peer)
                }
                pairAnotherSection
            }

            if !sync.journal.isEmpty {
                journalSection
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Your Mac")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("yourMac.root")
        .sheet(isPresented: $showScanner) {
            PairingSheet(isPresented: $showScanner)
                .environmentObject(sync)
        }
    }

    // MARK: - Sections

    private var introSection: some View {
        Section {
            Label("Sync your setup with your Mac", systemImage: "laptopcomputer.and.iphone")
                .font(.headline)
            Text("Your vocabulary, history, and profiles stay in step across both devices — "
                 + "over your local Wi-Fi, encrypted, never the cloud.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } footer: {
            Text("Nothing leaves your devices. See Privacy for the full posture.")
        }
    }

    private var pairSection: some View {
        Section {
            Button {
                showScanner = true
            } label: {
                Label("Pair a Mac", systemImage: "qrcode.viewfinder")
            }
            .accessibilityIdentifier("yourMac.pair")
        } header: {
            Text("Not paired yet")
        } footer: {
            Text("On your Mac: open OpenWhisp, choose \u{201C}Pair iPhone\u{2026}\u{201D}, and scan the code it shows.")
        }
    }

    private var pairAnotherSection: some View {
        Section {
            Button {
                showScanner = true
            } label: {
                Label("Pair another Mac", systemImage: "qrcode.viewfinder")
            }
            .accessibilityIdentifier("yourMac.pairAnother")
        }
    }

    private func pairedCard(_ peer: PeerIdentity) -> some View {
        Section {
            HStack {
                Image(systemName: "laptopcomputer")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(peer.displayName).font(.headline)
                    Text(lastSyncedText(peer))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if sync.isSyncing {
                    ProgressView()
                }
            }

            Button {
                sync.syncNow(peer)
            } label: {
                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(sync.isSyncing)
            .accessibilityIdentifier("yourMac.syncNow")

            Button(role: .destructive) {
                sync.unpair(peer)
            } label: {
                Label("Unpair", systemImage: "minus.circle")
            }
            .accessibilityIdentifier("yourMac.unpair")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Key fingerprint: \(peer.pskFingerprint)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                if let error = sync.lastError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var journalSection: some View {
        Section {
            ForEach(sync.journal) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.message).font(.caption)
                    Text(entry.date, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Recent syncs")
        }
    }

    private func lastSyncedText(_ peer: PeerIdentity) -> String {
        guard let last = peer.lastSeen else { return "Never synced" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "Last synced \(f.localizedString(for: last, relativeTo: Date()))"
    }
}

/// The QR pairing sheet: scan → parse → complete pairing, or show the failure /
/// camera-unavailable fallback.
struct PairingSheet: View {
    @EnvironmentObject private var sync: SyncCoordinator
    @Binding var isPresented: Bool
    @State private var cameraUnavailable = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ZStack {
                if !cameraUnavailable {
                    QRScannerView(
                        onScan: handleScan,
                        onUnavailable: { cameraUnavailable = true }
                    )
                    .ignoresSafeArea(edges: .bottom)
                }

                VStack {
                    Spacer()
                    if cameraUnavailable {
                        unavailableFallback
                    } else if let errorText {
                        errorBanner(errorText)
                    } else {
                        instruction
                    }
                }
                .padding()
            }
            .navigationTitle("Pair a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                        .accessibilityIdentifier("pairing.cancel")
                }
            }
            .accessibilityIdentifier("pairing.root")
        }
    }

    private var instruction: some View {
        Text("Point the camera at the QR code on your Mac.")
            .font(.callout)
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var unavailableFallback: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.metering.unknown")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Camera unavailable")
                .font(.headline)
            Text("Pairing needs a camera to scan the code your Mac shows. Try on a device with a camera.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("pairing.cameraUnavailable")
    }

    private func errorBanner(_ text: String) -> some View {
        VStack(spacing: 8) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
            Button("Try again") { errorText = nil }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func handleScan(_ raw: String) {
        do {
            _ = try sync.completePairing(scannedQR: Data(raw.utf8))
            isPresented = false
        } catch {
            errorText = Self.describe(error)
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let e = error as? PairingPayload.ParseError else {
            return "That code couldn't be read. Try again."
        }
        switch e {
        case .malformed: return "That doesn't look like an OpenWhisp pairing code."
        case .unsupportedVersion: return "This pairing code is from a newer OpenWhisp. Update this app."
        case .invalidPSK, .invalidPeerID: return "The pairing code is damaged. Ask your Mac to show a fresh one."
        }
    }
}
