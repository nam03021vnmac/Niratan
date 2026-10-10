import Accelerate
import CoreGraphics
import Foundation
import ImageIO

/// Packed 8-bit RGB pixels used by the OCR preprocessors.
///
/// Pixel values are read without color management in the source color space
/// (matching Fushi's `package:image` decoding, which ignores ICC profiles).
nonisolated struct MangaOCRBitmap: Sendable {
    let width: Int
    let height: Int
    /// RGB, row-major, 3 bytes per pixel.
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init?(image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let model = image.colorSpace?.model
        if model == .monochrome {
            var gray = [UInt8](repeating: 0, count: width * height)
            let drawn = gray.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: image.colorSpace ?? CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            var rgb = [UInt8](repeating: 0, count: width * height * 3)
            gray.withUnsafeMutableBytes { gray in
                rgb.withUnsafeMutableBytes { rgb in
                    var plane = vImage_Buffer(data: gray.baseAddress, height: vImagePixelCount(height),
                                              width: vImagePixelCount(width), rowBytes: width)
                    var destination = vImage_Buffer(data: rgb.baseAddress, height: vImagePixelCount(height),
                                                    width: vImagePixelCount(width), rowBytes: width * 3)
                    _ = vImageConvert_Planar8toRGB888(&plane, &plane, &plane, &destination, vImage_Flags(kvImageNoFlags))
                }
            }
            self.init(width: width, height: height, pixels: rgb)
            return
        }
        let space: CGColorSpace = (model == .rgb ? image.colorSpace : nil)
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        rgba.withUnsafeMutableBytes { rgba in
            rgb.withUnsafeMutableBytes { rgb in
                var source = vImage_Buffer(data: rgba.baseAddress, height: vImagePixelCount(height),
                                           width: vImagePixelCount(width), rowBytes: width * 4)
                var destination = vImage_Buffer(data: rgb.baseAddress, height: vImagePixelCount(height),
                                                width: vImagePixelCount(width), rowBytes: width * 3)
                _ = vImageConvert_RGBA8888toRGB888(&source, &destination, vImage_Flags(kvImageNoFlags))
            }
        }
        self.init(width: width, height: height, pixels: rgb)
    }

    /// Crop a pixel rectangle; the caller guarantees it lies within bounds.
    func cropped(x: Int, y: Int, width cropWidth: Int, height cropHeight: Int) -> MangaOCRBitmap {
        let w = max(1, min(cropWidth, width - x))
        let h = max(1, min(cropHeight, height - y))
        var output = [UInt8](repeating: 0, count: w * h * 3)
        pixels.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                guard let source = source.baseAddress, let destination = destination.baseAddress else { return }
                for row in 0..<h {
                    (destination + row * w * 3).update(from: source + ((y + row) * width + x) * 3, count: w * 3)
                }
            }
        }
        return MangaOCRBitmap(width: w, height: h, pixels: output)
    }

    /// Rotate 90° counter-clockwise (`copyRotate(angle: -90)`): the top of a
    /// vertical column ends up on the left, so it reads as a horizontal line.
    func rotatedCounterClockwise() -> MangaOCRBitmap {
        let dstWidth = height
        let dstHeight = width
        var output = [UInt8](repeating: 0, count: pixels.count)
        pixels.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                for y in 0..<dstHeight {
                    for x in 0..<dstWidth {
                        let sourceOffset = (x * width + (width - 1 - y)) * 3
                        let destinationOffset = (y * dstWidth + x) * 3
                        destination[destinationOffset] = source[sourceOffset]
                        destination[destinationOffset + 1] = source[sourceOffset + 1]
                        destination[destinationOffset + 2] = source[sourceOffset + 2]
                    }
                }
            }
        }
        return MangaOCRBitmap(width: dstWidth, height: dstHeight, pixels: output)
    }

    /// Crop `box` (page pixels) clamped to the page: floor origin, ceil size,
    /// at least one pixel. Returns the crop and its page origin.
    func blockCrop(_ box: CGRect) -> (bitmap: MangaOCRBitmap, x: Int, y: Int)? {
        let clamped = box.ocrClamped(width: CGFloat(width), height: CGFloat(height))
        let x = Int(floor(clamped.minX))
        let y = Int(floor(clamped.minY))
        let w = min(max(1, Int(ceil(clamped.width))), width - x)
        let h = min(max(1, Int(ceil(clamped.height))), height - y)
        guard w > 0, h > 0 else { return nil }
        return (cropped(x: x, y: y, width: w, height: h), x, y)
    }

    private static let levels: [Double] = (0..<256).map(Double.init)

    /// `package:image` `copyResize(interpolation: linear)`: point-sample at
    /// `(x * srcW/dstW, y * srcH/dstH)` with bilinear blending of the four
    /// neighbours, truncating to 8 bits.
    func resizedLinear(width dstWidth: Int, height dstHeight: Int) -> MangaOCRBitmap {
        if dstWidth == width && dstHeight == height { return self }
        let dx = Double(width) / Double(dstWidth)
        let dy = Double(height) / Double(dstHeight)
        // Column sample offsets repeat on every row; -1 marks a right neighbour
        // past the edge.
        var left = [Int](repeating: 0, count: dstWidth)
        var right = [Int](repeating: 0, count: dstWidth)
        var weights = [Double](repeating: 0, count: dstWidth)
        for x in 0..<dstWidth {
            let fx = Double(x) * dx
            let x0 = Int(fx)
            left[x] = x0 * 3
            right[x] = x0 + 1 >= width ? -1 : (x0 + 1) * 3
            weights[x] = fx - Double(x0)
        }
        let levels = Self.levels
        var output = [UInt8](repeating: 0, count: dstWidth * dstHeight * 3)
        pixels.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                guard let source = source.baseAddress, let destination = destination.baseAddress else { return }
                for y in 0..<dstHeight {
                    let fy = Double(y) * dy
                    let y0 = Int(fy)
                    let ny = y0 + 1
                    let wy = fy - Double(y0)
                    let row = y0 * width * 3
                    let nextRow = ny >= height ? -1 : ny * width * 3
                    var target = destination + y * dstWidth * 3
                    for x in 0..<dstWidth {
                        let cc = row + left[x]
                        let cn = nextRow < 0 ? cc : nextRow + left[x]
                        let nc = right[x] < 0 ? cc : row + right[x]
                        let nn = (right[x] < 0 || nextRow < 0) ? cc : nextRow + right[x]
                        let wx = weights[x]
                        // Unrolled: a range loop per channel dominates unoptimized builds.
                        func blend(_ channel: Int) {
                            let icc = levels[Int(source[cc + channel])]
                            let inc = levels[Int(source[nc + channel])]
                            let icn = levels[Int(source[cn + channel])]
                            let inn = levels[Int(source[nn + channel])]
                            let value = icc
                                + wx * (inc - icc + wy * (icc + inn - icn - inc))
                                + wy * (icn - icc)
                            target[channel] = UInt8(max(0, min(255, value)))
                        }
                        blend(0); blend(1); blend(2)
                        target += 3
                    }
                }
            }
        }
        return MangaOCRBitmap(width: dstWidth, height: dstHeight, pixels: output)
    }
}

nonisolated enum MangaOCRImageDecoding {
    /// Decode encoded image data into a CGImage with EXIF orientation applied,
    /// so OCR coordinates match the page as displayed.
    static func orientedImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if orientation == 1 || width <= 0 || height <= 0 {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
