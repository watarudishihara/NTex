//
//  PseudoLatexPreview.swift
//  NTex
//
//  Created by Wataru Ishihara on 9/11/25.
//
import SwiftUI
import WebKit

struct PseudoLatexPreview: UIViewRepresentable {
    let text: String
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var ready = false
        var pending: String?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            if let html = pending { LatexService.setInnerHTML(html, on: webView); pending = nil }
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero)
        wv.navigationDelegate = context.coordinator
        LatexService.loadShell(into: wv)
        return wv
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let inner = LatexService.renderInnerHTML(from: text)
        if context.coordinator.ready { LatexService.setInnerHTML(inner, on: webView) }
        else { context.coordinator.pending = inner }
    }
}
