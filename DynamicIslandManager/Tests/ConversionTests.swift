#if DEBUG
import AppKit
import AudioToolbox
import AVFoundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// small real files made at test time, converted, then opened again
enum ConversionTests: TestSuite {
    static let name = "Conversion"

    static func image(_ dir: URL, _ name: String, type: UTType, width: Int = 64, height: Int = 48) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.9, green: 0.6, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConversionError.failed("no writer for \(type.identifier)")
        }
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.failed("fixture") }
        return url
    }

    // a 440 hz tone as a wav, float unless bits says otherwise
    // written with extaudiofile, avaudiofile would quietly cap the rate at 192 khz
    static func tone(_ dir: URL, _ name: String, seconds: Double = 1, rate: Double = 44_100,
                     channels: UInt32 = 1, bits: UInt32? = nil) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let depth = bits ?? 32
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: (bits == nil ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) | kAudioFormatFlagIsPacked,
            mBytesPerPacket: depth / 8 * channels, mFramesPerPacket: 1, mBytesPerFrame: depth / 8 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: depth, mReserved: 0)
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)!
        var file: ExtAudioFileRef?
        let status = ExtAudioFileCreateWithURL(url as CFURL, kAudioFileWAVEType, &fileFormat, channels > 2 ? layout.layout : nil,
                                               AudioFileFlags.eraseFile.rawValue, &file)
        guard status == noErr, let file else { throw ConversionError.failed("fixture \(status)") }
        defer { ExtAudioFileDispose(file) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false, channelLayout: layout)
        var client = format.streamDescription.pointee
        ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for index in 0..<Int(frames) {
                buffer.floatChannelData![channel][index] = Float(sin(2 * .pi * 440 * Double(index) / rate) * 0.3)
            }
        }
        guard ExtAudioFileWrite(file, frames, buffer.audioBufferList) == noErr else { throw ConversionError.failed("fixture") }
        return url
    }

    // convert names the file itself, so this reads what it really holds
    static func container(_ url: URL) -> String {
        guard let head = try? FileHandle(forReadingFrom: url).read(upToCount: 12), head.count == 12 else { return "" }
        let word = { (at: Int) in String(decoding: head[at..<at + 4], as: UTF8.self) }
        // riff and form name the type at 8, iso media has ftyp at 4 and its brand at 8
        return ["RIFF", "FORM"].contains(word(0)) || word(4) == "ftyp" ? word(8) : ""
    }

    static func audioFormat(_ url: URL) async throws -> AudioStreamBasicDescription? {
        let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first
        let format = try await track?.load(.formatDescriptions).first
        return format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
    }

    // a short movie of solid frames
    static func movie(_ dir: URL, _ name: String, frames: Int = 30) async throws -> URL {
        let url = dir.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                           AVVideoWidthKey: 160, AVVideoHeightKey: 120])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 160, 120, kCVPixelFormatType_32BGRA, nil, &buffer)
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    static func duration(_ url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    static func service(_ dir: URL) -> ConversionService {
        ConversionService(root: dir.appendingPathComponent("convert", isDirectory: true))
    }

    static var tests: [TestCase] {
        [
            TestCase("what each type can become, never itself") { t in
                func outputs(_ name: String) -> [ConvertFormat] {
                    ConversionService.outputs(for: URL(fileURLWithPath: "/tmp/" + name))
                }
                let heic: [ConvertFormat] = ConversionService.canWriteHEIC ? [.heic] : []
                t.expectEqual(outputs("a.heic"), [.jpeg, .png, .pdf])
                t.expectEqual(outputs("a.png"), [.jpeg] + heic + [.pdf], "png isn't offered for a png")
                t.expectEqual(outputs("a.JPG"), [.png] + heic + [.pdf])
                t.expectEqual(outputs("a.gif"), [.jpeg, .png] + heic + [.pdf])
                t.expectEqual(outputs("a.wav"), [.m4a, .aiff])
                t.expectEqual(outputs("a.m4a"), [.wav, .aiff])
                t.expectEqual(outputs("a.mp3"), [.m4a, .wav, .aiff], "no mp3 output, macos has no encoder")
                t.expectEqual(outputs("a.heif"), [.jpeg, .png, .pdf])
                t.expectEqual(outputs("a.tiff"), [.jpeg, .png] + heic + [.pdf])
                t.expectEqual(outputs("a.bmp"), [.jpeg, .png] + heic + [.pdf])
                t.expectEqual(outputs("a.webp"), [.jpeg, .png] + heic + [.pdf])
                t.expectEqual(outputs("a.aiff"), [.m4a, .wav])
                for name in ["a.aac", "a.flac", "a.caf"] {
                    t.expectEqual(outputs(name), [.m4a, .wav, .aiff], name)
                }
                t.expectEqual(outputs("a.m4v"), [.mp4])
                // both sides of the encoder check, whatever this mac has
                let png = URL(fileURLWithPath: "/tmp/a.png")
                t.expectEqual(ConversionService.outputs(for: png, heic: true), [.jpeg, .heic, .pdf])
                t.expectEqual(ConversionService.outputs(for: png, heic: false), [.jpeg, .pdf])
                t.expectEqual(outputs("a.mov"), [.mp4])
                t.expectEqual(outputs("a.mp4"), [], "mp4 is already the output")
                t.expectEqual(outputs("a.pdf"), [])
                t.expectEqual(outputs("a.docx"), [])
                t.expectEqual(outputs("a.zip"), [])
                t.expectEqual(ConversionService.outputs(for: URL(fileURLWithPath: "/tmp/folder"), isDirectory: true), [])
            },
            TestCase("images convert and keep their size") { t in
                let dir = try t.tempDirectory()
                let service = service(dir)
                let png = try image(dir, "photo.png", type: .png)
                let jpeg = try await service.convert(png, to: .jpeg)
                t.expectEqual(jpeg.lastPathComponent, "photo.jpg")
                let source = CGImageSourceCreateWithURL(jpeg as CFURL, nil)
                t.expectEqual(source.flatMap { CGImageSourceGetType($0) as String? }, UTType.jpeg.identifier)
                let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
                t.expectEqual(properties?[kCGImagePropertyPixelWidth] as? Int, 64)
                t.expectEqual(properties?[kCGImagePropertyPixelHeight] as? Int, 48)
                if ConversionService.canWriteHEIC {
                    let heic = try await service.convert(png, to: .heic)
                    t.expectEqual(CGImageSourceCreateWithURL(heic as CFURL, nil).flatMap { CGImageSourceGetType($0) as String? },
                                  UTType.heic.identifier)
                    // a heic in, the main case
                    let fromHEIC = try await service.convert(try image(dir, "shot.heic", type: .heic), to: .jpeg)
                    let out = CGImageSourceCreateWithURL(fromHEIC as CFURL, nil)
                    t.expectEqual(out.flatMap { CGImageSourceGetType($0) as String? }, UTType.jpeg.identifier)
                    let size = out.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
                    t.expectEqual(size?[kCGImagePropertyPixelWidth] as? Int, 64)
                }
                let pdf = try await service.convert(png, to: .pdf)
                t.expectEqual(PDFDocument(url: pdf)?.pageCount, 1)
                let back = try await service.convert(jpeg, to: .png)
                t.expectEqual(CGImageSourceCreateWithURL(back as CFURL, nil).flatMap { CGImageSourceGetType($0) as String? }, UTType.png.identifier)
            },
            TestCase("audio converts and keeps its length") { t in
                let dir = try t.tempDirectory()
                let service = service(dir)
                let wav = try tone(dir, "tone.wav")
                let m4a = try await service.convert(wav, to: .m4a)
                t.expectEqual(m4a.lastPathComponent, "tone.m4a")
                t.expectEqual(container(m4a), "M4A ")
                t.expect(abs(try await duration(m4a) - 1) < 0.1, "m4a length")
                let aiff = try await service.convert(m4a, to: .aiff)
                t.expectEqual(container(aiff), "AIFF")
                t.expect(abs(try await duration(aiff) - 1) < 0.1, "aiff length")
                let back = try await service.convert(aiff, to: .wav)
                t.expectEqual(container(back), "WAVE")
                t.expect(abs(try await duration(back) - 1) < 0.1, "wav length")
                let tracks = try await AVURLAsset(url: back).loadTracks(withMediaType: .audio)
                t.expectEqual(tracks.count, 1)
            },
            TestCase("a movie becomes an mp4 that plays as long as the source") { t in
                let dir = try t.tempDirectory()
                let mov = try await movie(dir, "clip.mov")
                let mp4 = try await service(dir).convert(mov, to: .mp4)
                t.expectEqual(mp4.lastPathComponent, "clip.mp4")
                t.expect(!["", "qt  "].contains(container(mp4)), "an mp4 brand, not quicktime (\(container(mp4)))")
                let source = try await duration(mov)
                t.expect(abs(try await duration(mp4) - source) < 0.1, "mp4 length within 0.1 s of \(source)")
                t.expect(try await !AVURLAsset(url: mp4).loadTracks(withMediaType: .video).isEmpty)
            },
            TestCase("unreadable or unsupported input fails clearly and leaves no temp folder") { t in
                let dir = try t.tempDirectory()
                let service = service(dir)
                let bogus = dir.appendingPathComponent("broken.png")
                try Data("not an image".utf8).write(to: bogus)
                await t.expectThrows({ try await service.convert(bogus, to: .jpeg) }) { ($0 as? ConversionError) == .unreadable }
                let pdf = dir.appendingPathComponent("doc.pdf")
                try Data("%PDF-1.4".utf8).write(to: pdf)
                await t.expectThrows({ try await service.convert(pdf, to: .jpeg) }) { ($0 as? ConversionError) == .unsupported }
                // avfoundation's own error comes back as a conversion error, the row says couldn't
                let fake = dir.appendingPathComponent("fake.wav")
                try Data("not audio".utf8).write(to: fake)
                await t.expectThrows({ try await service.convert(fake, to: .aiff) }) { $0 is ConversionError }
                t.expectEqual(DriveError.from(ConversionError.failed("x")).shortText, "Couldn't convert (x)")
                let left = (try? FileManager.default.contentsOfDirectory(atPath: service.root.path)) ?? []
                t.expect(left.isEmpty, "\(left)")
            },
            TestCase("surround, hi-res and 24 bit audio convert without bringing the app down") { t in
                let dir = try t.tempDirectory()
                let service = service(dir)
                let surround = try await service.convert(try tone(dir, "surround.wav", seconds: 0.2, rate: 48_000, channels: 6), to: .aiff)
                t.expectEqual(container(surround), "AIFF")
                t.expectEqual(try await audioFormat(surround)?.mChannelsPerFrame, 6)
                let hires = try await service.convert(try tone(dir, "hires.wav", seconds: 0.2, rate: 384_000, channels: 2), to: .aiff)
                t.expectEqual(container(hires), "AIFF")
                t.expectEqual(try await audioFormat(hires)?.mSampleRate, 384_000, "the rate is kept")
                let deep = try await service.convert(try tone(dir, "deep.wav", seconds: 0.2, rate: 96_000, channels: 2, bits: 24), to: .aiff)
                t.expectEqual(try await audioFormat(deep)?.mBitsPerChannel, 24, "24 bit stays 24 bit")
            },
            TestCase("the temp folder goes on cleanup") { t in
                let dir = try t.tempDirectory()
                let service = service(dir)
                _ = try await service.convert(try image(dir, "a.png", type: .png), to: .jpeg)
                t.expect(FileManager.default.fileExists(atPath: service.root.path))
                service.removeTemporaryFiles()
                t.expect(!FileManager.default.fileExists(atPath: service.root.path))
            },
            TestCase("defaults pre-select only what they name") { t in
                let dir = try t.tempDirectory()
                let wav = FileItem(url: try tone(dir, "a.wav", seconds: 0.1))
                let png = FileItem(url: try image(dir, "a.png", type: .png))
                let heic = FileItem(url: dir.appendingPathComponent("photo.heic"))
                let mov = FileItem(url: dir.appendingPathComponent("clip.mov"))
                let all: (String) -> String = { ["convertHEIC": "jpeg", "convertAudio": "m4a", "convertMOV": "mp4"][$0] ?? "keep" }
                let none: (String) -> String = { _ in "keep" }
                t.expectEqual(ConvertDefaults.format(for: heic, value: all), .jpeg)
                t.expectEqual(ConvertDefaults.format(for: wav, value: all), .m4a)
                t.expectEqual(ConvertDefaults.format(for: mov, value: all), .mp4)
                t.expect(ConvertDefaults.format(for: png, value: all) == nil, "no default for png")
                t.expect(ConvertDefaults.format(for: heic, value: none) == nil, "keep is the default")
                let parsed = ConvertDefaults.parse(["app", "--convert-defaults", "heic=jpeg,audio=m4a,bogus"])
                t.expectEqual(parsed, ["convertHEIC": "jpeg", "convertAudio": "m4a"])
                t.expect(ConvertDefaults.parse(["app"]) == nil)
            },
            TestCase("save to mac names like finder") { t in
                let dir = try t.tempDirectory()
                t.expectEqual(SaveToMac.destination(in: dir, name: "photo.jpg").lastPathComponent, "photo.jpg")
                try Data().write(to: dir.appendingPathComponent("photo.jpg"))
                t.expectEqual(SaveToMac.destination(in: dir, name: "photo.jpg").lastPathComponent, "photo 2.jpg")
                try Data().write(to: dir.appendingPathComponent("photo 2.jpg"))
                t.expectEqual(SaveToMac.destination(in: dir, name: "photo.jpg").lastPathComponent, "photo 3.jpg")
                try Data().write(to: dir.appendingPathComponent("notes"))
                t.expectEqual(SaveToMac.destination(in: dir, name: "notes").lastPathComponent, "notes 2")
            },
            TestCase("save to mac asks where when the folder can't be written") { t in
                let dir = try t.tempDirectory()
                let locked = dir.appendingPathComponent("locked", isDirectory: true)
                let elsewhere = dir.appendingPathComponent("elsewhere", isDirectory: true)
                try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
                let original = locked.appendingPathComponent("photo.png")
                let converted = dir.appendingPathComponent("photo.jpg")
                try Data("jpeg".utf8).write(to: converted)
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
                var asked: URL?
                SaveToMac.panelAnswer = { file in
                    asked = file
                    return elsewhere.appendingPathComponent(file.lastPathComponent)
                }
                defer { SaveToMac.panelAnswer = nil }
                let saved = await SaveToMac.save(converted, nextTo: original)
                t.expectEqual(asked, converted)
                t.expectEqual(saved, elsewhere.appendingPathComponent("photo.jpg"))
                t.expect(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("photo.jpg").path))
                SaveToMac.panelAnswer = { _ in nil }
                let cancelled = await SaveToMac.save(converted, nextTo: original)
                t.expect(cancelled == nil, "a cancelled panel saves nothing")
            },
        ]
    }
}
#endif
