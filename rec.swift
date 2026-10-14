import AVFoundation
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let secs = Double(CommandLine.arguments[2]) ?? 5
let engine = AVAudioEngine()
let input = engine.inputNode
let fmt = input.outputFormat(forBus: 0)
print("Input format:", fmt); fflush(stdout)
let file = try! AVAudioFile(forWriting: out, settings: fmt.settings)
var peak: Float = 0
input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in
  try? file.write(from: buf)
  if let d = buf.floatChannelData?[0] { for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(d[i])) } }
}
try! engine.start()
print("Recording \(secs)s..."); fflush(stdout)
Thread.sleep(forTimeInterval: secs)
engine.stop()
print("Done. Peak amplitude: \(peak) (\(20*log10(max(peak,1e-9))) dBFS)")
