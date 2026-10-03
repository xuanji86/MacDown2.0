import Foundation

/// Vendored JS/CSS built from `Web/` (run `make web` after changing it).
public enum WebAssets {
    public static func url(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources")
    }
}
