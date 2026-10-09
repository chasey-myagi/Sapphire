import XCTest
import AVFoundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import Sapphire

final class FileConversionTests: XCTestCase {
    @MainActor
    func testMP4ConvertsToReadableMOV() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        let destination = directory.appendingPathComponent("output.mov")
        try await writeVideo(to: source, fileType: .mp4)
        let formats = FileConversionManager.shared.availableFormats(for: source).map(\.id)
        XCTAssertTrue(formats.contains("mov"))
        XCTAssertFalse(formats.contains("mp4"))
        try await FileConversionManager.shared.convert(from: source, to: destination, as: .quickTimeMovie)
        try await assertReadableMedia(at: destination, mediaType: .video)
        XCTAssertEqual(try destination.resourceValues(forKeys: [.contentTypeKey]).contentType, .quickTimeMovie)
    }

    @MainActor
    func testMOVConvertsToReadableMP4() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        let destination = directory.appendingPathComponent("output.mp4")
        try await writeVideo(to: source, fileType: .mov)
        let formats = FileConversionManager.shared.availableFormats(for: source).map(\.id)
        XCTAssertTrue(formats.contains("mp4"))
        XCTAssertFalse(formats.contains("mov"))
        try await FileConversionManager.shared.convert(from: source, to: destination, as: .mpeg4Movie)
        try await assertReadableMedia(at: destination, mediaType: .video)
        XCTAssertEqual(try destination.resourceValues(forKeys: [.contentTypeKey]).contentType, .mpeg4Movie)
    }

    @MainActor
    func testImageConversionProducesReadableJPEG() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        let destination = directory.appendingPathComponent("output.jpeg")
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try XCTUnwrap(context.makeImage())
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        try await FileConversionManager.shared.convert(from: source, to: destination, as: .jpeg)
        let reader = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(reader) as String?, UTType.jpeg.identifier)
        let converted = try XCTUnwrap(CGImageSourceCreateImageAtIndex(reader, 0, nil))
        XCTAssertEqual(converted.width, 8)
        XCTAssertEqual(converted.height, 8)
    }

    @MainActor
    func testAudioConversionProducesReadableM4A() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let destination = directory.appendingPathComponent("output.m4a")
        try writeAudio(to: source)
        XCTAssertTrue(FileConversionManager.shared.availableFormats(for: source).map(\.id).contains("m4a"))
        try await FileConversionManager.shared.convert(from: source, to: destination, as: .mpeg4Audio)
        try await assertReadableMedia(at: destination, mediaType: .audio)
    }

    @MainActor
    func testUnsupportedFormatReturnsARecoverableError() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.data")
        let destination = directory.appendingPathComponent("output.data")
        try Data([1, 2, 3]).write(to: source)
        do {
            try await FileConversionManager.shared.convert(from: source, to: destination, as: .data)
            XCTFail("Unsupported formats must fail through a recoverable error")
        } catch {
            XCTAssertEqual((error as NSError).domain, "FileConversionError")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    func testUnsupportedVideoFormatReturnsARecoverableError() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        let destination = directory.appendingPathComponent("output.avi")
        try await writeVideo(to: source, fileType: .mp4)
        do {
            try await FileConversionManager.shared.convert(from: source, to: destination, as: .avi)
            XCTFail("An unsupported video container must be rejected before configuring the exporter")
        } catch {
            XCTAssertEqual((error as NSError).domain, "FileConversionError")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    func testUnsupportedAudioFormatReturnsARecoverableError() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let destination = directory.appendingPathComponent("output.wav")
        try writeAudio(to: source)
        do {
            try await FileConversionManager.shared.convert(from: source, to: destination, as: .wav)
            XCTFail("An unsupported audio container must not silently produce M4A")
        } catch {
            XCTAssertEqual((error as NSError).domain, "FileConversionError")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    func testTextConversionPreservesReadablePDFContentAcrossPages() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.txt")
        let destination = directory.appendingPathComponent("output.pdf")
        let text = "FIRST-VISIBLE-LINE\n" + (0..<180).map { "Line \($0) content" }.joined(separator: "\n") + "\nCOMPLETE-TAIL"
        try text.write(to: source, atomically: true, encoding: .utf8)
        try await FileConversionManager.shared.convert(from: source, to: destination, as: .pdf)
        let document = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertGreaterThan(document.pageCount, 1)
        let visibleText = (0..<document.pageCount).compactMap { index -> String? in
            guard let page = document.page(at: index) else { return nil }
            return page.selection(for: page.bounds(for: .mediaBox))?.string
        }.joined(separator: "\n")
        XCTAssertTrue(visibleText.contains("FIRST-VISIBLE-LINE"), "The first line must lie within the PDF page")
        for line in 0..<180 {
            XCTAssertTrue(visibleText.contains("Line \(line) content"), "Missing line \(line)")
        }
        XCTAssertTrue(visibleText.contains("COMPLETE-TAIL"), "The entire document must be exported")
    }

    @MainActor
    func testTextConversionPreservesRTFContent() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.txt")
        let destination = directory.appendingPathComponent("output.rtf")
        let text = "First line\n中文文本\nFinal line"
        try text.write(to: source, atomically: true, encoding: .utf8)
        try await FileConversionManager.shared.convert(from: source, to: destination, as: .rtf)
        let restored = try NSAttributedString(url: destination, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertEqual(restored.string, text)
    }

    private func writeAudio(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        try XCTUnwrap(buffer.floatChannelData)[0].initialize(repeating: 0, count: 4_410)
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    private func writeVideo(to url: URL, fileType: AVFileType) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &pixelBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        pixels.initializeMemory(as: UInt8.self, repeating: 128, count: CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let deadline = Date().addingTimeInterval(5)
        for frame in 0..<3 {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, Date() < deadline else {
                    throw writer.error ?? NSError(domain: "VideoFixtureError", code: 1)
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "Video fixture did not finish")
    }

    @MainActor
    private func assertReadableMedia(at url: URL, mediaType: AVMediaType, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertGreaterThan(try Data(contentsOf: url).count, 0, file: file, line: line)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(CMTimeGetSeconds(duration), 0, file: file, line: line)
        let tracks = try await asset.loadTracks(withMediaType: mediaType)
        let track = try XCTUnwrap(tracks.first, file: file, line: line)
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any]? = mediaType == .video ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] : [AVFormatIDKey: kAudioFormatLinearPCM]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        XCTAssertTrue(reader.canAdd(output), file: file, line: line)
        reader.add(output)
        XCTAssertTrue(reader.startReading(), reader.error?.localizedDescription ?? "Could not read converted media", file: file, line: line)
        XCTAssertNotNil(output.copyNextSampleBuffer(), reader.error?.localizedDescription ?? "No readable media samples", file: file, line: line)
        reader.cancelReading()
    }
}
