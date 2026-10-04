import CLIKit
import Foundation
import PrintKit

// Printing needs AppKit and WebKit, which CLIKit stays clear of. `--export pdf` lays the page out in a hidden WKWebView inside
// this process (no app, no window, no Dock icon; it needs a login session). Nothing of that is touched unless a PDF is asked
// for: `macdown2 --version` still takes about 15 ms.
var host = CLIHost.live()
host.renderPDF = { html, setup in
    await PrintPage.becomeHeadless()
    return try await PrintPage.pdf(html: html, setup: setup)
}
exit(await CLI.run(Array(CommandLine.arguments.dropFirst()), host: host))
