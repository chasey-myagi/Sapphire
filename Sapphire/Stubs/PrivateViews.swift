//
//  PrivateViews.swift
//  Sapphire
//
//  Created by Shariq Charolia on 2026-08-30

#if !SAPPHIRE_FULL_BUILD
import SwiftUI

private struct UnavailableFeatureView: View {
    let name: String

    var body: some View {
        Text("\(name) is not included in this build.")
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SportsSettingsView: View {
    var body: some View { UnavailableFeatureView(name: String(localized: "Sports")) }
}


#endif
