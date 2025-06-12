//
//  sobjdtApp.swift
//  sobjdt
//
//  Created by Suwapat Kongjang on 22/4/2568 BE.
//

//    import SwiftUI
//    
//    @main
//    struct sobjdtApp: App {
//        var body: some Scene {
//            WindowGroup {
//                ContentView()
//            }
//        }
//    }
//    
import SwiftUI

@main
struct sobjdtApp: App {
    // 1️⃣ Insert this initializer
    init() {
        let modelPaths = Bundle.main.paths(
            forResourcesOfType: "mlmodelc",
            inDirectory: nil
        )
        if modelPaths.isEmpty {
            print("⚠️ No .mlmodelc files found in bundle!")
        } else {
            print("📦 Compiled Core ML models in bundle:")
            modelPaths.forEach { print(" •", $0) }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
