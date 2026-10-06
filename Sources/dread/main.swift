import DreadCLI
import Foundation

let code = await Dread.run(Array(CommandLine.arguments.dropFirst()))
exit(code.rawValue)
