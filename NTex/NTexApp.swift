//
//  NTexApp.swift
//  NTex
//
//  Created by Wataru Ishihara on 9/2/25.
//

import SwiftUI

@main
struct NTexApp: App {
    @StateObject private var store = NotebookStore.shared
    var body: some Scene {
        WindowGroup {
            FoldersView()                 // start at folders list
                .environmentObject(store) // inject the store once
        }
    }
}
