import Foundation

/// Lightweight diagnostic logger. Always NSLogs; also appends to a file when
/// HALO_LOG_FILE is set, so the app's real (non-inherited) permission/tap
/// state can be inspected even when launched via Finder/`open`.
func diag(_ message: String) {
    NSLog("[Halo] \(message)")
    guard let path = ProcessInfo.processInfo.environment["HALO_LOG_FILE"] else { return }
    let line = "\(Date()) \(message)\n"
    if let data = line.data(using: .utf8) {
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
