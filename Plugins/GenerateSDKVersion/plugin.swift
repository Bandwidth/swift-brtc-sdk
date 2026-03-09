import PackagePlugin

/// Build tool plugin that generates `SDKVersion+Generated.swift` before compilation.
///
/// The version string is provided by the `GenerateSDKVersionTool` executable, which
/// reads the `MARKETING_VERSION` environment variable (set by the release workflow
/// via `xcodebuild MARKETING_VERSION=…`). Falls back to `"dev"` for local builds.
@main
struct GenerateSDKVersion: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let output = context.pluginWorkDirectory.appending("SDKVersion+Generated.swift")
        return [
            .buildCommand(
                displayName: "Generate SDKVersion",
                executable: try context.tool(named: "GenerateSDKVersionTool").path,
                arguments: [output.string],
                outputFiles: [output]
            )
        ]
    }
}
