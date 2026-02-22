import Foundation
@preconcurrency import AVFoundation
import Vision
import CoreImage
import os

@MainActor
final class PresenceService: ObservableObject {
    private let logger = Logger(subsystem: "DonnaSwift", category: "presence")
    private let appLog = AppLog.shared

    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var isAway: Bool = false

    private var timer: Timer?
    var checkInterval: TimeInterval = 2
    var awayThreshold: TimeInterval = 2

    private var lastPresentSignal: Date = .now
    private let captureQueue = DispatchQueue(label: "DonnaSwift.Presence.CaptureQueue")
    private let analysisQueue = DispatchQueue(label: "DonnaSwift.Presence.AnalysisQueue")
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var frameDelegate: FrameDelegate?

    func start() {
        guard !isEnabled else { return }

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            startCapturePipeline()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.startCapturePipeline()
                    } else {
                        self.logger.error("camera permission denied")
                        self.appLog.log(.error, category: "presence", "camera permission denied")
                    }
                }
            }
        default:
            logger.error("camera permission unavailable status=\(status.rawValue, privacy: .public)")
            appLog.log(.error, category: "presence", "camera permission unavailable", metadata: ["status": String(status.rawValue)])
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        captureQueue.async { [session = captureSession] in
            session?.stopRunning()
        }
        captureSession = nil
        videoOutput = nil
        frameDelegate = nil
        isEnabled = false
        isAway = false
        logger.info("presence stopped")
        appLog.log(.info, category: "presence", "presence stopped")
    }

    private func evaluateAwayState() {
        let awayNow = Date().timeIntervalSince(lastPresentSignal) >= awayThreshold
        if awayNow != isAway {
            isAway = awayNow
            logger.info("presence state changed is_away=\(awayNow, privacy: .public)")
            appLog.log(.info, category: "presence", "state changed", metadata: ["is_away": String(awayNow)])
        }
    }

    private func startCapturePipeline() {
        do {
            let session = try buildSession()
            captureSession = session

            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.evaluateAwayState()
                }
            }

            isEnabled = true
            isAway = false
            lastPresentSignal = .now

            captureQueue.async {
                session.startRunning()
            }
            logger.info("presence started with AVFoundation + Vision")
            appLog.log(.info, category: "presence", "presence started")
        } catch {
            logger.error("presence pipeline failed: \(error.localizedDescription, privacy: .public)")
            appLog.log(.error, category: "presence", "presence pipeline failed", metadata: ["error": error.localizedDescription])
        }
    }

    private func buildSession() throws -> AVCaptureSession {
        let session = AVCaptureSession()
        session.sessionPreset = .vga640x480

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
        else {
            throw NSError(domain: "DonnaSwift.Presence", code: 1, userInfo: [NSLocalizedDescriptionKey: "No camera found"])
        }

        configureDeviceForLowLight(camera)

        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else {
            throw NSError(domain: "DonnaSwift.Presence", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot add camera input"])
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

        let delegate = FrameDelegate(
            minInterval: checkInterval,
            analysisQueue: analysisQueue,
            onFaceDetected: { [weak self] faceDetected in
                guard let self else { return }
                Task { @MainActor in
                    if faceDetected {
                        self.lastPresentSignal = .now
                        if self.isAway {
                            self.evaluateAwayState()
                        }
                    } else {
                        self.evaluateAwayState()
                    }
                }
            }
        )

        output.setSampleBufferDelegate(delegate, queue: captureQueue)
        guard session.canAddOutput(output) else {
            throw NSError(domain: "DonnaSwift.Presence", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot add video output"])
        }
        session.addOutput(output)

        frameDelegate = delegate
        videoOutput = output
        return session
    }

    private func configureDeviceForLowLight(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }

            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }

            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }

            // Lower frame-rate gives the camera more light per frame.
            let frameDuration = CMTime(value: 1, timescale: 10) // 10 FPS
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
                $0.minFrameDuration <= frameDuration && $0.maxFrameDuration >= frameDuration
            }) {
                device.activeVideoMinFrameDuration = frameDuration
                device.activeVideoMaxFrameDuration = frameDuration
            }
        } catch {
            logger.error("low-light camera configuration failed: \(error.localizedDescription, privacy: .public)")
            appLog.log(.warning, category: "presence", "low-light camera configuration failed", metadata: ["error": error.localizedDescription])
        }
    }
}

private final class FrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let minInterval: TimeInterval
    private let analysisQueue: DispatchQueue
    private let onFaceDetected: (Bool) -> Void
    private var lastAnalysis = Date.distantPast
    private let ciContext = CIContext()

    // Debounce no-face frames to reduce false "away" in poor lighting.
    private var consecutiveMisses: Int = 0
    private let normalMissLimit = 2
    private let lowLightMissLimit = 8
    private let lowLightLumaThreshold: Float = 0.12

    init(minInterval: TimeInterval, analysisQueue: DispatchQueue, onFaceDetected: @escaping (Bool) -> Void) {
        self.minInterval = max(0.2, minInterval)
        self.analysisQueue = analysisQueue
        self.onFaceDetected = onFaceDetected
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastAnalysis) >= minInterval else { return }
        lastAnalysis = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            onFaceDetected(false)
            return
        }

        let luma = estimateLuma(from: pixelBuffer)

        analysisQueue.async {
            let request = VNDetectFaceRectanglesRequest()
            let enhancedImage = self.enhancedImage(from: pixelBuffer)
            let handler: VNImageRequestHandler
            if let enhancedImage {
                handler = VNImageRequestHandler(ciImage: enhancedImage, orientation: .up)
            } else {
                handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
            }

            do {
                try handler.perform([request])
                let hasFace = !(request.results?.isEmpty ?? true)

                if hasFace {
                    self.consecutiveMisses = 0
                    self.onFaceDetected(true)
                } else {
                    self.consecutiveMisses += 1
                    let missLimit = luma < self.lowLightLumaThreshold ? self.lowLightMissLimit : self.normalMissLimit
                    if self.consecutiveMisses >= missLimit {
                        self.onFaceDetected(false)
                    } else {
                        // Keep recent-present signal alive briefly when frames are noisy/dark.
                        self.onFaceDetected(true)
                    }
                }
            } catch {
                self.onFaceDetected(false)
            }
        }
    }

    private func enhancedImage(from pixelBuffer: CVPixelBuffer) -> CIImage? {
        let base = CIImage(cvPixelBuffer: pixelBuffer)
        let exposure = base.applyingFilter("CIExposureAdjust", parameters: ["inputEV": 1.0])
        let denoised = exposure.applyingFilter(
            "CINoiseReduction",
            parameters: [
                "inputNoiseLevel": 0.02,
                "inputSharpness": 0.40,
            ]
        )
        return denoised
    }

    private func estimateLuma(from pixelBuffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
        else {
            return 1.0
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)

        let step = 12
        var sum: Float = 0
        var count: Float = 0

        for y in stride(from: 0, to: height, by: step) {
            let rowStart = y * bytesPerRow
            for x in stride(from: 0, to: width, by: step) {
                let idx = rowStart + (x * 4)
                let b = Float(bytes[idx]) / 255.0
                let g = Float(bytes[idx + 1]) / 255.0
                let r = Float(bytes[idx + 2]) / 255.0
                let yPrime = (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
                sum += yPrime
                count += 1
            }
        }

        guard count > 0 else { return 1.0 }
        return sum / count
    }
}
