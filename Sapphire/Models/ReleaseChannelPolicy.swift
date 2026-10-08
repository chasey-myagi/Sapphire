//
//  ReleaseChannelPolicy.swift
//  Sapphire
//
//  Created by Shariq Charolia on 2026-08-10

import Foundation

enum ReleaseChannelPolicy {
    static var runningBuildChannel: ReleaseChannel {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return version.lowercased().contains("beta") ? .beta : .stable
    }

    static func preferredChannel(from settings: Settings) -> ReleaseChannel {
        return settings.releaseChannel
    }

    static func displayedChannel(for settings: Settings) -> ReleaseChannel {
        preferredChannel(from: settings)
    }

    static func shouldOfferStableDowngrade(for settings: Settings) -> Bool {
        runningBuildChannel == .beta && preferredChannel(from: settings) == .stable
    }

}
