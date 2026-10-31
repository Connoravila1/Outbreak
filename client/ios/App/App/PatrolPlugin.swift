import Capacitor
import CoreLocation
import UIKit
import UserNotifications

// Patrol mode on iOS (best effort: written without a Mac, see client/MOBILE.md for what to verify).
//
// CLLocationManager keeps the app running in the background (UIBackgroundModes: location) and
// delivers fixes; at most once per interval the latest fix is POSTed to /api/patrol and each
// returned event becomes a local notification. Significant-change monitoring relaunches the app
// after the system terminates it. The coordinate is held in memory only; the token and server URL
// come from the web layer at start and are erased when patrol stops.

private let defaults = UserDefaults.standard
private enum K {
    static let active = "patrol.active"
    static let url = "patrol.url"
    static let token = "patrol.token"
    static let intervalSec = "patrol.interval"
    static let endsAt = "patrol.endsAt"
    static let lastOk = "patrol.lastOk"
    static let lastError = "patrol.lastError"
}

/// The patrol worker. A singleton so it can be resumed from AppDelegate after a relaunch.
final class PatrolEngine: NSObject, CLLocationManagerDelegate {
    static let shared = PatrolEngine()

    private let manager = CLLocationManager()
    private var latest: CLLocation?
    private var lastPost = Date.distantPast
    private var failures = 0
    private var inFlight = false
    private var timer: Timer?
    private var authWaiters: [() -> Void] = []

    override init() {
        super.init()
        manager.delegate = self
    }

    var active: Bool {
        guard defaults.bool(forKey: K.active) else { return false }
        let ends = defaults.double(forKey: K.endsAt)
        return ends == 0 || ends > Date().timeIntervalSince1970 * 1000
    }

    /// True when CoreLocation says the newest fix (under a minute old) was produced by software
    /// rather than a GPS receiver (iOS 15+: `CLLocationSourceInformation.isSimulatedBySoftware`).
    /// Any doubt is false: a miss costs nothing, a false alarm costs a real player their fights.
    var simulated: Bool {
        guard let loc = manager.location ?? latest else { return false }
        return PatrolEngine.isSimulated(loc)
    }

    static func isSimulated(_ loc: CLLocation) -> Bool {
        guard #available(iOS 15.0, *), Date().timeIntervalSince(loc.timestamp) < 60 else { return false }
        return loc.sourceInformation?.isSimulatedBySoftware ?? false
    }

    var hasAlways: Bool { manager.authorizationStatus == .authorizedAlways }
    var hasFine: Bool { manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse }

    // MARK: Control

    func start(url: String, token: String, intervalSec: Int, durationSec: Int) {
        defaults.set(true, forKey: K.active)
        defaults.set(url, forKey: K.url)
        defaults.set(token, forKey: K.token)
        defaults.set(intervalSec, forKey: K.intervalSec)
        defaults.set(durationSec > 0 ? Date().timeIntervalSince1970 * 1000 + Double(durationSec) * 1000 : 0, forKey: K.endsAt)
        defaults.removeObject(forKey: K.lastError)
        failures = 0
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        run()
    }

    /// Begin (or resume after a relaunch) location updates and the check-in timer.
    func run() {
        guard defaults.bool(forKey: K.active) else { return }
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 40
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = true
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        // Relaunches the app after the system ends it, with far less power than continuous updates.
        manager.startMonitoringSignificantLocationChanges()
        timer?.invalidate()
        let every = max(10, defaults.integer(forKey: K.intervalSec))
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(every), repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func stop() {
        defaults.set(false, forKey: K.active)
        defaults.removeObject(forKey: K.token)
        defaults.removeObject(forKey: K.url)
        defaults.set(0, forKey: K.endsAt)
        timer?.invalidate()
        timer = nil
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.allowsBackgroundLocationUpdates = false
        latest = nil
    }

    func requestAlways(_ done: @escaping () -> Void) {
        if manager.authorizationStatus == .authorizedAlways { done(); return }
        authWaiters.append(done)
        // From "while using" iOS shows the Always upgrade prompt once; from "not determined" it shows both.
        manager.requestAlwaysAuthorization()
        // The prompt is not guaranteed to appear again; do not hang the web layer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.flushWaiters() }
    }

    private func flushWaiters() {
        let w = authWaiters
        authWaiters = []
        w.forEach { $0() }
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus != .notDetermined { flushWaiters() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 150 else { return }
        latest = loc
        tick()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        defaults.set("no_fix", forKey: K.lastError)
    }

    // MARK: Check-in

    private func tick() {
        guard defaults.bool(forKey: K.active) else { return }
        let ends = defaults.double(forKey: K.endsAt)
        if ends > 0 && Date().timeIntervalSince1970 * 1000 >= ends {
            stop()
            notify(title: "OUTBREAK", body: "Patrol ended. Open Outbreak to see what happened.", id: "patrol-end")
            return
        }
        let interval = TimeInterval(max(10, defaults.integer(forKey: K.intervalSec)))
        let wait = failures == 0 ? interval * 0.9 : min(600, interval * pow(2, Double(min(failures, 5))))
        guard !inFlight, Date().timeIntervalSince(lastPost) >= wait else { return }
        guard let loc = latest ?? manager.location, Date().timeIntervalSince(loc.timestamp) < 20 * 60 else {
            defaults.set("no_fix", forKey: K.lastError)
            return
        }
        post(loc)
    }

    private func post(_ loc: CLLocation) {
        guard let base = defaults.string(forKey: K.url), let token = defaults.string(forKey: K.token),
              let url = URL(string: base + "/api/patrol") else { return }
        inFlight = true
        lastPost = Date()
        var bg = UIBackgroundTaskIdentifier.invalid
        bg = UIApplication.shared.beginBackgroundTask(withName: "patrol-checkin") {
            UIApplication.shared.endBackgroundTask(bg)
            bg = .invalid
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["lat": loc.coordinate.latitude, "lon": loc.coordinate.longitude, "acc": loc.horizontalAccuracy, "mock": PatrolEngine.isSimulated(loc)]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, error in
            defer {
                if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.inFlight = false
                guard error == nil, let http = resp as? HTTPURLResponse else {
                    self.failures += 1
                    defaults.set("network", forKey: K.lastError)
                    return
                }
                switch http.statusCode {
                case 200:
                    self.failures = 0
                    defaults.set(Date().timeIntervalSince1970 * 1000, forKey: K.lastOk)
                    defaults.removeObject(forKey: K.lastError)
                    if let data = data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let events = obj["events"] as? [[String: Any]] {
                        events.forEach { self.deliver($0) }
                    }
                case 401, 403:
                    self.stop()
                    self.notify(title: "OUTBREAK", body: "Patrol stopped: you were signed out. Open Outbreak to sign in and start it again.", id: "patrol-end")
                case 409:
                    self.stop()
                    self.notify(title: "OUTBREAK", body: "Patrol stopped: finish setting up your character in Outbreak first.", id: "patrol-end")
                case 429, 500...599:
                    self.failures += 1
                    defaults.set("http_\(http.statusCode)", forKey: K.lastError)
                default:
                    defaults.set("http_\(http.statusCode)", forKey: K.lastError)
                }
            }
        }.resume()
    }

    // MARK: Notifications

    private func deliver(_ e: [String: Any]) {
        let type = e["type"] as? String ?? ""
        var text = e["text"] as? String ?? ""
        let title: String
        switch type {
        case "contact":
            title = "CONTACT"
            if let r = text.range(of: #"^CONTACT\. (A (?:Human|Zombie)), level \d+\. You (won|lost)\.$"#, options: .regularExpression) {
                let m = String(text[r])
                let who = m.contains("Zombie") ? "A Zombie" : "A Human"
                text = "\(who) found you. " + (m.hasSuffix("won.") ? "You held." : "You were beaten.")
            } else if text.hasPrefix("CONTACT. ") {
                text = String(text.dropFirst("CONTACT. ".count))
            }
        case "level_up": title = "LEVEL UP"
        case "raid": title = "RAID"
        case "echo_report": title = "ECHO"
        default: title = "OUTBREAK"
        }
        notify(title: title, body: text, id: "patrol-event-\(e["id"] as? String ?? UUID().uuidString)", timeSensitive: type == "contact")
    }

    private func notify(title: String, body: String, id: String, timeSensitive: Bool = false) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        if timeSensitive, #available(iOS 15.0, *) { c.interruptionLevel = .timeSensitive }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }
}

@objc(PatrolPlugin)
public class PatrolPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "PatrolPlugin"
    public let jsName = "Patrol"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "status", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestBackground", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openSettings", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "mockCheck", returnType: CAPPluginReturnPromise),
    ]

    private func readStatus(_ done: @escaping (JSObject) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let engine = PatrolEngine.shared
            let allowed = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
            DispatchQueue.main.async {
                let ends = defaults.double(forKey: K.endsAt)
                let active = engine.active
                done([
                    "active": active,
                    "endsAt": active ? ends : 0,
                    "intervalSec": defaults.integer(forKey: K.intervalSec),
                    "lastCheckIn": defaults.double(forKey: K.lastOk),
                    "lastError": defaults.string(forKey: K.lastError) ?? "",
                    "fineLocation": engine.hasFine,
                    "backgroundLocation": engine.hasAlways,
                    "notifications": allowed,
                ])
            }
        }
    }

    @objc func start(_ call: CAPPluginCall) {
        guard let url = call.getString("serverUrl"), url.hasPrefix("http"), let token = call.getString("token"), !token.isEmpty else {
            call.reject("serverUrl and token are required")
            return
        }
        let interval = max(10, min(600, call.getInt("intervalSec") ?? 60))
        let duration = max(0, min(24 * 3600, call.getInt("durationSec") ?? 0))
        DispatchQueue.main.async {
            PatrolEngine.shared.start(url: url.trimmingCharacters(in: CharacterSet(charactersIn: "/")), token: token, intervalSec: interval, durationSec: duration)
            self.readStatus { call.resolve($0) }
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            PatrolEngine.shared.stop()
            self.readStatus { call.resolve($0) }
        }
    }

    @objc func status(_ call: CAPPluginCall) {
        readStatus { call.resolve($0) }
    }

    @objc func requestBackground(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            PatrolEngine.shared.requestAlways { self.readStatus { call.resolve($0) } }
        }
    }

    /// Whether the newest location fix was simulated by software: {mock: Bool}.
    @objc func mockCheck(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            call.resolve(["mock": PatrolEngine.shared.simulated])
        }
    }

    @objc func openSettings(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            call.resolve()
        }
    }
}
