// Copied verbatim from the private Backd repo: modules/screen-time/ios/ScreenTimeModule.swift
// Reproduced unmodified for reference. Nothing was redacted — this file
// contains no credentials; every secret is read at runtime from the
// environment (Supabase secrets / App Group storage).

// =============================================================================
// ScreenTimeModule — main-app side of the Backd "Focus Vault" (Slice 7).
//
// Exposes Apple's Screen Time stack (FamilyControls + ManagedSettings +
// DeviceActivity) to JS through expo-modules-core. The companion
// DeviceActivityMonitor extension (targets/screentime) applies/clears the shield
// at scheduled window boundaries; this module handles the foreground flows:
// authorization, the app picker, and manual / until-proof arm + disarm.
//
// THREE STRINGS ARE THE ENTIRE APP↔EXTENSION CONTRACT — they MUST stay identical
// to the extension's:
//   • App Group     "group.com.anson.lockin"
//   • selection key "focusSelection"  (App Group UserDefaults)
//   • store name    "focusVault"      (ManagedSettingsStore)
//
// HARD GUARDRAIL (§9 no-trap, overrides everything): the user is NEVER trapped.
//   • We NEVER set denyAppRemoval / denyAppInstallation / any account or passcode
//     lock — nothing here can block uninstalling the app or deleting the account.
//   • `disarmAll` / `clearShield` are NOT gated on authorization or availability —
//     clearing a shield must always succeed (it's the user's escape hatch).
//   • ManagedSettingsStore restrictions SURVIVE app deletion, so JS calls
//     `disarmAll` on disarm, sign-out, and account deletion to avoid an orphaned
//     shield with no app left to lift it.
//
// PRIVACY: the FamilyActivitySelection token blob is OPAQUE. We encode/decode it
// as a black box and only ever surface COUNTS to JS — never decode, log, or
// transmit the tokens.
//
// Family Controls is iOS 16+ and PHYSICAL DEVICE only (the simulator throws
// FamilyControlsError code 3). Everything degrades to a safe no-op otherwise.
// =============================================================================

import ExpoModulesCore
import Foundation

#if canImport(FamilyControls)
import FamilyControls
import ManagedSettings
import DeviceActivity
import SwiftUI
import UIKit
#endif

// MARK: - Shared contract (must match the DeviceActivityMonitor extension)
private enum FocusConstants {
  static let appGroup     = "group.com.anson.lockin"
  static let selectionKey = "focusSelection"
  static let storeName    = "focusVault"
  static let activityName  = "focusSchedule"

  static var appGroupDefaults: UserDefaults? { UserDefaults(suiteName: appGroup) }
}

public final class ScreenTimeModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ScreenTime")

    Events("onAuthorizationChange")

    // True only on a physical iOS 16+ device. No-op everywhere else.
    Function("isSupported") { () -> Bool in Self.isAvailable }

    // Synchronous status read — never prompts. "unavailable" off-device / pre-16.
    Function("getAuthorizationStatus") { () -> String in
      guard Self.isAvailable else { return "unavailable" }
      if #available(iOS 16.0, *) { return FocusAuth.statusString() }
      return "unavailable"
    }

    // Counts for the currently-saved selection (so the UI can show "12 apps
    // shielded" after a relaunch without re-opening the picker). Zeros if none.
    Function("getSelectionSummary") { () -> [String: Int] in
      guard Self.isAvailable, #available(iOS 16.0, *),
            let sel = FocusStore.loadSelection() else {
        return ["applications": 0, "categories": 0, "webDomains": 0]
      }
      return [
        "applications": sel.applicationTokens.count,
        "categories": sel.categoryTokens.count,
        "webDomains": sel.webDomainTokens.count,
      ]
    }

    // Prompt for Screen Time authorization (async/throws on device).
    AsyncFunction("requestAuthorization") { (promise: Promise) in
      guard Self.isAvailable else {
        promise.reject("E_UNSUPPORTED", "Screen Time needs a physical iOS 16+ device.")
        return
      }
      if #available(iOS 16.0, *) {
        Task {
          do {
            let status = try await FocusAuth.request()
            self.sendEvent("onAuthorizationChange", ["status": status])
            promise.resolve(status)
          } catch {
            promise.reject("E_AUTH_FAILED", error.localizedDescription)
          }
        }
      } else {
        promise.reject("E_UNSUPPORTED", "Requires iOS 16+.")
      }
    }

    // Present FamilyActivityPicker modally; on Done, persist the selection to the
    // App Group and resolve with counts. On Cancel, resolve { cancelled: true }.
    AsyncFunction("presentPicker") { (promise: Promise) in
      guard Self.isAvailable else {
        promise.reject("E_UNSUPPORTED", "Screen Time needs a physical iOS 16+ device.")
        return
      }
      if #available(iOS 16.0, *) {
        Task { @MainActor in Self.presentPicker(promise) }
      } else {
        promise.reject("E_UNSUPPORTED", "Requires iOS 16+.")
      }
    }

    // Apply the saved selection as a shield right now (manual / until-proof modes).
    Function("applyShield") { () -> Bool in
      guard Self.isAvailable, #available(iOS 16.0, *) else { return false }
      FocusShield.apply()
      return true
    }

    // Lift the shield. UNGATED — clearing must always be attempted.
    Function("clearShield") { () -> Bool in
      if #available(iOS 16.0, *) { FocusShield.clear() }
      return true
    }

    // Start a recurring daily [start, end) window; the extension shields at the
    // boundaries. Hours/minutes are local time.
    AsyncFunction("startSchedule") { (startHour: Int, startMinute: Int, endHour: Int, endMinute: Int, promise: Promise) in
      guard Self.isAvailable else {
        promise.reject("E_UNSUPPORTED", "Screen Time needs a physical iOS 16+ device.")
        return
      }
      if #available(iOS 16.0, *) {
        do {
          try FocusSchedule.start(startHour: startHour, startMinute: startMinute, endHour: endHour, endMinute: endMinute)
          promise.resolve(true)
        } catch {
          promise.reject("E_SCHEDULE_FAILED", error.localizedDescription)
        }
      } else {
        promise.reject("E_UNSUPPORTED", "Requires iOS 16+.")
      }
    }

    Function("stopSchedule") { () -> Bool in
      if #available(iOS 16.0, *) { FocusSchedule.stop() }
      return true
    }

    // The panic button JS calls on disarm / sign-out / account deletion. UNGATED.
    Function("disarmAll") { () -> Bool in
      if #available(iOS 16.0, *) { FocusDisarm.everything() }
      return true
    }
  }

  /// Family Controls is functional only on a real device with iOS 16+.
  static var isAvailable: Bool {
    guard #available(iOS 16.0, *) else { return false }
    #if targetEnvironment(simulator)
    return false
    #else
    return true
    #endif
  }
}

#if canImport(FamilyControls)

// MARK: - Authorization
@available(iOS 16.0, *)
private enum FocusAuth {
  static func statusString() -> String {
    switch AuthorizationCenter.shared.authorizationStatus {
    case .notDetermined: return "notDetermined"
    case .denied:        return "denied"
    case .approved:      return "approved"
    @unknown default:    return "notDetermined"
    }
  }

  /// iOS 16+ async/throws form. `.individual` = manage THIS device.
  static func request() async throws -> String {
    try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
    return statusString()
  }
}

// MARK: - Selection persistence (shared with the extension; tokens stay opaque)
@available(iOS 16.0, *)
private enum FocusStore {
  static func saveSelection(_ selection: FamilyActivitySelection) {
    guard let defaults = FocusConstants.appGroupDefaults,
          let data = try? JSONEncoder().encode(selection) else { return }
    defaults.set(data, forKey: FocusConstants.selectionKey)
  }

  static func loadSelection() -> FamilyActivitySelection? {
    guard let defaults = FocusConstants.appGroupDefaults,
          let data = defaults.data(forKey: FocusConstants.selectionKey) else { return nil }
    return try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
  }

  static func clearSelection() {
    FocusConstants.appGroupDefaults?.removeObject(forKey: FocusConstants.selectionKey)
  }
}

// MARK: - Shield (manual modes) — named store shared with the extension
@available(iOS 16.0, *)
private enum FocusShield {
  private static var store: ManagedSettingsStore {
    ManagedSettingsStore(named: ManagedSettingsStore.Name(FocusConstants.storeName))
  }

  static func apply() {
    guard let selection = FocusStore.loadSelection() else { return }
    let s = store
    s.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
    s.shield.applicationCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
    s.shield.webDomains = selection.webDomainTokens.isEmpty ? nil : selection.webDomainTokens
  }

  /// Lift the shield entirely. SAFE to call any time — fully reversible.
  static func clear() {
    store.clearAllSettings()
  }
}

// MARK: - Schedule (recurring windows → extension interval callbacks)
@available(iOS 16.0, *)
private enum FocusSchedule {
  private static let center = DeviceActivityCenter()
  private static let activity = DeviceActivityName(FocusConstants.activityName)

  static func start(startHour: Int, startMinute: Int, endHour: Int, endMinute: Int) throws {
    let schedule = DeviceActivitySchedule(
      intervalStart: DateComponents(hour: startHour, minute: startMinute),
      intervalEnd: DateComponents(hour: endHour, minute: endMinute),
      repeats: true
    )
    try center.startMonitoring(activity, during: schedule)
  }

  static func stop() {
    center.stopMonitoring([activity])
  }
}

// MARK: - Full disarm (the §9 escape — call on disarm / sign-out / delete)
@available(iOS 16.0, *)
private enum FocusDisarm {
  static func everything() {
    FocusSchedule.stop()
    FocusShield.clear()
    FocusStore.clearSelection()
  }
}

// MARK: - Picker presentation
@available(iOS 16.0, *)
extension ScreenTimeModule {
  @MainActor
  static func presentPicker(_ promise: Promise) {
    guard AuthorizationCenter.shared.authorizationStatus == .approved else {
      promise.reject("E_NOT_AUTHORIZED", "Screen Time access hasn't been approved.")
      return
    }
    guard let presenter = topViewController() else {
      promise.reject("E_NO_PRESENTER", "No view controller available to present from.")
      return
    }

    // Single-settle guard shared by Done / Cancel / swipe-dismiss so the Promise
    // resolves exactly once (expo-modules-core asserts on a double-settle), and a
    // swipe-down dismissal can't leave the JS `await` hanging forever.
    var settled = false
    weak var weakHosting: UIHostingController<FocusPickerView>?
    func settle(_ value: [String: Any]) {
      if settled { return }
      settled = true
      weakHosting?.dismiss(animated: true)
      promise.resolve(value)
    }

    let initial = FocusStore.loadSelection() ?? FamilyActivitySelection()
    // weakHosting (not a strong capture) keeps the closures from forming a retain
    // cycle with the hosting controller (which holds these closures via its view).
    let view = FocusPickerView(
      initial: initial,
      onDone: { selection in
        FocusStore.saveSelection(selection)
        settle([
          "applications": selection.applicationTokens.count,
          "categories": selection.categoryTokens.count,
          "webDomains": selection.webDomainTokens.count,
        ])
      },
      onCancel: { settle(["cancelled": true]) }
    )
    let hosting = UIHostingController(rootView: view)
    hosting.modalPresentationStyle = .formSheet
    // Catch the interactive swipe-down dismissal (fires neither toolbar button).
    let dismissDelegate = PickerDismissDelegate { settle(["cancelled": true]) }
    hosting.presentationController?.delegate = dismissDelegate
    // presentationController.delegate is weak — keep the delegate alive for the
    // controller's lifetime (released with the controller on dismissal).
    objc_setAssociatedObject(hosting, &pickerDismissDelegateKey, dismissDelegate, .OBJC_ASSOCIATION_RETAIN)
    weakHosting = hosting
    presenter.present(hosting, animated: true)
  }

  @MainActor
  static func topViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
            ?? scene?.windows.first?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }
}

// MARK: - SwiftUI picker host
@available(iOS 16.0, *)
struct FocusPickerView: View {
  @State private var selection: FamilyActivitySelection
  let onDone: (FamilyActivitySelection) -> Void
  let onCancel: () -> Void

  init(initial: FamilyActivitySelection,
       onDone: @escaping (FamilyActivitySelection) -> Void,
       onCancel: @escaping () -> Void) {
    _selection = State(initialValue: initial)
    self.onDone = onDone
    self.onCancel = onCancel
  }

  var body: some View {
    NavigationView {
      FamilyActivityPicker(selection: $selection)
        .navigationTitle("Choose what to block")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onCancel() } }
          ToolbarItem(placement: .confirmationAction) { Button("Done") { onDone(selection) } }
        }
    }
  }
}

// Resolves the picker Promise (as "cancelled") when the sheet is dismissed by an
// interactive swipe-down, which fires neither toolbar button.
private var pickerDismissDelegateKey: UInt8 = 0

final class PickerDismissDelegate: NSObject, UIAdaptivePresentationControllerDelegate {
  private let onDismiss: () -> Void
  init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    onDismiss()
  }
}

#endif
