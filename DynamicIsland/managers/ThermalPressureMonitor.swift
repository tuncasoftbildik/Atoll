/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

// Thermal pressure reading adapted from MacThrottle (MIT, Copyright (c) 2025 Stanislas):
// https://github.com/angristan/MacThrottle

import AppKit
import AtollExtensionKit
import Defaults
import Foundation

/// Watches the system thermal pressure level and shows a live activity in the
/// notch while the Mac is being throttled (heavy or critical pressure).
///
/// `ProcessInfo.thermalState` folds "moderate" and "heavy" into `.fair`, but heavy
/// is where throttling actually starts, so the private Darwin notification
/// `com.apple.system.thermalpressurelevel` is read instead.
///
/// The activity is rendered through the extension live-activity pipeline under
/// an internal bundle identifier, which keeps this feature out of the notch view
/// code and makes it easy to carry across upstream merges.
@MainActor
final class ThermalPressureMonitor {
    static let shared = ThermalPressureMonitor()

    enum Level: Int, Comparable {
        case nominal = 0, moderate, heavy, critical

        init(rawState: UInt64) {
            switch rawState {
            case 0: self = .nominal
            case 1: self = .moderate
            case 2: self = .heavy
            default: self = .critical
            }
        }

        var isThrottling: Bool { self >= .heavy }

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    static let bundleIdentifier = "com.Ebullioscopic.Atoll.thermal"
    private static let activityID = "thermal-pressure"
    private static let pollInterval: TimeInterval = 5
    private static let recoveryVisibleFor: TimeInterval = 6

    private let liveActivityManager = ExtensionLiveActivityManager.shared
    private let authorizationManager = ExtensionAuthorizationManager.shared

    private var token: Int32 = 0
    private var isRegistered = false
    private var timer: Timer?
    private var dismissWorkItem: DispatchWorkItem?
    private lazy var sensorCollector = CPUSensorCollector()

    private(set) var level: Level = .nominal
    private var throttleStartedAt: Date?
    private var isShowingActivity = false

    private init() {}

    func start() {
        guard timer == nil else { return }
        if !isRegistered {
            isRegistered = thermalNotifyRegisterCheck("com.apple.system.thermalpressurelevel", &token) == thermalNotifyStatusOK
        }
        guard isRegistered else {
            Logger.log("Thermal pressure notification unavailable", category: .extensions)
            return
        }
        ensureAuthorization()
        tick()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        dismissActivity()
        throttleStartedAt = nil
        level = .nominal
    }

    // MARK: - Reading

    private func readLevel() -> Level? {
        // Lets the feature be tried without heating the Mac:
        // `defaults write com.Ebullioscopic.Atoll thermalPressureDebugOverride -int 2`
        let override = Defaults[.thermalPressureDebugOverride]
        if override >= 0 { return Level(rawState: UInt64(override)) }

        var state: UInt64 = 0
        guard thermalNotifyGetState(token, &state) == thermalNotifyStatusOK else { return nil }
        return Level(rawState: state)
    }

    private func tick() {
        guard Defaults[.enableThermalPressureAlerts] else {
            if isShowingActivity || throttleStartedAt != nil { stop() }
            return
        }
        guard let newLevel = readLevel() else { return }
        let oldLevel = level
        level = newLevel

        if newLevel.isThrottling {
            if !oldLevel.isThrottling || throttleStartedAt == nil {
                throttleStartedAt = Date()
            }
            // Re-present on entering or escalating so the sneak peek fires.
            let escalated = newLevel > oldLevel
            showThrottling(level: newLevel, representing: escalated || !isShowingActivity)
        } else if let startedAt = throttleStartedAt {
            throttleStartedAt = nil
            let duration = Date().timeIntervalSince(startedAt)
            recordThrottled(seconds: duration)
            showRecovery(after: duration)
        }
    }

    private func currentTemperature() -> Double? {
        sensorCollector.readTemperature().celsius
    }

    // MARK: - Presentation

    private func showThrottling(level: Level, representing: Bool) {
        dismissWorkItem?.cancel()
        let isCritical = level == .critical
        let color: AtollColorDescriptor = isCritical
            ? AtollColorDescriptor(red: 1, green: 0.27, blue: 0.23)
            : AtollColorDescriptor(red: 1, green: 0.62, blue: 0.04)
        let tempText = currentTemperature().map { String(format: "%.0f°", $0) } ?? (isCritical ? "!" : "")
        let elapsed = throttleStartedAt.map { Self.durationText(Date().timeIntervalSince($0)) } ?? ""
        let title = isCritical ? "Mac ciddi şekilde yavaşlatılıyor" : "Mac ısındı, yavaşlatılıyor"

        let descriptor = AtollLiveActivityDescriptor(
            id: Self.activityID,
            bundleIdentifier: Self.bundleIdentifier,
            priority: isCritical ? .critical : .high,
            title: title,
            subtitle: elapsed.isEmpty ? nil : "\(elapsed) sürüyor",
            leadingIcon: .symbol(name: isCritical ? "thermometer.sun.fill" : "thermometer.high", size: 15, weight: .semibold),
            trailingContent: tempText.isEmpty ? .none : .text(tempText, font: .monospacedDigit(size: 12, weight: .semibold), color: color),
            accentColor: color,
            allowsMusicCoexistence: true,
            sneakPeekConfig: .standard(duration: 3),
            sneakPeekTitle: title,
            sneakPeekSubtitle: tempText.isEmpty ? nil : "İşlemci \(tempText)"
        )
        present(descriptor, fresh: representing)
    }

    private func showRecovery(after duration: TimeInterval) {
        let green = AtollColorDescriptor(red: 0.2, green: 0.78, blue: 0.35)
        let descriptor = AtollLiveActivityDescriptor(
            id: Self.activityID,
            bundleIdentifier: Self.bundleIdentifier,
            // Short-lived; must win over other activities (e.g. Claude sessions) to be seen
            priority: .high,
            title: "Isı normale döndü",
            subtitle: "\(Self.durationText(duration)) sürdü",
            leadingIcon: .symbol(name: "thermometer.low", size: 15, weight: .semibold),
            trailingContent: .icon(.symbol(name: "checkmark", size: 12, weight: .bold)),
            accentColor: green,
            allowsMusicCoexistence: true,
            sneakPeekConfig: .standard(duration: 3),
            sneakPeekTitle: "Isı normale döndü",
            sneakPeekSubtitle: "\(Self.durationText(duration)) sürdü · bugün toplam \(Self.durationText(todayThrottledSeconds()))"
        )
        present(descriptor, fresh: true)

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.dismissActivity() }
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.recoveryVisibleFor, execute: work)
    }

    private func present(_ descriptor: AtollLiveActivityDescriptor, fresh: Bool) {
        ensureAuthorization()
        do {
            if fresh || !isShowingActivity {
                liveActivityManager.dismiss(activityID: Self.activityID, bundleIdentifier: Self.bundleIdentifier)
                try liveActivityManager.present(descriptor: descriptor, bundleIdentifier: Self.bundleIdentifier)
            } else {
                try liveActivityManager.update(descriptor: descriptor, bundleIdentifier: Self.bundleIdentifier)
            }
            isShowingActivity = true
        } catch {
            Logger.log("Thermal activity could not be shown: \(error.localizedDescription)", category: .extensions)
        }
    }

    private func dismissActivity() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        guard isShowingActivity else { return }
        liveActivityManager.dismiss(activityID: Self.activityID, bundleIdentifier: Self.bundleIdentifier)
        isShowingActivity = false
    }

    private func ensureAuthorization() {
        let entry = authorizationManager.ensureEntryExists(bundleIdentifier: Self.bundleIdentifier, appName: "Isı Baskısı")
        if !entry.isAuthorized {
            authorizationManager.authorize(bundleIdentifier: Self.bundleIdentifier, appName: "Isı Baskısı")
        }
    }

    // MARK: - Daily total

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func recordThrottled(seconds: TimeInterval) {
        let today = Self.dayFormatter.string(from: Date())
        if Defaults[.thermalThrottledDay] != today {
            Defaults[.thermalThrottledDay] = today
            Defaults[.thermalThrottledSecondsToday] = 0
        }
        Defaults[.thermalThrottledSecondsToday] += seconds
    }

    private func todayThrottledSeconds() -> TimeInterval {
        Defaults[.thermalThrottledDay] == Self.dayFormatter.string(from: Date())
            ? Defaults[.thermalThrottledSecondsToday]
            : 0
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(max(total, 1)) sn" }
        if total < 3600 { return "\(total / 60) dk" }
        return "\(total / 3600) sa \((total % 3600) / 60) dk"
    }
}

@_silgen_name("notify_register_check")
private func thermalNotifyRegisterCheck(_ name: UnsafePointer<CChar>, _ token: UnsafeMutablePointer<Int32>) -> UInt32

@_silgen_name("notify_get_state")
private func thermalNotifyGetState(_ token: Int32, _ state: UnsafeMutablePointer<UInt64>) -> UInt32

private let thermalNotifyStatusOK: UInt32 = 0
