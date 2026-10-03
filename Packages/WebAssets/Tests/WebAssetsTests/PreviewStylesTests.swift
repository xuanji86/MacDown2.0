import Foundation
import Testing
@testable import WebAssets

struct PreviewStylesTests {
    @Test func theRequestedStylesAreRegistered() {
        let names = Set(PreviewStyles.all.map(\.name))
        for want in ["GitHub", "GitHub Dark", "Clearness", "Paper", "Solarized Light", "Solarized Dark", "Academic"] {
            #expect(names.contains(want), "missing \(want)")
        }
        #expect(PreviewStyles.defaultID == "github")
    }

    @Test func everyStyleHasItsFilesInTheBundle() {
        for style in PreviewStyles.all {
            #expect(WebAssets.url("preview-styles/\(style.id).css") != nil, "\(style.id).css")
            #expect(WebAssets.url("hljs-themes/\(style.hljs).css") != nil, "hljs \(style.hljs)")
        }
    }

    @Test func pairsAreMutualAndOfOppositeAppearance() {
        let byID = Dictionary(uniqueKeysWithValues: PreviewStyles.all.map { ($0.id, $0) })
        for style in PreviewStyles.all {
            guard let pair = style.pair else { continue }
            #expect(byID[pair]?.pair == style.id)
            #expect(byID[pair]?.appearance != style.appearance)
        }
    }

    @Test func aFixedChoiceIsOneStyleWithNoDarkVariant() {
        #expect(PreviewStyles.resolve(id: "solarized-dark", followSystem: false) == ("solarized-dark", nil))
    }

    @Test func followingTheSystemOrdersThePairByAppearance() {
        #expect(PreviewStyles.resolve(id: "github", followSystem: true) == ("github", "github-dark"))
        #expect(PreviewStyles.resolve(id: "github-dark", followSystem: true) == ("github", "github-dark"))
        #expect(PreviewStyles.resolve(id: "solarized-dark", followSystem: true) == ("solarized-light", "solarized-dark"))
    }

    @Test func aStyleWithoutAPartnerStaysFixedAndAnUnknownIdFallsBack() {
        #expect(PreviewStyles.resolve(id: "paper", followSystem: true) == ("paper", nil))
        #expect(PreviewStyles.resolve(id: "gone", followSystem: true) == ("github", "github-dark"))
        #expect(PreviewStyles.resolve(id: "gone", followSystem: false) == ("github", nil))
    }
}
