import SwiftUI
import AVFoundation

public struct CameraPreviewView: UIViewRepresentable {
    public let captureSession: AVCaptureSession
    
    public init(captureSession: AVCaptureSession) {
        self.captureSession = captureSession
    }
    
    public func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.previewLayer.session = captureSession
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }
    
    public func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.previewLayer.session = captureSession
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
