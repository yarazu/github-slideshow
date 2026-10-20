import SwiftUI

extension OpenURLAction {
    /// Versucht die Adressen der Reihe nach, z. B. erst die App, dann das Web.
    @MainActor
    func first(of urls: [URL]) {
        guard let url = urls.first else { return }
        let rest = Array(urls.dropFirst())
        self(url) { accepted in
            guard !accepted else { return }
            Task { @MainActor in first(of: rest) }
        }
    }
}
