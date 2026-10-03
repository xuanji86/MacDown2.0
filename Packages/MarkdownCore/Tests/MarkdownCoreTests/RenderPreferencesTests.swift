import Foundation
import Testing
@testable import MarkdownCore

private func scratchDefaults() -> UserDefaults {
    let name = "RenderPreferencesTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Test func untouchedSettingsGiveTheRenderOptionsDefaults() {
    #expect(RenderPreferences().options == RenderOptions())
    #expect(RenderPreferences(defaults: scratchDefaults()).options == RenderOptions())
}

@Test func switchesMapOntoOptions() {
    var p = RenderPreferences()
    p.extensions.remove(.tables)
    p.extensions.insert(.sup)
    p.extensions.insert(.smartPunctuation)
    p.hardBreaks = true
    p.allowRawHTML = false
    p.codeHighlighting = false
    p.codeLineNumbers = true
    p.inlineDollarMath = true
    p.frontMatterDisplay = .table
    let o = p.options
    #expect(!o.extensions.contains(.tables) && o.extensions.contains(.sup) && o.extensions.contains(.smartPunctuation))
    #expect(o.hardBreaks && !o.allowRawHTML && !o.codeHighlighting && o.codeLineNumbers && o.inlineDollarMath)
    #expect(o.frontMatterDisplay == .table)
    // Not a setting: stays as RenderOptions has it.
    #expect(o.flavor == .markdown && o.renderChunks.isEmpty && o.headingAnchors)
}

@Test func preferencesSurviveARoundTripThroughDefaults() {
    let defaults = scratchDefaults()
    var p = RenderPreferences()
    p.extensions.remove(.footnotes)
    p.extensions.insert(.underline)
    p.hardBreaks = true
    p.frontMatterDisplay = .table
    p.write(to: defaults)
    #expect(RenderPreferences(defaults: defaults) == p)
}

@Test func onlyNonDefaultValuesAreStored() {
    let defaults = scratchDefaults()
    var p = RenderPreferences()
    p.write(to: defaults)
    #expect(defaults.object(forKey: RenderPreferences.Key.hardBreaks) == nil)
    #expect(defaults.object(forKey: RenderPreferences.Key.ext(.tables)) == nil)
    p.hardBreaks = true
    p.write(to: defaults)
    #expect(defaults.bool(forKey: RenderPreferences.Key.hardBreaks))
    p.hardBreaks = false  // back to the default: the key goes away again
    p.write(to: defaults)
    #expect(defaults.object(forKey: RenderPreferences.Key.hardBreaks) == nil)
}

@Test func garbageInDefaultsFallsBackToTheDefault() {
    let defaults = scratchDefaults()
    defaults.set("yes please", forKey: RenderPreferences.Key.hardBreaks)
    defaults.set("sideways", forKey: RenderPreferences.Key.frontMatterDisplay)
    #expect(RenderPreferences(defaults: defaults).options == RenderOptions())
}
