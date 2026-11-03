// Writes a reproducible photo library for scripts/bench-similar.sh: unrelated scenes plus groups of near-identical
// copies of one scene (re-saved smaller, recompressed, cropped, brightened, burst frames), as JPEG, HEIC and PNG.
// The same arguments always write the same images. Each group is listed in `<folder>/groups.txt`, one line per
// group, its paths (relative to the folder) sorted and separated by tabs, the lines sorted.
//
// Usage: swiftc -O similar-photos-fixture.swift -o fixture && ./fixture FOLDER [PHOTOS] [LONG_SIDE]
//   PHOTOS     photos to write (default 2000), about half of them in groups of 2–6
//   LONG_SIDE  pixels of the long side of an original (default 2400)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Small seeded generator, so a scene is the same on every run.
struct SplitMix {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x2545_F491_4F6C_DD1D }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

func context(_ width: Int, _ height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// A "photo" drawn from `seed`: a gradient, overlapping shapes and lines, then grain. `frame` > 0 is a burst frame:
/// the same scene moved a little, with its own grain.
func scene(seed: UInt64, width: Int, height: Int, frame: Int = 0) -> CGImage {
    var random = SplitMix(seed)
    let image = context(width, height)
    func color() -> CGColor { CGColor(srgbRed: random.unit(), green: random.unit(), blue: random.unit(), alpha: 1) }
    let gradient = CGGradient(colorsSpace: nil, colors: [color(), color(), color()] as CFArray, locations: [0, 0.5, 1])!
    image.drawLinearGradient(gradient, start: CGPoint(x: random.unit() * Double(width), y: 0),
                             end: CGPoint(x: random.unit() * Double(width), y: Double(height)), options: [])
    image.translateBy(x: Double(frame) * Double(width) * 0.006, y: Double(frame) * Double(height) * 0.004)
    let (w, h) = (Double(width), Double(height))
    for index in 0..<(12 + Int(random.next() % 40)) {
        image.setFillColor(color())
        let rect = CGRect(x: random.unit() * w - w * 0.1, y: random.unit() * h - h * 0.1,
                          width: w * (0.05 + random.unit() * 0.35), height: h * (0.05 + random.unit() * 0.35))
        switch index % 3 {
        case 0: image.fillEllipse(in: rect)
        case 1: image.fill(rect)
        default:
            image.setStrokeColor(color())
            image.setLineWidth(w * (0.004 + random.unit() * 0.02))
            image.strokeLineSegments(between: [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)])
        }
    }
    // Coarse grain (cells of 0.4% of the width): photo-sized files, and detail that survives resizing.
    var grain = SplitMix(seed ^ UInt64(frame + 1) << 40)
    let pixels = image.data!.assumingMemoryBound(to: UInt8.self)
    let cell = max(2, width / 250)
    for cellY in stride(from: 0, to: height, by: cell) {
        for cellX in stride(from: 0, to: width, by: cell) {
            let shift = Int(grain.next() % 41) - 20
            for y in cellY..<min(cellY + cell, height) {
                for x in cellX..<min(cellX + cell, width) {
                    let offset = (y * width + x) * 4
                    for channel in 0..<3 { pixels[offset + channel] = UInt8(clamping: Int(pixels[offset + channel]) + shift) }
                }
            }
        }
    }
    return image.makeImage()!
}

func resized(_ image: CGImage, by factor: Double) -> CGImage {
    let target = context(Int(Double(image.width) * factor), Int(Double(image.height) * factor))
    target.interpolationQuality = .high
    target.draw(image, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
    return target.makeImage()!
}

/// The middle of `image`, `fraction` cut from each side.
func cropped(_ image: CGImage, by fraction: Double) -> CGImage {
    let (dx, dy) = (Int(Double(image.width) * fraction), Int(Double(image.height) * fraction))
    return image.cropping(to: CGRect(x: dx, y: dy, width: image.width - 2 * dx, height: image.height - 2 * dy))!
}

func brightened(_ image: CGImage) -> CGImage {
    let target = context(image.width, image.height)
    target.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    target.setBlendMode(.screen)
    target.setFillColor(CGColor(gray: 0.1, alpha: 1))
    target.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return target.makeImage()!
}

func write(_ image: CGImage, to url: URL, type: UTType, quality: Double = 0.85) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
        fatalError("can't write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fatalError("can't write \(url.path)") }
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write("usage: fixture FOLDER [PHOTOS] [LONG_SIDE]\n".data(using: .utf8)!)
    exit(2)
}
let folder = URL(fileURLWithPath: arguments[1])
let total = arguments.count > 2 ? Int(arguments[2]) ?? 2000 : 2000
let longSide = arguments.count > 3 ? Int(arguments[3]) ?? 2400 : 2400

/// One file to write: its scene, the edit made to it, the format.
struct Job {
    enum Edit { case none, recompressed, half, cropped, brightened, burst(Int) }
    let name: String
    let seed: UInt64
    let portrait: Bool
    let edit: Edit
    let type: UTType
}

// Groups of 2…6 until half the photos are in one, the rest unrelated scenes. Each group starts with its original
// and takes its edits in turn from a list that rotates, so every kind of copy and format is in groups of every size.
var jobs: [Job] = []
var groups: [[String]] = []
let edits: [(Job.Edit, UTType, String)] = [(.recompressed, .jpeg, "jpg"), (.half, .png, "png"), (.cropped, .heic, "heic"),
                                           (.burst(1), .jpeg, "jpg"), (.brightened, .jpeg, "jpg"), (.burst(2), .heic, "heic")]
var seed: UInt64 = 1
while jobs.count < total / 2 {
    let size = min(2 + groups.count % 5, total / 2 - jobs.count)
    guard size >= 2 else { break }
    let portrait = seed % 4 == 0
    var names = ["IMG_\(String(format: "%05d", seed)).jpg"]
    jobs.append(Job(name: names[0], seed: seed, portrait: portrait, edit: .none, type: .jpeg))
    for step in 0..<(size - 1) {
        let (edit, type, ext) = edits[(groups.count + step) % edits.count]
        let name = "IMG_\(String(format: "%05d", seed)) copy \(step + 1).\(ext)"
        jobs.append(Job(name: name, seed: seed, portrait: portrait, edit: edit, type: type))
        names.append(name)
    }
    groups.append(names)
    seed += 1
}
while jobs.count < total {
    let (type, ext): (UTType, String) = seed % 10 == 0 ? (.png, "png") : seed % 5 == 1 ? (.heic, "heic") : (.jpeg, "jpg")
    jobs.append(Job(name: "IMG_\(String(format: "%05d", seed)).\(ext)", seed: seed, portrait: seed % 4 == 0, edit: .none,
                    type: type))
    seed += 1
}

try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
// Spread over a few folders, as photos are.
let folders = ["Camera", "Exports", "Imported", "Phone backup", "Trips"]
for name in folders { try FileManager.default.createDirectory(at: folder.appending(path: name), withIntermediateDirectories: true) }
func path(_ index: Int) -> String { "\(folders[index % folders.count])/\(jobs[index].name)" }
let index = Dictionary(uniqueKeysWithValues: jobs.indices.map { (jobs[$0].name, $0) })

DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
    autoreleasepool {
        let job = jobs[i]
        let (width, height) = job.portrait ? (longSide * 3 / 4, longSide) : (longSide, longSide * 3 / 4)
        var frame = 0
        if case .burst(let n) = job.edit { frame = n }
        let image = scene(seed: job.seed, width: width, height: height, frame: frame)
        let url = folder.appending(path: path(i))
        switch job.edit {
        case .none, .burst: write(image, to: url, type: job.type)
        case .recompressed: write(image, to: url, type: job.type, quality: 0.4)
        case .half: write(resized(image, by: 0.5), to: url, type: job.type)
        case .cropped: write(cropped(image, by: 0.05), to: url, type: job.type)
        case .brightened: write(brightened(image), to: url, type: job.type)
        }
    }
}
let listing = groups.map { $0.map { path(index[$0]!) }.sorted().joined(separator: "\t") }.sorted().joined(separator: "\n") + "\n"
try listing.write(to: folder.appending(path: "groups.txt"), atomically: true, encoding: .utf8)
print("\(jobs.count) photos, \(groups.count) groups of \(groups.reduce(0) { $0 + $1.count }) photos")
