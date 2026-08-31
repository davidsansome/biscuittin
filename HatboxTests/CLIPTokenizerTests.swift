import XCTest
@testable import Hatbox

/// Pins `CLIPTokenizer` against the reference implementation.
///
/// **Every expected sequence here was produced by HuggingFace `transformers`'
/// `AutoTokenizer.from_pretrained("openai/clip-vit-base-patch32")`, not by this code.** That
/// distinction is the whole value of the file: a tokenizer that is merely self-consistent will
/// happily encode a *different sentence* than the user typed and still return a plausible
/// 512-dim vector, so search would quietly degrade with nothing failing. AGENTS.md has the
/// general form of this trap ("a mock you wrote yourself cannot falsify your own assumptions").
///
/// To regenerate after a vocabulary change:
/// ```python
/// from transformers import AutoTokenizer
/// tok = AutoTokenizer.from_pretrained("openai/clip-vit-base-patch32")
/// tok("a diagram", add_special_tokens=True)["input_ids"]
/// ```
final class CLIPTokenizerTests: XCTestCase {

    private var tokenizer: CLIPTokenizer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        do {
            tokenizer = try CLIPTokenizer.bundled()
        } catch {
            throw XCTSkip("CLIP resources are not bundled — run Tools/fetch_models.sh. (\(error))")
        }
    }

    /// Reference ids include the sentinels, so compare against the sentinel-framed prefix of
    /// the padded output rather than re-deriving them here.
    private func assertTokens(_ text: String,
                              _ expected: [Int32],
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        let padded = tokenizer.encodePadded(text)
        XCTAssertEqual(padded.count, CLIPTokenizer.contextLength, file: file, line: line)
        XCTAssertEqual(Array(padded.prefix(expected.count)), expected,
                       "tokenization of \(text.debugDescription) diverged from the reference",
                       file: file, line: line)
        // Everything past the reference sequence must be padding.
        XCTAssertTrue(padded.dropFirst(expected.count).allSatisfy { $0 == 0 },
                      "expected zero padding after the end-of-text marker", file: file, line: line)
    }

    // MARK: - Reference sequences

    func testCanonicalCLIPExamples() {
        // The three prompts from the CLIP README's own zero-shot example.
        assertTokens("a diagram", [49406, 320, 22697, 49407])
        assertTokens("a dog", [49406, 320, 1929, 49407])
        assertTokens("a cat", [49406, 320, 2368, 49407])
    }

    func testTypicalSearchQuery() {
        assertTokens("a photo of a waterfall", [49406, 320, 1125, 539, 320, 16403, 49407])
        assertTokens("dog on a beach", [49406, 1929, 525, 320, 2117, 49407])
    }

    /// The merge loop's real test: a word absent from the vocabulary as a whole, which must be
    /// split by merge rank. The split is deliberately non-obvious — "mobi|lec|lip", not the
    /// "mobile|clip" a reader might assume — which is exactly why it is pinned to the reference.
    func testWordAbsentFromVocabularySplitsByMergeRank() {
        assertTokens("mobileclip", [49406, 9451, 944, 8546, 49407])
    }

    /// The `</w>` end-of-word marker, which the vocabulary encodes as *separate entries* rather
    /// than a flag: inside "hatbox" the first piece is the bare `hat` (3447), while a standalone
    /// "hat" is the distinct `hat</w>` (3801). Both spellings exist and both look plausible, so
    /// an implementation that appends the marker to every piece — or to none — still returns
    /// well-formed ids for a different string than the user typed, and only this case notices.
    func testEndOfWordMarkerAppliesOnlyToTheFinalPiece() {
        assertTokens("hatbox", [49406, 3447, 2063, 49407])
        assertTokens("hat box", [49406, 3801, 2063, 49407])
    }

    func testCaseAndWhitespaceAreNormalized() {
        // Lowercased, runs of whitespace collapsed, punctuation split off as its own token.
        assertTokens("Hello,   WORLD!", [49406, 3306, 267, 1002, 256, 49407])
    }

    /// Each digit is its own token under CLIP's regex — a date in a query does not survive as
    /// one unit, which is worth knowing before anyone tries to make search date-aware.
    func testDigitsTokenizeIndividually() {
        assertTokens("birthday cake 2024", [49406, 1166, 2972, 273, 271, 273, 275, 49407])
    }

    /// Byte-level BPE has to be total over any input. Accents and emoji must not throw, drop,
    /// or produce replacement characters.
    func testNonASCIIInput() {
        assertTokens("café", [49406, 15304, 49407])
        assertTokens("🐶", [49406, 10631, 49407])
    }

    func testEmptyQuery() {
        assertTokens("", [49406, 49407])
        assertTokens("     ", [49406, 49407])
    }

    // MARK: - Framing

    func testOverlongInputKeepsTheEndOfTextMarker() {
        // The encoder reads its sentence embedding from the EOT position, so truncation that
        // drops that token yields a meaningless vector rather than a merely shortened one.
        let ids = tokenizer.encodePadded(String(repeating: "waterfall ", count: 200))
        XCTAssertEqual(ids.count, CLIPTokenizer.contextLength)
        XCTAssertEqual(ids.first, 49406)
        XCTAssertEqual(ids.last, 49407, "end-of-text must survive truncation")
        XCTAssertFalse(ids.contains(0), "a truncated query has no room for padding")
    }

    func testRepeatedEncodingIsStable() {
        // The BPE cache is mutable state on a shared instance; a stale entry would corrupt
        // later queries rather than the one that populated it.
        let first = tokenizer.encodePadded("a photo of a waterfall")
        for _ in 0..<3 {
            XCTAssertEqual(tokenizer.encodePadded("a photo of a waterfall"), first)
        }
    }
}
