import AppKit
import Vision

/// Reads the words in copied images with macOS's own text recognition, once per image and on this Mac only,
/// so search finds a screenshot by what it says. One image at a time, in the background.
/// Apple's text model takes about 90 MB that is only freed when its process ends, so a helper copy of
/// PasteTrove (started with `flag`) reads each batch and quits; the app itself stays small.
final class ImageText {
    static let flag = "--read-image-text"

    /// After each image: its id, and how many are left.
    var onChange: ((Int64?, Int) -> Void)?

    private let store: Store
    private let queue = DispatchQueue(label: "io.github.tawsifahmed.pastetrove.image-text", qos: .utility)
    /// Images waiting to be read, newest first. Main thread only.
    private var pending: [Int64] = []
    private let helperURL: URL?
    private var helper: (process: Process, input: FileHandle, output: FileHandle)?

    init(store: Store, helper: URL? = Bundle.main.executableURL) {
        self.store = store
        helperURL = helper
    }

    /// Queues every image not read yet: new copies, and older ones after an update.
    func readNew() {
        let ids = store.unreadImages().filter { !pending.contains($0) }
        guard !ids.isEmpty else { return }
        let idle = pending.isEmpty
        pending += ids
        onChange?(nil, pending.count)
        if idle { next() }
    }

    private func next() {
        guard let id = pending.first else {
            // Closing its input ends the helper, and its memory with it.
            try? helper?.input.close()
            helper = nil
            return
        }
        let png = store.data(id, type: NSPasteboard.PasteboardType.png.rawValue) ?? Data()
        let pipes = startHelper()
        queue.async {
            let answer = pipes.flatMap { pipes in (try? Self.send(png, pipes.input)).flatMap { Self.receive(pipes.output) } }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // A helper that failed is started again for the next image; this one stays without words.
                if answer == nil { helper = nil }
                store.setWords(id, answer.map { String(decoding: $0, as: UTF8.self) } ?? "")
                pending.removeFirst()
                onChange?(id, pending.count)
                next()
            }
        }
    }

    private func startHelper() -> (input: FileHandle, output: FileHandle)? {
        if let helper, helper.process.isRunning { return (helper.input, helper.output) }
        guard let helperURL else { return nil }
        let process = Process()
        process.executableURL = helperURL
        process.arguments = [Self.flag]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        helper = (process, input.fileHandleForWriting, output.fileHandleForReading)
        return (input.fileHandleForWriting, output.fileHandleForReading)
    }

    /// The helper's side: answers each image with its words until its input closes.
    static func serve(_ input: FileHandle = .standardInput, _ output: FileHandle = .standardOutput) {
        while let png = receive(input) {
            try? send(Data((read(png) ?? "").utf8), output)
        }
    }

    /// One message on a pipe: its length, then its bytes.
    static func send(_ data: Data, _ handle: FileHandle) throws {
        var count = UInt32(data.count).bigEndian
        try handle.write(contentsOf: Data(bytes: &count, count: 4) + data)
    }

    static func receive(_ handle: FileHandle) -> Data? {
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return nil }
        let count = Int(head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        guard count > 0 else { return Data() }
        guard let body = try? handle.read(upToCount: count), body.count == count else { return nil }
        return body
    }

    /// Large screenshots are scaled down first: text stays readable and reading stays fast.
    static func read(_ png: Data) -> String? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2000] as CFDictionary
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
