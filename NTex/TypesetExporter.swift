import WebKit

enum ExportError: Error { case pdfFailed }

final class TypesetExporter: NSObject, WKNavigationDelegate {
    private var onFinish: ((Result<URL, Error>) -> Void)?
    private var html: String!
    private var baseURL: URL?
    private var web: WKWebView!

    func exportPDF(html: String, baseURL: URL? = nil, completion: @escaping (Result<URL,Error>) -> Void) {
        self.html = html
        self.baseURL = baseURL
        self.onFinish = completion

        let cfg = WKWebViewConfiguration()
        web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = self
        web.loadHTMLString(html, baseURL: baseURL) // if you bundled katex/, pass its URL in baseURL
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        waitForKaTeXThenPDF()
    }

    private func waitForKaTeXThenPDF(deadline: TimeInterval = 3.0) {
        let start = Date()
        func poll() {
            web.evaluateJavaScript("window.__katexDone === true") { [weak self] val, _ in
                guard let self = self else { return }
                let ready = (val as? Bool) == true || Date().timeIntervalSince(start) > deadline
                if ready { self.makePDF() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll) }
            }
        }
        poll()
    }

    private func makePDF() {
        let cfg = WKPDFConfiguration()

        // Use the Result<Data, Error> completion form (works iOS 14+)
        web.createPDF(configuration: cfg) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let data):
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("NTex-\(UUID().uuidString).pdf")
                do {
                    try data.write(to: url)
                    self.onFinish?(.success(url))
                } catch {
                    self.onFinish?(.failure(error))
                }
            case .failure(let error):
                self.onFinish?(.failure(error))
            }
        }
    }
}
