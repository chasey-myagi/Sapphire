//
//  SpotifyAppleScript.swift
//  Sapphire
//
//  Created by Shariq Charolia on 2025-09-22.
//

import Foundation
import AppKit

/// Commands that must reach Spotify itself. MediaRemote only addresses the system
/// Now Playing app, so these are used when Spotify is the selected source but another
/// app owns Now Playing.
@MainActor
protocol SpotifyPlaybackScripting: AnyObject {
    func isAppRunning() -> Bool
    @discardableResult func resume() async -> Bool
    @discardableResult func pause() async -> Bool
    @discardableResult func seek(to seconds: TimeInterval) async -> Bool
}

@MainActor
final class SpotifyAppleScriptManager: SpotifyPlaybackScripting {
    static let shared = SpotifyAppleScriptManager()

    private init() {}

    func isAppRunning() -> Bool {
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.spotify.client" }
    }

    @discardableResult
    func resume() async -> Bool {
        guard isAppRunning() else { return false }
        return await runAppleScriptInBackground("tell application \"Spotify\" to play track \"\"")
    }

    @discardableResult
    func pause() async -> Bool {
        guard isAppRunning() else { return false }
        return await runAppleScriptInBackground("tell application \"Spotify\" to pause")
    }

    @discardableResult
    func seek(to seconds: TimeInterval) async -> Bool {
        guard isAppRunning() else { return false }
        let clamped = max(0, seconds)
        return await runAppleScriptInBackground(
            "tell application \"Spotify\" to set player position to \(clamped)"
        )
    }

    private func runAppleScriptInBackground(_ script: String) async -> Bool {
        guard let result = await ProcessRunner.run(
            executablePath: "/usr/bin/osascript",
            arguments: ["-e", script],
            timeout: 2
        ) else { return false }
        return result.succeeded
    }
}
