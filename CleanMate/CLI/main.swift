import Foundation

// The tool lives in CleanMate.app/Contents/Helpers: it reads the app's settings (Settings › Exclusions, Scan Groups,
// the user's ticks) and never writes them.
UserDefaults.standard.addSuite(named: AppIdentity.bundleID)
exit(await CommandLineTool.run(Array(CommandLine.arguments.dropFirst())))
