//
//  OpenWatchApp.swift
//  OpenWatch
//
//  Created by Alex Ign on 03.06.2026.
//

import SwiftUI

@main
struct OpenWatchApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
