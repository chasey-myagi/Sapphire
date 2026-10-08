//
//  APIKeyManager.swift
//  Sapphire
//
//  Created by Shariq Charolia on 2026-08-10

import Foundation
import Security

extension Notification.Name {
    static let apiKeyManagerSpotifyCredentialsChanged = Notification.Name("apiKeyManagerSpotifyCredentialsChanged")
    static let apiKeyManagerTidalCredentialsChanged = Notification.Name("apiKeyManagerTidalCredentialsChanged")
}

final class APIKeyManager {
    static let shared = APIKeyManager()

    private let keychain = KeychainHelper.standard
    private let legacyMigrationDefaultsKey = "apiKeysMigratedFromUserDefaults_v1"

    private let spotifyClientIdKeychainKey = "spotify_client_id"
    private let spotifyClientSecretKeychainKey = "spotify_client_secret"
    private let tidalClientIdKeychainKey = "tidal_client_id"
    private let tidalClientSecretKeychainKey = "tidal_client_secret"

    private init() {
        migrateLegacyUserDefaultsKeysIfNeeded()
    }

    private func migrateLegacyUserDefaultsKeysIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: legacyMigrationDefaultsKey) else { return }

        let defaults = UserDefaults.standard
        let migrations: [(keychainKey: String, userDefaultsKeys: [String])] = [
            (spotifyClientIdKeychainKey, ["spotifyClientId"]),
            (spotifyClientSecretKeychainKey, ["spotifyClientSecret"]),
        ]

        for migration in migrations {
            guard keychain.load(forKey: migration.keychainKey) == nil else { continue }
            for userDefaultsKey in migration.userDefaultsKeys {
                guard let existing = defaults.string(forKey: userDefaultsKey), !existing.isEmpty else { continue }
                keychain.save(existing, forKey: migration.keychainKey)
                break
            }
        }

        for migration in migrations {
            for userDefaultsKey in migration.userDefaultsKeys {
                defaults.removeObject(forKey: userDefaultsKey)
            }
        }

        defaults.set(true, forKey: legacyMigrationDefaultsKey)
    }

    // MARK: - Spotify
    var spotifyClientId: String {
        get { loadKey(keychainKey: spotifyClientIdKeychainKey) }
        set { saveKey(newValue, keychainKey: spotifyClientIdKeychainKey) }
    }

    var spotifyClientSecret: String {
        get { loadKey(keychainKey: spotifyClientSecretKeychainKey) }
        set { saveKey(newValue, keychainKey: spotifyClientSecretKeychainKey) }
    }

    // MARK: - TIDAL
    var tidalClientId: String {
        get { loadKey(keychainKey: tidalClientIdKeychainKey) }
        set { saveKey(newValue, keychainKey: tidalClientIdKeychainKey) }
    }

    var tidalClientSecret: String {
        get { loadKey(keychainKey: tidalClientSecretKeychainKey) }
        set { saveKey(newValue, keychainKey: tidalClientSecretKeychainKey) }
    }

    private func loadKey(keychainKey: String) -> String {
        keychain.load(forKey: keychainKey) ?? ""
    }

    private func saveKey(_ newValue: String, keychainKey: String) {
        if newValue.isEmpty {
            keychain.delete(forKey: keychainKey)
        } else {
            keychain.save(newValue, forKey: keychainKey)
        }

        if keychainKey == spotifyClientIdKeychainKey || keychainKey == spotifyClientSecretKeychainKey {
            NotificationCenter.default.post(name: .apiKeyManagerSpotifyCredentialsChanged, object: nil)
        }
        if keychainKey == tidalClientIdKeychainKey || keychainKey == tidalClientSecretKeychainKey {
            NotificationCenter.default.post(name: .apiKeyManagerTidalCredentialsChanged, object: nil)
        }
    }

    var hasSpotifyCredentials: Bool { !spotifyClientId.isEmpty && !spotifyClientSecret.isEmpty }
    var hasTidalCredentials: Bool { !tidalClientId.isEmpty && !tidalClientSecret.isEmpty }
}
