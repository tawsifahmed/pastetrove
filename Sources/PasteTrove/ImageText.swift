import AppKit
import Vision

/// Reads the words in copied images with macOS's own text recognition, once per image and on this Mac only,
/// so search finds a screenshot by what it says. One image at a time, in the background.
final class ImageText {
    /// After each image: its id, and how many are left.
    var onChange: ((Int64?, Int) -> Void)?

    private let store: Store
    private let queue = DispatchQueue(label: "io.github.tawsifahmed.pastetrove.image-text", qos: .utility)
    /// Images waiting to be read, newest first. Main thread only.
    private var pending: [Int64] = []

    init(store: Store) {
        self.store = store
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
        guard let id = pending.first else { return }
        let png = store.data(id, type: NSPasteboard.PasteboardType.png.rawValue)
        queue.async {
            let words = png.flatMap(Self.read) ?? ""
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                store.setWords(id, words)
                pending.removeFirst()
                onChange?(id, pending.count)
                next()
            }
        }
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
