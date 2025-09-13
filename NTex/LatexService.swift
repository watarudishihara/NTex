// LatexService.swift
import Foundation
import UIKit
import WebKit
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Abstraction

protocol LatexConverting {
    func convert(image: UIImage) async throws -> String
}

enum LatexService {
    // load once
    static let htmlShell = """
    <!doctype html>
    <html><head>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.10/dist/katex.min.css">
    <script src="https://cdn.jsdelivr.net/npm/katex@0.16.10/dist/katex.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/katex@0.16.10/dist/contrib/auto-render.min.js"></script>
    <style>
      :root { color-scheme: light dark; }
      body { margin:0; padding:24px; line-height:1.5;
             font-family: ui-serif, "Times New Roman", Times, serif; }
      .title  { text-align:center; font-weight:700; font-size:28px; margin:.5rem 0 0 }
      .author { text-align:center; color:#444; margin:0 0 1rem }  /* darker than opacity */
      .meta   { text-align:center; color:#888; margin:0 0 1.2rem }
      code    { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    </style>
    </head>
    <body>
      <div id="root"></div>
      <script>
        window.NTex = {
          root: document.getElementById('root'),
          setHTML(inner) {
            this.root.innerHTML = inner;
            if (window.renderMathInElement) {
              renderMathInElement(this.root, {
                delimiters: [
                  {left: "$$", right: "$$", display: true},
                  {left: "$",  right: "$",  display: false},
                  {left: "\\(", right: "\\)", display: false},
                  {left: "\\[", right: "\\]", display: true}
                ],
                throwOnError: false,
                trust: true
              });
            }
          }
        };
      </script>
    </body></html>
    """

    static func loadShell(into webView: WKWebView) {
        webView.loadHTMLString(htmlShell, baseURL: nil)
    }

    /// Convert user text to inner HTML (uses your new MiniTeX)
    static func renderInnerHTML(from source: String) -> String {
        // MiniTeX.render returns a fragment that already includes a small <style> and KaTeX triggers.
        // If you prefer, you can strip its <style> and keep only the body—either works.
        return MiniTeX.render(source)
    }

    /// Inject new HTML into the shell without reloading the whole page.
    static func setInnerHTML(_ html: String, on webView: WKWebView) {
        let b64 = (html.data(using: .utf8) ?? Data()).base64EncodedString()
        let js = """
        (function(){
          var s = atob('\(b64)');
          if (window.NTex && window.NTex.setHTML) { window.NTex.setHTML(s); }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}

enum LatexServiceError: LocalizedError {
    case invalidBaseURL
    case badStatus(Int, String)
    case noData
    case decodeFailed
    case imageEncodingFailed
    case onDeviceUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Server URL is not valid. Open Settings and set your Mac’s LAN URL (e.g. http://192.168.x.x:8000)."
        case .badStatus(let code, let body):
            return "Server returned \(code).\n\(body)"
        case .noData:
            return "Server response was empty."
        case .decodeFailed:
            return "Could not decode server response."
        case .imageEncodingFailed:
            return "Could not encode the image for upload."
        case .onDeviceUnavailable(let why):
            return "On-device conversion isn’t available: \(why)"
        }
    }
}

struct LatexResponse: Decodable { let latex: String }

// MARK: - Network backend (your existing flow)

struct NetworkLatexConverter: LatexConverting {
    let apiKey: String
    
    func convert(image: UIImage) async throws -> String {
        // Convert UIImage to JPEG
        guard let jpegData = image.jpegData(compressionQuality: 0.9) else {
            throw LatexServiceError.imageEncodingFailed
        }

        // Base64 encode for Gemini
        let base64Image = jpegData.base64EncodedString()
        
        // Gemini endpoint (using flash for speed/cost)
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-pro:generateContent?key=\(apiKey)") else {
            throw LatexServiceError.invalidBaseURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        func loadPrompt() -> String {
            guard let url = Bundle.main.url(forResource: "Prompt", withExtension: "txt"),
                  let content = try? String(contentsOf: url, encoding: .utf8) else {
                return "Convert handwriting into LaTeX. Only return LaTeX code."
            }
            return content
        }


        // Build JSON body with text instruction + image
        let systemPrompt = loadPrompt()
        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": systemPrompt + "\n\nHere is the image:"],
                    ["inlineData": [
                        "mimeType": "image/jpeg",
                        "data": base64Image
                    ]]
                ]
            ]]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        // Send request
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw LatexServiceError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1, snippet)
        }
        
        // Decode Gemini JSON response
        struct GeminiResponse: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String? }
                    let parts: [Part]
                }
                let content: Content
            }
            let candidates: [Candidate]
        }
        
        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        var latex = decoded.candidates.first?.content.parts.first?.text
        
        // Clean up ```latex fences if Gemini wrapped it
        latex = latex?
            .replacingOccurrences(of: "```latex", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let latexString = latex, !latexString.isEmpty else {
            throw LatexServiceError.decodeFailed
        }
        return latexString
    }
}
// MARK: - On-device backend (stub you can later wire to Apple’s on-device model)
#if canImport(FoundationModels)
struct OnDeviceLatexConverter: LatexConverting {
    func convert(image: UIImage) async throws -> String {
        // Ensure availability
        guard #available(iOS 18.0, *), FoundationModels.isAvailable else {
            throw LatexServiceError.onDeviceUnavailable("Apple Intelligence not supported on this device.")
        }

        // 1. Get a reference to the built-in text model
        let model = try await FMTextModel.named(.foundational)  // Apple’s built-in LLM

        // 2. Convert UIImage → JPEG data
        guard let jpegData = image.jpegData(compressionQuality: 0.85) else {
            throw LatexServiceError.imageEncodingFailed
        }

        // 3. Ask the model to describe the image as LaTeX
        // (You may later swap this for a vision-capable variant if Apple ships one;
        //  for now, we treat this as OCR via prompt injection.)
        let prompt = """
        You are a LaTeX converter. The user provides an image of handwriting or math.
        Respond ONLY with LaTeX code representing the content of the image.
        Do not add commentary.

        Here is the image:
        """

        let request = FMTextRequest(
            messages: [
                .user(prompt, attachments: [.init(data: jpegData, type: .imageJpeg)])
            ],
            options: .init(temperature: 0.0) // deterministic output
        )

        let response = try await model.complete(request: request)

        // 4. Return the text
        guard let latex = response.outputText, !latex.isEmpty else {
            throw LatexServiceError.decodeFailed
        }

        return latex
    }
}
#else
struct OnDeviceLatexConverter: LatexConverting {
    func convert(image: UIImage) async throws -> String {
        throw LatexServiceError.onDeviceUnavailable("This iOS SDK doesn’t include FoundationModels.")
    }
}
#endif
