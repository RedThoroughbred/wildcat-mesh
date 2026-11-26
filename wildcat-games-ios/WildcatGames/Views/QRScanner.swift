import AVFoundation
import SwiftUI
import VisionKit

/// Camera QR scanner (VisionKit). Reports the first code `accept` likes and
/// keeps looking past others. Without a usable camera it says why instead
/// of showing a black sheet.
struct QRScanner: View {
    /// Which codes this caller understands (channel link, hunt invite, key…).
    let accept: (String) -> Bool
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        Group {
            if !DataScannerViewController.isSupported {
                problem("This iPhone can't scan QR codes here. Paste the link or key instead.", settings: false)
            } else {
                switch camera {
                case .notDetermined:
                    Color.black.task {
                        _ = await AVCaptureDevice.requestAccess(for: .video)
                        camera = AVCaptureDevice.authorizationStatus(for: .video)
                    }
                case .authorized where DataScannerViewController.isAvailable:
                    Camera(accept: accept, onCode: onCode)
                        .overlay(alignment: .top) {
                            HStack(spacing: 10) {
                                HStack(spacing: 6) {
                                    Image(systemName: "qrcode.viewfinder").font(.system(size: 13))
                                    Text("POINT AT A QR CODE")
                                        .font(Theme.Fonts.label)
                                        .tracking(Theme.labelTracking)
                                }
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 7)
                                .background(Theme.surface1.opacity(0.92), in: Capsule())
                                .overlay(Capsule().strokeBorder(Theme.hairlineStrong, lineWidth: 1))
                                Spacer(minLength: 0)
                                Button("Close") { dismiss() }
                                    .buttonStyle(.field(.secondary, .small))
                            }
                            .padding(.top, 16)
                            .padding(.horizontal, Theme.Space.edge)
                        }
                case .authorized:
                    problem("The camera isn't available right now. Close other apps using it, then try again.", settings: false)
                case .restricted:
                    problem("The camera is restricted on this phone (Screen Time or a device profile). You can paste the link or key instead.",
                            settings: false)
                default:
                    problem("The camera is off for Wildcat, so it can't scan codes. You can paste the link or key instead.",
                            settings: !PermissionHistory.cameraDecidedThisRun)
                }
            }
        }
    }

    private func problem(_ text: String, settings: Bool) -> some View {
        VStack(spacing: Theme.Space.stack) {
            IconTile(symbol: "camera", size: 56)
            Text(text).font(Theme.Fonts.callout).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            Button("Close") { dismiss() }.buttonStyle(.fieldPrimary)
            if settings {
                HStack(spacing: 4) {
                    Text("You can change this any time in").font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
                    SettingsLink()
                }
            }
        }
        .padding(Theme.Space.edge * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screen()
    }

    private struct Camera: UIViewControllerRepresentable {
        let accept: (String) -> Bool
        let onCode: (String) -> Void

        func makeUIViewController(context: Context) -> DataScannerViewController {
            let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
            vc.delegate = context.coordinator
            try? vc.startScanning()
            return vc
        }

        // Again once it's on screen, in case starting in make was too early.
        func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
            guard !context.coordinator.done, !vc.isScanning else { return }
            try? vc.startScanning()
        }

        func makeCoordinator() -> Coordinator { Coordinator(accept: accept, onCode: onCode) }

        final class Coordinator: NSObject, DataScannerViewControllerDelegate {
            let accept: (String) -> Bool
            let onCode: (String) -> Void
            var done = false
            init(accept: @escaping (String) -> Bool, onCode: @escaping (String) -> Void) {
                self.accept = accept
                self.onCode = onCode
            }

            func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
                guard !done else { return }
                for case .barcode(let b) in items {
                    if let s = b.payloadStringValue, accept(s) {
                        done = true
                        scanner.stopScanning()
                        onCode(s)
                        return
                    }
                }
            }
        }
    }
}
