import Foundation
import MetricKit
import os

/// Crash and performance diagnostics through Apple's MetricKit: no
/// third-party SDK and no personal data. Payloads (crashes, hangs, launch
/// time, memory) arrive at most daily. They're logged and kept on device;
/// `upload` is the hook for sending them to your own endpoint.
final class DiagnosticsReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = DiagnosticsReporter()

    private let logger = Logger(subsystem: "app.vector.ios", category: "diagnostics")
    private var started = false

    /// Set to your collector (e.g. an endpoint on backend/api).
    var upload: ((Data, String) -> Void)?

    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let crashes = payload.crashDiagnostics?.count ?? 0
            let hangs = payload.hangDiagnostics?.count ?? 0
            logger.error("Diagnostics: \(crashes) crashes, \(hangs) hangs")
            store(payload.jsonRepresentation(), kind: "diagnostic")
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            store(payload.jsonRepresentation(), kind: "metrics")
        }
    }

    private func store(_ json: Data, kind: String) {
        upload?(json, kind)
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Diagnostics", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(kind)-\(Int(Date().timeIntervalSince1970)).json")
        try? json.write(to: file, options: .atomic)
    }
}
