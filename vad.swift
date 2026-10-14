// vad: always-on voice-activated recorder.
// Listens on the default input, starts a clip when the level rises above the
// (adaptive) noise floor, and finishes it after a stretch of silence.
//
// Usage: vad <recordings-dir>
//   finished clips -> <dir>/pending/<id>.caf + <id>.meta.json
//   live status    -> <dir>/state.json (several times a second)
//   pause          -> create <dir>/PAUSED to stop recording, delete it to resume
import AVFoundation
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "recordings")
let incoming = dir.appendingPathComponent(".incoming")
let pending = dir.appendingPathComponent("pending")
let stateURL = dir.appendingPathComponent("state.json")
let pauseURL = dir.appendingPathComponent("PAUSED")
for d in [dir, incoming, pending] {
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
}

// Tunables
let preRollSec = 0.5        // audio kept from before the trigger
let hangSec = 1.5           // silence that ends a clip
let maxSec = 120.0          // hard cap on clip length
let minVoicedSec = 0.25     // clips with less loud audio than this are discarded
let marginDb: Float = 12    // trigger this far above the noise floor
let absMinDb: Float = -60   // never trigger below this level

let q = DispatchQueue(label: "vad")
let engine = AVAudioEngine()
var sampleRate = 44100.0

var floorDb: Float = -50
var levelDb: Float = -120
var recording = false
var paused = FileManager.default.fileExists(atPath: pauseURL.path)
var file: AVAudioFile?
var clipId = ""
var clipStart = Date()
var clipFrames = 0
var silentFrames = 0
var voicedFrames = 0
var clipPeak: Float = 0
var preRoll: [AVAudioPCMBuffer] = []
var lastStateWrite = Date.distantPast

func threshold() -> Float { max(floorDb + marginDb, absMinDb) }

func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
    let c = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength)!
    c.frameLength = b.frameLength
    for ch in 0..<Int(b.format.channelCount) {
        memcpy(c.floatChannelData![ch], b.floatChannelData![ch], Int(b.frameLength) * 4)
    }
    return c
}

func stats(_ b: AVAudioPCMBuffer) -> (db: Float, peak: Float) {
    let p = b.floatChannelData![0]
    let n = Int(b.frameLength)
    var sum: Float = 0, peak: Float = 0
    for i in 0..<n { let v = p[i]; sum += v * v; peak = max(peak, abs(v)) }
    let rms = n > 0 ? sqrt(sum / Float(n)) : 0
    return (20 * log10(max(rms, 1e-6)), peak)
}

func startClip(format: AVAudioFormat) {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss-SSS"
    clipId = f.string(from: Date())
    let preFrames = preRoll.reduce(0) { $0 + Int($1.frameLength) }
    clipStart = Date().addingTimeInterval(-Double(preFrames) / sampleRate)
    do {
        file = try AVAudioFile(forWriting: incoming.appendingPathComponent("\(clipId).caf"),
                               settings: format.settings)
    } catch {
        print("could not open clip file: \(error)")
        return
    }
    recording = true
    clipFrames = 0; silentFrames = 0; voicedFrames = 0; clipPeak = 0
    for b in preRoll { write(b) }
    preRoll.removeAll()
    print("● recording \(clipId)")
}

func write(_ b: AVAudioPCMBuffer) {
    try? file?.write(from: b)
    clipFrames += Int(b.frameLength)
}

func finishClip() {
    guard recording else { return }
    recording = false
    file = nil  // closes the file
    let src = incoming.appendingPathComponent("\(clipId).caf")
    let dur = Double(clipFrames) / sampleRate
    if Double(voicedFrames) / sampleRate < minVoicedSec {
        try? FileManager.default.removeItem(at: src)
        print("  discarded \(clipId) (too short)")
        return
    }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let meta: [String: Any] = [
        "id": clipId,
        "start": iso.string(from: clipStart),
        "duration": (dur * 100).rounded() / 100,
        "peak_db": Double((20 * log10(max(clipPeak, 1e-6)) * 10).rounded() / 10),
    ]
    let metaURL = pending.appendingPathComponent("\(clipId).meta.json")
    try? JSONSerialization.data(withJSONObject: meta).write(to: metaURL)
    try? FileManager.default.moveItem(at: src, to: pending.appendingPathComponent("\(clipId).caf"))
    print("  saved \(clipId) \(String(format: "%.1f", dur))s")
}

func writeState() {
    let s: [String: Any] = [
        "level_db": Double(levelDb), "floor_db": Double(floorDb), "threshold_db": Double(threshold()),
        "recording": recording, "paused": paused, "clip": recording ? clipId : "",
        "ts": Date().timeIntervalSince1970,
    ]
    try? JSONSerialization.data(withJSONObject: s).write(to: stateURL, options: .atomic)
}

func process(_ b: AVAudioPCMBuffer) {
    let (db, peak) = stats(b)
    levelDb = db
    let n = Int(b.frameLength)

    if Date().timeIntervalSince(lastStateWrite) > 0.15 {
        paused = FileManager.default.fileExists(atPath: pauseURL.path)
        if paused { finishClip() }
        writeState()
        lastStateWrite = Date()
    }
    if paused { preRoll.removeAll(); return }

    if recording {
        write(b)
        clipPeak = max(clipPeak, peak)
        if db > threshold() - 4 { silentFrames = 0; voicedFrames += n } else { silentFrames += n }
        if Double(silentFrames) / sampleRate >= hangSec || Double(clipFrames) / sampleRate >= maxSec {
            finishClip()
        }
        return
    }

    if db > threshold() {
        startClip(format: b.format)
        write(b)
        clipPeak = peak
        voicedFrames = n
        return
    }

    // Idle: track the noise floor (falls quickly, rises slowly) and keep a pre-roll.
    floorDb = db < floorDb ? floorDb * 0.8 + db * 0.2 : floorDb * 0.995 + db * 0.005
    floorDb = max(floorDb, -90)
    preRoll.append(b)
    var frames = preRoll.reduce(0) { $0 + Int($1.frameLength) }
    while frames > Int(preRollSec * sampleRate), preRoll.count > 1 {
        frames -= Int(preRoll.removeFirst().frameLength)
    }
}

func startEngine() {
    let input = engine.inputNode
    let fmt = input.outputFormat(forBus: 0)
    sampleRate = fmt.sampleRate
    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { buf, _ in
        let c = copy(buf)
        q.async { process(c) }
    }
    do {
        try engine.start()
        print("listening: \(Int(fmt.sampleRate)) Hz, \(fmt.channelCount) ch -> \(dir.path)")
    } catch {
        print("engine start failed: \(error)")
        exit(1)
    }
}

// Restart if the audio device changes (e.g. mic unplugged and replugged).
NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
    q.async {
        print("audio configuration changed, restarting")
        finishClip()
        preRoll.removeAll()
        engine.stop()
        startEngine()
    }
}

// Save the clip in progress on Ctrl-C / kill.
var sources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: q)
    s.setEventHandler {
        finishClip()
        try? FileManager.default.removeItem(at: stateURL)
        exit(0)
    }
    s.resume()
    sources.append(s)
}

// 0 notDetermined, 1 restricted, 2 denied, 3 authorized
let auth = AVCaptureDevice.authorizationStatus(for: .audio)
print("microphone permission: \(auth.rawValue)")
if auth == .notDetermined {
    AVCaptureDevice.requestAccess(for: .audio) { ok in print("microphone access granted: \(ok)") }
}

startEngine()

// If no audio arrives, say so in the log (usually a permission problem).
q.asyncAfter(deadline: .now() + 5) {
    if lastStateWrite == .distantPast { print("warning: no audio received after 5s") }
}
dispatchMain()
