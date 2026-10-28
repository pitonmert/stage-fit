import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
// CLI paths exit before NSApplication, observers or hotkeys. Only --diagnose reads AX data.
if arguments == ["--version"] {
    print("StageFit 1.0.0")
} else if arguments == ["--help"] || arguments == ["-h"] {
    print("""
    StageFit — window layouts with room for Stage Manager.
    Usage: StageFit [--help | --version | --diagnose]
    Launch StageFit.app to use the menu bar application.
    Left-click: arrange windows. Right-click: swap visible windows, options and Quit.
    --diagnose: print window geometry and group membership without changing windows.
    """)
} else if arguments == ["--diagnose"] {
    Task { @MainActor in
        do { print(try await Diagnostics.report()); exit(0) }
        catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
    dispatchMain()
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
