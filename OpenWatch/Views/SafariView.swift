import SwiftUI
import SafariServices

// Ariadne's Thread
// What: SwiftUI wrapper around SFSafariViewController plus an Identifiable URL box for sheet presentation.
// Why:  Links sent by the agent inside a session should open in an in-app browser instead of leaving the app.
// When: 2026-06-04
// Notes: SFSafariViewController only supports http/https. Callers must filter other schemes before presenting.

/// Identifiable wrapper so a `URL` can drive a `.sheet(item:)` presentation.
struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

/// Presents an in-app browser (SFSafariViewController) for http/https links.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        AppLog.info("SafariView opening in-app browser url=\(url.absoluteString)")
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: configuration)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
