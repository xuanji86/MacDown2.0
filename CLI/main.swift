import CLIKit
import Foundation

exit(await CLI.run(Array(CommandLine.arguments.dropFirst()), host: .live()))
