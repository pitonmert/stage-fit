import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
// CLI paths deliberately exit before NSApplication, AX permissions, observers or hotkeys.
if arguments == ["--version"] {
    print("StageFit 1.0.0")
} else if arguments == ["--help"] || arguments == ["-h"] {
    print("""
    StageFit — window layouts with room for Stage Manager.
    Usage: StageFit [--help | --version]
    Launch StageFit.app to use the menu bar application.
    Left-click: arrange windows. Right-click: options and Quit.
    """)
} else if !arguments.isEmpty {
    FileHandle.standardError.write(Data("Unknown arguments. Use --help.\n".utf8))
    exit(64)
} else if Bundle.main.bundleURL.pathExtension != "app" {
    FileHandle.standardError.write(Data("Launch StageFit.app; use scripts/build.sh to create it.\n".utf8))
    exit(64)
} else {
    MainActor.assumeIsolated {
        let identifier = Bundle.main.bundleIdentifier ?? "com.pitonmert.StageFit"
        guard NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .allSatisfy({ $0.processIdentifier == getpid() }) else { exit(0) }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppController()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
