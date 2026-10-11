//
//  MusicUtilities.swift
//  Sapphire
//
//  Created by Shariq Charolia on 2026-08-21

import Foundation
import SwiftUI
import AppKit
import Combine
import CryptoKit
import AVFoundation
import CoreAudio
import Accelerate

// MARK: - Consolidated from BrowserAppleScriptManager.swift

@MainActor
class BrowserAppleScriptManager {
    static let shared = BrowserAppleScriptManager()

    private init() {}

    private func escapeStringForAppleScript(_ input: String) -> String {
        return input.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    func focusTab(for bundleID: String, with trackTitle: String) {
        print("[BrowserAppleScriptManager] LOG: Received request to focus tab for bundleID: '\(bundleID)' with track title: '\(trackTitle)'")

        let appName: String
        let script: String
        let escapedTitle = escapeStringForAppleScript(trackTitle)

        switch bundleID {
        case "com.apple.Safari":
            appName = "Safari"
            script = """
            tell application "\(appName)"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        if name of t contains "\(escapedTitle)" then
                            set current tab of w to t
                            set index of w to 1
                            return "FOUND"
                        end if
                    end repeat
                end repeat
                return "NOT_FOUND"
            end tell
            """

        case "com.google.Chrome", "com.microsoft.edgemac":
            appName = bundleID == "com.google.Chrome" ? "Google Chrome" : "Microsoft Edge"
            script = """
            tell application "\(appName)"
                activate
                repeat with w in windows
                    set i to 0
                    repeat with t in tabs of w
                        set i to i + 1
                        if title of t contains "\(escapedTitle)" then
                            set active tab index of w to i
                            set index of w to 1
                            return "FOUND"
                        end if
                    end repeat
                end repeat
                return "NOT_FOUND"
            end tell
            """

        case "company.thebrowser.Browser":
            appName = "Arc"
            script = """
            tell application "\(appName)"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        if title of t contains "\(escapedTitle)" then
                            select t
                            set index of w to 1
                            return "FOUND"
                        end if
                    end repeat
                end repeat
                return "NOT_FOUND"
            end tell
            """

        default:
            print("[BrowserAppleScriptManager] LOG: BundleID '\(bundleID)' is not a supported browser. Aborting.")
            return
        }

        print("[BrowserAppleScriptManager] LOG: Determined app name: '\(appName)'.")
        print("[BrowserAppleScriptManager] LOG: Preparing to execute the following AppleScript:\n---\n\(script)\n---")

        Task {
            let result = await runAppleScriptInBackground(script)
            if result == "NOT_FOUND" {
                print("[BrowserAppleScriptManager] LOG: Tab not found. Activating app as a fallback.")
                if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    NSWorkspace.shared.open(appURL)
                }
            }
        }
    }

    private func runAppleScriptInBackground(_ script: String) async -> String {
        print("[BrowserAppleScriptManager] LOG: Executing AppleScript via osascript...")
        guard let result = await ProcessRunner.run(
            executablePath: "/usr/bin/osascript",
            arguments: ["-e", script],
            timeout: 5
        ) else {
            print("[BrowserAppleScriptManager] ERROR: AppleScript execution failed to launch.")
            return "ERROR"
        }
        if result.exitCode != 0 { return "ERROR" }
        let resultString = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[BrowserAppleScriptManager] LOG: AppleScript execution SUCCEEDED. Result: \(resultString)")
        return resultString
    }
}

// MARK: - Consolidated from SystemAudioMonitor.swift

class SystemAudioMonitor: ObservableObject {
    @Published var audioLevel: Float = 0.0

    private let engine = AVAudioEngine()
    private var isMonitoring = false
    private var lastUpdateTime: TimeInterval = 0

    init() {}

    func start() {
        guard !isMonitoring else { return }
        setupAndStartEngine()
    }

    func stop() {
        guard isMonitoring else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isMonitoring = false
    }

    private func setupAndStartEngine() {
        let inputNode = engine.inputNode

        guard let blackHoleDeviceID = findBlackHoleDeviceID() else {
            return
        }

        do {
            var deviceID = blackHoleDeviceID
            guard let audioUnit = inputNode.audioUnit else {
                print("[SystemAudioMonitor] Could not get AudioUnit for input node."); return
            }
            let error = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            if error != noErr {
                print("[SystemAudioMonitor] Failed to set input device. Error: \(error)"); return
            }
            try engine.start()
        } catch {
            print("[SystemAudioMonitor] Failed to start audio engine: \(error.localizedDescription)"); return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputNode.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            guard let self = self else { return }
            let level = self.calculateRMS(from: buffer)

            let now = CACurrentMediaTime()
            if now - self.lastUpdateTime >= 0.033 {
                self.lastUpdateTime = now
                DispatchQueue.main.async { self.audioLevel = level }
            }
        }

        isMonitoring = true
    }

    private func findBlackHoleDeviceID() -> AudioDeviceID? {
        var deviceID: AudioDeviceID = 0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        if status == noErr, let deviceName = CoreAudioDevices.name(of: deviceID), deviceName.contains("BlackHole") {
            return deviceID
        }

        guard let deviceIDs = CoreAudioDevices.all() else { return nil }

        for id in deviceIDs {
            if let name = CoreAudioDevices.name(of: id), name.contains("BlackHole") {
                return id
            }
        }

        return nil
    }

    private func calculateRMS(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        let channelCount = Int(buffer.format.channelCount)
        var rms: Float = 0.0

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            var channelRms: Float = 0.0
            vDSP_rmsqv(samples, 1, &channelRms, vDSP_Length(frameLength))
            rms += channelRms
        }

        let averageRms = rms / Float(channelCount)
        let amplifier: Float = 4.5
        let processedRms = min(1.0, averageRms * amplifier)

        return processedRms
    }
}

// MARK: - Consolidated from MusicLongPressSupport.swift

extension MusicLongPressAction {
    var isRepeatableWhileHeld: Bool {
        switch self {
        case .repeatMode, .shuffle, .playPause, .nextTrack, .previousTrack:
            return true
        default:
            return false
        }
    }

    @MainActor
    func feedbackSystemImage(musicManager: MusicManager) -> String {
        switch self {
        case .shuffle:
            return "shuffle"
        case .repeatMode:
            switch musicManager.repeatState {
            case .track: return "repeat.1"
            case .context: return "repeat"
            case .off: return "repeat"
            }
        case .playPause:
            return musicManager.isPlaying ? "pause.fill" : "play.fill"
        case .nextTrack:
            return "forward.fill"
        case .previousTrack:
            return "backward.fill"
        case .seek:
            return "goforward"
        case .none:
            return "ellipsis"
        }
    }

    @MainActor
    func feedbackColor(musicManager: MusicManager) -> Color {
        switch self {
        case .shuffle:
            return musicManager.shuffleState ? .green : .secondary
        case .repeatMode:
            return musicManager.repeatState != .off ? .green : .secondary
        default:
            return .primary
        }
    }
}

@MainActor
extension MusicManager {
    func performLongPressAction(_ action: MusicLongPressAction) async {
        switch action {
        case .none, .seek:
            break
        case .shuffle:
            await toggleShuffle()
        case .repeatMode:
            await cycleRepeatMode()
        case .playPause:
            if isPlaying {
                await pause()
            } else {
                await play()
            }
        case .nextTrack:
            await nextTrack()
        case .previousTrack:
            await previousTrack()
        }
    }
}

enum MusicLongPressUI {
    @MainActor
    static func skipHoldHandler(
        for target: MusicLongPressTarget,
        settings: Settings,
        musicManager: MusicManager
    ) -> (() -> Void)? {
        let action = settings.resolvedSkipHoldAction(for: target)
        guard action != .seek, action != .none else { return nil }
        return {
            Task { await musicManager.performLongPressAction(action) }
        }
    }

    static func skipHelp(primary: String, target: MusicLongPressTarget, settings: Settings) -> String {
        if !settings.musicLongPressActionsEnabled {
            return String(localized: "\(primary) · hold to seek")
        }
        let action = settings.resolvedSkipHoldAction(for: target)
        if action == .none {
            return primary
        }
        if action == .seek {
            return String(localized: "\(primary) · hold to seek")
        }
        return String(localized: "\(primary) · hold for \(action.displayName)")
    }

    static func accessoryHelp(primary: String, target: MusicLongPressTarget, settings: Settings) -> String {
        guard let action = settings.resolvedAccessoryHoldAction(for: target) else {
            return primary
        }
        return String(localized: "\(primary) · hold for \(action.displayName)")
    }
}

@MainActor
final class MusicHoldFeedbackController: ObservableObject {
    enum Palette {
        case standard
        case lightOverlay
    }

    @Published private(set) var action: MusicLongPressAction?
    @Published private(set) var icon: String?
    @Published private(set) var color: Color
    @Published private(set) var buttonID: String?

    private let palette: Palette
    private var restoreTask: Task<Void, Never>?
    private var actionInFlight = false

    init(palette: Palette = .standard) {
        self.palette = palette
        self.color = palette == .lightOverlay ? .white : .primary
    }

    func skipAction(for target: MusicLongPressTarget, settings: Settings) -> MusicLongPressAction? {
        let action = settings.resolvedSkipHoldAction(for: target)
        return action == .none || action == .seek ? nil : action
    }

    func handler(
        for action: MusicLongPressAction,
        musicManager: MusicManager,
        onCompletion: @escaping @MainActor () -> Void = {}
    ) -> () -> Void {
        { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.actionInFlight else { return }
                self.actionInFlight = true
                defer { self.actionInFlight = false }
                await musicManager.performLongPressAction(action)
                self.refresh(using: musicManager)
                onCompletion()
            }
        }
    }

    func begin(action: MusicLongPressAction, buttonID: String, musicManager: MusicManager) {
        restoreTask?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) {
            self.buttonID = buttonID
            self.action = action
            updateFeedback(for: action, using: musicManager)
        }
    }

    func end() {
        restoreTask?.cancel()
        restoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                self.action = nil
                self.icon = nil
                self.buttonID = nil
            }
        }
    }

    func reset() {
        restoreTask?.cancel()
        restoreTask = nil
        action = nil
        icon = nil
        buttonID = nil
    }

    private func refresh(using musicManager: MusicManager) {
        guard let action else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            updateFeedback(for: action, using: musicManager)
        }
    }

    private func updateFeedback(for action: MusicLongPressAction, using musicManager: MusicManager) {
        icon = action.feedbackSystemImage(musicManager: musicManager)
        let actionColor = action.feedbackColor(musicManager: musicManager)
        color = palette == .lightOverlay && actionColor == .secondary ? .white.opacity(0.7) : actionColor
    }
}

struct LongPressControlButton<Label: View>: View {
    let onTap: () -> Void
    var onLongPress: (() -> Void)? = nil
    var onHoldBegan: ((MusicLongPressAction) -> Void)? = nil
    var holdAction: MusicLongPressAction? = nil
    var onHoldRepeat: (() -> Void)? = nil
    var onHoldEnded: (() -> Void)? = nil
    @ViewBuilder var label: () -> Label

    var body: some View {
        if onLongPress != nil || holdAction != nil {
            LongPressControlButtonBody(
                onTap: onTap,
                onLongPress: onLongPress,
                onHoldBegan: onHoldBegan,
                holdAction: holdAction,
                onHoldRepeat: onHoldRepeat,
                onHoldEnded: onHoldEnded,
                label: label
            )
        } else {
            Button(action: onTap, label: label)
        }
    }
}

private struct LongPressControlButtonBody<Label: View>: View {
    let onTap: () -> Void
    let onLongPress: (() -> Void)?
    let onHoldBegan: ((MusicLongPressAction) -> Void)?
    let holdAction: MusicLongPressAction?
    let onHoldRepeat: (() -> Void)?
    let onHoldEnded: (() -> Void)?
    @ViewBuilder var label: () -> Label

    @GestureState private var isPressing = false
    @State private var longPressTimer: Timer?
    @State private var repeatTimer: Timer?
    @State private var tapIsEligible = false
    @State private var didFireLongPress = false

    var body: some View {
        label()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressing) { _, state, _ in state = true }
            )
            .onChange(of: isPressing) { _, nowPressing in
                if nowPressing {
                    tapIsEligible = true
                    didFireLongPress = false
                    longPressTimer?.invalidate()
                    repeatTimer?.invalidate()
                    let timer = Timer(timeInterval: 0.45, repeats: false) { _ in
                        tapIsEligible = false
                        didFireLongPress = true
                        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                        if let holdAction {
                            onHoldBegan?(holdAction)
                        }
                        onLongPress?()
                        let shouldRepeat = holdAction?.isRepeatableWhileHeld == true || onHoldRepeat != nil
                        guard shouldRepeat else { return }
                        let repeating = Timer(timeInterval: 0.55, repeats: true) { _ in
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                            onLongPress?()
                            onHoldRepeat?()
                        }
                        RunLoop.main.add(repeating, forMode: .common)
                        repeatTimer = repeating
                    }
                    RunLoop.main.add(timer, forMode: .common)
                    longPressTimer = timer
                } else {
                    longPressTimer?.invalidate()
                    repeatTimer?.invalidate()
                    repeatTimer = nil
                    if didFireLongPress {
                        onHoldEnded?()
                    } else if tapIsEligible {
                        onTap()
                    }
                    didFireLongPress = false
                }
            }
            .blur(radius: (isPressing && !didFireLongPress) ? 3 : 0)
            .scaleEffect(isPressing ? 0.92 : 1.0)
            .opacity((isPressing && !didFireLongPress) ? 0.85 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.5), value: isPressing)
            .animation(.easeInOut(duration: 0.12), value: didFireLongPress)
    }
}

// MARK: - Consolidated from ImageCache.swift

final class FileImageCache: @unchecked Sendable {
    static let shared = FileImageCache()

    private struct InFlightImage {
        let token: UUID
        let task: Task<NSImage?, Never>
    }

    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let ioQueue = DispatchQueue(label: "com.sapphire.imagecache.io", qos: .utility)
    private let memoryCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 48
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    private var inFlight: [String: InFlightImage] = [:]
    private let lock = NSLock()

    private init() {
        let cacheBaseUrl = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        cacheDirectory = cacheBaseUrl.appendingPathComponent("ImageCache")
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: nil)

        Task.detached(priority: .background) { [weak self] in
            self?.cleanupOldFiles()
        }
    }

    private func withLockedState<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func cacheKey(for urlKey: String) -> String {
        let digest = SHA256.hash(data: Data(urlKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func cacheUrl(forKey key: String) -> URL {
        cacheDirectory.appendingPathComponent(cacheKey(for: key)).appendingPathExtension("img")
    }

    private func approximateCost(for image: NSImage) -> Int {
        let size = image.size
        let pixels = max(1, Int(size.width * size.height))
        return min(pixels * 4, 8 * 1024 * 1024)
    }

    func get(forKey key: String) -> NSImage? {
        memoryCache.object(forKey: NSString(string: key))
    }

    func set(_ image: NSImage, forKey key: String, rawData: Data? = nil) {
        let cacheKey = NSString(string: key)
        memoryCache.setObject(image, forKey: cacheKey, cost: approximateCost(for: image))

        let url = cacheUrl(forKey: key)
        let dataToWrite: Data? = {
            if let rawData, !rawData.isEmpty { return rawData }
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else { return nil }
            return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
        }()

        guard let dataToWrite else { return }
        ioQueue.async {
            try? dataToWrite.write(to: url, options: .atomic)
        }
    }

    func image(for url: URL) async -> NSImage? {
        let key = url.absoluteString
        if let cached = get(forKey: key) { return cached }

        let request: InFlightImage = withLockedState {
            if let existing = inFlight[key] { return existing }
            let token = UUID()
            let task = Task.detached(priority: .utility) { [weak self] in
                await self?.loadOrDownloadImage(for: url, key: key)
            }
            let request = InFlightImage(token: token, task: task)
            inFlight[key] = request
            return request
        }

        let image = await request.task.value
        withLockedState {
            if inFlight[key]?.token == request.token {
                inFlight.removeValue(forKey: key)
            }
        }
        return image
    }

    private func loadOrDownloadImage(for url: URL, key: String) async -> NSImage? {
        if url.isFileURL {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  !Task.isCancelled,
                  let image = NSImage(data: data) else { return nil }
            memoryCache.setObject(
                image,
                forKey: NSString(string: key),
                cost: approximateCost(for: image)
            )
            return image
        }

        let diskURL = cacheUrl(forKey: key)
        if fileManager.fileExists(atPath: diskURL.path),
           let data = try? Data(contentsOf: diskURL),
           let image = NSImage(data: data) {
            memoryCache.setObject(
                image,
                forKey: NSString(string: key),
                cost: approximateCost(for: image)
            )
            return image
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled,
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let image = NSImage(data: data) else { return nil }
            set(image, forKey: key, rawData: data)
            return image
        } catch {
            return nil
        }
    }

    func remove(forKey key: String) {
        memoryCache.removeObject(forKey: NSString(string: key))
    }

    func trimMemoryCache() {
        memoryCache.removeAllObjects()
    }

    private func cleanupOldFiles() {
        let expirationInterval: TimeInterval = 7 * 24 * 60 * 60
        do {
            let files = try fileManager.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            )
            for file in files {
                if let modificationDate = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   Date().timeIntervalSince(modificationDate) > expirationInterval {
                    try fileManager.removeItem(at: file)
                }
            }
        } catch {
            print("Error cleaning up image cache: \(error)")
        }
    }
}

struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    private let url: URL?
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder

    @State private var image: NSImage?
    @State private var loadedURL: URL?

    init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let nsImage = image, url == loadedURL {
                content(Image(nsImage: nsImage))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                loadedURL = nil
                return
            }
            let nsImage = await FileImageCache.shared.image(for: url)
            image = nsImage
            loadedURL = url
        }
    }
}
