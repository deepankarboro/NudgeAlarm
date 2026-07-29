import SwiftUI
import Vision

public struct PoseOverlayCanvas: View {
    public let skeleton: PoseSkeleton
    public let isFormValid: Bool
    
    // Joint connections for skeletal rendering
    private let connections: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
        (.leftShoulder, .rightShoulder),
        (.leftShoulder, .leftElbow),
        (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow),
        (.rightElbow, .rightWrist),
        (.leftShoulder, .leftHip),
        (.rightShoulder, .rightHip),
        (.leftHip, .rightHip),
        (.leftHip, .leftKnee),
        (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee),
        (.rightKnee, .rightAnkle),
        (.neck, .leftShoulder),
        (.neck, .rightShoulder),
        (.nose, .neck)
    ]
    
    public init(skeleton: PoseSkeleton, isFormValid: Bool = true) {
        self.skeleton = skeleton
        self.isFormValid = isFormValid
    }
    
    public var body: some View {
        Canvas { context, size in
            let strokeColor: Color = isFormValid ? .cyan : .orange
            let nodeColor: Color = isFormValid ? .green : .red
            
            // Draw skeleton limb lines
            for (j1, j2) in connections {
                if let p1Norm = skeleton.points[j1], let p2Norm = skeleton.points[j2] {
                    // Vision coordinates are normalized [0,1] with origin at bottom-left.
                    // Convert to SwiftUI View coordinate system (origin top-left).
                    let pt1 = CGPoint(x: p1Norm.x * size.width, y: (1 - p1Norm.y) * size.height)
                    let pt2 = CGPoint(x: p2Norm.x * size.width, y: (1 - p2Norm.y) * size.height)
                    
                    var path = Path()
                    path.move(to: pt1)
                    path.addLine(to: pt2)
                    
                    context.stroke(
                        path,
                        with: .color(strokeColor),
                        lineWidth: 4
                    )
                }
            }
            
            // Draw joint nodes
            for (joint, pNorm) in skeleton.points {
                let pt = CGPoint(x: pNorm.x * size.width, y: (1 - pNorm.y) * size.height)
                let rect = CGRect(x: pt.x - 7, y: pt.y - 7, width: 14, height: 14)
                
                context.fill(Path(ellipseIn: rect), with: .color(nodeColor))
                context.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 2)
            }
        }
    }
}
