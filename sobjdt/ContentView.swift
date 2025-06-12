// ContentView.swift

import SwiftUI
import Vision

struct ContentView: View {
    @ObservedObject private var overlay = DistanceOverlay.shared

    var body: some View {
        ZStack {
            ARViewContainer()
                .edgesIgnoringSafeArea(.all)

            // Draw the red box
            GeometryReader { geo in
                if let bbox = overlay.latestBBox {
                    let w = bbox.width * geo.size.width
                    let h = bbox.height * geo.size.height
                    let x = bbox.midX * geo.size.width
                    let y = (1 - bbox.midY) * geo.size.height

                    Rectangle()
                        .stroke(Color.red, lineWidth: 3)
                        .frame(width: w, height: h)
                        .position(x: x, y: y)
                }
            }

            // Name + distance label
            VStack(spacing: 4) {
                if !overlay.objectName.isEmpty {
                    Text(overlay.objectName)
                        .font(.title2).bold()
                        .padding(.horizontal, 8)
                        .background(Color.black.opacity(0.7))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }

                Text(overlay.distanceString)
                    .font(.headline)
                    .padding(8)
                    .background(Color.black.opacity(0.6))
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .padding(.top, 32)
        }
    }
}
