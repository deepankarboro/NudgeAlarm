import SwiftUI
import AVFoundation

public struct CameraPreviewView: UIViewRepresentable {
    public let captureSession: AVCaptureSession
    public let videoOrientation: AVCaptureVideoOrientation
    public let isMirrored: Bool

    public init(
        captureSession: AVCaptureSession,
        videoOrientation: AVCaptureVideoOrientation = .portrait,
        isMirrored: Bool = false
    ) {
        self.captureSession = captureSession
        self.videoOrientation = videoOrientation
        self.isMirrored = isMirrored
    }

    public func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.previewLayer.session = captureSession
        view.previewLayer.videoGravity = .resizeAspectFill
        applyConnectionSettings(to: view.previewLayer)
        return view
    }

    public func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.previewLayer.session = captureSession
        applyConnectionSettings(to: uiView.previewLayer)
    }

    private func applyConnectionSettings(to previewLayer: AVCaptureVideoPreviewLayer) {
        guard let connection = previewLayer.connection else { return }
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = videoOrientation
        }
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = isMirrored
        }
    }
}

public class CameraPreviewUIView: UIView {
    public override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    public var previewLayer: AVCaptureVideoPreviewLayer {
        return layer as! AVCaptureVideoPreviewLayer
    }
}
