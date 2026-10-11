import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  // Folders the user has granted, kept open for as long as the app runs.
  private var granted: [URL] = []

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // What the App Store edition needs from macOS: inside the sandbox the app
    // can only reach folders the user has picked, and cannot run `open`.
    let channel = FlutterMethodChannel(
      name: "marsa/native",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "openUrl":
        guard let url = URL(string: args["url"] as? String ?? "") else {
          return result(false)
        }
        result(NSWorkspace.shared.open(url))
      case "grantFolder":
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.canCreateDirectories = true
        panel.message = args["message"] as? String ?? ""
        panel.prompt = args["button"] as? String ?? "Allow"
        if let start = args["start"] as? String {
          panel.directoryURL = URL(fileURLWithPath: start, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else {
          return result(nil)
        }
        let bookmark = try? url.bookmarkData(
          options: .withSecurityScope, includingResourceValuesForKeys: nil,
          relativeTo: nil)
        result([
          "path": url.path,
          "bookmark": bookmark?.base64EncodedString() ?? "",
        ])
      case "useFolder":
        guard
          let data = Data(base64Encoded: args["bookmark"] as? String ?? "")
        else { return result(nil) }
        var stale = false
        guard
          let url = try? URL(
            resolvingBookmarkData: data, options: .withSecurityScope,
            relativeTo: nil, bookmarkDataIsStale: &stale),
          url.startAccessingSecurityScopedResource()
        else { return result(nil) }
        self?.granted.append(url)
        result(url.path)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
