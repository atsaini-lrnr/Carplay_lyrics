//
//  SilentAudioPlayer.swift
//  CarPlayLyrics
//
//  Synthesizes an in-memory silent audio loop and configures AVAudioSession with .mixWithOthers.
//  This keeps the app's RunLoop and timers active when the phone screen is locked or asleep,
//  WITHOUT interrupting or ducking Apple Music / Spotify / CarPlay audio.
//  100% Free Tier, zero external asset dependencies.
//

import Foundation
import AVFoundation

public final class SilentAudioPlayer {
    public static let shared = SilentAudioPlayer()
    
    private var audioPlayer: AVAudioPlayer?
    public private(set) var isRunning = false
    private let queue = DispatchQueue(label: "com.atul.CarPlayLyrics.audioQueue", qos: .utility)
    
    private init() {}
    
    /// Prepares AVAudioSession to allow silent background playback mixed with other music asynchronously
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                let session = AVAudioSession.sharedInstance()
                // Use .playback with .mixWithOthers so Apple Music / CarPlay audio stream is uninterrupted
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true, options: [])
                
                if self.audioPlayer == nil {
                    let silentWavData = self.generateSilentWavData(durationSeconds: 2)
                    let player = try AVAudioPlayer(data: silentWavData)
                    player.numberOfLoops = -1 // Infinite background loop
                    player.volume = 0.0001
                    player.prepareToPlay()
                    self.audioPlayer = player
                }
                
                self.audioPlayer?.play()
                print("[SilentAudioPlayer] Background keep-alive loop started cleanly on background queue.")
            } catch {
                print("[SilentAudioPlayer] Audio session notice: \(error.localizedDescription)")
            }
        }
    }
    
    /// Stops the background keep-alive loop
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        
        queue.async { [weak self] in
            guard let self = self else { return }
            self.audioPlayer?.stop()
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                print("[SilentAudioPlayer] Background keep-alive loop stopped.")
            } catch {
                print("[SilentAudioPlayer] Deactivate notice: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - In-Memory Silent WAV Generator
    
    private func generateSilentWavData(durationSeconds: Int = 1) -> Data {
        let sampleRate: Int32 = 44100
        let channels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let totalSamples = Int(sampleRate) * durationSeconds
        let subChunk2Size = Int32(totalSamples * Int(channels) * Int(bitsPerSample / 8))
        let chunkSize = 36 + subChunk2Size
        let byteRate = sampleRate * Int32(channels) * Int32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.append(withUnsafeBytes(of: chunkSize.littleEndian) { Data($0) })
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        let subChunk1Size: Int32 = 16
        data.append(withUnsafeBytes(of: subChunk1Size.littleEndian) { Data($0) })
        let audioFormat: Int16 = 1 // PCM
        data.append(withUnsafeBytes(of: audioFormat.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: channels.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        data.append(contentsOf: "data".utf8)
        data.append(withUnsafeBytes(of: subChunk2Size.littleEndian) { Data($0) })
        let silenceBytes = [UInt8](repeating: 0, count: Int(subChunk2Size))
        data.append(contentsOf: silenceBytes)
        return data
    }
}
