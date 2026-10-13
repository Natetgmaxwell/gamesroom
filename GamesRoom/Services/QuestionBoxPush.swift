//
//  QuestionBoxPush.swift
//  GamesRoom
//
//  V0.106 — reader-only APNs plumbing (spec §1.4, steer #2). Mirrors
//  Felt Faction's PushNotificationManager: register for remote
//  notifications, upsert the token via `register_device_token`
//  (migration 097), and route a tapped "You're asking" push to the
//  reader card. The sender (`question-turn-push`) sends to exactly one
//  user: the turn's reader. Nothing here can address anyone else.
//
//  Also the AVFoundation side of the speaking light.
//

import AVFoundation
import UIKit
import UserNotifications

// MARK: - App delegate

final class GamesRoomAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Set by `GamesRoomApp` once the service exists.
    @MainActor static weak var questionBox: QuestionBoxService?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        #if DEBUG
        let sandbox = true
        #else
        let sandbox = false
        #endif
        Task { @MainActor in
            await Self.questionBox?.registerDeviceToken(token, sandbox: sandbox)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No APNs on the simulator without a paired device, or no
        // entitlement on this build: local notifications still work.
    }

    /// Foreground: a question turn is shown by the in-app card (realtime
    /// / poll), so its banner is suppressed. Everything else keeps the
    /// pre-V0.106 behaviour (no foreground banners).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if let eventId = Self.questionTurnEventId(notification.request.content.userInfo) {
            await MainActor.run { Task { await Self.questionBox?.refreshTurn(eventId: eventId) } }
        }
        return []
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let eventId = Self.questionTurnEventId(response.notification.request.content.userInfo) else { return }
        await Self.questionBox?.refreshTurn(eventId: eventId)
    }

    static func questionTurnEventId(_ userInfo: [AnyHashable: Any]) -> UUID? {
        guard userInfo["type"] as? String == "question_turn",
              let raw = userInfo["event_id"] as? String else { return nil }
        return UUID(uuidString: raw)
    }
}

enum QuestionBoxPushRegistration {
    /// Ask APNs for a token once we have a signed-in user. Alert
    /// permission is requested by the existing NotificationDispatcher
    /// flow; the token is useful regardless (the push is silent to the
    /// user until they grant alerts).
    @MainActor
    static func registerIfPossible() {
        #if DEBUG
        if CommandLine.arguments.contains("-screenshots-bypass-auth") { return }
        #endif
        UIApplication.shared.registerForRemoteNotifications()
    }
}

// MARK: - Torch

/// `TorchControlling` over the back camera torch. Fails soft: no
/// torch (iPad), torch in use, or lock failure → `setOn` returns false.
final class AVTorch: TorchControlling {
    private var device: AVCaptureDevice? {
        AVCaptureDevice.default(for: .video)
    }

    var hasTorch: Bool {
        guard let device else { return false }
        return device.hasTorch && device.isTorchAvailable
    }

    func setOn(level: Float) -> Bool {
        guard let device, device.hasTorch, device.isTorchAvailable, !device.isTorchActive else { return false }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            try device.setTorchModeOn(level: min(max(level, 0.01), AVCaptureDevice.maxAvailableTorchLevel))
            return true
        } catch {
            return false
        }
    }

    func setOff() {
        guard let device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = .off
            device.unlockForConfiguration()
        } catch {}
    }
}
