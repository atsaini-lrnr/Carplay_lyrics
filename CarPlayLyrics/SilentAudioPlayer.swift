//
//  SilentAudioPlayer.swift
//  CarPlayLyrics
//
//  Synthesizes an in-memory silent audio loop and configures AVAudioSession with .mixWithOthers.
//  This keeps the app's RunLoop and timers active when the phone screen is locked or asleep,
//  WITHOUT interrupting or ducking Apple Music / Spotify / CarPlay audio.
//

import Foundation
import AVFoundation
import UIKit

public final class SilentAudioPlayer: NSObject, AVAudioPlayerDelegate {
    public static let shared = SilentAudioPlayer()
    
    private var audioPlayer: AVAudioPlayer?
    public private(set) var isRunning = false
    
    private override init() {
        super.init()
    }
    
    /// Prepares AVAudioSession to allow silent background playback mixed with other music
    @MainActor
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        
        do {
            let session = AVAudioSession.sharedInstance()
            // Use .playback with .mixWithOthers & Bluetooth options so Apple Music / CarPlay audio stream is uninterrupted
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .allowBluetoothA2DP, .allowAirPlay])
            try session.setActive(true, options: [])
            
            if audioPlayer == nil {
                let silentWavData = generateSilentWavData(durationSeconds: 3)
                let player = try AVAudioPlayer(data: silentWavData)
                player.delegate = self
                player.numberOfLoops = -1 // Infinite background loop
                player.volume = 0.01 // Audible to system audio graph, but data is zero PCM (true silence)
                player.prepareToPlay()
                self.audioPlayer = player
            }
            
            audioPlayer?.play()
            print("[SilentAudioPlayer] Background keep-alive loop active on Main Thread.")
        } catch {
            print("[SilentAudioPlayer] Audio session notice: \(error.localizedDescription)")
        }
    }
    
    /// Stops the background keep-alive loop
    @MainActor
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        audioPlayer?.stop()
        audioPlayer = nil
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            print("[SilentAudioPlayer] Background keep-alive loop stopped.")
        } catch {
            print("[SilentAudioPlayer] Deactivate notice: \(error.localizedDescription)")
        }
    }
    
    // MARK: - In-Memory Silent WAV Generator (Clean 44.1kHz 16-bit Mono PCM)
    
    private func generateSilentWavData(durationSeconds: Int = 3) -> Data {
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
