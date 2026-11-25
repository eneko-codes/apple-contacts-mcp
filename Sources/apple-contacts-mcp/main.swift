import ContactsMCPCore
import Foundation

// Launcher only. Everything testable lives in ContactsMCPCore, which the test target
// imports; an executable target cannot be imported.
let configuration = Configuration.parse(Array(CommandLine.arguments.dropFirst()))
await ContactsMCPServer.run(configuration: configuration)
