import Cocoa
import QuartzCore
import Darwin

func parseHexColor(_ hex: String) -> NSColor? {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    guard let value = UInt64(s, radix: 16) else { return nil }
    let r, g, b, a: CGFloat
    switch s.count {
    case 6:
        r = CGFloat((value >> 16) & 0xFF) / 255
        g = CGFloat((value >> 8) & 0xFF) / 255
        b = CGFloat(value & 0xFF) / 255
        a = 1
    case 8:
        r = CGFloat((value >> 24) & 0xFF) / 255
        g = CGFloat((value >> 16) & 0xFF) / 255
        b = CGFloat((value >> 8) & 0xFF) / 255
        a = CGFloat(value & 0xFF) / 255
    default:
        return nil
    }
    return NSColor(red: r, green: g, blue: b, alpha: a)
}

func printHelp() {
    let progName = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "curink"
    print("""
    Usage: \(progName) [options]
           \(progName) start
           \(progName) stop

    With no subcommand, runs as a silent daemon that idles until it
    receives "start" or "stop" via its Unix socket. Launch once at
    login, then drive it from a hotkey tool.

    Options (daemon launch):
      --color <hex>     Ink color in #RRGGBB or #RRGGBBAA (default: #40E0D0).
      --width <pt>      Base line width in points (default: 4).
      --glow <pt>       Glow blur radius in points (default: width * 2; 0 disables).
      -h, --help        Show this help and exit.
    """)
}

let socketPath: String = (NSTemporaryDirectory() as NSString).appendingPathComponent("curink.sock")

func fillSunPath(_ addr: inout sockaddr_un, _ path: String) -> Bool {
    let cap = MemoryLayout.size(ofValue: addr.sun_path)
    let cstr = path.utf8CString
    if cstr.count > cap { return false }
    _ = path.withCString { src in
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            memcpy(dst, src, cstr.count)
        }
    }
    return true
}

@discardableResult
func sendCommand(_ cmd: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return false }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    if !fillSunPath(&addr, socketPath) { return false }
    let rc = withUnsafePointer(to: &addr) { ap -> Int32 in
        ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
            connect(fd, sap, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if rc != 0 { return false }
    let msg = cmd + "\n"
    msg.withCString { _ = send(fd, $0, strlen($0), 0) }
    return true
}

func daemonAlive() -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return false }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    if !fillSunPath(&addr, socketPath) { return false }
    let rc = withUnsafePointer(to: &addr) { ap -> Int32 in
        ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
            connect(fd, sap, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    return rc == 0
}

signal(SIGPIPE, SIG_IGN)

func bootstrapDaemon() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    p.arguments = []
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do {
        try p.run()
    } catch {
        return false
    }
    let deadline = Date().addingTimeInterval(2.0)
    while Date() < deadline {
        usleep(20_000)
        if daemonAlive() { return true }
    }
    return false
}

if CommandLine.arguments.count >= 2 {
    let sub = CommandLine.arguments[1]
    if sub == "start" {
        if sendCommand("start") {
            exit(0)
        }
        if bootstrapDaemon() {
            sendCommand("start")
        }
        exit(0)
    }
    if sub == "stop" {
        sendCommand("stop")
        exit(0)
    }
}

var accentColor = parseHexColor("#40E0D0") ?? NSColor.cyan
var lineBaseWidth: CGFloat = 4
var glowRadiusOverride: CGFloat? = nil
var argIter = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIter.next() {
    switch arg {
    case "-h", "--help":
        printHelp()
        exit(0)
    case "--color":
        if let v = argIter.next(), let c = parseHexColor(v) { accentColor = c }
    case "--width":
        if let v = argIter.next(), let n = Double(v), n > 0 { lineBaseWidth = CGFloat(n) }
    case "--glow":
        if let v = argIter.next(), let n = Double(v), n >= 0 { glowRadiusOverride = CGFloat(n) }
    default:
        break
    }
}

let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
if serverFD < 0 {
    FileHandle.standardError.write(Data("curink: socket() failed\n".utf8))
    exit(1)
}
var serverAddr = sockaddr_un()
serverAddr.sun_family = sa_family_t(AF_UNIX)
if !fillSunPath(&serverAddr, socketPath) {
    FileHandle.standardError.write(Data("curink: socket path too long\n".utf8))
    exit(1)
}
var bindRC = withUnsafePointer(to: &serverAddr) { ap -> Int32 in
    ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
        bind(serverFD, sap, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
if bindRC != 0 {
    if daemonAlive() {
        exit(0)
    }
    unlink(socketPath)
    bindRC = withUnsafePointer(to: &serverAddr) { ap -> Int32 in
        ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
            bind(serverFD, sap, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if bindRC != 0 {
        FileHandle.standardError.write(Data("curink: bind() failed\n".utf8))
        exit(1)
    }
}
listen(serverFD, 4)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let unionFrame: NSRect = {
    var u: NSRect? = nil
    for s in NSScreen.screens {
        u = u.map { $0.union(s.frame) } ?? s.frame
    }
    return u ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
}()

let window = NSWindow(
    contentRect: unionFrame,
    styleMask: .borderless,
    backing: .buffered,
    defer: false
)
window.isOpaque = false
window.backgroundColor = .clear
window.level = .screenSaver
window.ignoresMouseEvents = true
window.hasShadow = false
window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

let view = NSView(frame: NSRect(origin: .zero, size: unionFrame.size))
view.wantsLayer = true

let resolvedGlowRadius = glowRadiusOverride ?? (lineBaseWidth * 2)

let inkLayer = CAShapeLayer()
inkLayer.frame = view.bounds
inkLayer.fillColor = NSColor.clear.cgColor
inkLayer.strokeColor = accentColor.cgColor
inkLayer.lineWidth = lineBaseWidth
inkLayer.lineCap = .round
inkLayer.lineJoin = .round
inkLayer.shadowColor = NSColor.white.cgColor
inkLayer.shadowOffset = .zero
inkLayer.shadowRadius = resolvedGlowRadius
inkLayer.shadowOpacity = resolvedGlowRadius > 0 ? 1.0 : 0.0
inkLayer.masksToBounds = false
view.layer?.addSublayer(inkLayer)

window.contentView = view

var path = CGMutablePath()
var lastPoint: CGPoint? = nil
var pollTimer: Timer? = nil
var isDrawing = false

func mouseInView() -> CGPoint {
    let m = NSEvent.mouseLocation
    return CGPoint(x: m.x - unionFrame.origin.x, y: m.y - unionFrame.origin.y)
}

func tick() {
    let p = mouseInView()
    if let lp = lastPoint {
        if hypot(p.x - lp.x, p.y - lp.y) < 0.5 { return }
        path.addLine(to: p)
    } else {
        path.move(to: p)
    }
    lastPoint = p
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    inkLayer.path = path
    CATransaction.commit()
}

func startDrawing() {
    if isDrawing { return }
    isDrawing = true

    path = CGMutablePath()
    lastPoint = nil

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    inkLayer.removeAnimation(forKey: "fadeOut")
    inkLayer.path = nil
    inkLayer.opacity = 1.0
    CATransaction.commit()

    window.orderFrontRegardless()

    tick()

    let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { _ in tick() }
    RunLoop.main.add(timer, forMode: .common)
    pollTimer = timer
}

func stopDrawing() {
    if !isDrawing { return }
    isDrawing = false
    pollTimer?.invalidate()
    pollTimer = nil

    let anim = CABasicAnimation(keyPath: "opacity")
    anim.fromValue = inkLayer.presentation()?.opacity ?? 1.0
    anim.toValue = 0.0
    anim.duration = 0.4
    anim.fillMode = .forwards
    anim.isRemovedOnCompletion = false

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    CATransaction.setCompletionBlock {
        if !isDrawing {
            window.orderOut(nil)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            inkLayer.removeAnimation(forKey: "fadeOut")
            inkLayer.path = nil
            inkLayer.opacity = 1.0
            CATransaction.commit()
            path = CGMutablePath()
            lastPoint = nil
        }
    }
    inkLayer.add(anim, forKey: "fadeOut")
    inkLayer.opacity = 0
    CATransaction.commit()
}

DispatchQueue.global(qos: .userInteractive).async {
    while true {
        var ca = sockaddr_un()
        var clen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let cfd = withUnsafeMutablePointer(to: &ca) { ap -> Int32 in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                accept(serverFD, sap, &clen)
            }
        }
        if cfd < 0 { continue }
        var buf = [UInt8](repeating: 0, count: 64)
        let n = recv(cfd, &buf, buf.count, 0)
        close(cfd)
        if n <= 0 { continue }
        let s = String(bytes: buf[0..<n], encoding: .utf8) ?? ""
        DispatchQueue.main.async {
            if s.hasPrefix("start") {
                startDrawing()
            } else if s.hasPrefix("stop") {
                stopDrawing()
            }
        }
    }
}

app.run()
