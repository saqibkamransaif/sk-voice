import Foundation
import AVFoundation

/// Persists each capture's audio as a WAV named after its history entry, entirely local.
/// 16 kHz mono 16-bit ≈ 32 KB per second of speech.
public enum AudioStore {
    public static var directory: URL {
        AppSettings.supportDirectory.appendingPathComponent("audio", isDirectory: true)
    }

    public static func url(for entryID: String) -> URL {
        directory.appendingPathComponent("\(entryID).wav")
    }

    public static func hasAudio(for entryID: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: entryID).path)
    }

    /// Writes 16 kHz mono Float32 samples as 16-bit PCM WAV.
    @discardableResult
    public static func save(samples: [Float], for entryID: String) -> Bool {
        guard !samples.isEmpty else { return false }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let destination = url(for: entryID)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: AudioResampler.targetRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let file = try AVAudioFile(forWriting: destination, settings: settings)
            guard let buffer = AudioResampler.buffer(from: samples) else { return false }
            try file.write(from: buffer)
            return true
        } catch {
            FileHandle.standardError.write(
                Data("SKVoice: audio save failed: \(error)\n".utf8))
            return false
        }
    }

    public static func delete(for entryID: String) {
        try? FileManager.default.removeItem(at: url(for: entryID))
    }

    /// Removes recordings older than `days`. Called at launch.
    public static func cleanup(olderThanDays days: Int = 30) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(
                forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
