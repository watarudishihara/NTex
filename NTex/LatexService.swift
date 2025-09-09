import Foundation
import UIKit

enum LatexServiceError: LocalizedError {
    case invalidBaseURL
    case badStatus(Int, String)
    case noData
    case decodeFailed
    case imageEncodingFailed

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
        }
    }
}

struct LatexResponse: Decodable {
    let latex: String
}

/// Small, testable service for POST /to_latex (multipart/form-data)
struct LatexService {

    /// Uploads an image and returns the LaTeX string.
    /// - Parameters:
    ///   - image: UIImage to send (JPEG preferred)
    ///   - baseURLString: e.g. "http://192.168.0.42:8000"
    static func convert(image: UIImage, baseURLString: String) async throws -> String {
        guard let url = buildURL(baseURLString: baseURLString) else {
            throw LatexServiceError.invalidBaseURL
        }

        // Prefer JPEG ~90%; fall back to PNG
        let jpegData = image.jpegData(compressionQuality: 0.9)
        let payloadData = jpegData ?? image.pngData()
        guard let bodyData = payloadData else {
            throw LatexServiceError.imageEncodingFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        // Build multipart body
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"note.jpg\"\r\n")
        body.append("Content-Type: \(jpegData != nil ? "image/jpeg" : "image/png")\r\n\r\n")
        body.append(bodyData)
        body.append("\r\n")
        body.append("--\(boundary)--\r\n")
        request.httpBody = body

        // Short-ish timeout so the UI stays responsive
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw LatexServiceError.noData
        }

        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw LatexServiceError.badStatus(http.statusCode, snippet)
        }

        guard !data.isEmpty else { throw LatexServiceError.noData }
        guard let result = try? JSONDecoder().decode(LatexResponse.self, from: data) else {
            throw LatexServiceError.decodeFailed
        }
        return result.latex
    }

    private static func buildURL(baseURLString: String) -> URL? {
        guard var comps = URLComponents(string: baseURLString.trimmingCharacters(in: .whitespaces)) else { return nil }
        // If user typed just 192.168.x.x:8000, add http:// for them
        if comps.scheme == nil { comps.scheme = "http" }
        // Ensure we call /to_latex
        var base = comps.url
        if let u = base, !u.absoluteString.hasSuffix("/") {
            base = URL(string: u.absoluteString + "/")
        }
        return base?.appendingPathComponent("to_latex")
    }
}

// MARK: - Data helper
private extension Data {
    mutating func append(_ string: String) {
        if let d = string.data(using: .utf8) { append(d) }
    }
}
