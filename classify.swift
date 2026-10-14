// classify: labels audio files with Apple's built-in sound classifier (SoundAnalysis, on-device).
//
// Usage: classify <file>...   one JSON line per file:
//          {"file": "...", "labels": [["speech", 0.93], ["music", 0.41], ...]}
//        (each label's highest confidence in any ~1 s window, best first, >= 0.05)
//        classify --labels    every label the classifier knows, one per line
import Foundation
import SoundAnalysis

setvbuf(stdout, nil, _IOLBF, 0)

final class Collector: NSObject, SNResultsObserving {
    var best: [String: Double] = [:]
    var error: Error?
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        for c in r.classifications { best[c.identifier] = max(best[c.identifier] ?? 0, c.confidence) }
    }
    func request(_ request: SNRequest, didFailWithError error: Error) { self.error = error }
}

func makeRequest() throws -> SNClassifySoundRequest {
    let r = try SNClassifySoundRequest(classifierIdentifier: .version1)
    r.windowDuration = CMTime(seconds: 1.0, preferredTimescale: 16000)
    r.overlapFactor = 0.5
    return r
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--labels" {
    try makeRequest().knownClassifications.sorted().forEach { print($0) }
    exit(0)
}

var failed = false
for path in args {
    var out: [String: Any] = ["file": path]
    do {
        let c = Collector()
        let analyzer = try SNAudioFileAnalyzer(url: URL(fileURLWithPath: path))
        try analyzer.add(try makeRequest(), withObserver: c)
        analyzer.analyze()
        if let e = c.error { throw e }
        out["labels"] = c.best.filter { $0.value >= 0.05 }
            .sorted { $0.value > $1.value }
            .map { [$0.key, ($0.value * 1000).rounded() / 1000] }
    } catch {
        out["error"] = "\(error)"
        failed = true
    }
    let data = try JSONSerialization.data(withJSONObject: out)
    print(String(data: data, encoding: .utf8)!)
}
exit(failed ? 1 : 0)
