// Claude Sim Audio
//
// Keeps the iOS simulators Claude runs off the Mac's speakers, while still letting Claude
// record and measure what they play (an alarm, a sound effect) to test it.
//
// How: each muted simulator's audio output is routed to BlackHole 2ch, a silent virtual
// device, through CoreSimulator's own per-simulator host route (router.m). Nothing is
// captured, so macOS shows no recording indicator. The route sticks across reboots and moves
// apps that are already playing.
//
// Safety net: every app and system process inside a simulator is its own Core Audio client
// on the Mac, so the guard can see where each one plays. If a muted simulator is caught
// playing to anything but BlackHole (BlackHole missing, a route that failed), the guard
// mutes it with a Core Audio process tap (CATapMuted) inside a private aggregate device it
// keeps running: a muted tap only works while something reads it. That shows the purple
// recording dot, which is why it is only the fallback.
//
// Last resort: the tap has a history of stalling, so it does not get the final word. A muted
// simulator that still plays to a real output after 3 seconds, with no tap seen reading its
// audio, has the playing process quit; if it plays out loud again within two minutes the
// simulator is shut down. Either way a banner says so. Problems the guard cannot fix itself
// (CoreSimulator not answering, a route it cannot read) are logged as ALERT lines and get a
// banner too, and the guard exits, for launchd to restart it, when it stops making progress.
//
// `simaudio record` opens a tap on one simulator for a few seconds (the dot shows only then),
// saves a WAV file and reports how loud it was. `simaudio doctor` checks the whole chain,
// down to playing a silent test sound inside each simulator and reading where it went.
//
// Which simulators are muted: all of them (mode "all", the default). `simaudio hear <sim>`
// lets one play out loud for a while. Mode "claude" is the older, looser rule: the ones the
// idle-reaper says a Claude session started (~/.claude/idle-reaper/state.json), any simulator
// with "Claude" in its name, and every simulator while no simulator window (DeviceHub or
// Simulator) is open.
//
// Cost: the guard does not poll for sound. Core Audio tells it when a simulator process
// appears, starts or stops playing or changes device, so at rest it wakes every 2 seconds
// only to check routes and write its heartbeat.
//
// One binary, two roles: `claude-sim-audio daemon` is the guard (run by the LaunchAgent
// local.sim-audio); every other subcommand is the `simaudio` CLI, which talks to the guard
// through small JSON files in ~/.claude/sim-audio (or $SIM_AUDIO_HOME).

import AVFoundation
import CoreAudio
import Darwin
import Foundation

// MARK: - Paths

let home = NSHomeDirectory()
/// The guard's folder: its app, settings, log and recordings. SIM_AUDIO_HOME moves it; the
/// installer sets it (in the LaunchAgent, the hooks and the `simaudio` command) when told to.
let baseDir = ProcessInfo.processInfo.environment["SIM_AUDIO_HOME"].flatMap { $0.isEmpty ? nil : $0 }
    ?? home + "/.claude/sim-audio"
let configPath = baseDir + "/config.json"
let statusPath = baseDir + "/status.json"
let eventsPath = baseDir + "/events.log"
let requestsDir = baseDir + "/requests"
let recordingsDir = baseDir + "/recordings"
let alertsPath = baseDir + "/alerts.json"
let tonePath = baseDir + "/Claude Sim Audio.app/Contents/Resources/simtone"
let reaperStatePath = home + "/.claude/idle-reaper/state.json"
let devicesDir = home + "/Library/Developer/CoreSimulator/Devices"

// MARK: - Small helpers

func fourCC(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [24, 16, 8, 0].map { UInt8((n >> UInt32($0)) & 0xFF) }
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }), let s = String(bytes: bytes, encoding: .ascii) {
        return "'\(s)' (\(status))"
    }
    return String(status)
}

func readJSON(_ path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func writeJSON(_ object: Any, to path: String) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

func modificationDate(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
}

let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

let fileClock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f
}()

func logEvent(_ line: String) {
    let text = clock.string(from: Date()) + "  " + line + "\n"
    let fm = FileManager.default
    if let size = (try? fm.attributesOfItem(atPath: eventsPath))?[.size] as? Int, size > 512_000 {
        try? fm.removeItem(atPath: eventsPath + ".1")
        try? fm.moveItem(atPath: eventsPath, toPath: eventsPath + ".1")
    }
    if let handle = FileHandle(forWritingAtPath: eventsPath) {
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
    } else {
        try? text.write(toFile: eventsPath, atomically: true, encoding: .utf8)
    }
}

let alertLock = NSLock()

/// A banner on the Mac for something the guard could not keep quiet or cannot check. At most
/// one per kind every 15 minutes, remembered across guard restarts.
func alert(_ key: String, _ message: String, testing: Bool = false) {
    alertLock.lock()
    defer { alertLock.unlock() }
    let now = Date().timeIntervalSince1970
    var seen = (readJSON(alertsPath) ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }.filter { now - $0.value < 86_400 }
    if let last = seen[key], now - last < 900 { return }
    seen[key] = now
    writeJSON(seen, to: alertsPath)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", "on run argv\ndisplay notification (item 1 of argv) with title (item 2 of argv)\nend run",
                      message, testing ? "Simulator audio (test of the alarm)" : "Simulator audio"]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    task.terminationHandler = { _ in }
    try? task.run()
}

func say(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

func complain(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func dB(_ linear: Double) -> Double {
    linear > 0 ? 20 * log10(linear) : -.infinity
}

func formatDB(_ value: Double) -> String {
    value.isFinite ? String(format: "%.1f dBFS", value) : "silent"
}

// MARK: - Core Audio helpers

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

func caValue<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
    var addr = address(selector)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

func caString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let s = value else { return nil }
    return s.takeRetainedValue() as String
}

func caObjects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
}

// MARK: - Which simulator a process belongs to

let udidPattern = try! NSRegularExpression(pattern: "CoreSimulator/Devices/([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})/")

func matchUDID(_ text: String) -> String? {
    let range = NSRange(text.startIndex..., in: text)
    guard let m = udidPattern.firstMatch(in: text, range: range), let r = Range(m.range(at: 1), in: text) else { return nil }
    return String(text[r]).uppercased()
}

func parentPID(_ pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? pid_t(info.pbi_ppid) : nil
}

func executablePath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
}

func commandLine(_ pid: pid_t) -> String {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return "" }
    return String(decoding: buffer.prefix(size).map { $0 == 0 ? 32 : $0 }, as: UTF8.self)
}

/// A simulator's apps live under Devices/<UDID>/, and its system processes (SpringBoard,
/// which plays notification sounds) are children of that device's launchd_sim, whose
/// command line names the device folder.
func simulatorUDID(of pid: pid_t) -> String? {
    var current = pid
    for _ in 0..<16 {
        if let path = executablePath(current) {
            if let udid = matchUDID(path) { return udid }
            if path.hasSuffix("launchd_sim") { return matchUDID(commandLine(current)) }
        }
        guard let parent = parentPID(current), parent > 1, parent != current else { return nil }
        current = parent
    }
    return nil
}

/// True while a window onto the simulators is open (Xcode's DeviceHub, or the older
/// Simulator app). With none open every booted simulator is headless, and only Claude
/// sessions drive headless simulators.
func simulatorWindowOpen() -> Bool {
    let capacity = Int(proc_listallpids(nil, 0)) + 128
    guard capacity > 128 else { return false }
    var pids = [pid_t](repeating: 0, count: capacity)
    let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
    for pid in pids.prefix(max(0, count)) where pid > 0 {
        guard let path = executablePath(pid) else { continue }
        if path.hasSuffix("/DeviceHub.app/Contents/MacOS/DeviceHub") || path.hasSuffix("/Simulator.app/Contents/MacOS/Simulator") {
            return true
        }
    }
    return false
}

/// A JSON number rounded to one decimal place, written as "-21.3" rather than "-21.300000000000001".
func tenths(_ value: Double) -> Any {
    value.isFinite ? NSDecimalNumber(string: String(format: "%.1f", value)) : NSNull()
}

/// The app's own name from its Info.plist ("My App", not its bundle folder "iPhone.app").
func appName(_ path: String) -> String {
    if path.hasSuffix("/simtone") { return "the doctor's test sound" }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    if let i = parts.lastIndex(where: { $0.hasSuffix(".app") || $0.hasSuffix(".appex") || $0.hasSuffix(".xpc") }) {
        let bundle = parts[...i].joined(separator: "/")
        let info = NSDictionary(contentsOfFile: bundle + "/Info.plist")
        if let name = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String),
           !name.isEmpty, !name.hasPrefix("$(") {
            return name
        }
        return String(parts[i].split(separator: ".").first ?? parts[i])
    }
    return parts.last.map(String.init) ?? "?"
}

var simNameCache: [String: String] = [:]
let simNameLock = NSLock()

func simName(_ udid: String) -> String {
    simNameLock.lock()
    defer { simNameLock.unlock() }
    if let name = simNameCache[udid] { return name }
    let plist = NSDictionary(contentsOfFile: "\(devicesDir)/\(udid)/device.plist")
    let name = plist?["name"] as? String ?? udid
    simNameCache[udid] = name
    return name
}

// MARK: - Level meter

final class Meter {
    let sampleRate: Double
    private(set) var frames = 0
    private(set) var peak: Float = 0
    private var sumSquares: Double = 0
    private var samples = 0
    private var windowSquares: Double = 0
    private var windowFrames = 0
    private(set) var audibleWindows = 0
    private(set) var firstSound: Double?
    private(set) var lastSound: Double?

    /// A tenth of a second counts as sound when its level is above -60 dBFS.
    static let audibleRMS = 0.001

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    /// `startsAt` is the buffer's first frame in seconds since the recording began, by the
    /// clock: a tap delivers audio only while something plays, so frame counts alone would
    /// squeeze out the quiet gaps.
    func add(_ buffer: AVAudioPCMBuffer, startsAt: Double) {
        guard let channels = buffer.floatChannelData else { frames += Int(buffer.frameLength); return }
        let count = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        let stride = buffer.stride
        let window = max(1, Int(sampleRate / 10))
        let bufferStartFrame = frames
        for i in 0..<count {
            var loudest: Float = 0
            for c in 0..<channelCount {
                let v = interleaved ? channels[0][i * stride + c] : channels[c][i]
                loudest = max(loudest, abs(v))
                sumSquares += Double(v) * Double(v)
                samples += 1
            }
            peak = max(peak, loudest)
            windowSquares += Double(loudest) * Double(loudest)
            windowFrames += 1
            if windowFrames >= window {
                if (windowSquares / Double(windowFrames)).squareRoot() > Self.audibleRMS {
                    audibleWindows += 1
                    let t = max(0, startsAt + Double(frames - bufferStartFrame) / sampleRate)
                    if firstSound == nil { firstSound = t }
                    lastSound = t
                }
                windowSquares = 0
                windowFrames = 0
            }
            frames += 1
        }
    }

    var rms: Double { samples > 0 ? (sumSquares / Double(samples)).squareRoot() : 0 }
}

// MARK: - A simulator's audio bus

/// One simulator's audio: a process tap over every process of that simulator, inside a
/// private aggregate device that runs the whole time.
///
/// A CATapMuted tap only keeps a process off the speakers while a device that contains the
/// tap is running; a tap nobody reads mutes nothing. So a muted simulator gets a bus that
/// runs for as long as the simulator has audio open, and the audio is thrown away unless a
/// recording has attached a sink.
final class SimBus {
    let udid: String
    let muted: Bool
    private(set) var objects: [AudioObjectID]
    private(set) var error: String?
    private(set) var format: AVAudioFormat?
    private let description: CATapDescription
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue: DispatchQueue
    private let sinkLock = NSLock()
    private var sink: ((AVAudioPCMBuffer) -> Void)?
    private var callbackCount = 0

    init(udid: String, objects: [AudioObjectID], muted: Bool) {
        self.udid = udid
        self.objects = objects
        self.muted = muted
        description = CATapDescription(stereoMixdownOfProcesses: objects)
        description.name = "Claude Sim Audio: \(simName(udid))"
        description.isPrivate = true
        description.muteBehavior = muted ? .muted : .unmuted
        ioQueue = DispatchQueue(label: "local.claude.sim-audio.bus", qos: .userInteractive)
        start()
    }

    private func start() {
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else {
            error = "could not create the tap: \(fourCC(status))"
            return
        }
        guard let tapUID = caString(tap, kAudioTapPropertyUID),
              var asbd = caValue(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription()),
              let tapFormat = AVAudioFormat(streamDescription: &asbd) else {
            error = "could not read the tap's format"
            return
        }
        format = tapFormat

        // The output device is only the aggregate's clock: nothing is ever written to it.
        let outputDevice = caValue(systemObject, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0)) ?? 0
        let outputUID = caString(outputDevice, kAudioDevicePropertyDeviceUID) ?? ""
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Claude Sim Audio bus",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUID]],
        ]
        status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &device)
        guard status == noErr, device != kAudioObjectUnknown else {
            error = "could not create the bus device: \(fourCC(status))"
            return
        }
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, ioQueue) { [weak self] _, input, _, _, _ in
            guard let self else { return }
            self.sinkLock.lock()
            self.callbackCount &+= 1
            let sink = self.sink
            self.sinkLock.unlock()
            guard let sink, let format = self.format,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            sink(buffer)
        }
        guard status == noErr, let procID else {
            error = "could not attach to the bus device: \(fourCC(status))"
            return
        }
        status = AudioDeviceStart(device, procID)
        if status != noErr { error = "could not start the bus device: \(fourCC(status))" }
    }

    /// How many audio callbacks have run; the guard checks that it keeps climbing.
    var callbacks: Int {
        sinkLock.lock()
        defer { sinkLock.unlock() }
        return callbackCount
    }

    /// Points the tap at a new set of processes (an app launched or quit). False when Core
    /// Audio refused, in which case the caller rebuilds the bus.
    func update(objects newObjects: [AudioObjectID]) -> Bool {
        if newObjects == objects { return true }
        guard tap != kAudioObjectUnknown else { return false }
        description.processes = newObjects
        var updated = description
        var addr = address(kAudioTapPropertyDescription)
        let status = AudioObjectSetPropertyData(tap, &addr, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), &updated)
        if status == noErr { objects = newObjects }
        return status == noErr
    }

    func setSink(_ newSink: ((AVAudioPCMBuffer) -> Void)?) {
        sinkLock.lock()
        sink = newSink
        sinkLock.unlock()
    }

    /// Waits for any audio callback already running to finish.
    func drain() { ioQueue.sync {} }

    func stop() {
        setSink(nil)
        if let procID {
            AudioDeviceStop(device, procID)
            AudioDeviceDestroyIOProcID(device, procID)
            self.procID = nil
        }
        drain()
        if device != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(device)
            device = kAudioObjectUnknown
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
            tap = kAudioObjectUnknown
        }
    }
}

// MARK: - The guard (daemon)

let blackHoleUID = "BlackHole2ch_UID"
let systemDefaultRoute = "__sim__hostUseSystemDefaultDeviceUID"
let routesPath = baseDir + "/routes.json"

/// Which simulators should be quiet, as of one moment.
struct MuteRule {
    let mode: String
    let hear: [String: Double]
    let reaperSims: Set<String>
    let windowOpen: Bool
    /// Test switches (config.json "test"): simulators deliberately left off BlackHole, and
    /// the fallback tap deliberately kept off, to prove the nets under them.
    var testNoRoute: Set<String> = []
    var testNoTap = false

    func shouldMute(_ udid: String) -> Bool {
        if let until = hear[udid], until > Date().timeIntervalSince1970 { return false }
        switch mode {
        case "off": return false
        case "claude":
            return reaperSims.contains(udid) || simName(udid).localizedCaseInsensitiveContains("claude") || !windowOpen
        default: return true
        }
    }
}

func developerDir() -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    task.arguments = ["-p"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    if (try? task.run()) != nil {
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        task.waitUntilExit()
        if !out.isEmpty { return out }
    }
    return "/Applications/Xcode.app/Contents/Developer"
}

func hostDeviceExists(uid: String) -> Bool {
    caObjects(systemObject, kAudioHardwarePropertyDevices).contains { caString($0, kAudioDevicePropertyDeviceUID) == uid }
}

func outputDeviceUIDs(ofProcess object: AudioObjectID) -> [String] {
    caObjects(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)
        .compactMap { caString($0, kAudioDevicePropertyDeviceUID) }
}

final class Guard {
    struct Proc {
        let object: AudioObjectID
        let pid: pid_t
        let udid: String
        let app: String
        var playing = false
        var since = Date()
    }

    /// How long the tap stays on after a muted simulator was last caught playing to a real output.
    private static let leakHold: TimeInterval = 30
    /// How long a muted simulator may play to a real output, with no working tap over it,
    /// before the guard quits what is playing.
    private static let leakLimit: TimeInterval = 3
    /// A simulator that plays out loud again this soon after its app was quit is shut down.
    private static let repeatWindow: TimeInterval = 120
    /// How often the guard looks: while a mute needs watching, while a muted simulator is
    /// playing, and the rest of the time. Core Audio tells it the moment a simulator process
    /// appears or starts or stops playing, so the timer is only the backstop.
    private static let busyInterval: TimeInterval = 0.5
    private static let playingInterval: TimeInterval = 1
    private static let quietInterval: TimeInterval = 2

    private let lock = NSLock()
    private var procs: [AudioObjectID: Proc] = [:]
    private var notSimulator: Set<AudioObjectID> = []
    /// Fallback mutes: a live, muted tap bus per simulator that is not safely routed. Touched with `lock` held.
    private var buses: [String: SimBus] = [:]
    private var busErrors: [String: String] = [:]
    private var busRetry: [String: Date] = [:]
    private var busCallbacks: [String: Int] = [:]
    /// Whether each tap was seen reading audio over the last half second: only then does it count as a mute.
    private var busSample: [String: (count: Int, at: Date)] = [:]
    private var busProven: Set<String> = []
    /// Each simulator's output route, as the router last saw it. Touched with `lock` held.
    private var routes: [String: String] = [:]
    private var routerProblem: String?
    private var booting = false
    private var forceRoute: Set<String> = []
    private var lastLeak: [String: Date] = [:]
    /// Since when each muted simulator has been playing to a real output with no working tap.
    private var exposedSince: [String: Date] = [:]
    private var lastQuit: [String: Date] = [:]
    private var mode = "all"
    private var hear: [String: Double] = [:]
    private var testNoRoute: Set<String> = []
    private var testNoTap = false
    private var testUntil: Double = 0
    private var reaperSims: Set<String> = []
    private var configDate: Date?
    private var reaperDate: Date?
    private var lastStatus = ""
    private var lastStatusWrite = Date.distantPast
    private var windowOpen = false

    // Main thread only.
    private var procListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var activeRequests: Set<String> = []
    private var timer: DispatchSourceTimer?
    private var interval: TimeInterval = 0
    private var pokePending = false
    private var blackHolePresent = false
    private var lastDeviceCheck = Date.distantPast
    private var lastWindowScan = Date.distantPast
    private var lastHealthCheck = Date.distantPast
    private var lastNameFlush = Date()
    private var lastRouterSync = Date.distantPast
    private var routerDue = true
    private var routerBusy = false
    private var routerStarted: TimeInterval = 0
    private var requestWatcher: DispatchSourceFileSystemObject?
    private var watchdog: DispatchSourceTimer?
    private let beatLock = NSLock()
    private var beat = ProcessInfo.processInfo.systemUptime

    // The router: touched only on `routerQueue`.
    private let routerQueue = DispatchQueue(label: "local.claude.sim-audio.router")
    private var routedByUs: Set<String> = []
    private var routeFailures: Set<String> = []
    private var routerDownSince: Date?
    private var routerDownReported = false
    private var unreadableSince: [String: Date] = [:]
    private var unreadableReported: Set<String> = []
    private let devDir = developerDir()

    /// Called with `lock` held.
    private var testing: Bool { testUntil > Date().timeIntervalSince1970 }

    /// Called with `lock` held.
    private var rule: MuteRule {
        let testing = self.testing
        return MuteRule(mode: mode, hear: hear, reaperSims: reaperSims, windowOpen: windowOpen,
                        testNoRoute: testing ? testNoRoute : [], testNoTap: testing && testNoTap)
    }

    func run() -> Never {
        for dir in [baseDir, requestsDir, recordingsDir] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        // One guard at a time. A second one (the LaunchAgent starting while a hand-started
        // guard runs) waits here and takes over when the first exits, instead of exiting and
        // being relaunched by launchd every few seconds.
        let lockFD = Darwin.open(baseDir + "/.guard.lock", O_CREAT | O_RDWR, 0o644)
        if lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            flock(lockFD, LOCK_EX)
        }
        routedByUs = Set((readJSON(routesPath)?["routed"] as? [String]) ?? [])
        logEvent("guard started (pid \(getpid()))")

        // Re-check the moment a new process connects to Core Audio.
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(systemObject, &addr, DispatchQueue.main) { [weak self] _, _ in
            self?.poke()
        }
        // The fallback buses clock off the default output device: rebuild them when it changes.
        var outputAddr = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(systemObject, &outputAddr, DispatchQueue.main) { [weak self] _, _ in
            self?.rebuildAllBuses(reason: "the Mac's output device changed")
        }
        // BlackHole coming or going.
        var devicesAddr = address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(systemObject, &devicesAddr, DispatchQueue.main) { [weak self] _, _ in
            self?.lastDeviceCheck = .distantPast
            self?.routerDue = true
            self?.poke()
        }
        // A `simaudio record` request arriving.
        let requestsFD = Darwin.open(requestsDir, O_EVTONLY)
        if requestsFD >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: requestsFD, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in self?.poke() }
            source.resume()
            requestWatcher = source
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        setInterval(Guard.busyInterval)
        timer.resume()

        // A guard that stops looking protects nothing, and launchd only restarts one that
        // exits: so exit when the main loop has not run for a minute.
        let dog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        dog.schedule(deadline: .now() + 20, repeating: 20, leeway: .seconds(2))
        dog.setEventHandler { [self] in
            beatLock.lock()
            let last = beat
            beatLock.unlock()
            if ProcessInfo.processInfo.systemUptime - last > 60 {
                logEvent("ALERT: the guard stopped responding for a minute, restarting it")
                exit(1)
            }
        }
        dog.resume()
        watchdog = dog

        tick()
        RunLoop.main.run()
        exit(0)
    }

    private func setInterval(_ seconds: TimeInterval) {
        guard seconds != interval, let timer else { return }
        interval = seconds
        timer.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .milliseconds(Int(seconds * 100)))
    }

    /// Looks again right away. Several things changing at once make one look, not several.
    private func poke() {
        if pokePending { return }
        pokePending = true
        DispatchQueue.main.async { [self] in
            pokePending = false
            tick()
        }
    }

    /// Core Audio says when a simulator process starts or stops playing, or changes device.
    private func watch(_ object: AudioObjectID) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.poke() }
        var running = address(kAudioProcessPropertyIsRunningOutput)
        AudioObjectAddPropertyListenerBlock(object, &running, DispatchQueue.main, block)
        var devices = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices, mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(object, &devices, DispatchQueue.main, block)
        procListeners[object] = block
    }

    private func unwatch(_ object: AudioObjectID) {
        guard let block = procListeners.removeValue(forKey: object) else { return }
        var running = address(kAudioProcessPropertyIsRunningOutput)
        AudioObjectRemovePropertyListenerBlock(object, &running, DispatchQueue.main, block)
        var devices = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices, mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(object, &devices, DispatchQueue.main, block)
    }

    private func reloadSettings() {
        let configStamp = modificationDate(configPath)
        if configStamp != configDate {
            configDate = configStamp
            let config = readJSON(configPath) ?? [:]
            mode = (config["mode"] as? String) ?? "all"
            hear = (config["hear"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
            // Test switches, for proving the safety nets: leave a simulator off BlackHole,
            // and keep the fallback tap off. They expire by themselves.
            let test = config["test"] as? [String: Any] ?? [:]
            testNoRoute = Set((test["no_route"] as? [String] ?? []).map { $0.uppercased() })
            testNoTap = test["no_tap"] as? Bool ?? false
            testUntil = (test["until"] as? NSNumber)?.doubleValue ?? 0
            if testing {
                logEvent("TEST settings are on for \(Int(testUntil - Date().timeIntervalSince1970)) s: not routing \(testNoRoute.map(simName).sorted().joined(separator: ", "))\(testNoTap ? ", fallback tap off" : "")")
            }
            routerDue = true
        }
        let reaperStamp = modificationDate(reaperStatePath)
        if reaperStamp != reaperDate {
            reaperDate = reaperStamp
            let state = readJSON(reaperStatePath) ?? [:]
            reaperSims = Set((state["sims"] as? [String: Any] ?? [:]).keys.map { $0.uppercased() })
        }
    }

    func objects(for udid: String) -> [(AudioObjectID, String)] {
        lock.lock()
        defer { lock.unlock() }
        return procs.values.filter { $0.udid == udid }.sorted { $0.object < $1.object }.map { ($0.object, $0.app) }
    }

    func bus(for udid: String) -> SimBus? {
        lock.lock()
        defer { lock.unlock() }
        return buses[udid]
    }

    func shouldMuteNow(_ udid: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return rule.shouldMute(udid)
    }

    private func rebuildAllBuses(reason: String) {
        lock.lock()
        let old = buses
        buses.removeAll()
        busCallbacks.removeAll()
        busSample.removeAll()
        busProven.removeAll()
        lock.unlock()
        for bus in old.values { bus.stop() }
        if !old.isEmpty { logEvent("rebuilding the fallback mute: \(reason)") }
        tick()
    }

    // MARK: Routing

    /// Points every simulator that should be quiet at BlackHole, and puts back the ones the
    /// guard routed that should play out loud again. Runs on `routerQueue`. True when
    /// something changed that the main loop should look at right away.
    private func syncRoutes(_ rule: MuteRule, force: Set<String>, testing: Bool) -> Bool {
        let present = hostDeviceExists(uid: blackHoleUID)
        var found: [String: String] = [:]
        var anyBooting = false
        var problem: String?
        let before = routedByUs
        let now = Date()
        let tag = testing ? "ALARM TEST" : "ALERT"
        if let live = SimAudioLiveDevices(devDir) {
            if routerDownReported { logEvent("CoreSimulator answers again: simulator audio routes are being checked") }
            routerDownSince = nil
            routerDownReported = false
            for (udid, state) in live {
                let isBooting = state.intValue != 3
                if isBooting { anyBooting = true }
                var route = SimAudioOutputRoute(udid)
                if route == nil {
                    SimAudioForget(udid)
                    route = SimAudioOutputRoute(udid)
                }
                guard var current = route else {
                    if isBooting { continue }  // its audio is not up yet
                    let since = unreadableSince[udid] ?? now
                    unreadableSince[udid] = since
                    if now.timeIntervalSince(since) > 10 {
                        problem = "The audio route of \(simName(udid)) cannot be read or set"
                        if !unreadableReported.contains(udid) {
                            unreadableReported.insert(udid)
                            logEvent("\(tag): \(simName(udid)): its audio route cannot be read or set (CoreSimulator gives no answer for it). Only the fallback tap covers it")
                            alert("route-\(udid)", "Cannot check or set the audio route of \(simName(udid)). Run: simaudio doctor", testing: testing)
                        }
                    }
                    continue
                }
                if unreadableReported.remove(udid) != nil { logEvent("\(simName(udid)): its audio route can be read again") }
                unreadableSince[udid] = nil
                let mute = rule.shouldMute(udid)
                let wanted = mute && present && !rule.testNoRoute.contains(udid)
                if wanted, current != blackHoleUID {
                    if SimAudioSetOutputRoute(udid, blackHoleUID) {
                        current = blackHoleUID
                        routedByUs.insert(udid)
                        routeFailures.remove(udid)
                        logEvent("\(simName(udid)): its sound now goes to BlackHole (silent)")
                    } else if !routeFailures.contains(udid) {
                        routeFailures.insert(udid)
                        logEvent("\(simName(udid)): could not route it to BlackHole; the fallback tap keeps it muted")
                    }
                } else if wanted, force.contains(udid) {
                    // On BlackHole by its route, yet caught playing to a real output: set the route afresh.
                    _ = SimAudioSetOutputRoute(udid, systemDefaultRoute)
                    let ok = SimAudioSetOutputRoute(udid, blackHoleUID)
                    if !ok { current = SimAudioOutputRoute(udid) ?? systemDefaultRoute }
                    logEvent("\(simName(udid)): set its BlackHole route again\(ok ? "" : ", and that failed")")
                } else if !wanted, current == blackHoleUID {
                    // Only this guard routes simulators to BlackHole, so any simulator on it is ours to put back.
                    if SimAudioSetOutputRoute(udid, systemDefaultRoute) {
                        current = systemDefaultRoute
                        routedByUs.remove(udid)
                        let why = !present ? "BlackHole is gone, so it plays through the Mac's output (the fallback tap mutes it)"
                            : mute ? "TEST: left on the Mac's output on purpose"
                            : "plays through the Mac's output again"
                        logEvent("\(simName(udid)): \(why)")
                    }
                }
                found[udid] = current
            }
            unreadableSince = unreadableSince.filter { live[$0.key] != nil }
            unreadableReported = unreadableReported.filter { live[$0] != nil }
        } else {
            let since = routerDownSince ?? now
            routerDownSince = since
            if now.timeIntervalSince(since) > 20 {
                problem = "CoreSimulator is not answering, so simulator audio routes cannot be checked or set"
                if !routerDownReported {
                    routerDownReported = true
                    logEvent("\(tag): CoreSimulator is not answering (an Xcode update may have changed it), so simulator audio routes cannot be checked or set. Routes already set stay; anything else is left to the fallback tap")
                    alert("router-down", "Cannot reach CoreSimulator, so simulator audio routes cannot be checked. Run: simaudio doctor", testing: testing)
                }
            }
        }
        if routedByUs != before { writeJSON(["routed": routedByUs.sorted()], to: routesPath) }
        lock.lock()
        let changed = routes != found || routerProblem != problem || booting != anyBooting
        routes = found
        routerProblem = problem
        booting = anyBooting
        lock.unlock()
        return changed
    }

    // MARK: The last resort

    /// A muted simulator kept playing to a real output: the route and the tap both failed.
    /// Quitting what plays cannot fail the way they can. A second time, the simulator goes off.
    private func lastResort(udid: String, procs: [Proc], shutdown: Bool, testing: Bool) {
        let name = simName(udid)
        let apps = Set(procs.map(\.app)).sorted().joined(separator: ", ")
        let tag = testing ? "ALARM TEST" : "ALERT"
        for p in procs { kill(p.pid, SIGKILL) }
        if shutdown {
            logEvent("\(tag): \(name): \(apps) played out loud again, so the simulator was shut down")
            DispatchQueue.global(qos: .userInitiated).async { shutDownSimulator(udid) }
            alert("shutdown-\(udid)", "\(name) kept playing out loud, so it was shut down. Run: simaudio doctor", testing: testing)
        } else {
            logEvent("\(tag): \(name): \(apps) played out loud for \(Int(Guard.leakLimit)) s (the BlackHole route and the fallback tap both failed), so it was quit")
            alert("quit-\(udid)", "\(apps) in \(name) played out loud for \(Int(Guard.leakLimit)) s and was quit. Run: simaudio doctor", testing: testing)
        }
    }

    // MARK: Tick

    func tick() {
        let uptime = ProcessInfo.processInfo.systemUptime
        beatLock.lock()
        beat = uptime
        beatLock.unlock()
        if routerBusy, uptime - routerStarted > 90 {
            logEvent("ALERT: CoreSimulator has not answered the guard for 90 s, restarting the guard")
            exit(1)
        }
        let now = Date()
        if now.timeIntervalSince(lastNameFlush) >= 60 {
            lastNameFlush = now
            simNameLock.lock(); simNameCache.removeAll(); simNameLock.unlock()
        }
        // Only the "claude" rule cares whether a simulator window is open.
        var window: Bool?
        if mode == "claude", now.timeIntervalSince(lastWindowScan) >= 2 {
            lastWindowScan = now
            window = simulatorWindowOpen()
        }
        if now.timeIntervalSince(lastDeviceCheck) >= 30 {
            lastDeviceCheck = now
            blackHolePresent = hostDeviceExists(uid: blackHoleUID)
        }
        lock.lock()
        reloadSettings()
        if let window, window != windowOpen {
            windowOpen = window
            logEvent(window ? "a simulator window opened: simulators Claude did not start play out loud"
                            : "no simulator window open: every simulator is muted")
        }
        let rule = self.rule
        let testing = self.testing
        let live = Set(caObjects(systemObject, kAudioHardwarePropertyProcessObjectList))

        for (object, p) in procs where !live.contains(object) {
            if p.playing {
                logEvent("\(simName(p.udid)): \(p.app) stopped after \(Int(now.timeIntervalSince(p.since))) s (it quit)")
            }
            procs[object] = nil
            unwatch(object)
        }
        notSimulator.formIntersection(live)

        for object in live where procs[object] == nil && !notSimulator.contains(object) {
            guard let pid = caValue(object, kAudioProcessPropertyPID, Int32(0)), pid > 0,
                  let udid = simulatorUDID(of: pid) else {
                notSimulator.insert(object)
                continue
            }
            procs[object] = Proc(object: object, pid: pid, udid: udid, app: appName(executablePath(pid) ?? "?"))
            watch(object)
            if routes[udid] != blackHoleUID { routerDue = true }  // a simulator the router has not placed yet
        }

        // Safety net: a muted simulator caught playing to anything but BlackHole gets the tap.
        var playingNow: [AudioObjectID: Bool] = [:]
        var leaking: [String: [Proc]] = [:]
        var mutedPlaying = false
        for (object, p) in procs {
            let playing = (caValue(object, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0
            playingNow[object] = playing
            guard playing, rule.shouldMute(p.udid) else { continue }
            mutedPlaying = true
            let devices = outputDeviceUIDs(ofProcess: object)
            if devices.contains(where: { $0 != blackHoleUID }) {
                if lastLeak[p.udid] == nil || now.timeIntervalSince(lastLeak[p.udid]!) > Guard.leakHold {
                    logEvent("\(simName(p.udid)): \(p.app) is playing to \(devices.joined(separator: ", ")); holding it with the fallback tap")
                    forceRoute.insert(p.udid)
                    routerDue = true
                }
                lastLeak[p.udid] = now
                leaking[p.udid, default: []].append(p)
            }
        }

        // A tap bus only where routing is not doing the job.
        let bySim = Dictionary(grouping: procs.values, by: \.udid).mapValues { $0.map(\.object).sorted() }
        func needsTap(_ udid: String) -> Bool {
            guard rule.shouldMute(udid), !rule.testNoTap, bySim[udid] != nil else { return false }
            if routes[udid] != blackHoleUID { return true }
            if let leak = lastLeak[udid], now.timeIntervalSince(leak) < Guard.leakHold { return true }
            return false
        }
        func forget(_ udid: String) {
            buses[udid] = nil
            busCallbacks[udid] = nil
            busSample[udid] = nil
            busProven.remove(udid)
        }
        var stopping: [SimBus] = []
        for (udid, bus) in buses where !needsTap(udid) {
            stopping.append(bus)
            forget(udid)
        }
        let checkHealth = now.timeIntervalSince(lastHealthCheck) >= 2
        if checkHealth { lastHealthCheck = now }
        for (udid, objects) in bySim where needsTap(udid) {
            if let bus = buses[udid] {
                var healthy = bus.update(objects: objects)
                let count = bus.callbacks
                if healthy, checkHealth {
                    if let before = busCallbacks[udid], count == before { healthy = false }
                    busCallbacks[udid] = count
                }
                if !healthy {
                    logEvent("\(simName(udid)): the fallback tap stalled, rebuilding it")
                    stopping.append(bus)
                    forget(udid)
                } else if let sample = busSample[udid] {
                    if now.timeIntervalSince(sample.at) >= 0.4 {
                        if count != sample.count { busProven.insert(udid) } else { busProven.remove(udid) }
                        busSample[udid] = (count, now)
                    }
                } else {
                    busSample[udid] = (count, now)
                }
            }
            if buses[udid] == nil, now >= busRetry[udid, default: .distantPast] {
                let bus = SimBus(udid: udid, objects: objects, muted: true)
                if let error = bus.error {
                    stopping.append(bus)
                    busRetry[udid] = now.addingTimeInterval(10)
                    if busErrors[udid] != error { logEvent("\(simName(udid)): NOT MUTED, \(error)") }
                    busErrors[udid] = error
                } else {
                    buses[udid] = bus
                    busErrors[udid] = nil
                }
            }
        }

        // The last resort: out loud for too long with no tap seen working over it.
        var quitting: [(udid: String, procs: [Proc], shutdown: Bool)] = []
        for (udid, list) in leaking {
            if buses[udid] != nil, busProven.contains(udid) {
                exposedSince[udid] = nil
                continue
            }
            let since = exposedSince[udid] ?? now
            exposedSince[udid] = since
            if now.timeIntervalSince(since) >= Guard.leakLimit {
                let again = lastQuit[udid].map { now.timeIntervalSince($0) < Guard.repeatWindow } ?? false
                quitting.append((udid, list, again))
                lastQuit[udid] = now
                exposedSince[udid] = nil
            }
        }
        exposedSince = exposedSince.filter { leaking[$0.key] != nil }

        for (object, var p) in procs {
            let playing = playingNow[object] ?? false
            if playing != p.playing {
                if playing {
                    let how: String
                    if !rule.shouldMute(p.udid) { how = "out loud" }
                    else if buses[p.udid] != nil { how = "muted by the fallback tap" }
                    else if routes[p.udid] == blackHoleUID { how = "silent, into BlackHole" }
                    else { how = "NOT muted" }
                    logEvent("\(simName(p.udid)): \(p.app) started playing (\(how))")
                } else {
                    logEvent("\(simName(p.udid)): \(p.app) stopped after \(Int(now.timeIntervalSince(p.since))) s")
                }
                p.playing = playing
                p.since = now
            }
            procs[object] = p
        }

        // Status: every simulator the router knows, plus any with audio open.
        var sims: [String: [String: Any]] = [:]
        let appsBySim = Dictionary(grouping: procs.values, by: \.udid)
        for udid in Set(routes.keys).union(appsBySim.keys) {
            var sim: [String: Any] = ["udid": udid, "name": simName(udid)]
            let mute = rule.shouldMute(udid)
            if !mute {
                sim["muted"] = false
            } else if buses[udid] != nil {
                sim["muted"] = true
                sim["how"] = "tap"
            } else if routes[udid] == blackHoleUID {
                sim["muted"] = true
                sim["how"] = "blackhole"
            } else {
                sim["muted"] = appsBySim[udid] == nil   // nothing to hear yet
                sim["how"] = "pending"
            }
            if let until = hear[udid], until > now.timeIntervalSince1970 { sim["hear_until"] = until }
            if let error = busErrors[udid] { sim["error"] = error }
            sim["apps"] = (appsBySim[udid] ?? []).sorted { $0.app < $1.app }.map { p -> [String: Any] in
                ["name": p.app, "pid": p.pid, "playing": p.playing]
            }
            sims[udid] = sim
        }
        let currentMode = mode
        let problem = routerProblem
        let force = forceRoute
        let watching = !buses.isEmpty || !exposedSince.isEmpty || booting
            || lastLeak.values.contains { now.timeIntervalSince($0) < Guard.leakHold }
        let routerEvery: TimeInterval = booting ? 0.5 : 2
        lock.unlock()

        for bus in stopping { bus.stop() }
        for q in quitting { lastResort(udid: q.udid, procs: q.procs, shutdown: q.shutdown, testing: testing) }
        writeStatus(sims.values.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") },
                    mode: currentMode, router: problem, testing: testing)
        if !routerBusy, routerDue || now.timeIntervalSince(lastRouterSync) >= routerEvery {
            routerDue = false
            lastRouterSync = now
            routerBusy = true
            routerStarted = uptime
            if !force.isEmpty {
                lock.lock()
                forceRoute.subtract(force)
                lock.unlock()
            }
            routerQueue.async { [self] in
                let changed = syncRoutes(rule, force: force, testing: testing)
                DispatchQueue.main.async {
                    self.routerBusy = false
                    if changed || self.routerDue { self.poke() }
                }
            }
        }
        handleRequests()
        setInterval(watching || !activeRequests.isEmpty ? Guard.busyInterval
                    : mutedPlaying ? Guard.playingInterval : Guard.quietInterval)
    }

    private func writeStatus(_ sims: [[String: Any]], mode: String, router: String?, testing: Bool) {
        var body: [String: Any] = ["mode": mode, "pid": getpid(), "sims": sims, "blackhole": blackHolePresent,
                                   "router": router ?? "ok"]
        if testing { body["testing"] = true }
        let text = (try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        if text == lastStatus && Date().timeIntervalSince(lastStatusWrite) < 5 { return }
        lastStatus = text
        lastStatusWrite = Date()
        var stamped = body
        stamped["updated"] = Date().timeIntervalSince1970
        writeJSON(stamped, to: statusPath)
    }

    // MARK: Recording requests

    private func handleRequests() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: requestsDir) else { return }
        for name in names where name.hasSuffix(".request.json") && !activeRequests.contains(name) {
            let path = requestsDir + "/" + name
            guard let request = readJSON(path) else { continue }
            try? FileManager.default.removeItem(atPath: path)
            activeRequests.insert(name)
            Thread.detachNewThread { [self] in
                let result = record(request)
                if let id = request["id"] as? String {
                    writeJSON(result, to: "\(requestsDir)/\(id).result.json")
                }
                DispatchQueue.main.async { self.activeRequests.remove(name) }
            }
        }
    }

    private func record(_ request: [String: Any]) -> [String: Any] {
        let udid = (request["udid"] as? String ?? "").uppercased()
        let seconds = min(max((request["seconds"] as? NSNumber)?.doubleValue ?? 10, 0.5), 600)
        let name = simName(udid)
        let safe = name.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let out = (request["out"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(recordingsDir)/\(fileClock.string(from: Date()))-\(safe).wav"
        var result: [String: Any] = ["udid": udid, "sim": name, "file": out, "seconds": seconds]
        pruneRecordings()

        // A simulator held by the fallback tap already has a live bus: listen in on it.
        // Otherwise open a tap just for this recording (muted when the simulator should be).
        var temporary: SimBus?
        var bus: SimBus
        if let live = self.bus(for: udid) {
            bus = live
        } else {
            let made = SimBus(udid: udid, objects: objects(for: udid).map(\.0), muted: shouldMuteNow(udid))
            if let error = made.error {
                made.stop()
                result["error"] = error
                return result
            }
            temporary = made
            bus = made
        }
        defer { temporary?.stop() }
        result["muted"] = shouldMuteNow(udid)

        guard let format = bus.format else {
            result["error"] = "the tap has no format"
            return result
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file: AVAudioFile
        do {
            try FileManager.default.createDirectory(atPath: (out as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            file = try AVAudioFile(forWriting: URL(fileURLWithPath: out), settings: settings,
                                   commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        } catch {
            result["error"] = "could not create \(out): \(error.localizedDescription)"
            return result
        }

        let meter = Meter(sampleRate: format.sampleRate)
        let began = CACurrentMediaTime()
        let sink: (AVAudioPCMBuffer) -> Void = { buffer in
            let length = Double(buffer.frameLength) / format.sampleRate
            meter.add(buffer, startsAt: CACurrentMediaTime() - began - length)
            try? file.write(from: buffer)
        }
        bus.setSink(sink)

        var heardApps = Set(objects(for: udid).map(\.1))
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            Thread.sleep(forTimeInterval: 0.2)
            let now = objects(for: udid)
            heardApps.formUnion(now.map(\.1))
            if let temporary {
                _ = temporary.update(objects: now.map(\.0))
            } else if let current = self.bus(for: udid), current !== bus {
                // The guard rebuilt the bus mid-recording: follow it.
                bus.setSink(nil)
                current.setSink(sink)
                bus = current
            }
        }
        bus.setSink(nil)
        bus.drain()

        result["captured_seconds"] = tenths(Double(meter.frames) / meter.sampleRate)
        result["audible_seconds"] = tenths(Double(meter.audibleWindows) / 10)
        result["peak_dbfs"] = tenths(dB(Double(meter.peak)))
        result["average_dbfs"] = tenths(dB(meter.rms))
        if let first = meter.firstSound { result["first_sound_at"] = tenths(first) }
        if let last = meter.lastSound { result["last_sound_at"] = tenths(last) }
        result["heard_sound"] = meter.audibleWindows > 0
        result["apps"] = heardApps.sorted()
        logEvent("\(name): recorded \(Int(seconds)) s, \(meter.audibleWindows > 0 ? "sound, peak \(formatDB(dB(Double(meter.peak))))" : "silence") -> \(out)")
        return result
    }

    private func pruneRecordings() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: recordingsDir) else { return }
        let cutoff = Date().addingTimeInterval(-3 * 24 * 3600)
        for name in names {
            let path = recordingsDir + "/" + name
            if let date = modificationDate(path), date < cutoff { try? fm.removeItem(atPath: path) }
        }
    }
}

// MARK: - CLI

struct Sim { let udid: String; let name: String; let booted: Bool }

func allSims() -> [Sim] {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    task.arguments = ["simctl", "list", "devices", "-j"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let devices = json["devices"] as? [String: [[String: Any]]] else { return [] }
    return devices.values.flatMap { $0 }.compactMap { d in
        guard let udid = d["udid"] as? String, let name = d["name"] as? String else { return nil }
        return Sim(udid: udid.uppercased(), name: name, booted: (d["state"] as? String) == "Booted")
    }
}

func resolveSim(_ query: String?) -> Sim? {
    let sims = allSims()
    let status = readJSON(statusPath)
    let statusSims = status?["sims"] as? [[String: Any]] ?? []
    guard let query, !query.isEmpty else {
        // No name given: the one muted simulator that has audio open, if there is exactly one.
        let candidates = statusSims.filter { $0["muted"] as? Bool == true }.compactMap { $0["udid"] as? String }
        if candidates.count == 1, let sim = sims.first(where: { $0.udid == candidates[0] }) { return sim }
        complain("Name the simulator (part of its name or its UDID). Booted now:")
        for sim in sims where sim.booted { complain("  \(sim.name)  \(sim.udid)") }
        return nil
    }
    if let exact = sims.first(where: { $0.udid == query.uppercased() }) { return exact }
    let q = query.lowercased()
    var matches = sims.filter { $0.name.lowercased() == q }
    if matches.isEmpty { matches = sims.filter { $0.name.lowercased().contains(q) } }
    if matches.count > 1 {
        let booted = matches.filter(\.booted)
        if booted.count == 1 { return booted[0] }
    }
    if matches.count == 1 { return matches[0] }
    complain(matches.isEmpty ? "No simulator matches \"\(query)\"." : "\"\(query)\" matches several simulators:")
    for sim in matches { complain("  \(sim.name)\(sim.booted ? " (booted)" : "")  \(sim.udid)") }
    return nil
}

func loadConfig() -> [String: Any] { readJSON(configPath) ?? ["mode": "all"] }

func saveConfig(_ config: [String: Any]) {
    try? FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
    writeJSON(config, to: configPath)
}

func guardAlive() -> (Bool, [String: Any]?) {
    guard let status = readJSON(statusPath), let updated = (status["updated"] as? NSNumber)?.doubleValue else { return (false, nil) }
    guard let pid = (status["pid"] as? NSNumber)?.int32Value, kill(pid, 0) == 0 else { return (false, status) }
    return (Date().timeIntervalSince1970 - updated < 15, status)
}

func showStatus() {
    let (alive, status) = guardAlive()
    let config = loadConfig()
    let mode = config["mode"] as? String ?? "all"
    let modeText = ["claude": "muting the simulators Claude runs (every simulator while no simulator window is open)",
                    "all": "muting every simulator", "off": "off, nothing is muted"][mode] ?? mode
    say(alive ? "Sim audio guard: on, \(modeText)" : "Sim audio guard: NOT RUNNING. Simulators already routed to BlackHole stay silent, new ones play out loud. Start it: simaudio restart")
    if alive, status?["blackhole"] as? Bool == false {
        say("  BlackHole 2ch is missing, so muting falls back to the tap (purple recording dot).")
    }
    if alive, let router = status?["router"] as? String, router != "ok" {
        say("  PROBLEM: \(router). Run: simaudio doctor")
    }
    if status?["testing"] as? Bool == true {
        say("  TEST settings are on (config.json \"test\"): a safety net is deliberately off for a few minutes.")
    }
    if let last = recentAlerts(hours: 24).last {
        say("  Last alarm: \(last)")
    }
    let sims = status?["sims"] as? [[String: Any]] ?? []
    if sims.isEmpty {
        say("  No simulator is booted.")
    }
    for sim in sims {
        let name = sim["name"] as? String ?? "?"
        var state = (sim["muted"] as? Bool == true) ? "muted" : "plays out loud"
        switch sim["how"] as? String {
        case "blackhole": state = "muted (into BlackHole)"
        case "tap": state = "muted (fallback tap, purple dot)"
        case "pending": state = "routing..."
        default: break
        }
        if let until = (sim["hear_until"] as? NSNumber)?.doubleValue {
            state = "plays out loud for \(max(1, Int((until - Date().timeIntervalSince1970) / 60))) more min"
        }
        if let error = sim["error"] as? String { state = "NOT MUTED (\(error))" }
        let apps = (sim["apps"] as? [[String: Any]] ?? []).map { app -> String in
            var text = app["name"] as? String ?? "?"
            if app["playing"] as? Bool == true { text += " (playing)" }
            return text
        }
        say("  \(name.padding(toLength: max(34, name.count + 2), withPad: " ", startingAt: 0))\(state)   \(apps.joined(separator: ", "))")
    }
    if let log = try? String(contentsOfFile: eventsPath, encoding: .utf8) {
        let lines = log.split(separator: "\n").suffix(6)
        if !lines.isEmpty {
            say("Recent:")
            for line in lines { say("  " + line) }
        }
    }
    say("Test a sound: simaudio record <sim> [seconds]   Check everything: simaudio doctor   Full log: simaudio log")
}

/// The guard's alarms (ALERT lines in the event log) from the last so many hours.
func recentAlerts(hours: Double) -> [String] {
    let cutoff = Date().addingTimeInterval(-hours * 3600)
    var found: [String] = []
    for path in [eventsPath + ".1", eventsPath] {
        guard let log = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        for line in log.split(separator: "\n") where line.contains("ALERT: ") {
            if let date = clock.date(from: String(line.prefix(19))), date >= cutoff { found.append(String(line)) }
        }
    }
    return found
}

/// Asks the guard for a recording of one simulator; the answer comes from `awaitRecording`.
func requestRecording(udid: String, seconds: Double, out: String?) -> String {
    let id = UUID().uuidString
    var request: [String: Any] = ["id": id, "udid": udid, "seconds": seconds]
    if let out { request["out"] = out }
    try? FileManager.default.createDirectory(atPath: requestsDir, withIntermediateDirectories: true)
    writeJSON(request, to: "\(requestsDir)/\(id).request.json")
    return id
}

func awaitRecording(_ id: String, timeout: Double) -> [String: Any]? {
    let resultPath = "\(requestsDir)/\(id).result.json"
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let result = readJSON(resultPath) {
            try? FileManager.default.removeItem(atPath: resultPath)
            return result
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return nil
}

func record(_ args: [String]) -> Int32 {
    var rest = args
    var out: String?
    var json = false
    if let i = rest.firstIndex(of: "--out"), i + 1 < rest.count { out = rest[i + 1]; rest.removeSubrange(i...(i + 1)) }
    if let i = rest.firstIndex(of: "--json") { json = true; rest.remove(at: i) }
    var seconds = 10.0
    if let last = rest.last, let value = Double(last) { seconds = value; rest.removeLast() }
    guard let sim = resolveSim(rest.isEmpty ? nil : rest.joined(separator: " ")) else { return 2 }
    guard sim.booted else {
        complain("\(sim.name) is not booted (the idle-reaper may have turned it off). Boot it, open the app, then record.")
        return 2
    }
    let (alive, _) = guardAlive()
    guard alive else {
        complain("The sim audio guard is not running. Start it: simaudio restart")
        return 1
    }
    if let o = out { out = (o as NSString).expandingTildeInPath; if !(out!.hasPrefix("/")) { out = FileManager.default.currentDirectoryPath + "/" + out! } }
    let id = requestRecording(udid: sim.udid, seconds: seconds, out: out)
    if !json { complain("Recording \(sim.name) for \(seconds.formatted()) s...") }

    do {
        if let result = awaitRecording(id, timeout: seconds + 20) {
            if json {
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                    say(String(decoding: data, as: UTF8.self))
                }
                return result["error"] == nil ? 0 : 1
            }
            if let error = result["error"] as? String { complain("Failed: \(error)"); return 1 }
            let apps = (result["apps"] as? [String] ?? []).joined(separator: ", ")
            if result["heard_sound"] as? Bool == true {
                let peak = (result["peak_dbfs"] as? NSNumber)?.doubleValue ?? -.infinity
                let avg = (result["average_dbfs"] as? NSNumber)?.doubleValue ?? -.infinity
                say("Sound: \(result["audible_seconds"] ?? 0) s audible, peak \(formatDB(peak)), average \(formatDB(avg))")
                say("  heard from \(result["first_sound_at"] ?? 0) s to \(result["last_sound_at"] ?? 0) s after the recording started (\(result["seconds"] ?? 0) s long)")
            } else {
                say("Silence: nothing above -60 dBFS in \(result["captured_seconds"] ?? 0) s.")
                say("  If sound was expected: is the app playing? Is Claude Sim Audio allowed in System Settings > Privacy & Security > Screen & System Audio Recording?")
            }
            say("Apps with audio open: \(apps.isEmpty ? "none" : apps)")
            if let notes = result["notes"] as? [String] { for n in notes { say("Note: \(n)") } }
            say("Saved: \(result["file"] ?? "")")
            return 0
        }
    }
    complain("Timed out waiting for the guard to finish the recording.")
    return 1
}

// MARK: - Doctor

/// Memory the guard holds, and the share of one CPU core it has used since it started.
func resourceUse(_ pid: pid_t) -> (megabytes: Double, cpuPercent: Double)? {
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard status == 0 else { return nil }
    // CPU time and the start time are both in mach ticks, which stop while the Mac sleeps.
    let awake = Double(mach_absolute_time()) - Double(info.ri_proc_start_abstime)
    let cpu = Double(info.ri_user_time + info.ri_system_time)
    return (Double(info.ri_phys_footprint) / 1_048_576, awake > 0 ? 100 * cpu / awake : 0)
}

func deviceName(uid: String) -> String {
    for device in caObjects(systemObject, kAudioHardwarePropertyDevices) where caString(device, kAudioDevicePropertyDeviceUID) == uid {
        return caString(device, kAudioObjectPropertyName) ?? uid
    }
    return uid
}

func defaultDeviceUID(_ selector: AudioObjectPropertySelector) -> String? {
    guard let device = caValue(systemObject, selector, AudioObjectID(0)), device != 0 else { return nil }
    return caString(device, kAudioDevicePropertyDeviceUID)
}

/// Apps recording from BlackHole right now: BlackHole hands back whatever is played into
/// it, so they hear every muted simulator.
func blackHoleListeners() -> [String] {
    var names: Set<String> = []
    for object in caObjects(systemObject, kAudioHardwarePropertyProcessObjectList) {
        guard (caValue(object, kAudioProcessPropertyIsRunningInput, UInt32(0)) ?? 0) != 0 else { continue }
        let inputs = caObjects(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
            .compactMap { caString($0, kAudioDevicePropertyDeviceUID) }
        guard inputs.contains(blackHoleUID), let pid = caValue(object, kAudioProcessPropertyPID, Int32(0)) else { continue }
        names.insert(appName(executablePath(pid) ?? "pid \(pid)"))
    }
    return names.sorted()
}

/// Plays the test sound inside a simulator: `level` is "silent" (digital zeros) or a dBFS value.
func playTone(in udid: String, seconds: Double, level: String) -> Process? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    task.arguments = ["simctl", "spawn", udid, tonePath, String(seconds), level]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    return (try? task.run()) != nil ? task : nil
}

/// Where the test sound is really playing right now, by simulator, straight from Core Audio.
func toneDevices() -> [String: Set<String>] {
    var found: [String: Set<String>] = [:]
    for object in caObjects(systemObject, kAudioHardwarePropertyProcessObjectList) {
        guard let pid = caValue(object, kAudioProcessPropertyPID, Int32(0)), pid > 0,
              executablePath(pid)?.hasSuffix("/simtone") == true,
              (caValue(object, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0,
              let udid = simulatorUDID(of: pid) else { continue }
        let devices = outputDeviceUIDs(ofProcess: object)
        found[udid, default: []].formUnion(devices.isEmpty ? ["no device"] : devices)
    }
    return found
}

/// Checks the whole chain and says, line by line, what holds and what does not.
func doctor(_ args: [String]) -> Int32 {
    let quick = args.contains("--quick")
    var passed = 0, warnings = 0, failures = 0
    func ok(_ text: String) { passed += 1; say("  ok    " + text) }
    func warn(_ text: String) { warnings += 1; say("  WARN  " + text) }
    func fail(_ text: String) { failures += 1; say("  FAIL  " + text) }
    func skip(_ text: String) { say("  --    " + text) }
    say("Simulator audio check")

    // The guard itself.
    let (alive, status) = guardAlive()
    let pid = (status?["pid"] as? NSNumber)?.int32Value ?? 0
    if alive {
        var detail = "pid \(pid)"
        if let use = resourceUse(pid) {
            detail += String(format: ", %.0f MB of memory, %.2f%% of one CPU core since it started", use.megabytes, use.cpuPercent)
        }
        ok("The guard is running (\(detail))")
    } else {
        fail("The guard is NOT running: simulators not yet routed to BlackHole play out loud. Start it: simaudio restart")
    }
    if run("/bin/launchctl", ["print", "gui/\(getuid())/local.sim-audio"]) == 0 {
        ok("launchd starts it at login and restarts it if it ever exits")
    } else {
        warn("The LaunchAgent local.sim-audio is not loaded, so the guard will not start at login or restart by itself")
    }

    // What is supposed to be muted.
    let config = loadConfig()
    let now = Date().timeIntervalSince1970
    switch config["mode"] as? String ?? "all" {
    case "off": fail("Muting is switched off (mode: off). Turn it on: simaudio mode all")
    case "claude": warn("Only Claude's simulators are muted (mode: claude): one you booted plays out loud while a simulator window is open. Mute them all: simaudio mode all")
    default: ok("Every simulator is muted (mode: all)")
    }
    let hearing = (config["hear"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }.filter { $0.value > now }
    for (udid, until) in hearing.sorted(by: { $0.key < $1.key }) {
        warn("\(simName(udid)) may play out loud for \(max(1, Int((until - now) / 60))) more min (simaudio hear). End it: simaudio mute \(simName(udid))")
    }
    if let test = config["test"] as? [String: Any], ((test["until"] as? NSNumber)?.doubleValue ?? 0) > now {
        fail("Test settings are on (\"test\" in \(configPath)): a safety net is deliberately off until they expire")
    }

    // BlackHole.
    if hostDeviceExists(uid: blackHoleUID) {
        ok("BlackHole 2ch is installed")
    } else {
        fail("BlackHole 2ch is not installed, so muting depends on the fallback tap. Install it: brew install blackhole-2ch")
    }
    let output = defaultDeviceUID(kAudioHardwarePropertyDefaultOutputDevice)
    if output == blackHoleUID {
        fail("The Mac's output is set to BlackHole 2ch, so the whole Mac is silent. Pick your speakers in the Sound menu")
    } else if let output {
        ok("The Mac plays through \(deviceName(uid: output)), not through BlackHole")
    }
    if defaultDeviceUID(kAudioHardwarePropertyDefaultInputDevice) == blackHoleUID {
        warn("The Mac's input is set to BlackHole 2ch: anything that records the Mac's input records the simulators")
    }
    let listeners = blackHoleListeners()
    if listeners.isEmpty {
        ok("Nothing is recording from BlackHole, so nothing can pass the simulators' sound on")
    } else {
        warn("\(listeners.joined(separator: ", ")) is recording from BlackHole right now, so it hears the muted simulators")
    }

    // The router.
    if alive {
        let router = status?["router"] as? String ?? "ok"
        if router == "ok" { ok("CoreSimulator answers: the guard can read and set audio routes") } else { fail(router) }
    }
    let alerts = recentAlerts(hours: 24)
    if alerts.isEmpty {
        ok("No alarms in the last 24 hours")
    } else {
        warn("\(alerts.count) alarm\(alerts.count == 1 ? "" : "s") in the last 24 hours, the latest: \(alerts.last!)")
    }

    // Each simulator that is on.
    let statusSims = status?["sims"] as? [[String: Any]] ?? []
    let booted = allSims().filter(\.booted).sorted { $0.name < $1.name }
    var routed: [Sim] = []
    for sim in booted {
        let entry = statusSims.first { ($0["udid"] as? String) == sim.udid }
        if hearing[sim.udid] != nil { continue }  // already reported above
        switch entry?["how"] as? String {
        case "blackhole": routed.append(sim)
        case "tap": warn("\(sim.name) is muted by the fallback tap (purple dot), not by a BlackHole route")
        default:
            if entry?["muted"] as? Bool == false {
                fail("\(sim.name) is NOT muted")
            } else {
                fail("\(sim.name) is not routed to BlackHole (the guard has not placed it)")
            }
        }
    }
    if booted.isEmpty {
        skip("No simulator is on, so there is nothing to test live. Run this again while one is booted for the full check")
    }

    // Live: play digital silence inside each simulator and read where Core Audio sends it.
    // Silence, so that a broken mute cannot be heard either.
    var proven: [Sim] = []
    if quick || !alive {
        for sim in routed { ok("\(sim.name) is routed to BlackHole") }
        if !routed.isEmpty { skip("Live test skipped\(quick ? " (--quick)" : "")") }
    } else if !routed.isEmpty {
        guard FileManager.default.isExecutableFile(atPath: tonePath) else {
            for sim in routed { ok("\(sim.name) is routed to BlackHole") }
            warn("The test sound is missing (\(tonePath)), so the live test was skipped. Rebuild: ./install.sh in the Claude-Code-Sim-Audio folder")
            say(failures == 0 ? "Done: \(passed) checks passed, \(warnings) warning\(warnings == 1 ? "" : "s")." : "\(failures) problem\(failures == 1 ? "" : "s") found.")
            return failures == 0 ? 0 : 1
        }
        var tasks: [String: Process] = [:]
        for sim in routed { tasks[sim.udid] = playTone(in: sim.udid, seconds: 2, level: "silent") }
        var seen: [String: Set<String>] = [:]
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline, tasks.values.contains(where: \.isRunning) {
            for (udid, devices) in toneDevices() { seen[udid, default: []].formUnion(devices) }
            Thread.sleep(forTimeInterval: 0.1)
        }
        for task in tasks.values where task.isRunning { task.terminate() }
        for sim in routed {
            if let devices = seen[sim.udid] {
                if devices == [blackHoleUID] {
                    ok("\(sim.name): a silent test sound played inside it went to BlackHole and nowhere else")
                    proven.append(sim)
                } else {
                    fail("\(sim.name): a silent test sound played inside it went to \(devices.sorted().map { deviceName(uid: $0) }.joined(separator: ", ")), not only to BlackHole")
                }
            } else {
                ok("\(sim.name) is routed to BlackHole")
                skip("\(sim.name): could not play a test sound inside it (not an iPhone or iPad simulator, or still starting)")
            }
        }
    }

    // Live: a quiet tone into a simulator already proven silent, to check that the guard
    // can still record (the same permission the fallback tap needs).
    let fresh = (readJSON(statusPath)?["sims"] as? [[String: Any]]) ?? statusSims
    func noise(_ sim: Sim) -> Int {
        // Apps of its own with audio open, playing this instant or not: an app that plays in
        // bursts would drown the tone a moment later.
        let apps = (fresh.first { ($0["udid"] as? String) == sim.udid })?["apps"] as? [[String: Any]] ?? []
        let own = apps.filter { ($0["name"] as? String) != "SpringBoard" && ($0["name"] as? String) != "the doctor's test sound" }
        return own.count * 100 + own.filter { $0["playing"] as? Bool == true }.count
    }
    if let sim = proven.min(by: { noise($0) < noise($1) }) {
        let id = requestRecording(udid: sim.udid, seconds: 3.5, out: recordingsDir + "/doctor.wav")
        Thread.sleep(forTimeInterval: 0.8)
        let tone = playTone(in: sim.udid, seconds: 1.5, level: "-30")
        let result = awaitRecording(id, timeout: 20)
        tone?.waitUntilExit()
        let peak = (result?["peak_dbfs"] as? NSNumber)?.doubleValue ?? -.infinity
        if result?["heard_sound"] as? Bool == true {
            if peak > -34, peak < -26 {
                ok("Recording works: the guard caught a quiet test tone in \(sim.name) at \(formatDB(peak)) (played at -30, heard only by the recorder)")
            } else {
                ok("Recording works: the guard captured sound in \(sim.name) (peak \(formatDB(peak)); its own apps were playing over the test tone)")
            }
        } else if let error = result?["error"] as? String {
            fail("Recording failed: \(error)")
        } else {
            fail("The guard recorded silence from a test tone in \(sim.name). Is Claude Sim Audio allowed in System Settings > Privacy & Security > Screen & System Audio Recording? BlackHole muting does not need it; simaudio record and the fallback tap do")
        }
    }

    if failures > 0 {
        say("\(failures) problem\(failures == 1 ? "" : "s") found\(warnings > 0 ? ", \(warnings) warning\(warnings == 1 ? "" : "s")" : "").")
        return 1
    }
    say("All good: \(passed) checks passed\(warnings > 0 ? ", \(warnings) warning\(warnings == 1 ? "" : "s")" : "").")
    return 0
}

func shutDownSimulator(_ udid: String) {
    run("/usr/bin/xcrun", ["simctl", "shutdown", udid])
}

@discardableResult
func run(_ tool: String, _ arguments: [String]) -> Int32 {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: tool)
    task.arguments = arguments
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return -1 }
    task.waitUntilExit()
    return task.terminationStatus
}

/// Restarts the guard: through launchd when the LaunchAgent is installed, otherwise by
/// quitting the running guard and opening the app again.
func restartGuard() -> Int32 {
    let agent = "gui/\(getuid())/local.sim-audio"
    let oldPID = (readJSON(statusPath)?["pid"] as? NSNumber)?.int32Value ?? 0
    if run("/bin/launchctl", ["print", agent]) == 0 {
        // A hand-started guard would hold the lock and keep the agent's guard waiting.
        run("/usr/bin/pkill", ["-f", "Claude Sim Audio.app/Contents/MacOS/claude-sim-audio daemon"])
        run("/bin/launchctl", ["kickstart", "-k", agent])
    } else {
        run("/usr/bin/pkill", ["-f", "Claude Sim Audio.app/Contents/MacOS/claude-sim-audio daemon"])
        Thread.sleep(forTimeInterval: 0.5)
        run("/usr/bin/open", ["-g", "-a", baseDir + "/Claude Sim Audio.app", "--args", "daemon"])
    }
    for _ in 0..<40 {
        Thread.sleep(forTimeInterval: 0.25)
        if guardAlive().0, let pid = (readJSON(statusPath)?["pid"] as? NSNumber)?.int32Value, pid != oldPID {
            say("Sim audio guard running (pid \(pid)).")
            return 0
        }
    }
    complain("The guard did not come back. Log: \(eventsPath)")
    return 1
}

func usage() {
    say("""
    simaudio: keeps every simulator off your speakers, and lets Claude test their sound.

      simaudio                        what is muted, what is playing, recent events
      simaudio doctor [--quick]       check the whole chain: the guard, BlackHole, every
                                      simulator's route, and (unless --quick) a silent test
                                      sound played inside each simulator to see where it goes
      simaudio record <sim> [secs]    capture a simulator's audio (default 10 s) to a WAV and
                                      report its levels; nothing reaches the speakers
            --out <file.wav>          where to save it (default ~/.claude/sim-audio/recordings)
            --json                    machine-readable result
      simaudio log [lines]            the event log (what started and stopped playing)
      simaudio hear <sim> [minutes]   let one simulator play out loud for a while (default 10)
      simaudio mute <sim>             end "hear" early
      simaudio mode all|claude|off    mute every simulator (the default), only Claude's (the
                                      ones Claude started, plus every simulator while no
                                      simulator window is open), or none
      simaudio restart                restart the guard (after a rebuild with build.sh)

    <sim> is part of a simulator's name ("iPhone 17 Pro", "iPad") or its UDID.
    """)
}

func cli(_ args: [String]) -> Int32 {
    let command = args.first ?? "status"
    let rest = Array(args.dropFirst())
    switch command {
    case "status":
        showStatus()
    case "record", "rec":
        return record(rest)
    case "doctor", "check":
        return doctor(rest)
    case "log":
        let count = rest.first.flatMap(Int.init) ?? 40
        let log = (try? String(contentsOfFile: eventsPath, encoding: .utf8)) ?? ""
        for line in log.split(separator: "\n").suffix(count) { say(String(line)) }
    case "hear", "unmute":
        var r = rest
        var minutes = 10.0
        if let last = r.last, let value = Double(last) { minutes = value; r.removeLast() }
        guard let sim = resolveSim(r.isEmpty ? nil : r.joined(separator: " ")) else { return 2 }
        var config = loadConfig()
        var hear = config["hear"] as? [String: Any] ?? [:]
        hear[sim.udid] = Date().timeIntervalSince1970 + minutes * 60
        config["hear"] = hear
        saveConfig(config)
        say("\(sim.name) plays out loud for the next \(minutes.formatted()) min. `simaudio mute \(sim.name)` ends it early.")
    case "mute":
        guard let sim = resolveSim(rest.isEmpty ? nil : rest.joined(separator: " ")) else { return 2 }
        var config = loadConfig()
        var hear = config["hear"] as? [String: Any] ?? [:]
        hear[sim.udid] = nil
        config["hear"] = hear
        saveConfig(config)
        say("\(sim.name) is back to the normal rule (mode: \(config["mode"] as? String ?? "all")).")
    case "mode":
        guard let mode = rest.first, ["claude", "all", "off"].contains(mode) else {
            complain("simaudio mode claude|all|off")
            return 2
        }
        var config = loadConfig()
        config["mode"] = mode
        saveConfig(config)
        say(["claude": "Muting the simulators Claude runs.", "all": "Muting every simulator.", "off": "Not muting any simulator."][mode]!)
    case "restart", "start":
        return restartGuard()
    case "daemon":
        Guard().run()
    case "help", "-h", "--help":
        usage()
    default:
        usage()
        return 2
    }
    return 0
}

setlinebuf(stdout)
exit(cli(Array(CommandLine.arguments.dropFirst())))
