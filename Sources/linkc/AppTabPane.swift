import SwiftUI
import WebKit
import LinkCKit

/// The pane for one app tab: asleep with a Start button, starting with a spinner, the app's page
/// in a `WKWebView` once it's running, or failed/exited with its log and a way to try again.
struct AppTabPane: View {
    let model: AppModel
    let app: AppModel.AppTabRef

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        switch model.appProcesses[app.id]?.state ?? .asleep {
        case .asleep:
            AppAsleepView(name: app.name) { model.startApp(app) }
        case .starting:
            AppStartingView(name: app.name)
        case .running(let url):
            AppWebView(model: model, key: app.id, url: url)
                .clipShape(RoundedRectangle(cornerRadius: Theme.terminalRadius, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        case .failed(let reason):
            AppTroubleView(
                title: "\(app.name) could not start", detail: reason,
                log: model.appProcesses[app.id]?.log ?? [], buttonTitle: "Retry"
            ) { model.startApp(app) }
        case .exited(let status):
            AppTroubleView(
                title: "\(app.name) stopped (status \(status))", detail: nil,
                log: model.appProcesses[app.id]?.log ?? [], buttonTitle: "Start"
            ) { model.startApp(app) }
        }
    }
}

/// Not running — the app name, a quiet caption, and the only way it ever starts.
private struct AppAsleepView: View {
    let name: String
    let start: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text(name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Not running")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            Button("Start", action: start)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 10)
        }
    }
}

/// The health poll is under way — no progress figure, just that it's happening.
private struct AppStartingView: View {
    let name: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Starting \(name)…")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Shared by `.failed` and `.exited`: a title, an optional reason, the process's log, and the
/// button that tries again.
private struct AppTroubleView: View {
    let title: String
    let detail: String?
    let log: [String]
    let buttonTitle: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Theme.statusError)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if !log.isEmpty {
                AppLogView(log: log)
            }
            Button(buttonTitle, action: retry)
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 24)
    }
}

/// The process's last lines, monospaced and selectable, capped so it never grows past the pane.
private struct AppLogView: View {
    let log: [String]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary.opacity(0.9))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(8)
        }
        .frame(maxHeight: 180)
        .planeCard()
    }
}

/// A tab's cached web view, plus the URL it was last explicitly told to load — tracked here
/// rather than read back from `WKWebView.url`, which reflects wherever an in-page link has
/// since taken the user, not what `AppTabPane` last asked it to show.
struct CachedAppWebView {
    let view: WKWebView
    var loaded: URL
}

/// The app's page. `makeNSView`/`updateNSView` write only `model.appWebViews`, the
/// `@ObservationIgnored` cache — never observed state — so the web view survives the tab going
/// out of view and back, keeping its in-page state alive.
struct AppWebView: NSViewRepresentable {
    let model: AppModel
    let key: String
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        if let cached = model.appWebViews[key] { return cached.view }
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        model.appWebViews[key] = CachedAppWebView(view: webView, loaded: url)
        webView.load(URLRequest(url: url))
        return webView
    }

    /// Reloads only when `url` itself changed since the view's last explicit load. A restart is
    /// caught upstream instead — `AppModel.startApp` drops the cache entry before starting, so a
    /// restart on the very same port (the two `url`s would otherwise compare equal) still gets a
    /// fresh `WKWebView` via `makeNSView`. This only has to tell "the same session, don't
    /// interrupt in-app navigation" apart from "the URL genuinely changed" — never by reading
    /// `webView.url`, which following a link changes without this ever having reloaded.
    func updateNSView(_ webView: WKWebView, context: Context) {
        guard model.appWebViews[key]?.loaded != url else { return }
        model.appWebViews[key]?.loaded = url
        webView.load(URLRequest(url: url))
    }
}
