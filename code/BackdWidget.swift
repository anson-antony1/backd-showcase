// Copied verbatim from the private Backd repo: targets/widget/BackdWidget.swift
// Reproduced unmodified for reference. Nothing was redacted — this file
// contains no credentials; every secret is read at runtime from the
// environment (Supabase secrets / App Group storage).

// Backd Home/Lock Screen widget (WidgetKit).
//
// A mini accountability command center. Reads a privacy-safe JSON payload the app
// writes into the shared App Group (group.com.anson.lockin) — keys match
// src/services/widgetBridge.ts `toPayload`. The app has already applied the user's
// privacy level, so every string here is safe to render on a Home/Lock Screen.
// The widget never reaches into app data and never crashes on missing/partial data.

import WidgetKit
import SwiftUI

private let appGroup = "group.com.anson.lockin"
private let payloadKey = "backd.widget.payload"

// MARK: - Payload (keys mirror widgetBridge.ts)

struct UpcomingItem: Decodable, Identifiable {
  let label: String
  let time: String
  let state: String      // completed | needs_proof | overdue | due_soon | pending
  let atRisk: Bool
  var id: String { "\(label)-\(time)-\(state)" }
}

struct BackdPayload: Decodable {
  let score: Int
  let statusLabel: String
  let streak: Int
  let longestStreak: Int
  let riskLabel: String
  let riskState: String
  let hasGoals: Bool
  let todayTotal: Int
  let todayDone: Int
  let todayRemaining: Int
  let todayPct: Int
  let nextLabel: String
  let nextTime: String
  let nextProofRequired: Bool
  let headline: String
  let body: String
  let upcoming: [UpcomingItem]
  let updatedAt: String

  var allDone: Bool { todayTotal > 0 && todayRemaining == 0 }
}

extension BackdPayload {
  /// Representative content shown in the widget gallery + while real data loads
  /// (Apple HIG: previews should show realistic content, not an empty state).
  static let sample = BackdPayload(
    score: 78, statusLabel: "Locked In", streak: 6, longestStreak: 14,
    riskLabel: "Due soon", riskState: "medium", hasGoals: true,
    todayTotal: 4, todayDone: 1, todayRemaining: 3, todayPct: 25,
    nextLabel: "Gym workout", nextTime: "6:30 PM", nextProofRequired: true,
    headline: "Gym workout", body: "Due 6:30 PM",
    upcoming: [
      UpcomingItem(label: "Gym workout", time: "6:30 PM", state: "due_soon", atRisk: true),
      UpcomingItem(label: "Read 20 pages", time: "9:00 PM", state: "pending", atRisk: false),
      UpcomingItem(label: "Morning run", time: "7:00 AM", state: "overdue", atRisk: false),
      UpcomingItem(label: "Meditate", time: "10:00 PM", state: "pending", atRisk: false),
    ],
    updatedAt: ""
  )
}

// MARK: - Brand

private extension Color {
  static let bViolet = Color(red: 0.486, green: 0.361, blue: 1.0)
  static let bVioletSoft = Color(red: 0.62, green: 0.52, blue: 1.0)
  static let bAmber  = Color(red: 1.0,   green: 0.72,  blue: 0.30)
  static let bGreen  = Color(red: 0.27,  green: 0.82,  blue: 0.52)
  static let bRed    = Color(red: 1.0,   green: 0.42,  blue: 0.42)
  static let bBG     = Color(red: 0.055, green: 0.055, blue: 0.086) // #0E0E16
  static let bBGTop  = Color(red: 0.098, green: 0.082, blue: 0.165) // violet-tinted top
}

/// Shared Home Screen backdrop: a quiet violet-tinted vertical gradient instead
/// of a flat fill — matches the app's elevated-surface look.
private let homeGradient = LinearGradient(
  colors: [.bBGTop, .bBG],
  startPoint: .top, endPoint: .bottom
)

private func stateColor(_ s: String) -> Color {
  switch s {
  case "completed": return .bGreen
  case "overdue", "needs_proof": return .bRed
  case "due_soon": return .bAmber
  default: return .bViolet
  }
}
private func stateGlyph(_ s: String) -> String {
  switch s {
  case "completed": return "checkmark.circle.fill"
  case "overdue": return "exclamationmark.triangle.fill"
  case "needs_proof": return "arrow.uturn.backward.circle.fill"
  case "due_soon": return "clock.fill"
  default: return "circle"
  }
}
private func riskColor(_ s: String) -> Color {
  switch s {
  case "high": return .bRed
  case "medium": return .bAmber
  case "low": return .bViolet
  default: return .bGreen
  }
}

private extension View {
  // containerBackground is required on iOS 17+; a plain background covers iOS 16.
  @ViewBuilder func homeBG() -> some View {
    if #available(iOS 17.0, *) { containerBackground(homeGradient, for: .widget) }
    else { background(homeGradient) }
  }
  @ViewBuilder func clearBG() -> some View {
    if #available(iOS 17.0, *) { containerBackground(.clear, for: .widget) } else { self }
  }
}

// MARK: - Reusable pieces

struct Ring: View {
  let pct: Int
  let color: Color
  let lineWidth: CGFloat
  let label: String
  let sub: String?
  var body: some View {
    ZStack {
      Circle().stroke(Color.white.opacity(0.10), lineWidth: lineWidth)
      Circle()
        .trim(from: 0, to: max(0, min(1, Double(pct) / 100)))
        .stroke(
          AngularGradient(
            colors: [color.opacity(0.65), color],
            center: .center,
            startAngle: .degrees(0),
            endAngle: .degrees(360.0 * max(0.05, min(1, Double(pct) / 100)))
          ),
          style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        )
        .rotationEffect(.degrees(-90))
        .shadow(color: color.opacity(0.45), radius: 3)
      VStack(spacing: 0) {
        Text(label).font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundColor(.white).minimumScaleFactor(0.6)
        if let sub = sub { Text(sub).font(.system(size: 9, weight: .semibold)).foregroundColor(.white.opacity(0.55)) }
      }
    }
  }
}

/// Streak indicator as a proper chip (amber-dim pill) instead of a floating
/// emoji + number.
struct StreakChip: View {
  let streak: Int
  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: "flame.fill").font(.system(size: 9, weight: .bold)).foregroundColor(.bAmber)
      Text("\(streak)").font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundColor(.bAmber)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Capsule().fill(Color.bAmber.opacity(0.14)))
  }
}

struct UpcomingRow: View {
  let item: UpcomingItem
  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: stateGlyph(item.state)).font(.system(size: 12, weight: .bold)).foregroundColor(stateColor(item.state))
      Text(item.label).font(.system(size: 12, weight: .semibold)).foregroundColor(.white).lineLimit(1)
      Spacer(minLength: 4)
      if item.atRisk { Image(systemName: "flame.fill").font(.system(size: 9)).foregroundColor(.bAmber) }
      if !item.time.isEmpty {
        Text(item.time)
          .font(.system(size: 10, weight: .semibold, design: .rounded))
          .foregroundColor(.white.opacity(0.7))
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Capsule().fill(Color.white.opacity(0.08)))
      }
    }
  }
}

// MARK: - States

struct EmptyState: View {
  let small: Bool
  var body: some View {
    VStack(spacing: small ? 5 : 8) {
      Image(systemName: "lock.fill").font(.system(size: small ? 22 : 30)).foregroundColor(.bViolet)
      Text("No goals yet").font(.system(size: small ? 14 : 16, weight: .bold)).foregroundColor(.white)
      Text("Create your first lock").font(.system(size: small ? 11 : 13)).foregroundColor(.white.opacity(0.6)).multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct NoSync: View {
  var body: some View {
    VStack(spacing: 6) {
      Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 22)).foregroundColor(.bViolet)
      Text("Open Backd to sync").font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.6))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Home screen sizes

struct SmallView: View {
  let p: BackdPayload
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top) {
        Ring(pct: p.todayPct, color: p.allDone ? .bGreen : riskColor(p.riskState), lineWidth: 7, label: "\(p.todayPct)%", sub: nil)
          .frame(width: 54, height: 54)
        Spacer()
        StreakChip(streak: p.streak)
      }
      Spacer(minLength: 6)
      Text(p.allDone ? "Locked in today" : "\(p.todayRemaining) left")
        .font(.system(size: 16, weight: .heavy)).foregroundColor(.white).lineLimit(1).minimumScaleFactor(0.8)
      if !p.allDone, !p.nextTime.isEmpty {
        HStack(spacing: 4) {
          Image(systemName: "clock.fill").font(.system(size: 9)).foregroundColor(stateColor(p.upcoming.first?.state ?? "pending"))
          Text(p.nextProofRequired ? "Proof \(p.nextTime)" : "Next \(p.nextTime)")
            .font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.65)).lineLimit(1)
        }
      } else if p.allDone {
        Text(p.streak > 0 ? "Streak alive" : "Nice work").font(.system(size: 11, weight: .semibold)).foregroundColor(.bGreen)
      } else {
        Text("Nothing due").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.5))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }
}

struct MediumView: View {
  let p: BackdPayload
  var body: some View {
    HStack(spacing: 14) {
      VStack(spacing: 6) {
        Ring(pct: p.todayPct, color: p.allDone ? .bGreen : riskColor(p.riskState), lineWidth: 8, label: "\(p.todayDone)/\(p.todayTotal)", sub: "done")
          .frame(width: 68, height: 68)
        StreakChip(streak: p.streak)
      }
      VStack(alignment: .leading, spacing: 6) {
        Text(p.allDone ? "Locked in today" : "\(p.todayRemaining) to go")
          .font(.system(size: 15, weight: .heavy)).foregroundColor(.white)
        if p.upcoming.isEmpty {
          Text(p.allDone ? "All proof submitted." : "Nothing due right now.")
            .font(.system(size: 12)).foregroundColor(.white.opacity(0.55))
        } else {
          ForEach(p.upcoming.prefix(3)) { UpcomingRow(item: $0) }
        }
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct LargeView: View {
  let p: BackdPayload
  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 1) {
          Text("TODAY").font(.system(size: 11, weight: .bold)).foregroundColor(.bViolet).tracking(1.6)
          Text(p.allDone ? "Locked in" : "\(p.todayRemaining) left").font(.system(size: 24, weight: .heavy)).foregroundColor(.white)
        }
        Spacer()
        Ring(pct: p.todayPct, color: p.allDone ? .bGreen : riskColor(p.riskState), lineWidth: 9, label: "\(p.todayPct)%", sub: "\(p.todayDone)/\(p.todayTotal)")
          .frame(width: 66, height: 66)
      }
      if !p.riskLabel.isEmpty, p.riskState != "none" {
        HStack(spacing: 6) {
          Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundColor(riskColor(p.riskState))
          Text(p.riskLabel).font(.system(size: 12, weight: .semibold)).foregroundColor(riskColor(p.riskState))
        }
      }
      Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
      if p.upcoming.isEmpty {
        Spacer()
        VStack(spacing: 6) {
          Image(systemName: p.allDone ? "checkmark.seal.fill" : "moon.zzz.fill").font(.system(size: 28)).foregroundColor(p.allDone ? .bGreen : .white.opacity(0.4))
          Text(p.allDone ? "Everything handled" : "Nothing due today").font(.system(size: 14, weight: .semibold)).foregroundColor(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        Spacer()
      } else {
        Text("DUE TODAY").font(.system(size: 10, weight: .bold)).foregroundColor(.white.opacity(0.4)).tracking(1.4)
        VStack(spacing: 10) { ForEach(p.upcoming.prefix(4)) { UpcomingRow(item: $0) } }
        Spacer(minLength: 0)
      }
      HStack(spacing: 12) {
        StreakChip(streak: p.streak)
        Text("day streak").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.5))
        Spacer()
        Text("Score \(p.score)")
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .foregroundColor(.bVioletSoft)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Capsule().fill(Color.bViolet.opacity(0.16)))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

// MARK: - Lock screen accessories

struct AccessoryRectView: View {
  let p: BackdPayload
  var body: some View {
    HStack(spacing: 9) {
      Gauge(value: Double(p.todayPct), in: 0...100) { Image(systemName: "lock.fill") }
        currentValueLabel: { Text("\(p.todayPct)") }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(.white)
      VStack(alignment: .leading, spacing: 1) {
        Text(p.allDone ? "Locked in today" : "\(p.todayRemaining) left today").font(.system(size: 13, weight: .semibold))
        if !p.allDone, !p.nextTime.isEmpty {
          Text(p.nextProofRequired ? "Proof by \(p.nextTime)" : "Next \(p.nextTime)").font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
          Text("🔥 \(p.streak) day streak").font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }
    }
  }
}

struct AccessoryCircView: View {
  let p: BackdPayload
  var body: some View {
    Gauge(value: Double(p.todayPct), in: 0...100) { Text("today") }
      currentValueLabel: { Text(p.todayRemaining > 0 ? "\(p.todayRemaining)" : "✓") }
      .gaugeStyle(.accessoryCircular)
  }
}

struct AccessoryInlineView: View {
  let p: BackdPayload
  var body: some View {
    if p.allDone {
      Label("Locked in · 🔥\(p.streak)", systemImage: "lock.fill")
    } else if !p.nextTime.isEmpty {
      Label("\(p.todayRemaining) left · \(p.nextTime)", systemImage: "lock.fill")
    } else {
      Label("\(p.todayRemaining) left today", systemImage: "lock.fill")
    }
  }
}

// MARK: - Entry view (family switch)

struct BackdWidgetView: View {
  @Environment(\.widgetFamily) var family
  var entry: BackdEntry

  var body: some View {
    switch family {
    case .accessoryCircular:
      circular.clearBG()
    case .accessoryRectangular:
      rectangular.clearBG()
    case .accessoryInline:
      inline
    default:
      home.homeBG()
    }
  }

  @ViewBuilder private var home: some View {
    Group {
      if let p = entry.payload {
        if p.hasGoals {
          switch family {
          case .systemLarge:  LargeView(p: p)
          case .systemMedium: MediumView(p: p)
          default:            SmallView(p: p)
          }
        } else {
          EmptyState(small: family == .systemSmall)
        }
      } else {
        NoSync()
      }
    }
    .padding(family == .systemLarge ? 16 : 14)
  }

  @ViewBuilder private var circular: some View {
    if let p = entry.payload { AccessoryCircView(p: p) }
    else { Gauge(value: 0, in: 0...100) { Image(systemName: "lock.fill") } currentValueLabel: { Text("–") }.gaugeStyle(.accessoryCircular) }
  }
  @ViewBuilder private var rectangular: some View {
    if let p = entry.payload { AccessoryRectView(p: p) } else { Label("Open Backd to sync", systemImage: "lock.fill") }
  }
  @ViewBuilder private var inline: some View {
    if let p = entry.payload { AccessoryInlineView(p: p) } else { Label("Backd", systemImage: "lock.fill") }
  }
}

// MARK: - Timeline

struct BackdEntry: TimelineEntry {
  let date: Date
  let payload: BackdPayload?
}

struct BackdProvider: TimelineProvider {
  func placeholder(in context: Context) -> BackdEntry { BackdEntry(date: Date(), payload: .sample) }

  func getSnapshot(in context: Context, completion: @escaping (BackdEntry) -> Void) {
    // In the gallery (isPreview) show a representative sample; otherwise real data.
    let payload = context.isPreview ? (readPayload() ?? .sample) : readPayload()
    completion(BackdEntry(date: Date(), payload: payload))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<BackdEntry>) -> Void) {
    let entry = BackdEntry(date: Date(), payload: readPayload())
    // Refresh ~hourly; the app force-reloads on check-in/proof/goal/settings changes.
    let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date().addingTimeInterval(3600)
    completion(Timeline(entries: [entry], policy: .after(next)))
  }

  private func readPayload() -> BackdPayload? {
    guard
      let defaults = UserDefaults(suiteName: appGroup),
      let raw = defaults.string(forKey: payloadKey),
      let data = raw.data(using: .utf8)
    else { return nil }
    return try? JSONDecoder().decode(BackdPayload.self, from: data)
  }
}

// MARK: - Widget

@main
struct BackdWidget: Widget {
  let kind = "BackdWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: BackdProvider()) { entry in
      BackdWidgetView(entry: entry)
        .widgetURL(URL(string: "backd://today"))
    }
    .configurationDisplayName("Backd")
    .description("Today's goals, proof due, streak, and what's at risk — at a glance.")
    .supportedFamilies([
      .systemSmall, .systemMedium, .systemLarge,
      .accessoryCircular, .accessoryRectangular, .accessoryInline,
    ])
  }
}
