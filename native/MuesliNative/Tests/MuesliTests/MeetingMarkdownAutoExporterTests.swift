import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("MeetingMarkdownAutoExporter")
struct MeetingMarkdownAutoExporterTests {

    @Test("disabled config writes nothing")
    func disabledIsNoOp() async throws {
        let support = makeTemporaryDirectory()
        let destination = makeTemporaryDirectory()
        let exporter = MeetingMarkdownAutoExporter(supportDirectory: support)
        var config = AppConfig()
        config.autoExportMarkdownEnabled = false
        config.autoExportMarkdownFolderPath = destination.path

        exporter.exportIfConfigured(meeting: makeMeeting(), config: config)

        #expect(FileManager.default.fileExists(atPath: exporter.logURL.path) == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test("empty folder path logs skipped and writes nothing")
    func emptyFolderLogsSkipped() async throws {
        let support = makeTemporaryDirectory()
        let exporter = MeetingMarkdownAutoExporter(supportDirectory: support)
        var config = AppConfig()
        config.autoExportMarkdownEnabled = true
        config.autoExportMarkdownFolderPath = "   "

        let result = await exporter.performExport(meeting: makeMeeting(), config: config)
        exporter.waitForPendingLogWrites()

        #expect(result == nil)
        let log = try String(contentsOf: exporter.logURL, encoding: .utf8)
        #expect(log.contains("no destination folder configured"))
    }

    @Test("relative folder path is rejected")
    func relativePathRejected() async throws {
        let support = makeTemporaryDirectory()
        let exporter = MeetingMarkdownAutoExporter(supportDirectory: support)
        var config = AppConfig()
        config.autoExportMarkdownEnabled = true
        config.autoExportMarkdownFolderPath = "relative/notes"

        let result = await exporter.performExport(meeting: makeMeeting(), config: config)
        exporter.waitForPendingLogWrites()

        #expect(result == nil)
        let log = try String(contentsOf: exporter.logURL, encoding: .utf8)
        #expect(log.contains("must be an absolute path"))
    }

    @Test("writes meeting package markdown files to destination folder")
    func writesMeetingPackageFiles() async throws {
        let support = makeTemporaryDirectory()
        let destination = makeTemporaryDirectory()
        let exporter = MeetingMarkdownAutoExporter(supportDirectory: support)
        var config = AppConfig()
        config.autoExportMarkdownEnabled = true
        config.autoExportMarkdownFolderPath = destination.path

        let urls = try #require(await exporter.performExport(meeting: makeMeeting(), config: config))

        #expect(urls.count == 3)
        #expect(Set(urls.map(\.lastPathComponent)) == Set([
            "2026-04-14-weekly-standup-transcript.md",
            "2026-04-14-weekly-standup-cleanup-prompt.md",
            "2026-04-14-weekly-standup-summary.md",
        ]))
        let transcript = try String(contentsOf: try #require(urls.first { $0.lastPathComponent.hasSuffix("-transcript.md") }), encoding: .utf8)
        let prompt = try String(contentsOf: try #require(urls.first { $0.lastPathComponent.hasSuffix("-cleanup-prompt.md") }), encoding: .utf8)
        let summary = try String(contentsOf: try #require(urls.first { $0.lastPathComponent.hasSuffix("-summary.md") }), encoding: .utf8)
        #expect(transcript.contains("## Raw Transcript"))
        #expect(prompt.contains("Prompt para limpar e corrigir"))
        #expect(summary.contains("## Key Points"))
    }

    @Test("filename includes date prefix and transcript suffix")
    func filenameHasDatePrefix() async throws {
        let support = makeTemporaryDirectory()
        let destination = makeTemporaryDirectory()
        let exporter = MeetingMarkdownAutoExporter(supportDirectory: support)
        var config = AppConfig()
        config.autoExportMarkdownEnabled = true
        config.autoExportMarkdownFolderPath = destination.path

        let url = try #require(await exporter.performExport(meeting: makeMeeting(), config: config)?.first)

        #expect(url.lastPathComponent == "2026-04-14-weekly-standup-transcript.md")
    }

    @Test("transcript package includes raw transcript")
    func transcriptContentOption() async throws {
        let support = makeTemporaryDirectory()
        let destination = makeTemporaryDirectory()
        let exporter = MeetingMarkdownAutoExporter(supportDirectory: support)
        var config = AppConfig()
        config.autoExportMarkdownEnabled = true
        config.autoExportMarkdownFolderPath = destination.path
        config.autoExportMarkdownContent = MeetingExportContent.transcript.rawValue

        let urls = try #require(await exporter.performExport(meeting: makeMeeting(), config: config))
        let url = try #require(urls.first { $0.lastPathComponent.hasSuffix("-transcript.md") })

        #expect(url.lastPathComponent.hasSuffix("-transcript.md"))
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("## Raw Transcript"))
        #expect(contents.contains("Hello everyone"))
    }

    @Test("repeated exports do not overwrite, append numeric suffix")
    func collisionAppendsSuffix() async throws {
        let support = makeTemporaryDirectory()
        let destination = makeTemporaryDirectory()
        let exporter = MeetingMarkdownAutoExporter(supportDirectory: support)
        var config = AppConfig()
        config.autoExportMarkdownEnabled = true
        config.autoExportMarkdownFolderPath = destination.path

        let first = try #require(await exporter.performExport(meeting: makeMeeting(), config: config)?.first)
        let second = try #require(await exporter.performExport(meeting: makeMeeting(), config: config)?.first)

        #expect(first.lastPathComponent == "2026-04-14-weekly-standup-transcript.md")
        #expect(second.lastPathComponent == "2026-04-14-weekly-standup-transcript-2.md")
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test("concurrent exports reserve distinct destinations")
    func concurrentExportsReserveDistinctDestinations() async throws {
        let support = makeTemporaryDirectory()
        let destination = makeTemporaryDirectory()
        let exporter = MeetingMarkdownAutoExporter(supportDirectory: support)
        var config = AppConfig()
        config.autoExportMarkdownEnabled = true
        config.autoExportMarkdownFolderPath = destination.path

        let urls = await withTaskGroup(of: URL?.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await exporter.performExport(meeting: makeMeeting(), config: config)?.first
                }
            }

            var results: [URL] = []
            for await url in group {
                if let url { results.append(url) }
            }
            return results
        }

        #expect(urls.count == 8)
        #expect(Set(urls.map(\.lastPathComponent)).count == 8)
    }

    @Test("meeting lookup failures are written to export log")
    func lookupFailureWritesLog() throws {
        let support = makeTemporaryDirectory()
        let exporter = MeetingMarkdownAutoExporter(supportDirectory: support)

        exporter.recordMeetingLookupFailure(meetingID: 42, error: nil)
        exporter.waitForPendingLogWrites()

        let log = try String(contentsOf: exporter.logURL, encoding: .utf8)
        #expect(log.contains("persisted meeting not found id=42"))
    }

    @Test("creates destination folder when missing")
    func createsMissingFolder() async throws {
        let support = makeTemporaryDirectory()
        let destination = makeTemporaryDirectory().appendingPathComponent("nested/notes", isDirectory: true)
        let exporter = MeetingMarkdownAutoExporter(supportDirectory: support)
        var config = AppConfig()
        config.autoExportMarkdownEnabled = true
        config.autoExportMarkdownFolderPath = destination.path

        let url = try #require(await exporter.performExport(meeting: makeMeeting(), config: config)?.first)

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.deletingLastPathComponent().path == destination.standardizedFileURL.path)
    }

    @Test("PDF format writes a PDF file")
    func pdfFormatWritesPDF() async throws {
        let support = makeTemporaryDirectory()
        let destination = makeTemporaryDirectory()
        let exporter = MeetingMarkdownAutoExporter(supportDirectory: support)
        var config = AppConfig()
        config.autoExportMarkdownEnabled = true
        config.autoExportMarkdownFolderPath = destination.path
        config.autoExportFileFormat = MeetingAutoExportFileFormat.pdf.rawValue

        let urls = try #require(await exporter.performExport(meeting: makeMeeting(), config: config))

        #expect(urls.count == 1)
        let url = try #require(urls.first)
        #expect(url.lastPathComponent == "2026-04-14-weekly-standup.pdf")
        #expect(try Data(contentsOf: url).starts(with: Data("%PDF".utf8)))
    }

    @Test("Markdown and PDF format writes both files")
    func markdownAndPDFFormatWritesBothFiles() async throws {
        let support = makeTemporaryDirectory()
        let destination = makeTemporaryDirectory()
        let exporter = MeetingMarkdownAutoExporter(supportDirectory: support)
        var config = AppConfig()
        config.autoExportMarkdownEnabled = true
        config.autoExportMarkdownFolderPath = destination.path
        config.autoExportFileFormat = MeetingAutoExportFileFormat.markdownAndPDF.rawValue

        let urls = try #require(await exporter.performExport(meeting: makeMeeting(), config: config))
        let extensions = Set(urls.map(\.pathExtension))

        #expect(urls.count == 4)
        #expect(extensions == ["md", "pdf"])
        for url in urls {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    // MARK: - Helpers

    private func makeMeeting(
        title: String = "Weekly Standup",
        startTime: String = "2026-04-14T10:00:00",
        rawTranscript: String = "[00:00:05] You: Hello everyone\n[00:00:10] Speaker 1: Hi there",
        formattedNotes: String = "## Key Points\n\n- Discussed roadmap\n- **Action item:** Ship export feature"
    ) -> MeetingRecord {
        MeetingRecord(
            id: 1,
            title: title,
            startTime: startTime,
            durationSeconds: 1800,
            rawTranscript: rawTranscript,
            formattedNotes: formattedNotes,
            wordCount: 42,
            folderID: nil,
            selectedTemplateName: "Default",
            selectedTemplateKind: .builtin
        )
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("markdown-auto-export-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
