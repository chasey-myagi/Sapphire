//
//  MusicModels.swift
//  Sapphire
//
//  Created by Shariq Charolia on 2025-10-02
//

import Foundation

// MARK: - Shared Enums

enum RepeatMode: String, Codable {
    case off, context, track

    func next() -> RepeatMode {
        switch self {
        case .off: return .context
        case .context: return .track
        case .track: return .off
        }
    }
}
