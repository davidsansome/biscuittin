import Foundation

/// OpenAI CLIP byte-pair-encoding tokenizer, in Swift (DESIGN.md D22).
///
/// MobileCLIP's text encoder expects exactly the token ids the reference Python implementation
/// produces, so this is a port rather than an approximation: same regex split, same byte→unicode
/// table, same greedy-lowest-rank merge loop, same `<|startoftext|>` / `<|endoftext|>` framing
/// padded to a fixed 77-token context. A subtly different tokenizer does not fail loudly — it
/// silently embeds a *different sentence* than the user typed, which is why `CLIPTokenizerTests`
/// pins exact id sequences.
///
/// Loading parses two bundled files (~1.7 MB) and builds the merge-rank table, so it happens off
/// the main thread and only when search is first opened.
final class CLIPTokenizer {

    enum LoadError: Error { case missingResource(String), malformed(String) }

    /// The text encoder's fixed input width (measured from the model, §19.4).
    static let contextLength = 77

    private let encoder: [String: Int32]
    private let bpeRanks: [BytePair: Int]
    private let startOfText: Int32
    private let endOfText: Int32

    /// Byte-level BPE works on a reversible unicode view of raw UTF-8 bytes, so that every byte
    /// sequence maps to printable characters the merge table can address.
    private let byteEncoder: [UInt8: Character]

    private struct BytePair: Hashable { let first: String; let second: String }

    /// Tokens are cached across a session: live search re-tokenizes an increasingly long prefix
    /// on every keystroke, so the same leading words are re-encoded constantly.
    private var bpeCache = [String: [String]]()

    private static let pattern = "<\\|startoftext\\|>|<\\|endoftext\\|>|'s|'t|'re|'ve|'m|'ll|'d|[\\p{L}]+|[\\p{N}]|[^\\s\\p{L}\\p{N}]+"
    private let regex: NSRegularExpression

    init(vocabURL: URL, mergesURL: URL) throws {
        guard let vocabData = try? Data(contentsOf: vocabURL),
              let rawVocab = try? JSONSerialization.jsonObject(with: vocabData) as? [String: Int] else {
            throw LoadError.malformed("vocab.json")
        }
        var encoder = [String: Int32](minimumCapacity: rawVocab.count)
        for (token, id) in rawVocab { encoder[token] = Int32(id) }
        self.encoder = encoder

        guard let sot = encoder["<|startoftext|>"], let eot = encoder["<|endoftext|>"] else {
            throw LoadError.malformed("vocab.json is missing the CLIP sentinel tokens")
        }
        self.startOfText = sot
        self.endOfText = eot

        guard let mergesText = try? String(contentsOf: mergesURL, encoding: .utf8) else {
            throw LoadError.malformed("merges.txt")
        }
        var ranks = [BytePair: Int]()
        var rank = 0
        for line in mergesText.split(separator: "\n", omittingEmptySubsequences: true) {
            // The file opens with a "#version:" header that is not a merge rule.
            if line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            ranks[BytePair(first: String(parts[0]), second: String(parts[1]))] = rank
            rank += 1
        }
        guard !ranks.isEmpty else { throw LoadError.malformed("merges.txt contained no rules") }
        self.bpeRanks = ranks

        self.byteEncoder = Self.makeByteEncoder()
        self.regex = try NSRegularExpression(pattern: Self.pattern, options: [])
    }

    /// Loads from the app bundle. `nil` when the model resources were not fetched —
    /// `Tools/fetch_models.sh` is a required build step, and search is disabled without it.
    static func bundled(in bundle: Bundle = .main) throws -> CLIPTokenizer {
        guard let vocab = bundle.url(forResource: "clip_vocab", withExtension: "json") else {
            throw LoadError.missingResource("clip_vocab.json")
        }
        guard let merges = bundle.url(forResource: "clip_merges", withExtension: "txt") else {
            throw LoadError.missingResource("clip_merges.txt")
        }
        return try CLIPTokenizer(vocabURL: vocab, mergesURL: merges)
    }

    // MARK: - Encoding

    /// Token ids padded (or truncated) to `contextLength`, ready for the text encoder.
    ///
    /// Truncation keeps the leading tokens and always restores the end-of-text marker in the
    /// final slot: the encoder reads its sentence embedding from the EOT position, so dropping
    /// that token yields a meaningless vector rather than a merely shortened one.
    func encodePadded(_ text: String) -> [Int32] {
        var ids = [startOfText] + encodeTokens(text)
        if ids.count >= Self.contextLength {
            ids = Array(ids.prefix(Self.contextLength - 1))
        }
        ids.append(endOfText)
        ids.append(contentsOf: repeatElement(0, count: Self.contextLength - ids.count))
        return ids
    }

    /// Raw ids without sentinels or padding — exposed for tests to pin exact sequences.
    func encodeTokens(_ text: String) -> [Int32] {
        let cleaned = Self.clean(text)
        guard !cleaned.isEmpty else { return [] }

        var ids = [Int32]()
        let ns = cleaned as NSString
        let matches = regex.matches(in: cleaned, range: NSRange(location: 0, length: ns.length))

        for match in matches {
            let word = ns.substring(with: match.range)
            // Raw bytes, not characters: this is what makes the tokenizer total over any input,
            // including emoji and scripts absent from the merge table.
            let byteView = String(Array(word.utf8).compactMap { byteEncoder[$0] })
            guard !byteView.isEmpty else { continue }
            for piece in bpe(byteView) {
                if let id = encoder[piece] { ids.append(id) }
            }
        }
        return ids
    }

    // MARK: - BPE

    private func bpe(_ token: String) -> [String] {
        if let cached = bpeCache[token] { return cached }

        // The trailing marker is what distinguishes a word-final fragment from a word-internal
        // one ("dog</w>" and "dog" are different vocabulary entries).
        var word = token.map(String.init)
        guard var last = word.popLast() else { return [] }
        last += "</w>"
        word.append(last)

        while word.count > 1 {
            // Merge the adjacent pair with the lowest rank; ranks encode merge order, so the
            // lowest-numbered rule always applies first.
            var bestRank = Int.max
            var bestIndex: Int?
            for i in 0..<(word.count - 1) {
                let pair = BytePair(first: word[i], second: word[i + 1])
                if let rank = bpeRanks[pair], rank < bestRank {
                    bestRank = rank
                    bestIndex = i
                }
            }
            guard let index = bestIndex else { break }

            let merged = word[index] + word[index + 1]
            word.replaceSubrange(index...(index + 1), with: [merged])
        }

        bpeCache[token] = word
        return word
    }

    // MARK: - Text normalisation

    private static func clean(_ text: String) -> String {
        // Matches the reference's whitespace_clean + lowercase. Any run of whitespace collapses
        // to one space so that spacing never changes the token stream.
        let collapsed = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.lowercased()
    }

    /// The reference `bytes_to_unicode()` table: printable ASCII and Latin-1 ranges map to
    /// themselves, and every remaining byte maps into the unused U+0100… block.
    private static func makeByteEncoder() -> [UInt8: Character] {
        var bytes = [UInt8]()
        bytes.append(contentsOf: UInt8(ascii: "!")...UInt8(ascii: "~"))
        bytes.append(contentsOf: UInt8(0xA1)...UInt8(0xAC))
        bytes.append(contentsOf: UInt8(0xAE)...UInt8(0xFF))

        var scalars = bytes.map { UInt32($0) }
        var next: UInt32 = 0
        for byte in UInt8.min...UInt8.max where !bytes.contains(byte) {
            bytes.append(byte)
            scalars.append(256 + next)
            next += 1
        }

        var table = [UInt8: Character](minimumCapacity: 256)
        for (byte, scalar) in zip(bytes, scalars) {
            guard let unicode = Unicode.Scalar(scalar) else { continue }
            table[byte] = Character(unicode)
        }
        return table
    }
}
