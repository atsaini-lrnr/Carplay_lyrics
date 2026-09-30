//
//  SilentAudioPlayer.swift
//  CarPlayLyrics
//
//  Plays an in-memory silent loop (mixed with other audio) so iOS keeps the app running while the
//  phone is locked. Without it the app is suspended ~30 s after locking and the lyrics freeze.
//
//  Phone calls, Siri and route changes stop the loop; this class restarts it afterwards. iOS doesn't
//  always send "interruption ended", so on "began" it asks for ~30 s of extra run time, during
//  which the tracker's tick keeps retrying `resumeIfNeeded()`.
//  Personal-use technique: App Review rejects silent-audio keep-alives.
//

import AVFoundation
import Foundation
import UIKit

@MainActor
final class SilentAudioPlayer {
    static let shared = SilentAudioPlayer()

    private var player: AVAudioPlayer?
    /// Whether the app wants the loop running (independent of whether iOS paused it).
    private var isWanted = false
    private var observers: [NSObjectProtocol] = []
    private var recoveryTask = UIBackgroundTaskIdentifier.invalid
    /// Retries fail every tick during a call; log only the first failure until it recovers.
    private var hasLoggedFailure = false

    var isPlaying: Bool { player?.isPlaying == true }

    private init() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: session, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let reasonRaw = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            MainActor.assumeIsolated {
                let reason = Self.describe(reasonRaw)
                // Silent audio never needs to wait for permission to resume.
                if raw == AVAudioSession.InterruptionType.ended.rawValue {
                    DiagnosticsLog.shared.add("Audio interruption ended (\(reason))")
                    SilentAudioPlayer.shared.resumeIfNeeded()
                } else {
                    DiagnosticsLog.shared.add("Audio interruption began (\(reason))")
                    SilentAudioPlayer.shared.beginRecoveryWindow()
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
        endRecoveryWindow()
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
            if player?.isPlaying == true {
                if hasLoggedFailure { DiagnosticsLog.shared.add("Audio keep-alive restarted") }
                hasLoggedFailure = false
                endRecoveryWindow()
            }
        } catch {
            print("[SilentAudioPlayer] Could not start keep-alive: \(error)")
            if !hasLoggedFailure {
                hasLoggedFailure = true
                DiagnosticsLog.shared.add("Audio keep-alive failed, retrying: \(error.localizedDescription)")
            }
        }
    }

    /// Keeps the app running briefly after an interruption so the loop can be restarted even if
    /// "interruption ended" never arrives. Without it the app would be suspended almost immediately.
    private func beginRecoveryWindow() {
        guard recoveryTask == .invalid else { return }
        // The expiration handler can run off the main thread, so hop rather than assume isolation.
        recoveryTask = UIApplication.shared.beginBackgroundTask(withName: "RestartSilentAudio") {
            Task { @MainActor in
                DiagnosticsLog.shared.add("Audio keep-alive could not restart within 30 s")
                SilentAudioPlayer.shared.endRecoveryWindow()
            }
        }
    }

    private func endRecoveryWindow() {
        guard recoveryTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(recoveryTask)
        recoveryTask = .invalid
    }

    private static func describe(_ reasonRaw: UInt?) -> String {
        guard let reasonRaw, let reason = AVAudioSession.InterruptionReason(rawValue: reasonRaw) else {
            return "call, Siri or other audio"
        }
        switch reason {
        case .appWasSuspended: return "app was suspended"
        case .builtInMicMuted: return "mic muted"
        case .routeDisconnected: return "audio route disconnected"
        case .default: return "call, Siri or other audio"
        @unknown default: return "reason \(reasonRaw)"
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
