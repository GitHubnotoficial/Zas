import AVFoundation
import CoreMedia
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case displayNotFound
    case writerSetupFailed

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "No se encontró la pantalla a grabar."
        case .writerSetupFailed: return "No se pudo crear el archivo de video."
        }
    }
}

/// Graba un área de la pantalla a MP4 (H.264, 30 fps, máximo 1920 px de lado),
/// con el micrófono opcional en macOS 15 o más nuevo.
/// El tamaño está pensado para que el archivo sea liviano y fácil de subir.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static var supportsMicrophone: Bool {
        if #available(macOS 15.0, *) {
            return true
        }
        return false
    }

    /// Se llama si la grabación se corta sola (por ejemplo, si se desconecta la pantalla).
    var onUnexpectedStop: (@MainActor (Error) -> Void)?

    /// El usuario pidió micrófono, pero macOS no dio acceso: el video queda sin audio.
    private(set) var microphoneDenied = false

    private let queue = DispatchQueue(label: "zas.recorder")
    private var reportedFailure = false
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var systemInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var sessionStarted = false
    private var lastTime = CMTime.zero

    func start(
        displayID: CGDirectDisplayID,
        rect: CGRect,
        scale: CGFloat,
        microphone: Bool,
        to url: URL,
        systemAudio: Bool = false,
        fps: Int = 30,
        showsCursor: Bool = true
    ) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw RecorderError.displayNotFound
        }

        // Excluye las ventanas de Zas, como el marco rojo de grabación.
        let ownApp = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])

        let fullWidth = rect.width * scale
        let fullHeight = rect.height * scale
        let downscale = min(1, 1920 / max(fullWidth, fullHeight))
        let width = max(2, Int(fullWidth * downscale) & ~1)
        let height = max(2, Int(fullHeight * downscale) & ~1)

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = rect
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 6
        configuration.showsCursor = showsCursor
        configuration.capturesAudio = systemAudio
        configuration.excludesCurrentProcessAudio = true

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw RecorderError.writerSetupFailed
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        var capturesMicrophone = false
        if microphone, #available(macOS 15.0, *) {
            capturesMicrophone = await AVCaptureDevice.requestAccess(for: .audio)
            microphoneDenied = !capturesMicrophone
            if capturesMicrophone {
                configuration.captureMicrophone = true
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 96_000,
                ])
                input.expectsMediaDataInRealTime = true
                if writer.canAdd(input) {
                    writer.add(input)
                    audioInput = input
                }
            }
        }

        var systemInput: AVAssetWriterInput?
        if systemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ])
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                systemInput = input
            }
        }

        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.writerSetupFailed
        }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.systemInput = systemInput
        self.outputURL = url

        do {
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            if systemInput != nil {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            }
            if capturesMicrophone, #available(macOS 15.0, *) {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
            }
            try await stream.startCapture()
            self.stream = stream
        } catch {
            // Sin esto quedaría un archivo incompleto en la carpeta.
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Detiene la grabación y devuelve el archivo final, o `nil` si no quedó nada.
    func stop() async -> URL? {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil

        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            queue.async { [self] in
                guard let writer, let videoInput, let outputURL, sessionStarted,
                      writer.status == .writing
                else {
                    self.writer?.cancelWriting()
                    if let outputURL = self.outputURL {
                        try? FileManager.default.removeItem(at: outputURL)
                    }
                    continuation.resume(returning: nil)
                    return
                }
                videoInput.markAsFinished()
                audioInput?.markAsFinished()
                systemInput?.markAsFinished()
                // Si la pantalla quedó quieta al final, el último cuadro cubre ese tiempo.
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                writer.endSession(atSourceTime: CMTimeMaximum(lastTime, now))
                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume(returning: outputURL)
                    } else {
                        try? FileManager.default.removeItem(at: outputURL)
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid, let writer else { return }

        // Por ejemplo, disco lleno: se avisa una sola vez en lugar de seguir contando.
        guard writer.status == .writing else {
            if !reportedFailure {
                reportedFailure = true
                let error = writer.error ?? RecorderError.writerSetupFailed
                let handler = onUnexpectedStop
                Task { @MainActor in
                    handler?(error)
                }
            }
            return
        }

        if type == .screen {
            guard let videoInput, Self.isCompleteFrame(sampleBuffer) else { return }
            let time = sampleBuffer.presentationTimeStamp
            if !sessionStarted {
                writer.startSession(atSourceTime: time)
                sessionStarted = true
            }
            if videoInput.isReadyForMoreMediaData, videoInput.append(sampleBuffer) {
                lastTime = time
            }
            return
        }

        if type == .audio {
            if sessionStarted, let systemInput, systemInput.isReadyForMoreMediaData {
                systemInput.append(sampleBuffer)
            }
            return
        }

        // Lo único que queda es el micrófono. El audio espera al primer cuadro de video.
        if sessionStarted, let audioInput, audioInput.isReadyForMoreMediaData {
            audioInput.append(sampleBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let handler = onUnexpectedStop
        Task { @MainActor in
            handler?(error)
        }
    }

    /// ScreenCaptureKit también entrega muestras vacías cuando la pantalla no cambia.
    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus)
        else { return false }
        return status == .complete
    }
}
