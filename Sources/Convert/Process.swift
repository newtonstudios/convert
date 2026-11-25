import Foundation

struct ConvertError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Thrown by a conversion the user stopped.
struct StoppedError: LocalizedError {
    var errorDescription: String? { "Stopped" }
}

/// The command-line tools Convert uses when they're installed. They're looked up on every use,
/// so installing ffmpeg or cwebp while Convert is open takes effect without a restart.
enum Tools {
    static let directories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    static func find(_ name: String, in directories: [String] = Tools.directories) -> String? {
        for dir in directories {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
    static var ffmpeg: String? { find("ffmpeg") }
    static var ffprobe: String? { find("ffprobe") }
    static var cwebp: String? { find("cwebp") }
    /// Optional: makes WOFF2 fonts smaller than macOS's own Brotli encoder can.
    static var brotli: String? { find("brotli") }
}

func lastLine(_ data: Data) -> String? {
    String(decoding: data, as: UTF8.self)
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .last { !$0.isEmpty }
}

/// Runs a tool to completion and returns stdout. Throws with the last stderr line on failure.
@discardableResult
func runSync(_ exe: String, _ args: [String]) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let out = Pipe()
    let err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = FileHandle.nullDevice
    try p.run()
    // Both pipes are read at the same time. Read one after the other, a tool that fills the
    // second pipe's buffer while we wait on the first would block for good. The second read gets
    // a thread of its own: callers block a thread of a shared pool here, and once every thread of
    // that pool is waiting, work queued to it never runs (CI's Mac has only 3 cores).
    let errBox = DataBox()
    let errRead = DispatchSemaphore(value: 0)
    Thread {
        errBox.append(err.fileHandleForReading.readDataToEndOfFile())
        errRead.signal()
    }.start()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    errRead.wait()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        throw ConvertError(lastLine(errBox.value) ?? "\(URL(fileURLWithPath: exe).lastPathComponent) failed")
    }
    return String(decoding: data, as: UTF8.self)
}

/// Where converted files go: next to the original, or a fallback folder when that isn't possible.
enum OutputFolder {
    /// Used when the original's folder can't be written to (a read-only disk or disk image, no permission).
    /// Downloads; `CONVERT_FALLBACK_DIR` replaces it for tests.
    static var fallback: URL {
        if let dir = ProcessInfo.processInfo.environment["CONVERT_FALLBACK_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// The folder to write a conversion of `input` into.
    static func directory(for input: URL, fallback: URL = OutputFolder.fallback) throws -> URL {
        let dir = input.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: dir.path) { return dir }
        guard FileManager.default.isWritableFile(atPath: fallback.path) else {
            throw ConvertError(
                "Can't save the converted file: the original's folder is read-only, and "
                    + "“\(name(of: fallback))” can't be written to either")
        }
        return fallback
    }

    /// Whether `output` was written somewhere other than next to `input`.
    static func isFallback(_ output: URL, for input: URL) -> Bool {
        output.deletingLastPathComponent().standardizedFileURL.path
            != input.deletingLastPathComponent().standardizedFileURL.path
    }

    /// The folder's name as Finder shows it.
    static func name(of folder: URL) -> String { FileManager.default.displayName(atPath: folder.path) }
}

/// Next free file name next to the input (or in the fallback folder): "name.ext", then "name 2.ext", …
func uniqueOutput(
    for input: URL, ext: String, suffix: String = "", fallback: URL = OutputFolder.fallback
) throws -> URL {
    let dir = try OutputFolder.directory(for: input, fallback: fallback)
    let base = input.deletingPathExtension().lastPathComponent + suffix
    var url = dir.appendingPathComponent(base).appendingPathExtension(ext)
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) {
        url = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
        n += 1
    }
    return url
}

func uniqueFolder(for input: URL, suffix: String, fallback: URL = OutputFolder.fallback) throws -> URL {
    let dir = try OutputFolder.directory(for: input, fallback: fallback)
    let base = input.deletingPathExtension().lastPathComponent + suffix
    var url = dir.appendingPathComponent(base, isDirectory: true)
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) {
        url = dir.appendingPathComponent("\(base) \(n)", isDirectory: true)
        n += 1
    }
    return url
}

/// Collects a tool's error output. Only the end is kept (the last line is the message we show),
/// so a tool that logs without end can't use up memory.
private final class DataBox: @unchecked Sendable {
    private static let kept = 64 * 1024
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) {
        lock.lock()
        data.append(d)
        if data.count > 2 * Self.kept { data = Data(data.suffix(Self.kept)) }
        lock.unlock()
    }
    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// Turns ffmpeg's `-progress` output into fractions done (0…1). The output arrives in chunks of
/// any size, so a line can be cut in two; the unfinished end is kept until the rest of it arrives.
struct ProgressParser {
    let duration: Double
    private var pending = Data()

    init(duration: Double) { self.duration = duration }

    mutating func feed(_ chunk: Data) -> [Double] {
        pending.append(chunk)
        var fractions: [Double] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            pending = Data(pending[pending.index(after: newline)...])
            guard duration > 0, line.hasPrefix("out_time_us="),
                let us = Double(line.dropFirst("out_time_us=".count).trimmingCharacters(in: .whitespaces)), us >= 0
            else { continue }
            fractions.append(min(1, us / 1_000_000 / duration))
        }
        return fractions
    }
}

private final class ProgressBox: @unchecked Sendable {
    private var parser: ProgressParser
    private let lock = NSLock()
    init(duration: Double) { parser = ProgressParser(duration: duration) }
    func feed(_ chunk: Data) -> [Double] { lock.withLock { parser.feed(chunk) } }
}

/// Whatever is still waiting in a pipe, without waiting for more. Used once the tool has exited,
/// for output it wrote just before that.
private func remainingData(in handle: FileHandle) -> Data {
    let fd = handle.fileDescriptor
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { break }
        data.append(buffer, count: n)
    }
    return data
}

/// One batch of conversions: runs ffmpeg-style processes with live progress, and carries Stop.
/// Stop kills the process that's running; work done in-process calls `checkCancelled()` between steps.
final class Runner: @unchecked Sendable {
    private var current: Process?
    private var cancelled = false
    private let lock = NSLock()

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.lock()
        cancelled = true
        current?.terminate()
        lock.unlock()
    }

    /// Clears an earlier Stop, before a new batch.
    func reset() { lock.withLock { cancelled = false } }

    func checkCancelled() throws {
        if isCancelled { throw StoppedError() }
    }

    func run(
        _ exe: String, _ args: [String], duration: Double,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let out = Pipe()
            let err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice
            let errBox = DataBox()
            let parser = ProgressBox(duration: duration)
            err.fileHandleForReading.readabilityHandler = { errBox.append($0.availableData) }
            out.fileHandleForReading.readabilityHandler = { h in
                for fraction in parser.feed(h.availableData) { progress(fraction) }
            }
            p.terminationHandler = { [weak self] proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                // The reason for a failure is often the last thing a tool writes before it exits.
                errBox.append(remainingData(in: err.fileHandleForReading))
                self?.lock.lock()
                self?.current = nil
                self?.lock.unlock()
                let name = URL(fileURLWithPath: exe).lastPathComponent
                if self?.isCancelled == true {
                    cont.resume(throwing: StoppedError())
                } else if proc.terminationStatus == 0 {
                    cont.resume()
                } else if proc.terminationReason == .uncaughtSignal {
                    cont.resume(throwing: ConvertError("\(name) quit unexpectedly"))
                } else {
                    cont.resume(
                        throwing: ConvertError(
                            lastLine(errBox.value) ?? "\(name) exited with code \(proc.terminationStatus)"))
                }
            }
            lock.lock()
            if cancelled {
                lock.unlock()
                cont.resume(throwing: StoppedError())
                return
            }
            do {
                try p.run()
                current = p
                lock.unlock()
            } catch {
                lock.unlock()
                cont.resume(throwing: error)
            }
        }
    }
}
