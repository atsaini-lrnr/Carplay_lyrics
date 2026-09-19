//
//  SilentAudioPlayer.swift
//  CarPlayLyrics
//
//  Plays an in-memory silent loop (mixed with other audio) so iOS keeps the app running while the
//  phone is locked. Without it the app is suspended ~30 s after locking and the lyrics freeze.
//
//  Phone calls, Siri and route changes stop the loop; this class restarts it afterwards.
//  Personal-use technique: App Review rejects silent-audio keep-alives.
//

import AVFoundation
import Foundation

@MainActor
final class SilentAudioPlayer {
    static let shared = SilentAudioPlayer()

    private var player: AVAudioPlayer?
    /// Whether the app wants the loop running (independent of whether iOS paused it).
    private var isWanted = false
    private var observers: [NSObjectProtocol] = []

    var isPlaying: Bool { player?.isPlaying == true }

    private init() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: session, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                // Silent audio never needs to wait for permission to resume.
                if raw == AVAudioSession.InterruptionType.ended.rawValue {
                    DiagnosticsLog.shared.add("Audio interruption ended (call/Siri)")
                    SilentAudioPlayer.shared.resumeIfNeeded()
                } else {
                    DiagnosticsLog.shared.add("Audio interruption began (call/Siri)")
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: session, queue: .main) { _ in
            MainActor.assumeIsolated {
                DiagnosticsLog.shared.add("Audio system reset")
                SilentAudioPlayer.shared.player = nil
                SilentAudioPlayer.shared.resumeIfNeeded()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: session, queue: .main) { _ in
            MainActor.assumeIsolated { SilentAudioPlayer.shared.resumeIfNeeded() }
        })
    }

    func start() {
        isWanted = true
        resumeIfNeeded()
    }

    func stop() {
        isWanted = false
        player?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Restarts the loop if iOS stopped it. Cheap; the tracker calls it on every tick as a watchdog.
    func resumeIfNeeded() {
        guard isWanted, player?.isPlaying != true else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // .mixWithOthers: never interrupts or ducks Apple Music / CarPlay audio.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            if player == nil {
                let newPlayer = try AVAudioPlayer(data: Self.silentWAV(seconds: 3))
                newPlayer.numberOfLoops = -1
                newPlayer.volume = 0.01
                newPlayer.prepareToPlay()
                player = newPlayer
            }
            player?.play()
        } catch {
            print("[SilentAudioPlayer] Could not start keep-alive: \(error)")
            DiagnosticsLog.shared.add("Audio keep-alive failed: \(error.localizedDescription)")
        }
    }

    /// 44.1 kHz, 16-bit mono PCM of pure zeros.
    private static func silentWAV(seconds: Int) -> Data {
        let sampleRate: UInt32 = 44_100
        let dataSize = UInt32(Int(sampleRate) * seconds * 2)

        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: Array("RIFF".utf8)); append(36 + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1))            // PCM
        append(UInt16(1))            // mono
        append(sampleRate)
        append(sampleRate * 2)       // byte rate
        append(UInt16(2))            // block align
        append(UInt16(16))           // bits per sample
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }
}
