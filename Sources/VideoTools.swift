import AVFoundation
import AVKit
import AppKit
import ImageIO
import UniformTypeIdentifiers

enum GifExporter {
    private static let framesPerSecond = 12.0
    private static let maximumFrames = 240

    static func export(video: URL, to output: URL) async -> Bool {
        let asset = AVURLAsset(url: video)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return false }

        let count = min(Int(duration * framesPerSecond), maximumFrames)
        guard count > 0,
              let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil)
        else { return false }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.04, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.04, preferredTimescale: 600)

        let delay = duration / Double(count)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay],
        ] as CFDictionary
        var added = 0
        for index in 0..<count {
            let time = CMTime(seconds: Double(index) * delay, preferredTimescale: 600)
            if let result = try? await generator.image(at: time) {
                CGImageDestinationAddImage(destination, result.image, frameProperties)
                added += 1
            }
        }
        return added > 0 && CGImageDestinationFinalize(destination)
    }
}

enum VideoTrimmer {
    /// Corta sin volver a codificar: es instantáneo y conserva la calidad.
    static func export(video: URL, from start: CMTime, to end: CMTime, output: URL) async -> Bool {
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: video), presetName: AVAssetExportPresetPassthrough) else {
            return false
        }
        session.outputURL = output
        session.outputFileType = .mp4
        session.timeRange = CMTimeRange(start: start, end: end)
        return await withCheckedContinuation { continuation in
            session.exportAsynchronously {
                continuation.resume(returning: session.status == .completed)
            }
        }
    }

    static func outputName(for video: URL) -> String {
        "\(video.deletingPathExtension().lastPathComponent) recortado.mp4"
    }
}

/// Ventana con el recortador del propio sistema, el mismo de QuickTime.
@MainActor
final class VideoTrimWindow: NSObject, NSWindowDelegate {
    var onFinish: ((URL) -> Void)?
    var onClose: (() -> Void)?

    private let video: URL
    private let window: NSWindow
    private let playerView = AVPlayerView()
    private let player: AVPlayer

    init(video: URL) {
        self.video = video
        player = AVPlayer(url: video)
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Recortar video"
        window.isReleasedWhenClosed = false
        window.delegate = self
        playerView.player = player
        playerView.controlsStyle = .inline
        window.contentView = playerView
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Task { @MainActor [weak self] in
            // El reproductor necesita un instante para saber la duración.
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.beginTrimming()
        }
    }

    private func beginTrimming() {
        playerView.beginTrimming { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                if result == .okButton {
                    await self.saveTrim()
                }
                self.window.close()
            }
        }
    }

    private func saveTrim() async {
        guard let item = player.currentItem else { return }
        let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
        let output = Capture.uniqueURL(in: video.deletingLastPathComponent(), name: VideoTrimmer.outputName(for: video))
        if await VideoTrimmer.export(video: video, from: start, to: end, output: output) {
            onFinish?(output)
        } else {
            Toast.shared.show("No se pudo recortar el video.")
        }
    }

    func windowWillClose(_ notification: Notification) {
        player.pause()
        onClose?()
    }
}
