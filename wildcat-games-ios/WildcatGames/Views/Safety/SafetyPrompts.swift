import MessageUI
import SwiftUI

/// Block or report, chosen from a message's long-press menu.
enum SafetyAction: Identifiable {
    case block(Flagged)
    case report(Flagged)

    var id: UUID {
        switch self { case .block(let f), .report(let f): return f.id }
    }

    var flagged: Flagged {
        switch self { case .block(let f), .report(let f): return f }
    }
}

/// "Report…" and "Block NAME" at the end of a received message's long-press menu.
struct SafetyMenuItems: View {
    let flagged: Flagged
    @Binding var action: SafetyAction?

    var body: some View {
        Divider()
        Button("Report…", systemImage: "exclamationmark.bubble") { action = .report(flagged) }
        Button("Block \(flagged.sender.name)", systemImage: "hand.raised", role: .destructive) { action = .block(flagged) }
    }
}

extension View {
    /// The confirmations behind `SafetyMenuItems`, and the report email.
    func safetyPrompts(_ action: Binding<SafetyAction?>) -> some View {
        modifier(SafetyPrompts(action: action))
    }
}

private struct SafetyPrompts: ViewModifier {
    @Environment(Safety.self) private var safety
    @Environment(\.openURL) private var openURL
    @Binding var action: SafetyAction?
    @State private var mail: Flagged?
    @State private var noMail: Flagged?

    private var title: String {
        switch action {
        case .block(let f)?: return "Block \(f.sender.name)?"
        case .report(let f)?: return "Report \(f.sender.name)?"
        case nil: return ""
        }
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(title, isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } }),
                                titleVisibility: .visible, presenting: action) { a in
                switch a {
                case .block(let f):
                    Button("Block", role: .destructive) { safety.block(f.sender); Haptics.thud() }
                case .report(let f):
                    Button("Report") { send(f) }
                    Button("Report and block", role: .destructive) { safety.block(f.sender); send(f) }
                }
            } message: { a in
                switch a {
                case .block:
                    Text("Their messages disappear from Wildcat, you get no notifications from them, and the bridge won't relay them. Unblock any time in \(AppMenuView.name) → Safety.")
                case .report:
                    Text("Opens an email to the Wildcat team with this message filled in. You can also block them.")
                }
            }
            .sheet(item: $mail) { f in
                MailComposer(flagged: f).ignoresSafeArea()
            }
            .alert("No mail app", isPresented: Binding(get: { noMail != nil }, set: { if !$0 { noMail = nil } }), presenting: noMail) { f in
                Button("Copy report") { UIPasteboard.general.string = "To: \(Support.email)\nSubject: \(Report.subject)\n\n" + Report.body(f) }
                Button("OK", role: .cancel) {}
            } message: { _ in
                Text("Send the report to \(Support.email) from any mail app. Copy it to paste.")
            }
    }

    private func send(_ f: Flagged) {
        if MFMailComposeViewController.canSendMail() {
            mail = f
        } else if let url = Report.mailto(f) {
            openURL(url) { accepted in if !accepted { noMail = f } }
        } else {
            noMail = f
        }
    }
}

/// The system mail sheet, filled in with a report.
private struct MailComposer: UIViewControllerRepresentable {
    let flagged: Flagged
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients([Support.email])
        vc.setSubject(Report.subject)
        vc.setMessageBody(Report.body(flagged), isHTML: false)
        return vc
    }

    func updateUIViewController(_ vc: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: { dismiss() }) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let dismiss: () -> Void
        init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            dismiss()
        }
    }
}

/// Message text with the word filter applied: listed words show as •••• until tapped.
struct FilteredText: View {
    @Environment(Safety.self) private var safety
    let text: String
    var font: Font = Theme.Fonts.body
    var color: Color = Theme.ink
    @State private var revealed = false

    var body: some View {
        if safety.masks(text) && !revealed {
            VStack(alignment: .leading, spacing: 4) {
                Text(WordFilter.masked(text)).font(font).foregroundStyle(color)
                Text("Filtered · tap to show").font(Theme.Fonts.labelSmall).foregroundStyle(Theme.mute)
            }
            .contentShape(Rectangle())
            .onTapGesture { revealed = true }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Shows the filtered words")
        } else {
            Text(text).font(font).foregroundStyle(color).textSelection(.enabled)
        }
    }
}
