import AVFoundation

/// Something about a video that Android TV hardware decoders commonly can't handle.
struct VideoIssue: Equatable {
    /// One line for the queue, e.g. "May not play on the TV: full-range colour, H.264 level 5.0".
    var summary: String
    var reasons: [String]
}

/// Spots videos the TV is likely to choke on (picture freezes or goes black while the audio
/// carries on) and converts them to a plain, widely supported H.264 MP4 using macOS's own encoder.
enum VideoCheck {
    /// Containers AVFoundation can open. (MKV/AVI/WebM can't be checked or converted this way.)
    static let checkable: Set<String> = ["mp4", "m4v", "mov"]

    static func isCheckable(_ url: URL) -> Bool { checkable.contains(url.pathExtension.lowercased()) }

    private static func fourCC(_ v: FourCharCode) -> String {
        let bytes = [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "?"
    }

    /// Returns nil when the video looks TV-friendly (or can't be inspected).
    static func inspect(_ url: URL) async -> VideoIssue? {
        guard isCheckable(url) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let fd = try? await track.load(.formatDescriptions).first else { return nil }

        let codec = CMFormatDescriptionGetMediaSubType(fd)
        let dims = CMVideoFormatDescriptionGetDimensions(fd)
        let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
        let atoms = ext[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any] ?? [:]
        let fullRange = (ext[kCMFormatDescriptionExtension_FullRangeVideo as String] as? Bool) == true
        var reasons: [String] = []

        switch codec {
        case kCMVideoCodecType_H264:
            // yuvj420p and friends: common in videos rendered from images. Macs cope; many TV chips don't.
            if fullRange { reasons.append("full-range colour") }
            if let avcC = atoms["avcC"] as? Data, avcC.count >= 4 {
                let b = [UInt8](avcC)
                let profile = b[1], level = b[3]
                switch profile {
                case 110: reasons.append("H.264 High 10 profile")
                case 122: reasons.append("H.264 4:2:2 profile")
                case 244: reasons.append("H.264 4:4:4 profile")
                default: break
                }
                // Level 4.1/4.2 covers 1080p; anything higher at ≤1080p is unusual and often rejected.
                if dims.height <= 1088 && level > 42 {
                    reasons.append("H.264 level \(level / 10).\(level % 10)")
                }
            }
        case kCMVideoCodecType_HEVC, FourCharCode(0x6865_7631) /* hev1 */:
            if let hvcC = atoms["hvcC"] as? Data, hvcC.count >= 23 {
                let b = [UInt8](hvcC)
                let chromaFormat = b[16] & 0x03   // 1 = 4:2:0
                let bitDepth = Int(b[17] & 0x07) + 8
                if chromaFormat != 1 { reasons.append("HEVC with \(chromaFormat == 2 ? "4:2:2" : "4:4:4") colour") }
                if bitDepth > 10 { reasons.append("\(bitDepth)-bit HEVC") }
            }
        case kCMVideoCodecType_MPEG4Video:
            break
        default:
            reasons.append("\(fourCC(codec)) video (e.g. ProRes), which TVs can't play")
        }

        guard !reasons.isEmpty else { return nil }
        return VideoIssue(summary: "May not play on the TV: " + reasons.joined(separator: ", "), reasons: reasons)
    }

    /// A running conversion that can be cancelled. Re-encodes the picture with explicit,
    /// TV-safe settings (macOS's export presets would pass a 1080p H.264 stream through untouched).
    final class Conversion {
        private let lock = NSLock()
        private var cancelled = false
        private var reader: AVAssetReader?
        private var writer: AVAssetWriter?

        func cancel() {
            lock.lock(); cancelled = true; let r = reader, w = writer; lock.unlock()
            r?.cancelReading()
            w?.cancelWriting()
        }

        private func register(_ r: AVAssetReader, _ w: AVAssetWriter) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if cancelled { return false }
            reader = r; writer = w
            return true
        }

        private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

        /// Writes a TV-friendly MP4 to `output`. `progress` gets 0...1 on the main actor.
        func run(input: URL, output: URL, progress: @escaping @MainActor (Double) -> Void) async throws {
            let asset = AVURLAsset(url: input)
            guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw ConversionError("There's no video in this file.")
            }
            let aTrack = try await asset.loadTracks(withMediaType: .audio).first
            let duration = try await asset.load(.duration).seconds
            let natural = try await vTrack.load(.naturalSize)
            let transform = try await vTrack.load(.preferredTransform)
            let fps = Double(try await vTrack.load(.nominalFrameRate))
            let srcBitrate = Double(try await vTrack.load(.estimatedDataRate))
            let aFormat = try await aTrack?.load(.formatDescriptions).first

            let width = Int(natural.width) & ~1, height = Int(natural.height) & ~1
            let pixels = width * height
            // Generous enough to look the same as the source, capped so files stay sensible.
            let ceiling: Double = pixels <= 960 * 540 ? 2_500_000 : pixels <= 1280 * 720 ? 5_000_000
                                : pixels <= 1920 * 1088 ? 8_000_000 : 20_000_000
            let bitrate = min(ceiling, max(srcBitrate * 1.5, 2_000_000))
            let keyInterval = max(1, Int((fps > 0 ? fps : 30) * 2))

            try? FileManager.default.removeItem(at: output)
            let reader = try AVAssetReader(asset: asset)
            let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
            writer.shouldOptimizeForNetworkUse = true

            // Decode to RGB so macOS applies the source's own colour range and matrix; the encoder then
            // writes standard ("video") range BT.709. This is what fixes full-range sources.
            let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            vOut.alwaysCopiesSampleData = false
            guard reader.canAdd(vOut) else { throw ConversionError("macOS can't decode this video.") }
            reader.add(vOut)

            var videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(bitrate),
                    AVVideoProfileLevelKey: pixels <= 1920 * 1088 ? AVVideoProfileLevelH264High41
                                                                   : AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoMaxKeyFrameIntervalKey: keyInterval,
                    AVVideoAllowFrameReorderingKey: true,
                    AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                ] as [String: Any],
            ]
            // Standard TV range + BT.709 matrix (what HD TVs assume), tagged with sRGB gamma so macOS's
            // encoder doesn't re-map colours for its own colour management. TVs don't colour-manage, so
            // this keeps the picture looking exactly as it does on the Mac.
            videoSettings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: kCVImageBufferTransferFunction_sRGB as String,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
            let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            vIn.transform = transform           // keep phone videos the right way up
            vIn.expectsMediaDataInRealTime = false
            guard writer.canAdd(vIn) else { throw ConversionError("macOS can't encode this video.") }
            writer.add(vIn)

            // Audio: AAC is copied as is; anything else becomes stereo AAC.
            var audioPair: (AVAssetReaderTrackOutput, AVAssetWriterInput)?
            if let aTrack {
                let isAAC = aFormat.map { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC } ?? false
                let aOut: AVAssetReaderTrackOutput
                let aIn: AVAssetWriterInput
                if isAAC {
                    aOut = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
                    aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: aFormat)
                } else {
                    aOut = AVAssetReaderTrackOutput(track: aTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
                    aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2,
                        AVSampleRateKey: 48_000, AVEncoderBitRateKey: 192_000,
                    ])
                }
                aIn.expectsMediaDataInRealTime = false
                if reader.canAdd(aOut) && writer.canAdd(aIn) {
                    reader.add(aOut); writer.add(aIn)
                    audioPair = (aOut, aIn)
                }
            }

            guard register(reader, writer) else { throw CancellationError() }
            guard reader.startReading() else {
                throw ConversionError(reader.error?.localizedDescription ?? "Couldn't read the video.")
            }
            guard writer.startWriting() else {
                reader.cancelReading()
                throw ConversionError(writer.error?.localizedDescription ?? "Couldn't write the converted video.")
            }
            writer.startSession(atSourceTime: .zero)

            let group = DispatchGroup()
            func pump(_ out: AVAssetReaderTrackOutput, into input: AVAssetWriterInput, label: String,
                      onSample: ((CMSampleBuffer) -> Void)? = nil) {
                group.enter()
                let q = DispatchQueue(label: "tvferry.convert.\(label)")
                var finished = false
                input.requestMediaDataWhenReady(on: q) {
                    while input.isReadyForMoreMediaData && !finished {
                        guard reader.status == .reading, let sample = out.copyNextSampleBuffer() else {
                            finished = true
                            input.markAsFinished()
                            group.leave()
                            return
                        }
                        onSample?(sample)
                        if !input.append(sample) {
                            finished = true
                            reader.cancelReading()
                            input.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }

            pump(vOut, into: vIn, label: "video") { sample in
                // TVs don't colour-manage: they turn the stored values straight into light. Dropping the
                // frame's colour tags stops macOS from re-mapping colours on the way into the encoder, so
                // the TV shows the same values the original had (only the range/matrix is converted).
                if let px = CMSampleBufferGetImageBuffer(sample) {
                    for key in [kCVImageBufferICCProfileKey, kCVImageBufferColorPrimariesKey,
                                kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey] {
                        CVBufferRemoveAttachment(px, key)
                    }
                }
                let t = CMSampleBufferGetPresentationTimeStamp(sample)
                guard duration > 0 else { return }
                let p = min(0.99, t.seconds / duration)
                Task { @MainActor in progress(p) }
            }
            if let (aOut, aIn) = audioPair { pump(aOut, into: aIn, label: "audio") }

            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                group.notify(queue: .global()) { c.resume() }
            }

            if isCancelled || reader.status == .cancelled {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: output)
                throw CancellationError()
            }
            if reader.status == .failed || writer.status == .failed {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: output)
                throw ConversionError((writer.error ?? reader.error)?.localizedDescription ?? "Conversion failed.")
            }
            await writer.finishWriting()
            guard writer.status == .completed else {
                try? FileManager.default.removeItem(at: output)
                throw ConversionError(writer.error?.localizedDescription ?? "Conversion failed.")
            }
            await progress(1)
        }
    }

    struct ConversionError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    /// Where converted copies live until they've been sent.
    static var workFolder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TV Ferry/Converted", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
