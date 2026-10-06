import AppKit
import AudioToolbox
import AVFoundation
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// what a dropped file can turn into before it's sent or saved
enum ConvertFormat: String, CaseIterable, Codable {
    case jpeg, png, heic, pdf, m4a, wav, aiff, mp4

    var title: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .heic: return "HEIC"
        case .pdf: return "PDF"
        case .m4a: return "M4A"
        case .wav: return "WAV"
        case .aiff: return "AIFF"
        case .mp4: return "MP4"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        default: return rawValue
        }
    }

    var type: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .pdf: return .pdf
        case .m4a: return .mpeg4Audio
        case .wav: return .wav
        case .aiff: return .aiff
        case .mp4: return .mpeg4Movie
        }
    }
}

enum ConversionError: LocalizedError, Equatable {
    case unsupported
    case unreadable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported: return "Can't convert that"
        case .unreadable: return "Couldn't read the file"
        case .failed(let why): return "Couldn't convert (\(why))"
        }
    }
}

// converts with macos's own frameworks, no packages, at most 2 at once
// output goes to a temp folder that's cleaned when the card closes and at launch
actor ConversionService {
    static let jpegQuality = 0.85
    static let heicQuality = 0.8
    static var defaultRoot: URL {
        #if DEBUG
        // a test clearing a card never cleans up the app's folder
        if CommandLine.arguments.contains("--test") {
            return FileManager.default.temporaryDirectory.appendingPathComponent("dim-tests/convert", isDirectory: true)
        }
        #endif
        return FileManager.default.temporaryDirectory.appendingPathComponent("DynamicIslandManager/convert", isDirectory: true)
    }

    #if DEBUG
    // file names whose next conversion fails, for the error checks
    static var failOnce: Set<String> = []
    #endif

    // tests and scenarios get their own, so they never clean up the app's
    nonisolated let root: URL
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(root: URL = ConversionService.defaultRoot) {
        self.root = root
    }

    // gif and webp read through imageio too
    private static let imageInputs: [UTType] = [.heic, .heif, .png, .jpeg, .tiff, .bmp, .gif, .webP]
    private static let audioInputs: [UTType] = [.mpeg4Audio, .mp3, .wav, .aiff, UTType("public.aac-audio") ?? .mpeg4Audio,
                                                UTType("org.xiph.flac") ?? .mpeg4Audio, UTType("com.apple.coreaudio-format") ?? .mpeg4Audio]
    private static let videoInputs: [UTType] = [.quickTimeMovie, UTType("com.apple.m4v-video") ?? .quickTimeMovie]

    // heic output needs the encoder, not every mac has one
    static let canWriteHEIC: Bool = {
        let types = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return types.contains(UTType.heic.identifier)
    }()

    // cheap, from the extension only, the file's own format is never offered
    // heic is for tests, both sides of the encoder check whatever this mac has
    nonisolated static func outputs(for url: URL, isDirectory: Bool = false, heic: Bool = ConversionService.canWriteHEIC) -> [ConvertFormat] {
        guard !isDirectory, let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return [] }
        if imageInputs.contains(where: { type.conforms(to: $0) }) {
            var formats: [ConvertFormat] = [.jpeg, .png]
            if heic {
                formats.append(.heic)
            }
            formats.append(.pdf)
            return formats.filter { !type.conforms(to: $0.type) && !($0 == .heic && type.conforms(to: .heif)) }
        }
        if audioInputs.contains(where: { type.conforms(to: $0) }) {
            return [ConvertFormat.m4a, .wav, .aiff].filter { !type.conforms(to: $0.type) }
        }
        if videoInputs.contains(where: { type.conforms(to: $0) }) {
            return [.mp4]
        }
        return []
    }

    // a fresh temp folder per conversion, the file keeps the original's name
    func convert(_ source: URL, to format: ConvertFormat) async throws -> URL {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        #if DEBUG
        if Self.failOnce.remove(source.lastPathComponent) != nil {
            throw ConversionError.failed("forced for a check")
        }
        #endif
        guard Self.outputs(for: source).contains(format) else {
            throw ConversionError.unsupported
        }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent(source.deletingPathExtension().lastPathComponent)
            .appendingPathExtension(format.fileExtension)
        do {
            switch format {
            case .jpeg, .png, .heic:
                try Self.convertImage(source, to: output, format: format)
            case .pdf:
                try Self.imageToPDF(source, to: output)
            case .m4a:
                try await Self.export(source, to: output, preset: AVAssetExportPresetAppleM4A, fileType: .m4a)
            case .wav, .aiff:
                try await Self.writePCM(source, to: output, fileType: format == .wav ? .wav : .aiff)
            case .mp4:
                try await Self.convertMovie(source, to: output)
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            // avfoundation throws its own errors, the row should still say it couldn't convert
            if error is ConversionError || error is CancellationError {
                throw error
            }
            throw ConversionError.failed(error.localizedDescription)
        }
        print("converted: \(source.lastPathComponent) to \(output.lastPathComponent)")
        return output
    }

    // after the card closes and at launch
    nonisolated func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: root)
    }

    private func acquire() async {
        if running < 2 {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }

    // MARK: images

    // keeps orientation and metadata, the first frame of a gif
    private static func convertImage(_ source: URL, to output: URL, format: ConvertFormat) throws {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(input) > 0,
              CGImageSourceGetStatus(input) == .statusComplete else {
            throw ConversionError.unreadable
        }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw ConversionError.failed("no \(format.title) writer")
        }
        var options: [CFString: Any] = [:]
        switch format {
        case .jpeg: options[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        case .heic: options[kCGImageDestinationLossyCompressionQuality] = heicQuality
        default: break
        }
        CGImageDestinationAddImageFromSource(destination, input, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.failed("\(format.title) didn't write")
        }
    }

    private static func imageToPDF(_ source: URL, to output: URL) throws {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(input, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw ConversionError.unreadable
        }
        // the photo upright, the way it shows in finder
        let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32).flatMap { CGImagePropertyOrientation(rawValue: $0) } ?? .up
        let upright = CIImage(cgImage: image).oriented(orientation)
        let rep = NSCIImageRep(ciImage: upright)
        let page = NSImage(size: rep.size)
        page.addRepresentation(rep)
        guard let pdfPage = PDFPage(image: page) else {
            throw ConversionError.failed("no pdf page")
        }
        let document = PDFDocument()
        document.insert(pdfPage, at: 0)
        guard document.write(to: output) else {
            throw ConversionError.failed("pdf didn't write")
        }
    }

    // MARK: audio and video

    private static func export(_ source: URL, to output: URL, preset: String, fileType: AVFileType) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError.failed("no export session")
        }
        // setting a type the session can't write raises, and swift can't catch that
        guard session.supportedFileTypes.contains(fileType) else {
            throw ConversionError.failed("can't make that format from this file")
        }
        session.outputURL = output
        session.outputFileType = fileType
        // the x stops a long export too
        let handle = Unchecked(session)
        await withTaskCancellationHandler {
            await session.export()
        } onCancel: {
            handle.value.cancelExport()
        }
        try Task.checkCancellation()
        if session.status != .completed {
            throw ConversionError.failed(session.error?.localizedDescription ?? "export \(session.status.rawValue)")
        }
    }

    // passthrough when mp4 can carry the tracks as they are, else re-encode
    private static func convertMovie(_ source: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: source)
        if let passthrough = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough),
           passthrough.supportedFileTypes.contains(.mp4) {
            passthrough.outputURL = output
            passthrough.outputFileType = .mp4
            let handle = Unchecked(passthrough)
            await withTaskCancellationHandler {
                await passthrough.export()
            } onCancel: {
                handle.value.cancelExport()
            }
            try Task.checkCancellation()
            if passthrough.status == .completed {
                return
            }
            try? FileManager.default.removeItem(at: output)
        }
        try await export(source, to: output, preset: AVAssetExportPresetHighestQuality, fileType: .mp4)
    }

    // decode and write wav or aiff, keeping the source's channels, rate and depth
    // extaudiofile, avaudiofile and the asset writer only make aifc and stop at 192 khz
    private static func writePCM(_ source: URL, to output: URL, fileType: AVFileType) async throws {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            // a damaged, mislabelled or moved file fails here
            throw ConversionError.unreadable
        }
        let format = input.processingFormat
        let channels = format.channelCount
        guard channels > 0, format.sampleRate > 0 else {
            throw ConversionError.unreadable
        }
        let bits = UInt32(bitDepth(input.fileFormat.streamDescription.pointee))
        let aiff = fileType == .aiff
        // aiff is big endian, wav little
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: format.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | (aiff ? kAudioFormatFlagIsBigEndian : 0),
            mBytesPerPacket: bits / 8 * channels, mFramesPerPacket: 1, mBytesPerFrame: bits / 8 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0)
        // past stereo the file carries a layout, the source's own when it has one
        let layout = channels > 2 ? channelLayout(format.channelLayout, channels: Int(channels)) : nil
        var file: ExtAudioFileRef?
        let type = aiff ? kAudioFileAIFFType : kAudioFileWAVEType
        var status: OSStatus
        if let layout {
            status = layout.withUnsafeBytes { bytes in
                ExtAudioFileCreateWithURL(output as CFURL, type, &fileFormat, bytes.baseAddress?.assumingMemoryBound(to: AudioChannelLayout.self),
                                          AudioFileFlags.eraseFile.rawValue, &file)
            }
        } else {
            status = ExtAudioFileCreateWithURL(output as CFURL, type, &fileFormat, nil, AudioFileFlags.eraseFile.rawValue, &file)
        }
        guard status == noErr, let file else {
            throw ConversionError.failed("can't write \(channels) channel audio (\(status))")
        }
        // closing it finishes the header, a stopped or failed one is removed with its folder
        defer { ExtAudioFileDispose(file) }
        var client = format.streamDescription.pointee
        status = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard status == noErr, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else {
            throw ConversionError.failed("can't convert this audio (\(status))")
        }
        // the x is checked between buffers
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            status = ExtAudioFileWrite(file, buffer.frameLength, buffer.audioBufferList)
            guard status == noErr else {
                throw ConversionError.failed("the audio didn't write (\(status))")
            }
        }
    }

    // lossless sources keep their depth, lossy ones have none so 16 is plenty
    private static func bitDepth(_ basic: AudioStreamBasicDescription) -> Int {
        switch basic.mFormatID {
        case kAudioFormatLinearPCM:
            // float goes to 32 bit integer, the same resolution below full scale
            if basic.mFormatFlags & kAudioFormatFlagIsFloat != 0 || basic.mBitsPerChannel > 24 {
                return 32
            }
            return basic.mBitsPerChannel > 16 ? 24 : 16
        case kAudioFormatAppleLossless, kAudioFormatFLAC:
            // their bits per channel is 0, the flags hold the source's depth
            switch basic.mFormatFlags {
            case kAppleLosslessFormatFlag_32BitSourceData: return 32
            case kAppleLosslessFormatFlag_20BitSourceData, kAppleLosslessFormatFlag_24BitSourceData: return 24
            default: return 16
            }
        default:
            return 16
        }
    }

    // the source's layout when it has one for these channels, else the channels in order
    private static func channelLayout(_ layout: AVAudioChannelLayout?, channels: Int) -> Data {
        if let layout, Int(layout.channelCount) == channels {
            let descriptions = Int(layout.layout.pointee.mNumberChannelDescriptions)
            let size = MemoryLayout<AudioChannelLayout>.size + max(0, descriptions - 1) * MemoryLayout<AudioChannelDescription>.size
            return Data(bytes: layout.layout, count: size)
        }
        var tagged = AudioChannelLayout()
        tagged.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels)
        return Data(bytes: &tagged, count: MemoryLayout<AudioChannelLayout>.size)
    }
}

// an export session is cancelled from another thread, which it allows, swift can't see that
private final class Unchecked<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
