//
//  LatexExpoerter.swift
//  NTex
//
//  Created by Wataru Ishihara on 9/10/25.
//

import Foundation

struct LatexExporter {
    static func buildTeXDocument(body: String, title: String = "NTex") -> String {
        """
        \\documentclass[11pt]{article}
        \\usepackage{amsmath, amssymb}
        \\usepackage[margin=1in]{geometry}
        \\title{\(title)}
        \\begin{document}
        \\maketitle

        \(body)

        \\end{document}
        """
    }

    static func writeTeXFile(body: String, fileName: String = "NTex.tex") throws -> URL {
        let tex = buildTeXDocument(body: body)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try tex.data(using: .utf8)!.write(to: url, options: .atomic)
        return url
    }
}
