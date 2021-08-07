/*
See LICENSE folder for this sample’s licensing information.

Abstract:
A utility class that receives processed depth information.
*/

import Foundation
import SwiftUI
import Combine
import ARKit

// Receive the newest AR data from an `ARReceiver`.
protocol ARDataReceiver: AnyObject {
    func onNewARData(arData: ARData)
}

//- Tag: ARData
// Store depth-related AR data.
final class ARData {
    var depthImage: CVPixelBuffer?
    var depthSmoothImage: CVPixelBuffer?
    var colorImage: CVPixelBuffer?
    var confidenceImage: CVPixelBuffer?
    var confidenceSmoothImage: CVPixelBuffer?
    var capturedImage: CVPixelBuffer?
    var cameraIntrinsics = simd_float3x3()
    var cameraResolution = CGSize()
    var cameraExtrinsics = simd_float4x4()
    var eulerAngles = simd_float3()
}

// Configure and run an AR session to provide the app with depth-related AR data.
final class ARReceiver: NSObject, ARSessionDelegate {
    var arData = ARData()
    var arSession = ARSession()
    weak var delegate: ARDataReceiver?
    
    // Configure and start the ARSession.
    override init() {
        super.init()
        arSession.delegate = self
        start()
    }
    
    // Configure the ARKit session.
    func start() {
        guard ARWorldTrackingConfiguration.supportsFrameSemantics([.sceneDepth, .smoothedSceneDepth]) else { return }
        // Enable both the `sceneDepth` and `smoothedSceneDepth` frame semantics.
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
        arSession.run(config)
    }
    
    func pause() {
        arSession.pause()
    }
    
    
    // Send required data from `ARFrame` to the delegate class via the `onNewARData` callback.
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        
        // In order to collect feature point data, uncomment lines 65-67, 72-82, 97-103.
        let fileName = "rawFeaturePoints\(frame.timestamp).csv"
        let path = NSURL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)
        var csvText = "X,Y,Z\n"
        
        if(frame.sceneDepth != nil) && (frame.smoothedSceneDepth != nil) {
            guard let depthData = frame.sceneDepth else {return}
            
            let points = frame.rawFeaturePoints?.points
            let index = frame.rawFeaturePoints?.points.count
            print(index)
            if points != nil {
            for item in 0 ... ((index)! - 1){
                    print(item)
                    print("\(points![item][0]), \(points![item][1]), \(points![item][2])\n")
                    let newLine = "\(points![item][0]), \(points![item][1]), \(points![item][2])\n"
                    csvText.append(newLine)
                }
            }

            arData.depthImage = frame.sceneDepth?.depthMap
            arData.depthSmoothImage = frame.smoothedSceneDepth?.depthMap
            arData.confidenceImage = frame.sceneDepth?.confidenceMap
            arData.confidenceSmoothImage = frame.smoothedSceneDepth?.confidenceMap
            arData.colorImage = frame.capturedImage
            arData.cameraIntrinsics = frame.camera.intrinsics
            arData.cameraResolution = frame.camera.imageResolution
            arData.cameraExtrinsics = frame.camera.transform
            arData.eulerAngles = frame.camera.eulerAngles
            arData.capturedImage = frame.capturedImage
            delegate?.onNewARData(arData: arData)
        }
        do {
                try csvText.write(to: path!, atomically: true, encoding: String.Encoding.utf8)
                    } catch {
                        print("Failed to create file")
                        print("\(error)")
                    }
                    print(path ?? "not found")
    }
}
