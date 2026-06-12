import Foundation

// ─── Ariadne's Thread [AT-0169] ─────────────────────
// What: Persist Watch-recorded voice messages on disk for chat playback.
// Why:  Temp recorder files are deleted after send; users need a stable local copy to replay.
// Date: 2026-06-12
// Related: [AT-0168] VoiceJob.localAudioFileName, [AT-0170] WatchVoiceMessagePlayerView
// ─────────────────────────────────────────────────────
enum WatchVoiceMessageStore {
    private static let folderName = "VoiceMessages"

    static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                AppLog.info("Watch voice message store created path=\(dir.path)")
            } catch {
                AppLog.error("Watch voice message store create failed path=\(dir.path) error=\(error.localizedDescription)")
            }
        }
        return dir
    }

    static func fileName(forJobId jobId: UUID) -> String {
        "\(jobId.uuidString).m4a"
    }

    static func url(forFileName fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    static func url(forJobId jobId: UUID) -> URL {
        url(forFileName: fileName(forJobId: jobId))
    }

    /// Copies the recorder temp file into the voice-message cache and returns the stored file name.
    static func persistRecording(from tempURL: URL, jobId: UUID) -> String? {
        let destURL = url(forJobId: jobId)
        let fileName = fileName(forJobId: jobId)
        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
                AppLog.info("Watch voice message store replaced existing file jobId=\(jobId) path=\(destURL.path)")
            }
            try FileManager.default.copyItem(at: tempURL, to: destURL)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? NSNumber)?.intValue ?? -1
            AppLog.info("Watch voice message persisted jobId=\(jobId) file=\(fileName) bytes=\(bytes) path=\(destURL.path)")
            return fileName
        } catch {
            AppLog.error("Watch voice message persist failed jobId=\(jobId) temp=\(tempURL.path) dest=\(destURL.path) error=\(error.localizedDescription)")
            return nil
        }
    }
}
