import Foundation
import Testing
@testable import MarkdownCore

private func scratchDefaults() -> UserDefaults {
    let name = "PageSetupTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private let us = Locale(identifier: "en_US")
private let germany = Locale(identifier: "de_DE")

@Test func paperFollowsTheRegionUntilChosen() {
    #expect(PageSetup(locale: us).paper == .letter)
    #expect(PageSetup(locale: Locale(identifier: "en_CA")).paper == .letter)
    #expect(PageSetup(locale: germany).paper == .a4)
    #expect(PageSetup(locale: Locale(identifier: "zh_CN")).paper == .a4)
    #expect(PageSetup(locale: us).top == 54 && PageSetup(locale: us).left == 54)  // 3/4 in, as before it was a setting
}

@Test func landscapeSwapsTheSides() {
    var setup = PageSetup(locale: germany)
    #expect(setup.pageSize.width < setup.pageSize.height)
    setup.orientation = .landscape
    #expect(setup.pageSize.width == PageSetup.Paper.a4.size.height && setup.pageSize.height == PageSetup.Paper.a4.size.width)
}

@Test func settingsSurviveARoundTripAndOnlyDifferencesAreStored() {
    let defaults = scratchDefaults()
    PageSetup(locale: us).write(to: defaults, locale: us)
    for key in [PageSetup.Key.paper, PageSetup.Key.orientation, PageSetup.Key.top, PageSetup.Key.right, PageSetup.Key.bottom, PageSetup.Key.left] {
        #expect(defaults.object(forKey: key) == nil, "\(key) stored for a default")
    }
    var setup = PageSetup(locale: us)
    setup.paper = .a4
    setup.orientation = .landscape
    setup.top = 36
    setup.left = 72
    setup.write(to: defaults, locale: us)
    #expect(PageSetup(defaults: defaults, locale: us) == setup)
    // A new region's default paper reaches someone who never chose one, but not someone who did.
    #expect(PageSetup(defaults: scratchDefaults(), locale: germany).paper == .a4)
    var chosen = PageSetup(locale: germany)
    chosen.paper = .letter
    let other = scratchDefaults()
    chosen.write(to: other, locale: germany)
    #expect(PageSetup(defaults: other, locale: us).paper == .letter)
}

@Test func nonsenseInDefaultsReadsAsDefaultOrClamped() {
    let defaults = scratchDefaults()
    defaults.set("tabloid", forKey: PageSetup.Key.paper)
    defaults.set(3, forKey: PageSetup.Key.orientation)
    defaults.set("wide", forKey: PageSetup.Key.top)
    defaults.set(-5.0, forKey: PageSetup.Key.bottom)
    defaults.set(9999.0, forKey: PageSetup.Key.left)
    defaults.set(Double.nan, forKey: PageSetup.Key.right)
    let setup = PageSetup(defaults: defaults, locale: us)
    #expect(setup.paper == .letter && setup.orientation == .portrait && setup.top == 54 && setup.right == 54)
    #expect(setup.bottom == 0 && setup.left == PageSetup.marginRange.upperBound)
}
