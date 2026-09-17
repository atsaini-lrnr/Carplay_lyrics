//
//  ContentView.swift
//  CarPlayLyrics
//
//  Main iPhone companion interface for permission handling,
//  real-time audio latency delay calibration, and live preview.
//

import SwiftUI
import MediaPlayer
import ActivityKit

struct ContentView: View {
    @StateObject private var tracker = LyricsTracker.shared
    @State private var showingInfoSheet = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    
                    // MARK: - Status & Permissions Banner
                    if !tracker.isLiveActivitySupported {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.yellow)
                            Text("Live Activities are disabled in iOS Settings. Enable them to display lyrics on CarPlay.")
                                .font(.caption)
                                .foregroundColor(.primary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.yellow.opacity(0.15))
                        .cornerRadius(12)
                    }
                    
                    // MARK: - Now Playing Card
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.purple.opacity(0.6), Color.blue.opacity(0.6)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 60, height: 60)
                                
                                Image(systemName: "music.note")
                                    .font(.title2)
                                    .foregroundColor(.white)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tracker.currentTitle)
                                    .font(.headline.bold())
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                
                                Text(tracker.currentArtist)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                
                                HStack(spacing: 8) {
                                    StatusBadge(
                                        title: tracker.isSyncedAvailable ? "Synced LRC" : (tracker.statusMessage ?? "Standby"),
                                        color: tracker.isSyncedAvailable ? .green : .orange
                                    )
                                    
                                    if tracker.isActivityActive {
                                        StatusBadge(title: "Live Activity Active", color: .blue)
                                    }
                                }
                                .padding(.top, 2)
                            }
                            Spacer()
                        }
                        
                        Divider()
                        
                        // Live Lyrics Teleprompter Preview
                        VStack(alignment: .leading, spacing: 6) {
                            Text("LIVE CARPLAY DISPLAY PREVIEW")
                                .font(.caption2.bold())
                                .foregroundColor(.secondary)
                            
                            Text(tracker.currentLine.isEmpty ? "Waiting for lyrics..." : tracker.currentLine)
                                .font(.system(size: 19, weight: .bold, design: .rounded))
                                .foregroundColor(tracker.isSyncedAvailable ? .primary : .secondary)
                                .lineLimit(2)
                                .animation(.spring(), value: tracker.currentLine)
                            
                            if let next = tracker.nextLine, !next.isEmpty {
                                Text(next)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.secondary.opacity(0.7))
                                    .lineLimit(1)
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 3)
                    
                    // MARK: - Bluetooth / CarPlay Delay Calibration Slider
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label("CarPlay Audio Sync Delay", systemImage: "timer")
                                .font(.headline)
                            Spacer()
                            Text(String(format: "%+.2f s", tracker.userDelay))
                                .font(.system(size: 16, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundColor(.accentColor)
                                .cornerRadius(8)
                        }
                        
                        Text("Wireless CarPlay and Bluetooth audio typically lag by 0.5 to 1.5 seconds. Increase delay if lyrics appear ahead of the vocal.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        // Smooth slider (-0.5s to 3.0s)
                        Slider(value: $tracker.userDelay, in: -0.5...3.0, step: 0.05)
                            .tint(.accentColor)
                        
                        // Micro adjustment buttons
                        HStack(spacing: 12) {
                            Button {
                                tracker.userDelay = max(-0.5, tracker.userDelay - 0.1)
                            } label: {
                                Label("-0.1s", systemImage: "minus")
                                    .font(.caption.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(Color(.secondarySystemBackground))
                                    .cornerRadius(8)
                            }
                            
                            Button {
                                tracker.userDelay = 0.8 // Standard Bluetooth default
                            } label: {
                                Text("Reset (0.8s)")
                                    .font(.caption.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(Color(.secondarySystemBackground))
                                    .cornerRadius(8)
                            }
                            
                            Button {
                                tracker.userDelay = min(3.0, tracker.userDelay + 0.1)
                            } label: {
                                Label("+0.1s", systemImage: "plus")
                                    .font(.caption.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(Color(.secondarySystemBackground))
                                    .cornerRadius(8)
                            }
                        }
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 3)
                    
                    // MARK: - Testing & Controls
                    VStack(alignment: .leading, spacing: 14) {
                        Text("CONTROLS & SIMULATION")
                            .font(.caption2.bold())
                            .foregroundColor(.secondary)
                        
                        Toggle(isOn: Binding(
                            get: { tracker.isDemoMode },
                            set: { newValue in
                                if newValue {
                                    tracker.enableDemoMode()
                                } else {
                                    tracker.disableDemoMode()
                                }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Xcode Simulator Demo Mode")
                                    .font(.body.weight(.medium))
                                Text("Simulates Apple Music playback with Queen lyrics")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Divider()
                        
                        Button {
                            tracker.requestMediaPermission()
                        } label: {
                            HStack {
                                Image(systemName: "music.note.house.fill")
                                Text("Connect to Apple Music Library")
                                    .fontWeight(.semibold)
                                Spacer()
                                Image(systemName: "arrow.clockwise")
                            }
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 3)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("CarPlay Lyrics")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingInfoSheet = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                }
            }
            .sheet(isPresented: $showingInfoSheet) {
                InfoSheetView()
            }
            .onAppear {
                tracker.requestMediaPermission()
            }
        }
    }
}

// MARK: - Status Badge Component
struct StatusBadge: View {
    let title: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundColor(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .cornerRadius(6)
    }
}

// MARK: - Info & Free Tier Disclosure Sheet
struct InfoSheetView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                Section("100% Free Tier Architecture") {
                    Label("No Paid CarPlay Entitlement Required (Uses ActivityKit)", systemImage: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Label("Public LRCLIB API (No API Key or Billing)", systemImage: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Label("Free Apple Developer Account Sideloading (7-day renewal)", systemImage: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Label("Zero-Volume Background Audio Loop (AVFoundation)", systemImage: "checkmark.seal.fill")
                        .foregroundColor(.green)
                }
                
                Section("CarPlay Setup Tips") {
                    Text("1. Connect iPhone to car via USB or Wireless CarPlay.")
                    Text("2. Open Apple Music and play any track.")
                    Text("3. Switch to CarPlay Dashboard (split screen with Maps). The lyrics Live Activity card will appear automatically.")
                    Text("4. Use the delay slider on your phone to calibrate for car Bluetooth latency.")
                }
            }
            .navigationTitle("System Architecture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
