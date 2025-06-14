// ContentView.swift

import SwiftUI
import Vision
import AVFoundation    // ← brings in the AVSpeechUtterance rate constants

struct ContentView: View {
    @ObservedObject private var overlay = DistanceOverlay.shared
    
    // MUST be Double here, not Float
    @AppStorage("speechRate")
    private var speechRate: Double = Double(AVSpeechUtteranceDefaultSpeechRate)

    var body: some View {
        ZStack {
            // 1) Your AR view
            ARViewContainer()
                .edgesIgnoringSafeArea(.all)

            // 2) (Optionally) your red-box + name/distance overlays here…

            // 3) Speech-rate slider at the bottom
            VStack(spacing: 8) {
                // First, compute the formatted string so we avoid any weird quoting
                let rateString = String(format: "%.2f", speechRate)

                // Then interpolate it with a simple Text call
                Text("Speech Speed: \(rateString)")
                    .foregroundColor(.white)
                    .bold()

                Slider(
                  value: $speechRate,
                  in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate)
                ) {
                  Text("Speech Speed")
                }

                .padding(.horizontal)
            }
        }
    }
}
