import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

/// Headless checks run on the build server; HDR display comparison still needs a real screen.
func runSelfTests() throws {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "SelfTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("oriented.jpg")
    let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let bitmap = CGContext(data: nil, width: 20, height: 30, bitsPerComponent: 8,
        bytesPerRow: 80, space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "SelfTests", code: 2)
    }
    bitmap.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
    bitmap.fill(CGRect(x: 0, y: 0, width: 20, height: 30))
    guard let cgImage = bitmap.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw NSError(domain: "SelfTests", code: 3)
    }
    CGImageDestinationAddImage(destination, cgImage, [kCGImagePropertyOrientation: 6] as CFDictionary)
    try require(CGImageDestinationFinalize(destination), "JPEG fixture could not be written")
    let photo = try Photo(url: url)
    try require(photo.hdr.extent.width == 30 && photo.hdr.extent.height == 20, "HDR EXIF orientation failed")
    try require(photo.sdr.extent.width == 30 && photo.sdr.extent.height == 20, "SDR EXIF orientation failed")
    try require(photo.hdr.contentHeadroom <= 1, "SDR JPEG unexpectedly identified as HDR")
    print("PASS: JPEG decode and EXIF orientation in HDR/SDR paths")

    let broken = folder.appendingPathComponent("broken.jpg")
    try Data("not an image".utf8).write(to: broken)
    var rejected = false
    do { _ = try Photo(url: broken) } catch { rejected = true }
    try require(rejected, "Corrupt photo should be rejected")
    print("PASS: corrupt file rejection")

    let linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    let samples: [Float] = [2, 1.5, 0.5, 1]
    let inputData = samples.withUnsafeBytes { Data($0) }
    let image = CIImage(bitmapData: inputData, bytesPerRow: 16,
        size: CGSize(width: 1, height: 1), format: .RGBAf, colorSpace: linear)
    let context = CIContext(options: [.useSoftwareRenderer: true,
        .workingColorSpace: linear, .workingFormat: CIFormat.RGBAf.rawValue])
    func pixel(_ image: CIImage) -> [Float] {
        var output = [Float](repeating: 0, count: 4)
        output.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: 16,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
        }
        return output
    }
    let hdrPixel = pixel(image)
    try require(abs(hdrPixel[0] - 2) < 0.02 && abs(hdrPixel[1] - 1.5) < 0.02,
        "Float color pipeline clipped or changed HDR samples")
    let toneMap = CIFilter.toneMapHeadroom()
    toneMap.inputImage = image
    toneMap.sourceHeadroom = 2
    toneMap.targetHeadroom = 1
    guard let mapped = toneMap.outputImage else { throw NSError(domain: "SelfTests", code: 4) }
    let sdrPixel = pixel(mapped)
    try require(sdrPixel.prefix(3).allSatisfy { $0.isFinite && $0 >= -0.01 && $0 <= 1.05 },
        "Tone mapping to SDR exceeded target headroom")
    try require(sdrPixel[0] > 0.01, "Tone mapping returned an empty image")
    print("PASS: float HDR preservation and tone mapping to SDR")
    try require(BrowserPanel.isPhoto(URL(fileURLWithPath: "/sample.HEIC")), "HEIC browser filter failed")
    try require(!BrowserPanel.isPhoto(URL(fileURLWithPath: "/sample.dng")), "RAW browser exclusion failed")
    print("PASS: browser format filtering")
}
