//
//  EraserOverlay.swift
//  NTex
//
//  Created by Wataru Ishihara on 9/9/25.
//

import SwiftUI
import UIKit

private struct TouchCaptureView: UIViewRepresentable {
    var onBegan: (CGPoint) -> Void
    var onMoved: (CGPoint) -> Void
    var onEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        let parent: TouchCaptureView
        init(_ p: TouchCaptureView) { self.parent = p }

        @objc func handlePan(_ gr: UIPanGestureRecognizer) {
            let p = gr.location(in: gr.view)
            switch gr.state {
            case .began:
                parent.onBegan(p)
            case .changed:
                parent.onMoved(p)
            case .ended, .cancelled, .failed:
                parent.onEnded()
            default: break
            }
        }
    }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.minimumNumberOfTouches = 1
        pan.cancelsTouchesInView = true     // <- IMPORTANT: swallows touches so PKCanvasView can’t draw
        pan.delaysTouchesBegan = true
        v.addGestureRecognizer(pan)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) { }
}

/// Live view that collects an eraser path and returns it in PKCanvasView content coordinates.
struct EraserOverlay: View {
    
    struct CanvasViewport: Equatable {
        var zoomScale: CGFloat = 1
        var contentOffset: CGPoint = .zero
    }
    
    var radius: CGFloat
    @Binding var viewport: CanvasViewport
    var onEnded: (_ polylineInCanvasSpace: [CGPoint]) -> Void
    
    @State private var localPoints: [CGPoint] = []
    @State private var isDrawing = false
    
    private func toCanvasSpace(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x + viewport.contentOffset.x) / max(0.001, viewport.zoomScale),
                y: (p.y + viewport.contentOffset.y) / max(0.001, viewport.zoomScale))
    }
    
    var body: some View {
        GeometryReader { _ in
            ZStack {
                // 1) subtle preview of the eraser path
                if isDrawing, localPoints.count > 1 {
                    let displayRadius = radius * viewport.zoomScale
                    Path { p in p.addLines(localPoints) }
                        .stroke(Color.blue.opacity(0.25),
                                style: StrokeStyle(lineWidth: max(1, displayRadius*2),
                                                   lineCap: .round, lineJoin: .round))
                        .allowsHitTesting(false)
                }

                // 2) transparent view that SWALLOWS touches and feeds us points
                TouchCaptureView(
                    onBegan: { p in
                        isDrawing = true
                        localPoints.removeAll(keepingCapacity: true)
                        localPoints.append(p)
                    },
                    onMoved: { p in
                        guard isDrawing else { return }
                        localPoints.append(p)
                    },
                    onEnded: {
                        guard isDrawing else { return }
                        isDrawing = false

                        // Deduplicate close points
                        var dedup: [CGPoint] = []
                        dedup.reserveCapacity(localPoints.count)
                        for p in localPoints {
                            if let last = dedup.last, hypot(p.x - last.x, p.y - last.y) < 0.5 { continue }
                            dedup.append(p)
                        }

                        // Map to canvas content space and emit
                        let polyCanvas = dedup.map(toCanvasSpace)
                        localPoints.removeAll(keepingCapacity: true)
                        if polyCanvas.count > 1 { onEnded(polyCanvas) }
                    }
                )
                .allowsHitTesting(true) // must be hit-testable to block the canvas
            }
            .contentShape(Rectangle()) // capture the whole overlay area
        }
    }
}
