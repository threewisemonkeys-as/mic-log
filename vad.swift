// vad: always-on voice-activated recorder.
// Listens on the default input, starts a clip when the level rises above the
// (adaptive) noise floor, and finishes it after a stretch of silence.
//
// Usage: vad <recordings-dir>
//   finished clips -> <dir>/pending/<id>.caf + <id>.meta.json
//   live status    -> <dir>/state.json (several times a second)
//   pause          -> create <dir>/PAUSED to stop recording, delete it to resume
//   sensitivity    -> <dir>/config.json {"margin_db": 12}, re-read while running
//
// Levels are measured in the speech band (250 Hz - 4 kHz) so rumble, thumps and
// HVAC noise don't trigger clips; the recorded audio itself is unfiltered.
import AVFoundation
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "recordings")
let incoming = dir.appendingPathComponent(".incoming")
let pending = dir.appendingPathComponent("pending")
let stateURL = dir.appendingPathComponent("state.json")
let configURL = dir.appendingPathComponent("config.json")
let pauseURL = dir.appendingPathComponent("PAUSED")
for d in [dir, incoming, pending] {
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
}

// Tunables
let preRollSec = 0.5        // audio kept from before the trigger
let hangSec = 1.5           // silence that ends a clip
let maxSec = 120.0          // hard cap on clip length
let minVoicedSec = 0.25     // clips with less loud audio than this are discarded
var marginDb: Float = 12    // trigger this far above the noise floor (overridden by config.json)
let absMinDb: Float = -70   // never trigger below this level
let onsetSec = 0.15         // level must stay above threshold this long to start a clip
let floorWindowSec = 20.0   // noise floor = 10th percentile of levels over this window

let q = DispatchQueue(label: "vad")
let engine = AVAudioEngine()
var sampleRate = 44100.0

var floorDb: Float = -60
var floorHistory: [Float] = []
var onsetFrames = 0
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

// RBJ biquad, used to band-limit the level measurement.
struct Biquad {
    var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
    init(highpass: Bool, freq: Double, sampleRate: Double, q: Double = 0.7071) {
        let w = 2 * Double.pi * freq / sampleRate, c = cos(w), al = sin(w) / (2 * q), a0 = 1 + al
        let b = highpass ? [(1 + c) / 2, -(1 + c), (1 + c) / 2] : [(1 - c) / 2, 1 - c, (1 - c) / 2]
        b0 = Float(b[0] / a0); b1 = Float(b[1] / a0); b2 = Float(b[2] / a0)
        a1 = Float(-2 * c / a0); a2 = Float((1 - al) / a0)
    }
    mutating func run(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}
var bandFilters: [Biquad] = []
func makeBandFilters(_ sr: Double) {
    bandFilters = [Biquad(highpass: true, freq: 250, sampleRate: sr),
                   Biquad(highpass: true, freq: 250, sampleRate: sr),
                   Biquad(highpass: false, freq: 4000, sampleRate: sr)]
}

// db: speech-band RMS level; peak: raw sample peak.
func stats(_ b: AVAudioPCMBuffer) -> (db: Float, peak: Float) {
    let p = b.floatChannelData![0]
    let n = Int(b.frameLength)
    var sum: Float = 0, peak: Float = 0
    for i in 0..<n {
        var v = p[i]
        peak = max(peak, abs(v))
        for k in bandFilters.indices { v = bandFilters[k].run(v) }
        sum += v * v
    }
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
        "margin_db": Double(marginDb),
        "recording": recording, "paused": paused, "clip": recording ? clipId : "",
        "ts": Date().timeIntervalSince1970,
    ]
    try? JSONSerialization.data(withJSONObject: s).write(to: stateURL, options: .atomic)
}

func process(_ b: AVAudioPCMBuffer) {
    let (db, peak) = stats(b)
    levelDb = db
    let n = Int(b.frameLength)

    // Noise floor: a low percentile of recent levels. Always updated (even while recording),
    // so a steady noise that crosses the threshold soon becomes the new floor and the clip ends.
    floorHistory.append(db)
    let keep = Int(floorWindowSec * sampleRate) / max(n, 1)
    if floorHistory.count > keep { floorHistory.removeFirst(floorHistory.count - keep) }

    if Date().timeIntervalSince(lastStateWrite) > 0.15 {
        let sorted = floorHistory.sorted()
        floorDb = max(sorted[sorted.count / 10], -90)
        paused = FileManager.default.fileExists(atPath: pauseURL.path)
        if paused { finishClip() }
        loadConfig()
        writeState()
        lastStateWrite = Date()
    }
    if paused { preRoll.removeAll(); onsetFrames = 0; return }

    if recording {
        write(b)
        clipPeak = max(clipPeak, peak)
        if db > threshold() - 4 { silentFrames = 0; voicedFrames += n } else { silentFrames += n }
        if Double(silentFrames) / sampleRate >= hangSec || Double(clipFrames) / sampleRate >= maxSec {
            finishClip()
        }
        return
    }

    // Idle: keep a pre-roll, and start a clip once the level has stayed above the
    // threshold for onsetSec (filters out clicks and knocks).
    preRoll.append(b)
    if db > threshold() {
        onsetFrames += n
        clipPeak = max(clipPeak, peak)
        if Double(onsetFrames) / sampleRate >= onsetSec {
            let peakSoFar = clipPeak
            startClip(format: b.format)  // writes the pre-roll, which includes this buffer
            clipPeak = peakSoFar
            voicedFrames = onsetFrames
            onsetFrames = 0
            return
        }
    } else {
        onsetFrames = 0
        clipPeak = 0
    }
    var frames = preRoll.reduce(0) { $0 + Int($1.frameLength) }
    while frames > Int(preRollSec * sampleRate), preRoll.count > 1 {
        frames -= Int(preRoll.removeFirst().frameLength)
    }
}

var configMtime = Date.distantPast
func loadConfig() {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: configURL.path),
          let m = attrs[.modificationDate] as? Date, m != configMtime else { return }
    configMtime = m
    if let d = try? Data(contentsOf: configURL),
       let c = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
       let v = c["margin_db"] as? Double, v >= 3, v <= 50 {
        marginDb = Float(v)
        print("sensitivity: trigger \(v) dB above noise floor")
    }
}

func startEngine() {
    let input = engine.inputNode
    let fmt = input.outputFormat(forBus: 0)
    sampleRate = fmt.sampleRate
    makeBandFilters(sampleRate)
    floorHistory.removeAll()
    onsetFrames = 0
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
