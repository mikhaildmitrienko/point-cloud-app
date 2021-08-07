/*
See LICENSE folder for this sample’s licensing information.

Abstract:
A utility class that provides processed depth information.
*/

import Foundation
import SwiftUI
import Combine
import ARKit
import Accelerate
import MetalPerformanceShaders

// Wrap the `MTLTexture` protocol to reference outputs from ARKit.
final class MetalTextureContent {
    var texture: MTLTexture?
}

// Enable `CVPixelBuffer` to output an `MTLTexture`.
extension CVPixelBuffer {
    
    func texture(withFormat pixelFormat: MTLPixelFormat, planeIndex: Int, addToCache cache: CVMetalTextureCache) -> MTLTexture? {
        
        let width = CVPixelBufferGetWidthOfPlane(self, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(self, planeIndex)
        
        var cvtexture: CVMetalTexture?
        _ = CVMetalTextureCacheCreateTextureFromImage(nil, cache, self, nil, pixelFormat, width, height, planeIndex, &cvtexture)
        let texture = CVMetalTextureGetTexture(cvtexture!)
        
        return texture
        
    }
    
}

// Collect AR data using a lower-level receiver. This class converts AR data
// to a Metal texture, optionally upscaling depth data using a guided filter,
// and implements `ARDataReceiver` to respond to `onNewARData` events.
final class ARProvider: ARDataReceiver, ObservableObject {
    // Set the destination resolution for the upscaled algorithm.
    let upscaledWidth = 960
    let upscaledHeight = 760

    // Set the original depth size.
    let origDepthWidth = 256
    let origDepthHeight = 192

    // Set the original color size.
    let origColorWidth = 1920
    let origColorHeight = 1440
    
    // Set the guided filter constants.
    let guidedFilterEpsilon: Float = 0.004
    let guidedFilterKernelDiameter = 5
    
    let arReceiver = ARReceiver()
    @Published var lastArData: ARData?
    let depthContent = MetalTextureContent()
    let confidenceContent = MetalTextureContent()
    let colorYContent = MetalTextureContent()
    let colorCbCrContent = MetalTextureContent()
    let upscaledCoef = MetalTextureContent()
    let downscaledRGB = MetalTextureContent()
    let upscaledConfidence = MetalTextureContent()
    
    let coefTexture: MTLTexture
    let destDepthTexture: MTLTexture
    let destConfTexture: MTLTexture
    let colorRGBTexture: MTLTexture
    let colorRGBTextureDownscaled: MTLTexture
    let colorRGBTextureDownscaledLowRes: MTLTexture
    
    // Enable or disable depth upsampling.
    public var isToUpsampleDepth: Bool = false {
        didSet {
            processLastArData()
        }
    }
    
    // Enable or disable smoothed-depth upsampling.
    public var isUseSmoothedDepthForUpsampling: Bool = false {
        didSet {
            processLastArData()
        }
    }
    var textureCache: CVMetalTextureCache?
    let metalDevice: MTLDevice?
    let guidedFilter: MPSImageGuidedFilter?
    let mpsScaleFilter: MPSImageBilinearScale?
    let commandQueue: MTLCommandQueue?
    var pipelineStateCompute: MTLComputePipelineState?
    
    // Create an empty texture.
    static func createTexture(metalDevice: MTLDevice, width: Int, height: Int, usage: MTLTextureUsage, pixelFormat: MTLPixelFormat) -> MTLTexture {
        let descriptor: MTLTextureDescriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = pixelFormat
        descriptor.width = width
        descriptor.height = height
        descriptor.usage = usage
        let resTexture = metalDevice.makeTexture(descriptor: descriptor)
        return resTexture!
    }
    
    // Start or resume the stream from ARKit.
    func start() {
        arReceiver.start()
    }
    
    // Pause the stream from ARKit.
    func pause() {
        arReceiver.pause()
    }
    
    // Initialize the MPS filters, metal pipeline, and Metal textures.
    init?() {
        do {
            metalDevice = MTLCreateSystemDefaultDevice()
            CVMetalTextureCacheCreate(nil, nil, metalDevice!, nil, &textureCache)
            guidedFilter = MPSImageGuidedFilter(device: metalDevice!, kernelDiameter: guidedFilterKernelDiameter)
            guidedFilter?.epsilon = guidedFilterEpsilon
            mpsScaleFilter = MPSImageBilinearScale(device: metalDevice!)
            commandQueue = metalDevice!.makeCommandQueue()
            let lib = metalDevice!.makeDefaultLibrary()
            let convertYUV2RGBFunc = lib!.makeFunction(name: "convertYCbCrToRGBA")
            pipelineStateCompute = try metalDevice!.makeComputePipelineState(function: convertYUV2RGBFunc!)
            // Initialize the working textures.
            coefTexture = ARProvider.createTexture(metalDevice: metalDevice!, width: origDepthWidth, height: origDepthHeight,
                                                   usage: [.shaderRead, .shaderWrite], pixelFormat: .rgba32Float)
            destDepthTexture = ARProvider.createTexture(metalDevice: metalDevice!, width: upscaledWidth, height: upscaledHeight,
                                                        usage: [.shaderRead, .shaderWrite], pixelFormat: .r32Float)
            destConfTexture = ARProvider.createTexture(metalDevice: metalDevice!, width: upscaledWidth, height: upscaledHeight,
                                                       usage: [.shaderRead, .shaderWrite], pixelFormat: .r8Unorm)
            colorRGBTexture = ARProvider.createTexture(metalDevice: metalDevice!, width: origColorWidth, height: origColorHeight,
                                                       usage: [.shaderRead, .shaderWrite], pixelFormat: .rgba32Float)
            colorRGBTextureDownscaled = ARProvider.createTexture(metalDevice: metalDevice!, width: upscaledWidth, height: upscaledHeight,
                                                                 usage: [.shaderRead, .shaderWrite], pixelFormat: .rgba32Float)
            colorRGBTextureDownscaledLowRes = ARProvider.createTexture(metalDevice: metalDevice!, width: origDepthWidth, height: origDepthHeight,
                                                                       usage: [.shaderRead, .shaderWrite], pixelFormat: .rgba32Float)
            upscaledCoef.texture = coefTexture
            upscaledConfidence.texture = destConfTexture
            downscaledRGB.texture = colorRGBTextureDownscaled
            
            // Set the delegate for ARKit callbacks.
            arReceiver.delegate = self
            
        } catch {
            print("Unexpected error: \(error).")
            return nil
        }
    }
    
    
    // Save a reference to the current AR data and process it.
    func onNewARData(arData: ARData) {
        
        //Lines 159 - 168 are for printing the depth at a single point
        let depthPixelBuffer = arData.depthImage
        let point = CGPoint(x: 35, y: 25)
        let width = CVPixelBufferGetWidth(depthPixelBuffer!)
        let height = CVPixelBufferGetHeight(depthPixelBuffer!)
        CVPixelBufferLockBaseAddress(depthPixelBuffer!, CVPixelBufferLockFlags(rawValue: 0))
        let depthPointer = unsafeBitCast(CVPixelBufferGetBaseAddress(depthPixelBuffer!), to: UnsafeMutablePointer<Float32>.self)
        let distanceAtXYPoint = depthPointer[Int(point.y * CGFloat(width) + point.x)]

        // Uncomment the below line to print the distance at a single pixel to the console.
        //        print(distanceAtXYPoint)
        
        
        //Lines 172 - 195 are for exporting depth data to a csv
        func convert(length: Int, data: UnsafeMutablePointer<Float32>) -> [Float32] {
            let buffer = UnsafeBufferPointer(start: data, count: length);
            return Array(buffer)
        }
        let depthPointerArray = convert(length: 49152, data: depthPointer)
        let depthPointArraySeperated = (depthPointerArray.map{String($0)}).joined(separator:",\n")
        let fileName = "depthData.csv"
        let path = NSURL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)
        var csvText = "Point\n"
        print("Creating csv text")
        //uncomment below line to see how the depth data is stored
//        print(depthPointArraySeperated)
        csvText.append(depthPointArraySeperated)
//        print(csvText)
        
        print("Starting to write...")
        do {
                try csvText.write(to: path!, atomically: true, encoding: String.Encoding.utf8)
                    } catch {
                        print("Failed to create file")
                        print("\(error)")
                    }
                    print(path ?? "not found")
        
        print("Write complete")
        

        //Process color
        let colorImage = arData.capturedImage
        CVPixelBufferLockBaseAddress(colorImage!, CVPixelBufferLockFlags(rawValue: 0))
        let colorPointer = unsafeBitCast(CVPixelBufferGetBaseAddress(colorImage!), to: UnsafeMutablePointer<Float32>.self)
        let colorAtXYPoint = colorPointer[Int(point.y * CGFloat(width) + point.x)]
        let colorWidth1 = CVPixelBufferGetWidth(colorImage!)
        let colorHeight1 = CVPixelBufferGetHeight(colorImage!)
        
        
        //Lines 212 - 213 are for processing the extrinsic matrix. Uncomment line 213 to get it for every frame
        let cameraExtrinsics = arData.cameraExtrinsics
//        print(cameraExtrinsics)
        
        //Lines 216 - 217 are for processing euler angles. Uncomment line 217 to get it for every frame
        let eulerAngles = arData.eulerAngles
//        print(eulerAngles)
        
        
        
//        let colorRGBTexture = ARProvider.createTexture(metalDevice: metalDevice!, width: origColorWidth, height: origColorHeight,
//                                                   usage: [.shaderRead, .shaderWrite], pixelFormat: .rgba32Float)
//
//        let colorWidth = colorRGBTexture.width
//        let colorHeight = colorRGBTexture.height
//        let bytesPerRow = colorWidth * 4
//
//        let data = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * colorHeight, alignment: 4)
//        defer {
//                data.deallocate(bytes: bytesPerRow * colorHeight, alignedTo: 4)
//            }
        
        
        
//        func getDocumentsDirectory() -> URL {
//            let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
//            return paths[0]
//        }
        
//        func textureToImage(texture: MTLTexture) -> Void {
//            let kciOptions: [CIImageOption:Any] = [.colorSpace: CGColorSpaceCreateDeviceRGB()]
//            let ciImage = CIImage(mtlTexture: texture, options: kciOptions)!
//            let transform = CGAffineTransform.identity
//                              .scaledBy(x: 1, y: -1)
//                              .translatedBy(x: 0, y: ciImage.extent.height)
//            let transformed = ciImage.transformed(by: transform)
//
//            let image = UIImage(ciImage: transformed)
//            print(image.pngData())
//            if let data = image.pngData() {
//                let filename = getDocumentsDirectory().appendingPathComponent("copy.png")
//                try? data.write(to: filename)
//            }
//
////            let image = UIImage(ciImage: transformed)
////                if let data = image.jpegData(compressionQuality: 0.8) {
////                    let filename = getDocumentsDirectory().appendingPathComponent("copy.jpeg")
////                    try? data.write(to: filename)
////                }
//          }

//        let pngData = textureToImage(texture: colorRGBTexture)
//        print(pngData)
        
//        let region = MTLRegionMake2D(0, 0, colorWidth, colorHeight)
//        let realData = colorRGBTexture.getBytes(data, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
//
//        print(realData)

//        colorRGBTexture.getBytes(data, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
//        let bind = data.assumingMemoryBound(to: UInt8.self)
//
//        print(bind)
        
//        CVPixelBufferLockBaseAddress(colorRGBTexture!, CVPixelBufferLockFlags(rawValue: 0))
//        let rgbPointer = unsafeBitCast(CVPixelBufferGetBaseAddress(colorImage!), to: UnsafeMutablePointer<Float32>.self)
//        let rgbColorAtXYPoint = rgbPointer[Int(point.y * CGFloat(width) + point.x)]
//        print("color", rgbColorAtXYPoint)
//
//        print("colorBuffer:", colorRGBTexture)
        
//        print(arData.depthImage as Any)
//        CVPixelBufferLockBaseAddress(arData.depthImage!, .readOnly)
//        print(CVPixelBufferGetBaseAddress(arData.depthImage!))
//        CVPixelBufferUnlockBaseAddress(arData.depthImage!, .readOnly)
        lastArData = arData
        processLastArData()
    }
    
    // Copy the AR data to Metal textures and, if the user enables the UI, upscale the depth using a guided filter.
    func processLastArData() {
        colorYContent.texture = lastArData?.colorImage?.texture(withFormat: .r8Unorm, planeIndex: 0, addToCache: textureCache!)!
        colorCbCrContent.texture = lastArData?.colorImage?.texture(withFormat: .rg8Unorm, planeIndex: 1, addToCache: textureCache!)!
        if isUseSmoothedDepthForUpsampling {
            depthContent.texture = lastArData?.depthSmoothImage?.texture(withFormat: .r32Float, planeIndex: 0, addToCache: textureCache!)!
            confidenceContent.texture = lastArData?.confidenceSmoothImage?.texture(withFormat: .r8Unorm, planeIndex: 0, addToCache: textureCache!)!
        } else {
            depthContent.texture = lastArData?.depthImage?.texture(withFormat: .r32Float, planeIndex: 0, addToCache: textureCache!)!
            confidenceContent.texture = lastArData?.confidenceImage?.texture(withFormat: .r8Unorm, planeIndex: 0, addToCache: textureCache!)!
        }
        if isToUpsampleDepth {
            guard let commandQueue = commandQueue else { return }
            guard let cmdBuffer = commandQueue.makeCommandBuffer() else { return }
            guard let computeEncoder = cmdBuffer.makeComputeCommandEncoder() else { return }
            // Convert YUV to RGB because the guided filter needs RGB format.
            computeEncoder.setComputePipelineState(pipelineStateCompute!)
            computeEncoder.setTexture(colorYContent.texture, index: 0)
            computeEncoder.setTexture(colorCbCrContent.texture, index: 1)
            computeEncoder.setTexture(colorRGBTexture, index: 2)
            let threadgroupSize = MTLSizeMake(pipelineStateCompute!.threadExecutionWidth,
                                              pipelineStateCompute!.maxTotalThreadsPerThreadgroup / pipelineStateCompute!.threadExecutionWidth, 1)
            let threadgroupCount = MTLSize(width: Int(ceil(Float(colorRGBTexture.width) / Float(threadgroupSize.width))),
                                           height: Int(ceil(Float(colorRGBTexture.height) / Float(threadgroupSize.height))),
                                           depth: 1)
            computeEncoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
            computeEncoder.endEncoding()
            
//            print(colorRGBTexture)

            // Downscale the RGB data. Pass in the target resoultion.
            mpsScaleFilter?.encode(commandBuffer: cmdBuffer, sourceTexture: colorRGBTexture,
                                   destinationTexture: colorRGBTextureDownscaled)
            // Match the input depth resolution.
            mpsScaleFilter?.encode(commandBuffer: cmdBuffer, sourceTexture: colorRGBTexture,
                                   destinationTexture: colorRGBTextureDownscaledLowRes)
            
            // Upscale the confidence data. Pass in the target resolution.
            mpsScaleFilter?.encode(commandBuffer: cmdBuffer, sourceTexture: confidenceContent.texture!,
                                   destinationTexture: destConfTexture)
            
            // Encode the guided filter.
            guidedFilter?.encodeRegression(to: cmdBuffer, sourceTexture: depthContent.texture!,
                                           guidanceTexture: colorRGBTextureDownscaledLowRes, weightsTexture: nil,
                                           destinationCoefficientsTexture: coefTexture)
            
            // Optionally, process `coefTexture` here.
            
            guidedFilter?.encodeReconstruction(to: cmdBuffer, guidanceTexture: colorRGBTextureDownscaled,
                                               coefficientsTexture: coefTexture, destinationTexture: destDepthTexture)
            cmdBuffer.commit()
            
            // Override the original depth texture with the upscaled version.
            depthContent.texture = destDepthTexture
        }
    }
}

