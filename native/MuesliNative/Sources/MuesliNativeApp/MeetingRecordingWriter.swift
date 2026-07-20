import AVFoundation
import Foundation
import os

enum MeetingRecordingFileFormat: String, CaseIterable, Sendable {
    case mp3
    case m4a
    case wav

    var displayName: String {
        switch self {
        case .mp3:
            return "MP3 (compatível)"
        case .m4a:
            return "M4A (AAC, menor)"
        case .wav:
            return "WAV (sem perdas)"
        }
    }

    var fileExtension: String {
        switch self {
        case .mp3:
            return "mp3"
        case .m4a:
            return "m4a"
        case .wav:
            return "wav"
        }
    }

    static func resolved(_ rawValue: String) -> MeetingRecordingFileFormat {
        MeetingRecordingFileFormat(rawValue: rawValue) ?? .mp3
    }
}

final class MeetingRecordingWriter {
    private final class ExportSessionBox: @unchecked Sendable {
        let session: AVAssetExportSession

        init(_ session: AVAssetExportSession) {
            self.session = session
        }
    }

    private struct State {
        var fileHandle: FileHandle?
        var fileURL: URL?
        var bytesWritten: Int = 0
        var pendingMic: [Int16] = []
        var pendingSystem: [Int16] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    init() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-meeting-recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let fileURL = tempDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let fileHandle = FileHandle(forWritingAtPath: fileURL.path) else {
            throw NSError(
                domain: "MeetingRecordingWriter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not open retained meeting recording file for writing."]
            )
        }
        fileHandle.write(Self.wavHeader(dataSize: 0))
        lock.withLock {
            $0 = State(fileHandle: fileHandle, fileURL: fileURL)
        }
    }

    func appendMic(_ samples: [Int16]) {
        append(samples, toMic: true)
    }

    func appendSystem(_ samples: [Int16]) {
        append(samples, toMic: false)
    }

    func stop() -> URL? {
        lock.withLock { state in
            writeMixedSamples(state: &state, flushAll: true)
            guard let fileHandle = state.fileHandle, let fileURL = state.fileURL else { return nil }

            fileHandle.seek(toFileOffset: 0)
            fileHandle.write(Self.wavHeader(dataSize: UInt32(state.bytesWritten)))
            fileHandle.closeFile()

            let outputURL = fileURL
            let bytesWritten = state.bytesWritten
            state = State()
            if bytesWritten == 0 {
                try? FileManager.default.removeItem(at: outputURL)
                return nil
            }
            return outputURL
        }
    }

    func markPauseBoundary() {
        lock.withLock { state in
            writeMixedSamples(state: &state, flushAll: true)
        }
    }

    func cancel() {
        let tempURL = lock.withLock { state -> URL? in
            state.fileHandle?.closeFile()
            let fileURL = state.fileURL
            state = State()
            return fileURL
        }
        if let tempURL {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    static func persistTemporaryRecordingAsync(
        from tempURL: URL,
        meetingTitle: String,
        startedAt: Date,
        supportDirectory: URL,
        fileFormat: MeetingRecordingFileFormat = .mp3
    ) async throws -> URL {
        let recordingsDirectory = supportDirectory
            .appendingPathComponent("meeting-recordings", isDirectory: true)
        try FileManager.default.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true
        )

        let destinationURL = recordingsDirectory.appendingPathComponent(
            "\(fileNamePrefix(for: startedAt, title: meetingTitle)).\(fileFormat.fileExtension)"
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        switch fileFormat {
        case .mp3:
            do {
                try await transcodeWAVToMP3Async(sourceURL: tempURL, destinationURL: destinationURL)
                try FileManager.default.removeItem(at: tempURL)
            } catch {
                try? FileManager.default.removeItem(at: destinationURL)
                throw error
            }
        case .m4a:
            do {
                try await transcodeWAVToM4AAsync(sourceURL: tempURL, destinationURL: destinationURL)
                try FileManager.default.removeItem(at: tempURL)
            } catch {
                try? FileManager.default.removeItem(at: destinationURL)
                throw error
            }
        case .wav:
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        }
        return destinationURL
    }

    private func append(_ samples: [Int16], toMic: Bool) {
        guard !samples.isEmpty else { return }
        lock.withLock { state in
            if toMic {
                state.pendingMic.append(contentsOf: samples)
            } else {
                state.pendingSystem.append(contentsOf: samples)
            }
            writeMixedSamples(state: &state, flushAll: false)
        }
    }

    private static func transcodeWAVToMP3Async(sourceURL: URL, destinationURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            try transcodeWAVToMP3(sourceURL: sourceURL, destinationURL: destinationURL)
        }.value
    }

    private static func transcodeWAVToMP3(sourceURL: URL, destinationURL: URL) throws {
        if let ffmpegURL = firstExecutable(named: "ffmpeg") {
            try runEncoder(
                executableURL: ffmpegURL,
                arguments: [
                    "-y",
                    "-hide_banner",
                    "-loglevel", "error",
                    "-i", sourceURL.path,
                    "-vn",
                    "-ac", "1",
                    "-ar", "16000",
                    "-codec:a", "libmp3lame",
                    "-b:a", "96k",
                    destinationURL.path
                ],
                failureDescription: "Não foi possível exportar a gravação da reunião em MP3 com ffmpeg."
            )
            return
        }

        if let lameURL = firstExecutable(named: "lame") {
            try runEncoder(
                executableURL: lameURL,
                arguments: [
                    "--silent",
                    "-b", "96",
                    "-m", "m",
                    sourceURL.path,
                    destinationURL.path
                ],
                failureDescription: "Não foi possível exportar a gravação da reunião em MP3 com lame."
            )
            return
        }

        throw NSError(
            domain: "MeetingRecordingWriter",
            code: 4,
            userInfo: [
                NSLocalizedDescriptionKey: "Não encontrei ffmpeg nem lame para exportar a gravação da reunião em MP3."
            ]
        )
    }

    private static func firstExecutable(named executableName: String) -> URL? {
        let manager = FileManager.default
        let pathCandidates = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        for directory in pathCandidates {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(executableName)
            if manager.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static func runEncoder(
        executableURL: URL,
        arguments: [String],
        failureDescription: String
    ) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "MeetingRecordingWriter",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: errorOutput.map { "\($0)\n\(failureDescription)" }
                        ?? failureDescription
                ]
            )
        }
    }

    private func writeMixedSamples(state: inout State, flushAll: Bool) {
        let availableCount = flushAll
            ? max(state.pendingMic.count, state.pendingSystem.count)
            : min(state.pendingMic.count, state.pendingSystem.count)
        guard availableCount > 0 else { return }

        let mixedSamples = Self.mix(
            mic: Array(state.pendingMic.prefix(availableCount)),
            system: Array(state.pendingSystem.prefix(availableCount))
        )
        state.pendingMic.removeFirst(min(availableCount, state.pendingMic.count))
        state.pendingSystem.removeFirst(min(availableCount, state.pendingSystem.count))

        let pcmData = mixedSamples.withUnsafeBufferPointer { Data(buffer: $0) }
        state.fileHandle?.write(pcmData)
        state.bytesWritten += pcmData.count
    }

    private static func fileNamePrefix(for date: Date, title: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let timestamp = formatter.string(from: date)

        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let normalized = title.unicodeScalars.map { allowed.contains($0) ? String($0) : " " }.joined()
        let slug = normalized
            .split(whereSeparator: \.isWhitespace)
            .prefix(6)
            .joined(separator: "-")
            .lowercased()

        return slug.isEmpty ? timestamp : "\(timestamp)-\(slug)"
    }

    private static func mix(mic: [Int16], system: [Int16]) -> [Int16] {
        let maxCount = max(mic.count, system.count)
        var output = [Int16]()
        output.reserveCapacity(maxCount)

        for index in 0..<maxCount {
            let hasMic = index < mic.count
            let hasSystem = index < system.count
            let micValue = hasMic ? Int(mic[index]) : 0
            let systemValue = hasSystem ? Int(system[index]) : 0
            let contributors = (hasMic ? 1 : 0) + (hasSystem ? 1 : 0)
            let averaged = contributors == 0 ? 0 : (micValue + systemValue) / contributors
            output.append(Int16(clamping: averaged))
        }

        return output
    }

    private static func transcodeWAVToM4AAsync(sourceURL: URL, destinationURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw NSError(
                domain: "MeetingRecordingWriter",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not create M4A export session for meeting recording."]
            )
        }

        exportSession.outputURL = destinationURL
        exportSession.outputFileType = .m4a
        let exportSessionBox = ExportSessionBox(exportSession)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportSessionBox.session.exportAsynchronously {
                guard exportSessionBox.session.status == .completed else {
                    continuation.resume(throwing: exportSessionBox.session.error ?? NSError(
                        domain: "MeetingRecordingWriter",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Could not export meeting recording as M4A."]
                    ))
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    private static func wavHeader(dataSize: UInt32) -> Data {
        let sampleRate: UInt32 = 16_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let chunkSize = 36 + dataSize

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        return header
    }
}
