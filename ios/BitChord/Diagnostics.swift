import UIKit
import WebKit

/// A small in-memory log of what the native side saw (network refusals, bridge
/// errors, page loads), for the diagnostics sheet. Cheap enough to keep always on.
enum Diag {
    private static var lines: [String] = []
    private static let lock = NSLock()
    private static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    private static let currentFile = folder.appendingPathComponent("diag-current.log")
    private static let previousFile = folder.appendingPathComponent("diag-previous.log")
    /// The last session's log (it may have ended in a crash), read once at launch.
    static let previousSession: String = {
        let fm = FileManager.default
        try? fm.removeItem(at: previousFile)
        try? fm.moveItem(at: currentFile, to: previousFile)
        fm.createFile(atPath: currentFile.path, contents: nil)
        return (try? String(contentsOf: previousFile, encoding: .utf8)) ?? ""
    }()
    private static let handle: FileHandle? = {
        _ = previousSession
        return try? FileHandle(forWritingTo: currentFile)
    }()
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        let line = "\(clock.string(from: Date())) \(message)"
        lock.lock()
        lines.append(line)
        if lines.count > 300 { lines.removeFirst(lines.count - 300) }
        if let handle {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        }
        lock.unlock()
        if WebViewController.diagnostics { NSLog("[BitChord] %@", message) }
    }

    static var text: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

/// Shake the phone (or hold the BitChord capsule): what the app and the page
/// logged lately, to copy or share when something goes wrong.
final class DiagnosticsViewController: UIViewController {
    private let textView = UITextView()
    private weak var webView: WKWebView?

    init(webView: WKWebView?) {
        self.webView = webView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Diagnóstico"
        view.backgroundColor = .systemBackground
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.text = "Leyendo el registro…"
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Compartir", primaryAction: UIAction { [weak self] _ in self?.share() }),
            UIBarButtonItem(title: "Copiar", primaryAction: UIAction { [weak self] _ in
                UIPasteboard.general.string = self?.textView.text
                self?.title = "Copiado ✓"
            }),
        ]
        load()
    }

    private func load() {
        let info = Bundle.main.infoDictionary
        let header = """
        BitChord iOS \(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?")) · \(UIDevice.current.model) iOS \(UIDevice.current.systemVersion)
        Página: \(webView?.url?.absoluteString ?? "?")
        """
        let native = Diag.text
        guard let webView else {
            textView.text = header + "\n\n== App ==\n" + native
            return
        }
        // A page that doesn't answer within 2 s is itself the finding.
        var answered = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !answered else { return }
            self.textView.text = header + "\n\n⚠️ La página no responde (JavaScript ocupado o colgado).\n\n== App ==\n" + native
        }
        webView.evaluateJavaScript("window.__bitchordDiag ? window.__bitchordDiag() : 'sin registro'") { [weak self] result, error in
            answered = true
            let page = (result as? String) ?? "error: \(String(describing: error))"
            let previous = Diag.previousSession.split(separator: "\n").suffix(60).joined(separator: "\n")
            self?.textView.text = header + "\n\n== Página ==\n" + page + "\n\n== App ==\n" + native
                + (previous.isEmpty ? "" : "\n\n== Sesión anterior (antes del último cierre) ==\n" + previous)
            self?.textView.scrollRangeToVisible(NSRange(location: max(0, (self?.textView.text.utf16.count ?? 1) - 1), length: 1))
        }
    }

    private func share() {
        let sheet = UIActivityViewController(activityItems: [textView.text ?? ""], applicationActivities: nil)
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.first
        present(sheet, animated: true)
    }
}
