import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController.init()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Headless mode (--headless, used by ae's PDF map rendering): park the window far off-screen and
    // keep the app out of the Dock/menu-bar. The window stays `display:true` (ordered-front), so
    // Flutter still runs its frame pipeline and the socket connects — unlike a hidden/miniaturised
    // window, which never gets a first frame and so never connects. The net effect is that report
    // generation no longer pops a visible window or steals focus. Note: this is gated on --headless,
    // NOT --socket, because the interactive point-drag/relax workflow also uses --socket and needs a
    // visible window.
    if CommandLine.arguments.contains("--headless") {
      self.setFrameOrigin(NSPoint(x: -30000, y: -30000))
      NSApp.setActivationPolicy(.accessory)
    }

    super.awakeFromNib()
  }
}
