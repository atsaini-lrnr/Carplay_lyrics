//
//  LiveActivityController.swift
//  CarPlayLyrics
//
//  Owns the ONE Live Activity used for the whole drive.
//
//  iOS only lets an app START a Live Activity while it is on screen. Updating one works from the
//  background, so we start once (from the foreground) and then only ever update it, including on
//  song changes. Ending and re-requesting per song would fail as soon as the phone is locked.
//

import ActivityKit
import Foundation

@MainActor
final class LiveActivityController {
    private(set) var activity: Activity<LyricsAttributes>?
    var onActiveChange: ((Bool) -> Void)?

    private var pending: LyricsAttributes.ContentState?
    private var lastSent: LyricsAttributes.ContentState?
    private var lastSentAt = Date.distantPast
    private var isSending = false
    private var stateTask: Task<Void, Never>?

    /// If the app stops updating (killed, crashed), the card turns into "Paused" after this long.
    private static let staleAfter: TimeInterval = 10 * 60
    /// While the app is alive, re-send an unchanged card this often so it never goes stale.
    private static let refreshAfter: TimeInterval = 4 * 60
    /// iOS redraws a Live Activity only so often and throttles apps that update faster, after which
    /// the card sticks on an old line. Fast songs change lyrics every 2 s, so updates are spaced
    /// out and only the newest line in each window is sent.
    private static let minimumSpacing: TimeInterval = 2

    /// Starts the Live Activity if none is running. Call only while the app is in the foreground.
    func startIfNeeded(with state: LyricsAttributes.ContentState) {
        let existing = Activity<LyricsAttributes>.activities
        print("[card] cards iOS knows about: \(existing.count) -> "
              + existing.map { "\($0.id.suffix(6)):\($0.activityState)" }.joined(separator: ", "))
        if activity == nil { adoptExisting() }
        guard activity == nil else {
            update(state)
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        do {
            let started = try Activity.request(attributes: LyricsAttributes(), content: content(state), pushType: nil)
            print("[card] started new card \(started.id.suffix(6))")
            lastSent = state
            lastSentAt = Date()
            attach(started)
        } catch {
            print("[LiveActivity] Could not start: \(error)")
        }
    }

    /// Queues an update. Updates are sent one at a time and only the newest pending state is sent,
    /// so fast skipping can never create duplicates or deliver lines out of order.
    func update(_ state: LyricsAttributes.ContentState) {
        guard activity != nil else { return }
        pending = state
        sendPending()
    }

    /// Re-sends the current card if it hasn't been sent for a while (e.g. a long song whose card
    /// never changes), pushing its stale date forward. Cheap; called on every tick.
    func refreshIfOld() {
        guard activity != nil, pending == nil, let current = lastSent,
              Date().timeIntervalSince(lastSentAt) > Self.refreshAfter else { return }
        pending = current
        sendPending()
    }

    func end() async {
        stateTask?.cancel()
        guard let current = activity else { return }
        activity = nil
        pending = nil
        lastSent = nil
        onActiveChange?(false)
        await current.end(nil, dismissalPolicy: .immediate)
    }

    // MARK: - Private

    /// Re-uses a card left running by a previous launch and ends any extras.
    private func adoptExisting() {
        let running = Activity<LyricsAttributes>.activities.filter {
            $0.activityState == .active || $0.activityState == .stale
        }
        guard let first = running.first else { return }
        print("[card] re-using existing card \(first.id.suffix(6)); ending \(running.count - 1) extra")
        attach(first)
        for extra in running.dropFirst() {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func attach(_ newActivity: Activity<LyricsAttributes>) {
        activity = newActivity
        onActiveChange?(true)

        // Notice when iOS ends the card (8-hour limit) or the user swipes it away.
        stateTask?.cancel()
        stateTask = Task { [weak self] in
            for await state in newActivity.activityStateUpdates where state == .ended || state == .dismissed {
                self?.detach(newActivity)
                break
            }
        }
    }

    private func detach(_ ended: Activity<LyricsAttributes>) {
        guard activity?.id == ended.id else { return }
        activity = nil
        pending = nil
        lastSent = nil
        onActiveChange?(false)
    }

    private func sendPending() {
        guard !isSending, let target = activity else { return }
        isSending = true
        Task {
            while pending != nil {
                let wait = Self.minimumSpacing - Date().timeIntervalSince(lastSentAt)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard let next = pending else { break }
                pending = nil
                let isOld = Date().timeIntervalSince(lastSentAt) > Self.refreshAfter
                guard next != lastSent || isOld else { continue }
                await target.update(content(next))
                let stamp = Date().formatted(date: .omitted, time: .standard)
                print("[card] \(stamp) sent to \(target.id.suffix(6)) [\(target.activityState)]: \(next.currentLine)")
                lastSent = next
                lastSentAt = Date()
            }
            isSending = false
        }
    }

    private func content(_ state: LyricsAttributes.ContentState) -> ActivityContent<LyricsAttributes.ContentState> {
        ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter), relevanceScore: 100)
    }
}
