//
//  StrokeEraser.swift
//  NTex
//
//  Created by Wataru Ishihara on 9/9/25.
//
import Foundation
import PencilKit
import CoreGraphics

public enum StrokeEraser {

    /// Main entry: split strokes that come within `radius` (canvas-content coords) of the eraser polyline.
    public static func erase(_ drawing: PKDrawing,
                             with eraser: [CGPoint],
                             radius: CGFloat) -> PKDrawing
    {
        guard !eraser.isEmpty, radius > 0 else { return drawing }
        let r2 = radius * radius
        var out: [PKStroke] = []

        for stroke in drawing.strokes {
            // 1) Get the original points (preserves pressure/width/etc.)
            let origPoints = points(from: stroke.path)
            if origPoints.count < 2 {
                // trivial: either keep or drop single-point strokes
                if let p = origPoints.first, !hit(p.location, eraser, r2) { out.append(stroke) }
                continue
            }

            // 2) Build keep-mask for each point
            var keep: [Bool] = .init(repeating: true, count: origPoints.count)
            for i in 0..<origPoints.count {
                keep[i] = !hit(origPoints[i].location, eraser, r2)
            }

            // 3) Make runs of kept points; drop crumbs (very short remnants)
            let runs = keptRuns(keepMask: keep, minCount: minCountToKeep(points: origPoints, radius: radius))

            if runs.isEmpty {
                // everything erased
                continue
            }

            // 4) Rebuild PKStrokes from original control points for each run
            for run in runs {
                // Ensure at least 2 points for a valid path
                guard run.count >= 2 else { continue }
                let sub = Array(origPoints[run])
                let path = PKStrokePath(controlPoints: sub, creationDate: stroke.path.creationDate)
                let rebuilt = PKStroke(ink: stroke.ink, path: path, transform: .identity)
                out.append(rebuilt)
            }
        }
        return PKDrawing(strokes: out)
    }

    // MARK: - Helpers

    /// Extract all control points in order (preserves width/pressure).
    private static func points(from path: PKStrokePath) -> [PKStrokePoint] {
        var pts: [PKStrokePoint] = []
        pts.reserveCapacity(path.count)
        // PKStrokePath conforms to Sequence of PKStrokePoint
        for p in path { pts.append(p) }
        return pts
    }

    /// Return array of contiguous index ranges where keepMask == true
    private static func keptRuns(keepMask: [Bool], minCount: Int) -> [Range<Int>] {
        var res: [Range<Int>] = []
        var i = 0
        while i < keepMask.count {
            if keepMask[i] {
                let start = i
                i += 1
                while i < keepMask.count, keepMask[i] { i += 1 }
                let r = start..<i
                if r.count >= minCount { res.append(r) }
            } else {
                i += 1
            }
        }
        return res
    }

    /// Small heuristic: drop tiny fragments. Use radius & average spacing estimate.
    private static func minCountToKeep(points: [PKStrokePoint], radius: CGFloat) -> Int {
        guard points.count >= 2 else { return 2 }
        var dist: CGFloat = 0
        for i in 1..<points.count {
            let a = points[i-1].location, b = points[i].location
            dist += hypot(b.x - a.x, b.y - a.y)
        }
        let avg = max(0.5, dist / CGFloat(max(1, points.count - 1)))
        let want = Int((2 * radius) / avg)   // ~ 2× radius worth of path
        return max(2, min(8, want))
    }

    /// Is point within r^2 of the polyline?
    private static func hit(_ p: CGPoint, _ poly: [CGPoint], _ r2: CGFloat) -> Bool {
        guard poly.count > 1 else { return false }
        var best = CGFloat.greatestFiniteMagnitude
        for i in 1..<poly.count {
            best = min(best, dist2PointToSegment(p, poly[i-1], poly[i]))
            if best <= r2 { return true }
        }
        return false
    }

    /// Squared distance from a point to segment AB
    private static func dist2PointToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let ap = CGPoint(x: p.x - a.x, y: p.y - a.y)
        let ab2 = ab.x*ab.x + ab.y*ab.y
        if ab2 <= 1e-6 {
            // a==b
            let dx = p.x - a.x, dy = p.y - a.y
            return dx*dx + dy*dy
        }
        let t = max(0, min(1, (ap.x*ab.x + ap.y*ab.y) / ab2))
        let proj = CGPoint(x: a.x + t*ab.x, y: a.y + t*ab.y)
        let dx = p.x - proj.x, dy = p.y - proj.y
        return dx*dx + dy*dy
    }
}
