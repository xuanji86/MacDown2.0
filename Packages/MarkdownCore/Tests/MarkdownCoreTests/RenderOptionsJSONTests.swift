import Foundation
import Testing

@testable import MarkdownCore

@Test func renderOptionsJSONIsTheSameEveryTimeAndWhateverTheInsertionOrder() throws {
    let names = (0..<40).map { "inc\($0).qmd" }
    var options = RenderOptions()
    for n in names { options.files[n] = "text of \(n)" }
    let first = try options.jsonString()
    #expect((0..<300).allSatisfy { _ in options.json == first })
    // Equal values built in the opposite order (files, and the extension set from empty) give the same string.
    var other = RenderOptions()
    for n in names.reversed() { other.files[n] = "text of \(n)" }
    other.extensions = []
    for e in MarkdownExtension.allCases.reversed() where options.extensions.contains(e) { other.extensions.insert(e) }
    #expect(other == options)
    #expect(try other.jsonString() == first)
}

@Test func renderOptionsJSONCarriesEveryStoredPropertyAndDecodesBack() throws {
    // The hand-written `encode(to:)` must not drop a property someone adds later.
    var options = RenderOptions()
    options.hardBreaks = true
    options.files = ["a.qmd": "x"]
    let object = try #require(try JSONSerialization.jsonObject(with: Data(options.json.utf8)) as? [String: Any])
    let stored = Set(Mirror(reflecting: options).children.compactMap(\.label))
    #expect(Set(object.keys) == stored)
    #expect(try JSONDecoder().decode(RenderOptions.self, from: Data(options.json.utf8)) == options)
}
