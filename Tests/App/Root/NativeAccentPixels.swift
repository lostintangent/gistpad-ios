import Accent
import Testing
import UIKit

@MainActor
func nativeAccentPixels(in image: UIImage, expected: RGBColor) throws
  -> (personal: Int, systemBlue: Int)
{
  let source = try #require(image.cgImage)
  let width = source.width
  let height = source.height
  let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
  var pixels = [UInt8](repeating: 0, count: width * height * 4)
  try pixels.withUnsafeMutableBytes { bytes in
    let context = try #require(
      CGContext(
        data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: space,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
          | CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
  }
  return stride(from: 0, to: pixels.count, by: 4).reduce(into: (0, 0)) { counts, index in
    let red = Int(pixels[index])
    let green = Int(pixels[index + 1])
    let blue = Int(pixels[index + 2])
    if abs(red - Int(expected.red)) <= 6, abs(green - Int(expected.green)) <= 6,
      abs(blue - Int(expected.blue)) <= 6, pixels[index + 3] > 250
    {
      counts.0 += 1
    }
    if red < 30, green > 90, green < 160, blue > 245, pixels[index + 3] > 250 {
      counts.1 += 1
    }
  }
}
