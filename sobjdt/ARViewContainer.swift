// ARViewContainer.swift

import SwiftUI
import RealityKit
import ARKit
import Vision
import CoreML

/// Shared object for publishing the latest measured distance and bounding box
class DistanceOverlay: ObservableObject {
    static let shared = DistanceOverlay()
    @Published var distanceString: String = "--"
    @Published var latestBBox: CGRect? = nil     // normalized bbox from Vision
    @Published var objectName: String = ""   // ← new
}

struct ARViewContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        context.coordinator.arView = arView

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        config.environmentTexturing = .automatic

        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        arView.session.delegate = context.coordinator

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, ARSessionDelegate {
        weak var arView: ARView?
        private let visionQueue = DispatchQueue(label: "visionQueue")
        private var request: VNCoreMLRequest!
        private var lastFrame: ARFrame?
        private var lastVisionTime = Date.distantPast
        private let minInterval: TimeInterval = 0.1

        override init() {
            super.init()
            setupDetectionModel()
        }

        private func setupDetectionModel() {
            let modelName = "YOLOv3"
            guard let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") else {
                fatalError("❌ \(modelName).mlmodelc not found")
            }
            do {
                let ml = try MLModel(contentsOf: url)
                let vnl = try VNCoreMLModel(for: ml)
                request = VNCoreMLRequest(model: vnl, completionHandler: visionDidComplete)
                request.imageCropAndScaleOption = .scaleFill
                print("✅ VNCoreMLRequest ready")
            } catch {
                fatalError("❌ Vision model load failed: \(error)")
            }
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            lastFrame = frame
            let now = Date()
            guard now.timeIntervalSince(lastVisionTime) >= minInterval else { return }
            lastVisionTime = now

            let handler = VNImageRequestHandler(
                cvPixelBuffer: frame.capturedImage,
                orientation: .right,
                options: [:]
            )
            visionQueue.async {
                try? handler.perform([self.request])
            }
        }

        private func visionDidComplete(request: VNRequest, error: Error?) {
            guard
                let detections = request.results as? [VNRecognizedObjectObservation],
                let top = detections.max(by: {
                    $0.labels.first!.confidence < $1.labels.first!.confidence
                }),
                let frame = lastFrame,
                let arView = arView
            else {
                DispatchQueue.main.async {
                    DistanceOverlay.shared.distanceString = "--"
                    DistanceOverlay.shared.latestBBox = nil
                    DistanceOverlay.shared.objectName = ""          // new
                }
                return
            }
            // 1) Publish the label
            let label = top.labels.first!.identifier
            DispatchQueue.main.async {
                DistanceOverlay.shared.objectName = label       // new
                DistanceOverlay.shared.latestBBox = top.boundingBox
            }

            // 1) Publish normalized bounding box
//            DispatchQueue.main.async {
//                DistanceOverlay.shared.latestBBox = top.boundingBox
//            }

            // 2) Measure depth at bbox center (LiDAR or fallback)
            let cx = top.boundingBox.midX
            let cy = top.boundingBox.midY

            if let depthMap = frame.sceneDepth?.depthMap {
                let w  = CVPixelBufferGetWidth(depthMap)
                let h  = CVPixelBufferGetHeight(depthMap)
                let px = Int(cx * CGFloat(w))
                let py = Int((1 - cy) * CGFloat(h))

                CVPixelBufferLockBaseAddress(depthMap, .readOnly)
                let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
                let base     = CVPixelBufferGetBaseAddress(depthMap)!
                let ptr      = base.advanced(by: py * rowBytes)
                                   .bindMemory(to: Float32.self, capacity: w)
                let d        = Double(ptr[px])
                CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)

                DispatchQueue.main.async {
                    DistanceOverlay.shared.distanceString = String(format: "%.2f m", d)
                }
            } else {
                // fallback raycast
                let screenPt = CGPoint(
                    x: cx * arView.bounds.width,
                    y: (1 - cy) * arView.bounds.height
                )
                if let hit = arView.raycast(
                    from: screenPt,
                    allowing: .estimatedPlane,
                    alignment: .any
                ).first {
                    let t = hit.worldTransform.columns.3
                    let dist = sqrt(t.x*t.x + t.y*t.y + t.z*t.z)
                    DispatchQueue.main.async {
                        DistanceOverlay.shared.distanceString = String(format: "%.2f m", dist)
                    }
                } else {
                    DispatchQueue.main.async {
                        DistanceOverlay.shared.distanceString = "--"
                    }
                }
            }
        }
    }
}
