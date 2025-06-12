import SwiftUI
import RealityKit
import ARKit
import Vision
import CoreML
import AVFoundation

/// Shared object for publishing the latest measured distance and bounding box
class DistanceOverlay: ObservableObject {
    static let shared = DistanceOverlay()
    @Published var distanceString: String = "--"
    @Published var latestBBox: CGRect? = nil     // normalized bbox from Vision
    @Published var objectName: String = ""       // object label
}

/// Manages speech synthesis for object name and distance feedback
class SpeechManager {
    private let synthesizer = AVSpeechSynthesizer()
    private var lastAnnouncement: String?
    
    // A DispatchWorkItem we can cancel if a new update comes in
    private var pendingWorkItem: DispatchWorkItem?
    
    // Call this whenever you get a new (object, distance)
    func scheduleSpeak(object: String, distanceMeters: Float) {
        let rounded = Int(distanceMeters.rounded(.toNearestOrEven))
        let metersText = "\(rounded) meter" + (rounded == 1 ? "" : "s")
        let announcement = "\(object), \(metersText)"
        
        // If it’s identical to the last thing we actually spoke, bail out
        guard announcement != lastAnnouncement else { return }
        
        // Cancel any speech already queued or in progress
        pendingWorkItem?.cancel()
        synthesizer.stopSpeaking(at: .immediate)
        
        // Create a new work item that will actually speak after 0.3 s
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lastAnnouncement = announcement
            
            let utterance = AVSpeechUtterance(string: announcement)
            utterance.rate = 0.5
            // zero pre-utterance delay so it fires immediately
            utterance.preUtteranceDelay = 0
            self.synthesizer.speak(utterance)
        }
        pendingWorkItem = work
        
        // Schedule it on the main queue after 0.3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}


struct ARViewContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        context.coordinator.arView = arView
        context.coordinator.speechManager = SpeechManager()

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
        var speechManager = SpeechManager()
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
                let top = detections.max(by: { $0.labels.first!.confidence < $1.labels.first!.confidence }),
                let frame = lastFrame,
                let arView = arView
            else {
                DispatchQueue.main.async {
                    DistanceOverlay.shared.distanceString = "--"
                    DistanceOverlay.shared.latestBBox = nil
                    DistanceOverlay.shared.objectName = ""
                }
                return
            }

            // Publish label and bounding box
            let label = top.labels.first!.identifier
            DispatchQueue.main.async {
                DistanceOverlay.shared.objectName = label
                DistanceOverlay.shared.latestBBox = top.boundingBox
            }

            // Compute center of bbox
            let cx = top.boundingBox.midX
            let cy = top.boundingBox.midY

            // Measure depth if available
            if let depthMap = frame.sceneDepth?.depthMap {
                let w = CVPixelBufferGetWidth(depthMap)
                let h = CVPixelBufferGetHeight(depthMap)
                let px = Int(cx * CGFloat(w))
                let py = Int((1 - cy) * CGFloat(h))

                CVPixelBufferLockBaseAddress(depthMap, .readOnly)
                let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
                let base = CVPixelBufferGetBaseAddress(depthMap)!
                let ptr = base.advanced(by: py * rowBytes)
                              .bindMemory(to: Float32.self, capacity: w)
                let d = Double(ptr[px])
                CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)

                let meters = Float(d)
                DispatchQueue.main.async {
                    DistanceOverlay.shared.distanceString = String(format: "%.2f m", d)
                }
                speechManager.scheduleSpeak(object: label, distanceMeters: meters)

            } else {
                // Fallback: raycast
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
                    let meters = Float(dist)
                    DispatchQueue.main.async {
                        DistanceOverlay.shared.distanceString = String(format: "%.2f m", dist)
                    }
                    speechManager.scheduleSpeak(object: label, distanceMeters: meters)
                } else {
                    DispatchQueue.main.async {
                        DistanceOverlay.shared.distanceString = "--"
                    }
                }
            }
        }
    }
}
