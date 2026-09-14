// DeepSeek Off-Peak – macOS Menüleisten-App (Intel / Apple Silicon)
//
// Zeigt an, ob gerade DeepSeek-Off-Peak-Preise (50 % Rabatt) gelten, wie lange
// das noch dauert bzw. wie lange es noch dauert, bis sie beginnen.
//
// Standard-Regel (api-docs.deepseek.com/quick_start/pricing, Stand Sep 2026):
//   Peak   = Mo–Fr 01:00–04:00 UTC und 06:00–10:00 UTC
//   Off-Peak = alle anderen Zeiten (50 % Rabatt), Wochenende ganztägig
//   (seit 23.08.2026: Wochenendtage – Peking-Zeit – ganztägig off-peak)
//
// Alle Zeitfenster, Erinnerungen und Schalter sind per JSON konfigurierbar:
//   ~/Library/Application Support/DeepSeekOffPeak/config.json
// Die Datei wird live überwacht – Änderungen werden ohne Neustart übernommen.
//
// CLI-Modi:
//   DeepSeekOffPeak --text            → eine Statuszeile auf stdout
//   DeepSeekOffPeak --selftest        → prüft die Fenster-Logik und beendet sich
//   DeepSeekOffPeak --config-path     → Pfad der Konfigurationsdatei
//   DeepSeekOffPeak --create-config   → legt eine Standard-Konfiguration an

import Cocoa
import UserNotifications
import ServiceManagement
import Darwin

// MARK: - Tarif

enum Tariff: Equatable {
    case peak
    case offPeak

    var isOffPeak: Bool { self == .offPeak }
    var isPeak: Bool { self == .peak }
}

// MARK: - Konfiguration (JSON)

/// Ein Peak-Fenster in UTC-Stunden (ganzstündig, start inklusiv, Ende exklusiv).
struct PeakWindow: Codable, Equatable {
    var startHour: Int
    var endHour: Int
}

struct AppConfigData: Codable, Equatable {
    var peakWindowsUtc: [PeakWindow]
    var weekendsOffPeak: Bool
    var weekendTimeZone: String      // Wochenende wird in dieser Zeitzone bestimmt
    var notifyOnChange: Bool         // Benachrichtigung bei jedem Tarifwechsel
    var remindersEnabled: Bool       // Erinnerungen kurz vor dem Wechsel
    var remindBeforeEndMinutes: [Int]   // vor Ende des Off-Peak (absteigend)
    var remindBeforeStartMinutes: [Int] // vor Beginn des Off-Peak (absteigend)

    // Guthaben-Abfrage (GET https://api.deepseek.com/user/balance)
    var apiKey: String               // Key direkt (nur bei Bedarf; Datei/Env bevorzugt)
    var apiKeyEnv: String            // Name der Umgebungsvariable mit dem Key
    var apiKeyFile: String           // Pfad zu einer Datei (KEY=VALUE-Format, z. B. .env)
    var balanceBaseURL: String       // z. B. https://api.deepseek.com
    var balanceRefreshMinutes: Int   // Abfrage-Intervall
    var balanceWarnBelow: Double     // Warnschwelle (total), z. B. 2.0
    var balanceWarnEnabled: Bool     // Benachrichtigung beim Unterschreiten
    var showBalanceInTitle: Bool     // Guthaben zusätzlich in der Menüleiste anzeigen

    var language: String              // UI language: "auto" | "en" | "de"

    // Verbrauchs-/Kosten-Auswertung (liest die DSH-Session-Logs)
    var usageRefreshMinutes: Int     // Intervall für die Log-Auswertung
    var eurPerUsd: Double            // Umrechnung USD → EUR (0 deaktiviert EUR-Anzeige)

    static let standard = AppConfigData(
        peakWindowsUtc: [
            PeakWindow(startHour: 1, endHour: 4),
            PeakWindow(startHour: 6, endHour: 10)
        ],
        weekendsOffPeak: true,
        weekendTimeZone: "Asia/Shanghai",  // Sa/So Peking-Zeit = Wochenende
        notifyOnChange: true,
        remindersEnabled: true,
        remindBeforeEndMinutes: [15, 5],
        remindBeforeStartMinutes: [15, 5]
    )

    // Tolerantes Decodieren: fehlende Schlüssel fallen auf die Standardwerte zurück.
    private struct Flat: Decodable {
        let peakWindowsUtc: [PeakWindow]?
        let weekendsOffPeak: Bool?
        let weekendTimeZone: String?
        let notifyOnChange: Bool?
        let remindersEnabled: Bool?
        let remindBeforeEndMinutes: [Int]?
        let remindBeforeStartMinutes: [Int]?
        let apiKey: String?
        let apiKeyEnv: String?
        let apiKeyFile: String?
        let balanceBaseURL: String?
        let balanceRefreshMinutes: Int?
        let balanceWarnBelow: Double?
        let balanceWarnEnabled: Bool?
        let showBalanceInTitle: Bool?
        let language: String?
        let usageRefreshMinutes: Int?
        let eurPerUsd: Double?
    }

    init(peakWindowsUtc: [PeakWindow],
         weekendsOffPeak: Bool,
         weekendTimeZone: String,
         notifyOnChange: Bool,
         remindersEnabled: Bool,
         remindBeforeEndMinutes: [Int],
         remindBeforeStartMinutes: [Int],
         apiKey: String = "",
         apiKeyEnv: String = "DEEPSEEK_API_KEY",
         apiKeyFile: String = "",
         balanceBaseURL: String = "https://api.deepseek.com",
         balanceRefreshMinutes: Int = 15,
         balanceWarnBelow: Double = 2.0,
         balanceWarnEnabled: Bool = true,
         showBalanceInTitle: Bool = false,
         language: String = "auto",
         usageRefreshMinutes: Int = 5,
         eurPerUsd: Double = 0.91) {
        self.peakWindowsUtc = AppConfigData.sanitizedWindows(peakWindowsUtc)
        self.weekendsOffPeak = weekendsOffPeak
        self.weekendTimeZone = weekendTimeZone
        self.notifyOnChange = notifyOnChange
        self.remindersEnabled = remindersEnabled
        self.remindBeforeEndMinutes = AppConfigData.sanitizedMinutes(remindBeforeEndMinutes)
        self.remindBeforeStartMinutes = AppConfigData.sanitizedMinutes(remindBeforeStartMinutes)
        self.apiKey = apiKey
        self.apiKeyEnv = apiKeyEnv.isEmpty ? "DEEPSEEK_API_KEY" : apiKeyEnv
        self.apiKeyFile = apiKeyFile
        self.balanceBaseURL = balanceBaseURL.isEmpty ? "https://api.deepseek.com" : balanceBaseURL
        self.balanceRefreshMinutes = max(1, min(1440, balanceRefreshMinutes))
        self.balanceWarnBelow = max(0, balanceWarnBelow)
        self.balanceWarnEnabled = balanceWarnEnabled
        self.showBalanceInTitle = showBalanceInTitle
        self.language = ["auto", "en", "de"].contains(language) ? language : "auto"
        self.usageRefreshMinutes = max(1, min(1440, usageRefreshMinutes))
        self.eurPerUsd = max(0, eurPerUsd)
    }

    init(from decoder: Decoder) throws {
        let flat = try Flat(from: decoder)
        let s = AppConfigData.standard
        self.init(
            peakWindowsUtc: flat.peakWindowsUtc ?? s.peakWindowsUtc,
            weekendsOffPeak: flat.weekendsOffPeak ?? s.weekendsOffPeak,
            weekendTimeZone: flat.weekendTimeZone ?? s.weekendTimeZone,
            notifyOnChange: flat.notifyOnChange ?? s.notifyOnChange,
            remindersEnabled: flat.remindersEnabled ?? s.remindersEnabled,
            remindBeforeEndMinutes: flat.remindBeforeEndMinutes ?? s.remindBeforeEndMinutes,
            remindBeforeStartMinutes: flat.remindBeforeStartMinutes ?? s.remindBeforeStartMinutes,
            apiKey: flat.apiKey ?? s.apiKey,
            apiKeyEnv: flat.apiKeyEnv ?? s.apiKeyEnv,
            apiKeyFile: flat.apiKeyFile ?? s.apiKeyFile,
            balanceBaseURL: flat.balanceBaseURL ?? s.balanceBaseURL,
            balanceRefreshMinutes: flat.balanceRefreshMinutes ?? s.balanceRefreshMinutes,
            balanceWarnBelow: flat.balanceWarnBelow ?? s.balanceWarnBelow,
            balanceWarnEnabled: flat.balanceWarnEnabled ?? s.balanceWarnEnabled,
            showBalanceInTitle: flat.showBalanceInTitle ?? s.showBalanceInTitle,
            language: flat.language ?? s.language,
            usageRefreshMinutes: flat.usageRefreshMinutes ?? s.usageRefreshMinutes,
            eurPerUsd: flat.eurPerUsd ?? s.eurPerUsd
        )
    }

    static func sanitizedWindows(_ windows: [PeakWindow]) -> [PeakWindow] {
        return windows
            .filter { $0.startHour >= 1 && $0.endHour > $0.startHour && $0.endHour <= 24 }
            .sorted { $0.startHour < $1.startHour }
    }

    static func sanitizedMinutes(_ minutes: [Int]) -> [Int] {
        return Array(Set(minutes.filter { $0 > 0 && $0 <= 1440 })).sorted(by: >)
    }
}

enum AppConfig {
    static var current: AppConfigData = .standard
    private static var cachedMTime: Date?

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("DeepSeekOffPeak/config.json")
    }

    private static func mtime() -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return attrs?[.modificationDate] as? Date
    }

    /// Lädt die Datei (falls geändert) und meldet, ob sich die Regeln geändert haben.
    static func syncFromDiskIfNeeded() -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        let mt = mtime()
        if mt == cachedMTime { return false }
        cachedMTime = mt
        do {
            let data = try Data(contentsOf: fileURL)
            let parsed = try JSONDecoder().decode(AppConfigData.self, from: data)
            let changed = parsed != current
            current = parsed
            L.configure(language: parsed.language)
            return changed
        } catch {
            fputs(L.f("DeepSeekOffPeak: cannot read configuration (%@) – using defaults. Error: %@\n", fileURL.path, String(describing: error)), stderr)
            return false
        }
    }

    static func forceReload() {
        cachedMTime = nil
        _ = syncFromDiskIfNeeded()
        L.configure(language: current.language)
    }

    static func ensureFileExists() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? save()
    }

    static func save() throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(current)
        try data.write(to: fileURL, options: .atomic)
        cachedMTime = mtime()
    }

    static func resetToStandard() {
        current = .standard
        try? save()
    }
}

// MARK: - Zeitfenster-Logik

enum DSSchedule {
    static let utc: TimeZone = TimeZone(identifier: "UTC")!
    static let pricingURL = URL(string: "https://api-docs.deepseek.com/quick_start/pricing/")!

    private static func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        return cal
    }

    /// Tarif zu einem Zeitpunkt gemäß der aktuell geladenen Konfiguration.
    static func tariff(at date: Date) -> Tariff {
        tariff(at: date, config: AppConfig.current)
    }

    static func tariff(at date: Date, config: AppConfigData) -> Tariff {
        if config.weekendsOffPeak && isWeekendDay(date, config: config) {
            return .offPeak
        }
        let hour = utcCalendar().component(.hour, from: date)
        for window in config.peakWindowsUtc where hour >= window.startHour && hour < window.endHour {
            return .peak
        }
        return .offPeak
    }

    /// Ist `date` ein Wochenendtag in der konfigurierten Wochenend-Zeitzone?
    static func isWeekendDay(_ date: Date, config: AppConfigData) -> Bool {
        let tz = TimeZone(identifier: config.weekendTimeZone) ?? utc
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let weekday = cal.component(.weekday, from: date) // 1 = Sonntag … 7 = Samstag
        return weekday == 1 || weekday == 7
    }

    /// Nächster Zeitpunkt nach `date`, an dem sich der Tarif ändert (oder nil).
    static func nextTransition(after date: Date) -> Date? {
        nextTransition(after: date, config: AppConfig.current)
    }

    static func nextTransition(after date: Date, config: AppConfigData) -> Date? {
        let current = tariff(at: date, config: config)
        let cal = utcCalendar()
        let startOfDay = cal.startOfDay(for: date)

        // Alle Fensteranfänge und -enden als UTC-Stunden eines Tages.
        var hours = Set<Int>()
        for window in config.peakWindowsUtc {
            hours.insert(window.startHour)
            hours.insert(window.endHour)
        }

        for dayOffset in 0..<8 {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: startOfDay) else { continue }
            for hour in hours.sorted() where hour > 0 && hour <= 24 {
                guard let candidate = cal.date(byAdding: .hour, value: hour, to: day) else { continue }
                if candidate <= date { continue }
                if tariff(at: candidate, config: config) != current { return candidate }
            }
        }
        return nil
    }
}

// MARK: - Guthaben (DeepSeek /user/balance)

/// Antwortformat of GET https://api.deepseek.com/user/balance
struct BalanceInfo: Codable {
    let currency: String
    let total_balance: String
    let granted_balance: String
    let topped_up_balance: String
}

struct BalanceResponse: Codable {
    let is_available: Bool
    let balance_infos: [BalanceInfo]
}

enum DeepSeekBalance {
    /// Schlüssel-Auflösung: inline → Umgebungsvariable → Datei (KEY=VALUE).
    static func resolveAPIKey(config: AppConfigData) -> String? {
        if !config.apiKey.isEmpty { return config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
        let env = ProcessInfo.processInfo.environment[config.apiKeyEnv]
        if let env = env, !env.isEmpty { return env.trimmingCharacters(in: .whitespacesAndNewlines) }
        if !config.apiKeyFile.isEmpty {
            let url = URL(fileURLWithPath: NSString(string: config.apiKeyFile).expandingTildeInPath)
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                for rawLine in content.split(separator: "\n") {
                    let line = rawLine.trimmingCharacters(in: .whitespaces)
                    guard !line.isEmpty, !line.hasPrefix("#") else { continue }
                    let parts = line.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2 else { continue }
                    let name = parts[0].trimmingCharacters(in: .whitespaces)
                    if name == config.apiKeyEnv {
                        var value = parts[1].trimmingCharacters(in: .whitespaces)
                        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                           (value.hasPrefix("'") && value.hasSuffix("'")) {
                            value.removeFirst()
                            value.removeLast()
                        }
                        if !value.isEmpty { return value }
                    }
                }
            }
        }
        return nil
    }

    /// Lädt das Guthaben und ruft `completion` auf dem Haupt-Thread auf.
    static func fetch(config: AppConfigData,
                      completion: @escaping (Result<BalanceResponse, Error>) -> Void) {
        guard let key = resolveAPIKey(config: config) else {
            completion(.failure(BalanceError.noAPIKey))
            return
        }
        let base = config.balanceBaseURL.hasSuffix("/")
            ? String(config.balanceBaseURL.dropLast())
            : config.balanceBaseURL
        guard let url = URL(string: base + "/user/balance") else {
            completion(.failure(BalanceError.invalidURL))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    completion(.failure(BalanceError.httpStatus(http.statusCode, body)))
                    return
                }
                guard let data = data else {
                    completion(.failure(BalanceError.invalidURL))
                    return
                }
                do {
                    let decoded = try JSONDecoder().decode(BalanceResponse.self, from: data)
                    completion(.success(decoded))
                } catch {
                    completion(.failure(error))
                }
            }
        }.resume()
    }
}

enum BalanceError: LocalizedError {
    case noAPIKey
    case invalidURL
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return L.t("No API key found (config: apiKeyFile / apiKeyEnv / apiKey).")
        case .invalidURL:
            return L.t("Invalid balanceBaseURL.")
        case .httpStatus(let code, let body):
            var text = "HTTP \(code)"
            let known: [Int: String] = [401: L.t("invalid key"), 402: L.t("balance exhausted"), 429: L.t("too many requests")]
            if let k = known[code] { text += " – \(k)" }
            if !body.isEmpty { text += " – \(String(body.prefix(120)))" }
            return text
        }
    }
}

// MARK: - Verbrauchs-Auswertung (DSH-Session-Logs)

enum UsagePricing {
    /// Off-Peak-Preise in USD pro 1 Mio. Tokens (Peak = exakt das Doppelte).
    /// Quelle: api-docs.deepseek.com/quick_start/pricing (Sep 2026).
    static func prices(model: String) -> (hitIn: Double, missIn: Double, out: Double) {
        if model.contains("deepseek-v4-pro") {
            return (0.022, 0.66, 1.98)
        }
        // deepseek-v4-flash, deepseek-v4-flash-vision-exp, Unbekanntes → Flash-Preise
        return (0.007, 0.22, 0.66)
    }
}

struct SessionUsage {
    var label: String            // cwd aus der Session, z. B. /Users/…/projekt
    var sessionID: String
    var messages = 0
    var hitIn: Int64 = 0         // Cache-Hit-Input-Tokens
    var missIn: Int64 = 0        // Cache-Miss-Input-Tokens
    var out: Int64 = 0           // Output-Tokens (inkl. Reasoning)
    var usdOffPeak: Double = 0   // Kosten, als wäre alles im Off-Peak gelaufen
    var usdActual: Double = 0    // Kosten mit echtem off-peak/peak-Zeitpunkt
    var usdPeak: Double = 0      // Kosten, als wäre alles im Peak gelaufen
    var lastActivity: Date?
}

enum UsageScanner {
    /// Mögliche Pfade des zstd-Werkzeugs. Wichtig: Aus dem Finder heraus hat
    /// die App kein Shell-PATH (kein /usr/local/bin) – daher feste Pfade.
    private static let zstdCandidates = [
        "/usr/local/bin/zstd",   // Intel Macs / Homebrew (x86_64)
        "/opt/homebrew/bin/zstd",// Apple Silicon / Homebrew
        "/usr/bin/zstd",
        "/bin/zstd"
    ]

    private static func zstdExecutable() -> URL? {
        for candidate in zstdCandidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        // Fallback über PATH (z. B. im Terminal gestartet)
        return nil
    }

    /// Liefert die Auswertung über alle Session-Logs unter ~/.dsh/sessions.
    /// `unreadable` zählt Dateien, die gerade nicht dekodierbar waren (laufende
    /// Sessions werden mitgeschrieben) – das ist kein harter Fehler.
    static func scanAll(config: AppConfigData) -> (sessions: [SessionUsage], unreadable: Int, warnings: [String]) {
        var result: [SessionUsage] = []
        var unreadable = 0
        var warnings: [String] = []

        guard let zstd = zstdExecutable() else {
            warnings.append(L.t("zstd command-line tool not found (install with: brew install zstd)."))
            return (result, unreadable, warnings)
        }

        let home = ProcessInfo.processInfo.environment["DSH_HOME"]
        let sessionsRoot = URL(fileURLWithPath: home ?? (NSHomeDirectory() + "/.dsh")).appendingPathComponent("sessions")
        guard FileManager.default.fileExists(atPath: sessionsRoot.path) else {
            warnings.append(L.f("DSH sessions folder not found: %@", sessionsRoot.path))
            return (result, unreadable, warnings)
        }

        let enumerator = FileManager.default.enumerator(at: sessionsRoot,
                                                        includingPropertiesForKeys: [.contentModificationDateKey],
                                                        options: [.skipsHiddenFiles]) { _, _ in true }
        // Pro Session-Verzeichnis nur die NEUESTE Logdatei werten: DSH hat das
        // Format auf "session.v3.jsonl.zstd" umgestellt, ältere Sessions haben
        // teils beide Dateien – sonst würden Tokens doppelt gezählt.
        var newestByDirectory: [String: (url: URL, modified: Date)] = [:]
        while let url = enumerator?.nextObject() as? URL {
            guard isSessionLogFileName(url.lastPathComponent) else { continue }
            let directory = url.deletingLastPathComponent().path
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if let existing = newestByDirectory[directory], existing.modified >= modified { continue }
            newestByDirectory[directory] = (url, modified)
        }
        let files = newestByDirectory.values.map { $0.url }

        // Kopien/Forks derselben Session enthalten dieselben Antwort-Events
        // (gleiche message.id) – global nur einmal zählen.
        var seenMessageIDs = Set<String>()

        for file in files {
            guard let content = zstdDecompress(url: file, zstd: zstd) else {
                unreadable += 1
                continue
            }
            if let usage = parse(content: content, config: config, seenMessageIDs: &seenMessageIDs) {
                var u = usage
                u.sessionID = file.deletingLastPathComponent().lastPathComponent
                u.label = usage.label.isEmpty
                    ? file.deletingLastPathComponent().lastPathComponent
                    : usage.label
                result.append(u)
            }
        }
        result.sort { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
        return (result, unreadable, warnings)
    }

    /// Erkennt die Session-Logdateien in allen bisherigen Namensvarianten,
    /// z. B. "session.jsonl.zstd" (alt) und "session.v3.jsonl.zstd" (neu).
    static func isSessionLogFileName(_ name: String) -> Bool {
        return name.hasPrefix("session") && name.hasSuffix(".jsonl.zstd")
    }

    /// Dekomprimiert eine .zstd-Datei über das zstd-Kommandozeilenwerkzeug.
    /// Läuft die Session gerade, sind bereits vollständige Frames dekodierbar;
    /// ein unvollständiger Rest-Frame führt zu Exit ≠ 0 – die ausgelesenen
    /// Frames bleiben trotzdem nutzbar. Nur bei komplett leerer Ausgabe wird
    /// die Datei als unlesbar gezählt.
    private static func zstdDecompress(url: URL, zstd: URL) -> String? {
        let process = Process()
        process.executableURL = zstd
        process.arguments = ["-d", "-c", "--", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Wertet die JSONL-Zeilen einer Session aus (assistant/message mit usage).
    private static func parse(content: String, config: AppConfigData,
                              seenMessageIDs: inout Set<String>) -> SessionUsage? {
        var usage = SessionUsage(label: "", sessionID: "", messages: 0)
        var sawAnything = false

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(rawLine.utf8)) as? [String: Any] else { continue }
            let type = obj["type"] as? String ?? ""

            if type == "session", let cwd = obj["cwd"] as? String {
                usage.label = cwd
                continue
            }
            guard type == "assistant/message" else { continue }
            guard let data = obj["data"] as? [String: Any],
                  let usageDict = data["usage"] as? [String: Any] else { continue }

            // Kopien/Forks derselben Session: identische message.id nicht doppelt zählen.
            if let messageID = (data["message"] as? [String: Any])?["id"] as? String, !messageID.isEmpty {
                if seenMessageIDs.contains(messageID) { continue }
                seenMessageIDs.insert(messageID)
            }

            let miss = intValue(usageDict["inputTokens"])
            let hit = intValue(usageDict["cacheReadTokens"])
            let out = intValue(usageDict["outputTokens"])
            guard miss > 0 || hit > 0 || out > 0 else { continue }
            sawAnything = true
            usage.messages += 1
            usage.missIn += miss
            usage.hitIn += hit
            usage.out += out

            let source = (data["message"] as? [String: Any])?["source"] as? [String: Any]
            let model = source?["model"] as? String ?? data["model"] as? String ?? ""
            let prices = UsagePricing.prices(model: model)
            let off = Double(hit) / 1_000_000 * prices.hitIn
                + Double(miss) / 1_000_000 * prices.missIn
                + Double(out) / 1_000_000 * prices.out
            usage.usdOffPeak += off
            usage.usdPeak += off * 2

            // Echter Tarif zum Zeitpunkt des Aufrufs: off-peak = 1×, Peak = 2×.
            if let time = timeValue(obj["time"]) {
                let date = Date(timeIntervalSince1970: time / 1000)
                if usage.lastActivity == nil || date > usage.lastActivity! {
                    usage.lastActivity = date
                }
                let factor = DSSchedule.tariff(at: date, config: config).isOffPeak ? 1.0 : 2.0
                usage.usdActual += off * factor
            } else {
                usage.usdActual += off
            }
        }
        return sawAnything ? usage : nil
    }

    private static func intValue(_ value: Any?) -> Int64 {
        guard let value = value else { return 0 }
        if let n = value as? NSNumber { return n.int64Value }
        if let s = value as? String { return Int64(s) ?? 0 }
        return 0
    }

    private static func timeValue(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

// MARK: - Localization

/// Lightweight localization: the English text is the key, and
/// `Resources/de.lproj/Localizable.strings` supplies the German translation.
/// Missing translations fall back to English. The config key `language`
/// ("auto" | "en" | "de") overrides the system language.
enum L {
    private static var bundle: Bundle = .main
    static private(set) var language: String = "auto"

    static func configure(language: String) {
        self.language = language
        guard language != "auto",
              let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let localized = Bundle(path: path) else {
            bundle = .main
            return
        }
        bundle = localized
    }

    /// Effective language code ("de" or "en").
    static var effectiveLanguage: String {
        if language == "de" || language == "en" { return language }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("de") ? "de" : "en"
    }

    static var locale: Locale {
        Locale(identifier: effectiveLanguage == "de" ? "de_DE" : "en_US")
    }

    static func t(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// Localized format string with arguments, e.g. `L.f("%d hours", 3)`.
    static func f(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), arguments: arguments)
    }
}

// MARK: - Formatting

enum Fmt {
    /// Time HH:mm in the local time zone.
    static func localTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = L.locale
        f.timeZone = .current
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// Short weekday + date, e.g. "Mon 07.09." / "Mo 07.09."
    static func weekdayDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = L.locale
        f.timeZone = .current
        f.dateFormat = "EEE dd.MM."
        return f.string(from: date).capitalized
    }

    private static func currencySymbol(_ code: String) -> String {
        switch code.uppercased() {
        case "USD": return "$"
        case "CNY": return "¥"
        case "EUR": return "€"
        default: return code
        }
    }

    /// Amount with currency, e.g. "$12.34" (en) or "12,34 $" (de).
    static func money(_ value: Double, currency: String) -> String {
        let nf = NumberFormatter()
        nf.locale = L.locale
        nf.numberStyle = .decimal
        nf.minimumFractionDigits = 2
        nf.maximumFractionDigits = 2
        let num = nf.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
        let symbol = currencySymbol(currency)
        return L.effectiveLanguage == "de" ? "\(num) \(symbol)" : "\(symbol)\(num)"
    }

    /// Compact amount for the menu bar: "$12.3" / "12,3$".
    static func moneyCompact(_ value: Double, currency: String) -> String {
        let nf = NumberFormatter()
        nf.locale = L.locale
        nf.numberStyle = .decimal
        nf.minimumFractionDigits = 0
        if value >= 1000 { nf.maximumFractionDigits = 0 }
        else if value >= 100 { nf.maximumFractionDigits = 1 }
        else { nf.maximumFractionDigits = 2 }
        let num = nf.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
        return L.effectiveLanguage == "de"
            ? "\(num)\(currencySymbol(currency))"
            : "\(currencySymbol(currency))\(num)"
    }

    /// Compact token counts: "25.1M"/"25,1M", "144K", "912".
    static func formatTokens(_ count: Int64) -> String {
        let d = Double(count)
        if d >= 1_000_000 {
            var s = String(format: "%.1f", d / 1_000_000)
            if s.hasSuffix(".0") { s = String(s.dropLast(2)) }
            if L.effectiveLanguage == "de" { s = s.replacingOccurrences(of: ".", with: ",") }
            return s + "M"
        }
        if d >= 1_000 { return "\(Int((d / 1_000).rounded()))K" }
        return "\(count)"
    }

    /// Human-readable duration, e.g. "3 hours 12 minutes" / "3 Stunden 12 Minuten".
    static func durationWords(_ interval: TimeInterval) -> String {
        var total = max(0, Int(interval.rounded(.down)))
        let days = total / 86400
        total %= 86400
        let hours = total / 3600
        total %= 3600
        let minutes = total / 60
        let seconds = total % 60

        var parts: [String] = []
        if days > 0 { parts.append(days == 1 ? L.t("1 day") : L.f("%d days", days)) }
        if hours > 0 { parts.append(hours == 1 ? L.t("1 hour") : L.f("%d hours", hours)) }
        if minutes > 0 { parts.append(minutes == 1 ? L.t("1 minute") : L.f("%d minutes", minutes)) }
        if parts.isEmpty { parts.append(seconds <= 0 ? L.t("less than a minute") : L.f("%d seconds", seconds)) }
        return parts.joined(separator: " ")
    }

    /// Minute count with correct singular/plural.
    static func minutesWords(_ minutes: Int) -> String {
        minutes == 1 ? L.t("1 minute") : L.f("%d minutes", minutes)
    }

    /// Compact menu-bar countdown, deliberately without a colon so it cannot be
    /// mistaken for a clock time: "1d5h", "9h30", "45m", "42s".
    static func compactCountdown(_ interval: TimeInterval) -> String {
        var total = max(0, Int(interval.rounded(.down)))
        let days = total / 86400
        total %= 86400
        let hours = total / 3600
        total %= 3600
        let minutes = total / 60
        let seconds = total % 60

        if days > 0 { return "\(days)d\(hours)h" }
        if hours > 0 { return "\(hours)h" + (minutes > 0 ? String(format: "%02d", minutes) : "") }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    /// "at 18:00 (in 1 hour 45 minutes)" / "um 18:00 (in 1 Stunde 45 Minuten)".
    static func untilWords(now: Date, target: Date) -> String {
        let words = durationWords(target.timeIntervalSince(now))
        return L.f("at %@ (in %@)", localTime(target), words)
    }
}

// MARK: - Text-Ausgabe (CLI)

enum TextOutput {
    /// Eine verständliche Statuszeile, z. B. für `--text`.
    static func statusLine(now: Date = Date()) -> String {
        let config = AppConfig.current
        let tariff = DSSchedule.tariff(at: now, config: config)
        switch tariff {
        case .offPeak:
            if let end = DSSchedule.nextTransition(after: now, config: config) {
                let remaining = end.timeIntervalSince(now)
                if remaining >= 20 * 3600 && DSSchedule.isWeekendDay(now, config: config) {
                    return L.f("DeepSeek off-peak active (weekend, 50%% off all day). Off-peak ends %@.", Fmt.untilWords(now: now, target: end))
                }
                return L.f("DeepSeek off-peak active (50%% off). Cheap for another %@, ends at %@.", Fmt.durationWords(remaining), Fmt.localTime(end))
            }
            return "DeepSeek Off-Peak aktiv (50 % Rabatt)."
        case .peak:
            if let start = DSSchedule.nextTransition(after: now, config: config) {
                return L.f("DeepSeek peak pricing active. Off-peak (50%% off) starts %@.", Fmt.untilWords(now: now, target: start))
            }
            return L.t("DeepSeek peak pricing active.")
        }
    }
}

// MARK: - Guthaben-Ausgabe (CLI)

enum CLIBalance {
    static func run() -> Int32 {
        let config = AppConfig.current
        var output = ""
        var exitCode: Int32 = 0

        let semaphore = DispatchSemaphore(value: 0)
        DeepSeekBalance.fetch(config: config) { result in
            switch result {
            case .success(let balance):
                if balance.balance_infos.isEmpty {
                    output = L.t("Balance: no account information returned.")
                } else {
                    var lines: [String] = []
                    for info in balance.balance_infos {
                        guard let total = Double(info.total_balance) else { continue }
                        let granted = Double(info.granted_balance) ?? 0
                        let toppedUp = Double(info.topped_up_balance) ?? 0
                        lines.append(L.f("Balance (%@): %@ total – granted %@, topped up %@", info.currency, Fmt.money(total, currency: info.currency), Fmt.money(granted, currency: info.currency), Fmt.money(toppedUp, currency: info.currency)))
                    }
                    output = lines.joined(separator: "\n")
                    if !balance.is_available && !lines.isEmpty {
                        output += L.t("\nWarning: the API reports insufficient balance (is_available = false).")
                    }
                }
            case .failure(let error):
                exitCode = 1
                output = L.f("Balance request failed: %@", error.localizedDescription)
            }
            semaphore.signal()
        }

        // Auf die Antwort warten (Main-Runloop pumpt die URLSession-Completion).
        let deadline = Date().addingTimeInterval(25)
        while semaphore.wait(timeout: .now()) == .timedOut {
            if Date() > deadline {
                output = L.t("Balance request failed: timeout.")
                exitCode = 1
                break
            }
            RunLoop.current.run(mode: .common, before: Date().addingTimeInterval(0.05))
        }

        print(output)
        return exitCode
    }
}

// MARK: - Verbrauchs-Zusammenfassung (CLI)

struct UsageTotals {
    var sessions = 0
    var messages = 0
    var hitIn: Int64 = 0
    var missIn: Int64 = 0
    var out: Int64 = 0
    var usdOffPeak: Double = 0
    var usdActual: Double = 0
    var usdPeak: Double = 0

    var inputTotal: Int64 { hitIn + missIn }
    var cacheRate: Double { inputTotal > 0 ? Double(hitIn) / Double(inputTotal) : 0 }
}

enum UsageSummary {
    static func totals(of sessions: [SessionUsage], newerThan cutoff: Date?) -> UsageTotals {
        var t = UsageTotals()
        for s in sessions {
            if let cutoff = cutoff {
                guard let last = s.lastActivity, last >= cutoff else { continue }
            }
            t.sessions += 1
            t.messages += s.messages
            t.hitIn += s.hitIn
            t.missIn += s.missIn
            t.out += s.out
            t.usdOffPeak += s.usdOffPeak
            t.usdActual += s.usdActual
            t.usdPeak += s.usdPeak
        }
        return t
    }

    /// "0,23 $ · 0,21 € (Peak-Vergleich 0,46 $)"
    static func costText(usd: Double, config: AppConfigData) -> String {
        var text = Fmt.money(usd, currency: "USD")
        if config.eurPerUsd > 0 {
            text += " · " + Fmt.money(usd * config.eurPerUsd, currency: "EUR")
        }
        return text
    }

    static func costWithPeakText(usd: Double, peak: Double, config: AppConfigData) -> String {
        var text = costText(usd: usd, config: config)
        let peakText = config.eurPerUsd > 0
            ? Fmt.money(peak * config.eurPerUsd, currency: "EUR")
            : Fmt.money(peak, currency: "USD")
        text += L.f(" (peak comparison %@)", peakText)
        return text
    }

    static func shortDateTime(_ date: Date?) -> String {
        guard let date = date else { return "–" }
        let f = DateFormatter()
        f.locale = L.locale
        f.dateFormat = "dd.MM. HH:mm"
        return f.string(from: date)
    }
}

enum CLICost {
    static func run() -> Int32 {
        let config = AppConfig.current
        let (sessions, unreadable, warnings) = UsageScanner.scanAll(config: config)
        for warning in warnings {
            fputs(L.f("Warning: %@\n", warning), stderr)
        }
        if unreadable > 0 {
            print(L.f("Note: %d session file(s) not readable right now (running sessions are being written) – skipped.", unreadable))
        }
        if sessions.isEmpty {
            print(L.f("No DSH session logs with usage found (under %@/.dsh/sessions).", NSHomeDirectory()))
            return warnings.isEmpty ? 0 : 1
        }

        print(L.t("DSH usage (all workspaces) – billed per request (off-peak/peak):"))
        print("\(String(repeating: "–", count: 92))")
        for s in sessions {
            let rawName = (s.label as NSString).lastPathComponent
            let name = rawName.isEmpty ? s.sessionID : rawName
            let padded = (name as NSString).padding(toLength: 22, withPad: " ", startingAt: 0)
            var line = "• \(UsageSummary.shortDateTime(s.lastActivity))  \(padded) "
            line += L.f("input %@ (hit %@ / miss %@) · output %@ · %d replies", Fmt.formatTokens(s.hitIn + s.missIn), Fmt.formatTokens(s.hitIn), Fmt.formatTokens(s.missIn), Fmt.formatTokens(s.out), s.messages)
            print(line)
            print(L.f("    Cost: %@ · all off-peak: %@ · all peak: %@", UsageSummary.costText(usd: s.usdActual, config: config), UsageSummary.costText(usd: s.usdOffPeak, config: config), UsageSummary.costText(usd: s.usdPeak, config: config)))
        }
        print(String(repeating: "–", count: 92))

        let now = Date()
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        guard let sevenDaysAgo = cal.date(byAdding: .day, value: -6, to: todayStart) else { return 0 }

        let today = UsageSummary.totals(of: sessions, newerThan: todayStart)
        let week = UsageSummary.totals(of: sessions, newerThan: sevenDaysAgo)
        let all = UsageSummary.totals(of: sessions, newerThan: nil)

        func block(_ title: String, _ t: UsageTotals) {
            let cache = t.inputTotal > 0 ? String(format: "%.1f", t.cacheRate * 100).replacingOccurrences(of: ".", with: ",") + " %" : "–"
            print(L.f("%@: %d sessions · %d replies · input %@ (%@ cache) · output %@", title, t.sessions, t.messages, Fmt.formatTokens(t.inputTotal), cache, Fmt.formatTokens(t.out)))
            print(L.f("   Cost (effective): %@", UsageSummary.costText(usd: t.usdActual, config: config)))
            print(L.f("   Comparison: all off-peak %@ · all peak %@", UsageSummary.costText(usd: t.usdOffPeak, config: config), UsageSummary.costText(usd: t.usdPeak, config: config)))
        }
        block(L.t("Today"), today)
        block(L.t("Last 7 days"), week)
        block(L.t("Total"), all)
        return 0
    }
}

// MARK: - Menüleisten-App

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {

    /// Einstiegspunkt: CLI-Modi zuerst, sonst GUI.
    static func main() {
        let arguments = CommandLine.arguments

        if arguments.contains("--version") {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            print("DeepSeek Off-Peak Menubar \(version)")
            exit(0)
        }
        if arguments.contains("--help") {
            print("""
            DeepSeek Off-Peak Menubar – unofficial macOS menu bar app

            Usage: DeepSeekOffPeak [option]

              (no option)      run the menu bar app
              --text           print one status line and exit
              --balance        query the DeepSeek account balance
              --cost           show token usage and costs of all DSH sessions
              --selftest       run the built-in self test
              --config-path    print the configuration file path
              --create-config  write a default configuration file
              --version        print the version
              --help           show this help

            Configuration: ~/Library/Application Support/DeepSeekOffPeak/config.json
            """)
            exit(0)
        }
        if arguments.contains("--selftest") {
            exit(SelfTest.run() ? 0 : 1)
        }
        if arguments.contains("--config-path") {
            print(AppConfig.fileURL.path)
            exit(0)
        }
        if arguments.contains("--create-config") {
            AppConfig.ensureFileExists()
            print(L.f("Configuration created: %@", AppConfig.fileURL.path))
            exit(0)
        }
        if arguments.contains("--text") {
            AppConfig.forceReload()
            print(TextOutput.statusLine())
            exit(0)
        }
        if arguments.contains("--balance") {
            AppConfig.forceReload()
            exit(CLIBalance.run())
        }
        if arguments.contains("--cost") {
            AppConfig.forceReload()
            exit(CLICost.run())
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    private var timer: Timer?
    private var previousTariff: Tariff?
    private var firedReminders = Set<String>()

    // Guthaben-Zustand
    private var balanceResponse: BalanceResponse?
    private var balanceError: String?
    private var balanceFetching = false
    private var nextBalanceFetch: Date?
    private var balanceWasLow = false

    // Verbrauchs-Zustand
    private var usageSessions: [SessionUsage]?
    private var usageWarnings: [String] = []
    private var usageUnreadable = 0
    private var usageScanning = false
    private var nextUsageScan: Date?

    // Dynamische Menüzeilen (werden jede Sekunde aktualisiert)
    private var tariffLine: NSMenuItem!
    private var detailLine: NSMenuItem!
    private var todayLine: NSMenuItem!
    private var tomorrowLine: NSMenuItem!
    private var nowLine: NSMenuItem!
    private var balanceLine: NSMenuItem!
    private var balanceSubLine: NSMenuItem!
    private var balanceWarnItem: NSMenuItem!
    private var balanceTitleItem: NSMenuItem!
    private var usageLine: NSMenuItem!
    private var usageSubLine: NSMenuItem!
    private var notifyItem: NSMenuItem!
    private var reminderItem: NSMenuItem!
    private var autostartItem: NSMenuItem!

    private var menuOpen = false

    // MARK: Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        AppConfig.ensureFileExists()
        _ = AppConfig.syncFromDiskIfNeeded()

        setupStatusItem()
        setupMenu()
        startTimer()

        UNUserNotificationCenter.current().delegate = self
        let cfg = AppConfig.current
        if cfg.notifyOnChange || cfg.remindersEnabled || cfg.balanceWarnEnabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        previousTariff = DSSchedule.tariff(at: Date())
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    // MARK: Status-Item

    private func setupStatusItem() {
        statusItem.button?.setAccessibilityLabel("DeepSeek Off-Peak Status")
    }

    private var statusButton: NSStatusBarButton? { statusItem.button }

    // MARK: Menü

    private func setupMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        tariffLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        detailLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(tariffLine)
        menu.addItem(detailLine)
        menu.addItem(.separator())

        todayLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        tomorrowLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(todayLine)
        menu.addItem(tomorrowLine)
        menu.addItem(.separator())

        nowLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(nowLine)
        menu.addItem(.separator())

        balanceLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        balanceSubLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(balanceLine)
        menu.addItem(balanceSubLine)

        let balanceNow = NSMenuItem(title: L.t("Refresh balance now"), action: #selector(refreshBalanceNow), keyEquivalent: "")
        balanceNow.target = self
        menu.addItem(balanceNow)

        balanceWarnItem = NSMenuItem(title: L.t("Warn on low balance"), action: #selector(toggleBalanceWarn), keyEquivalent: "")
        balanceWarnItem.target = self
        menu.addItem(balanceWarnItem)

        balanceTitleItem = NSMenuItem(title: L.t("Show balance in menu bar"), action: #selector(toggleBalanceInTitle), keyEquivalent: "")
        balanceTitleItem.target = self
        menu.addItem(balanceTitleItem)

        menu.addItem(.separator())

        usageLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        usageSubLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(usageLine)
        menu.addItem(usageSubLine)

        let usageNow = NSMenuItem(title: L.t("Refresh usage now"), action: #selector(refreshUsageNow), keyEquivalent: "")
        usageNow.target = self
        menu.addItem(usageNow)

        let usageDetails = NSMenuItem(title: L.t("Details in Terminal (--cost)"), action: #selector(openCostInTerminal), keyEquivalent: "")
        usageDetails.target = self
        menu.addItem(usageDetails)

        menu.addItem(.separator())

        let pricing = NSMenuItem(title: L.t("Open DeepSeek pricing & windows"), action: #selector(openPricing), keyEquivalent: "")
        pricing.target = self
        menu.addItem(pricing)

        let startDSH = NSMenuItem(title: L.t("Start DSH Web (alias „deepseek“)"), action: #selector(startDSHWeb), keyEquivalent: "")
        startDSH.target = self
        menu.addItem(startDSH)

        let dshWeb = NSMenuItem(title: L.t("Open DSH Web in browser (http://127.0.0.1:3080)"), action: #selector(openDSHWeb), keyEquivalent: "")
        dshWeb.target = self
        menu.addItem(dshWeb)

        let copy = NSMenuItem(title: L.t("Copy status to clipboard"), action: #selector(copyStatus), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)

        menu.addItem(.separator())

        notifyItem = NSMenuItem(title: L.t("Notify on tariff change"), action: #selector(toggleNotifications), keyEquivalent: "")
        notifyItem.target = self
        menu.addItem(notifyItem)

        reminderItem = NSMenuItem(title: L.t("Reminders before a change"), action: #selector(toggleReminders), keyEquivalent: "")
        reminderItem.target = self
        menu.addItem(reminderItem)

        autostartItem = NSMenuItem(title: L.t("Start at login"), action: #selector(toggleAutostart), keyEquivalent: "")
        autostartItem.target = self
        menu.addItem(autostartItem)

        menu.addItem(.separator())

        let editConfig = NSMenuItem(title: L.t("Edit configuration …"), action: #selector(openConfigFile), keyEquivalent: "")
        editConfig.target = self
        menu.addItem(editConfig)

        let resetConfig = NSMenuItem(title: L.t("Restore default window rules"), action: #selector(resetConfig), keyEquivalent: "")
        resetConfig.target = self
        menu.addItem(resetConfig)

        menu.addItem(.separator())

        let disclaimer = NSMenuItem(title: L.t("Unofficial, not affiliated with DeepSeek"), action: nil, keyEquivalent: "")
        disclaimer.isEnabled = false
        menu.addItem(disclaimer)

        let quit = NSMenuItem(title: L.t("Quit"), action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: Timer & Refresh

    private func startTimer() {
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func refresh() {
        // Konfigurationsdatei live überwachen
        if AppConfig.syncFromDiskIfNeeded() {
            previousTariff = DSSchedule.tariff(at: Date())
            firedReminders.removeAll()
            // Config-Änderung (z. B. neuer Key) → Guthaben-Cache verwerfen
            balanceResponse = nil
            balanceError = nil
            nextBalanceFetch = Date().addingTimeInterval(1)
            // Auch Verbrauchs-Auswertung neu anstoßen
            usageSessions = nil
            nextUsageScan = Date().addingTimeInterval(1)
        }

        maybeFetchBalanceIfDue()
        maybeScanUsageIfDue()

        let now = Date()
        let tariff = DSSchedule.tariff(at: now)
        let transition = DSSchedule.nextTransition(after: now)

        updateTitle(now: now, tariff: tariff, transition: transition)
        updateMenu(now: now, tariff: tariff, transition: transition)

        let config = AppConfig.current

        // Benachrichtigung bei Tarifwechsel
        if let previous = previousTariff, previous != tariff {
            previousTariff = tariff
            if config.notifyOnChange {
                sendTransitionNotification(to: tariff, transition: transition)
            }
        }

        // Erinnerungen kurz vor dem Wechsel
        if let transition = transition, config.notifyOnChange, config.remindersEnabled {
            sendReminderIfDue(now: now, transition: transition, tariff: tariff)
        }
    }

    // MARK: Guthaben

    /// Startet die Abfrage, wenn die Wartezeit abgelaufen ist und ein Key existiert.
    private func maybeFetchBalanceIfDue() {
        let config = AppConfig.current
        guard !balanceFetching else { return }

        if DeepSeekBalance.resolveAPIKey(config: config) == nil {
            balanceResponse = nil
            balanceError = BalanceError.noAPIKey.localizedDescription
            nextBalanceFetch = Date().addingTimeInterval(60)
            return
        }

        if let next = nextBalanceFetch, Date() < next { return }

        balanceFetching = true
        DeepSeekBalance.fetch(config: config) { [weak self] result in
            guard let self else { return }
            self.balanceFetching = false
            switch result {
            case .success(let response):
                self.balanceResponse = response
                self.balanceError = nil
                self.evaluateLowBalance(response)
            case .failure(let error):
                self.balanceResponse = nil
                self.balanceError = error.localizedDescription
            }
            self.nextBalanceFetch = Date().addingTimeInterval(TimeInterval(config.balanceRefreshMinutes * 60))
            self.refresh()
        }
    }

    /// Bevorzugtes Konto (USD bevorzugt, sonst das erste).
    private func preferredBalanceInfo() -> BalanceInfo? {
        guard let infos = balanceResponse?.balance_infos, !infos.isEmpty else { return nil }
        return infos.first { $0.currency.uppercased() == "USD" } ?? infos.first
    }

    private func evaluateLowBalance(_ response: BalanceResponse) {
        let config = AppConfig.current
        guard config.balanceWarnEnabled else {
            balanceWasLow = false
            return
        }
        guard let info = preferredBalanceInfo(), let total = Double(info.total_balance) else {
            balanceWasLow = false
            return
        }
        let low = total > 0 && total < config.balanceWarnBelow
        if low && !balanceWasLow {
            let content = UNMutableNotificationContent()
            content.title = L.t("DeepSeek balance low")
            content.body = L.f("Only %@ left – threshold %@.", Fmt.money(total, currency: info.currency), Fmt.money(config.balanceWarnBelow, currency: info.currency))
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
        balanceWasLow = low
    }

    private func updateBalanceMenu(now: Date) {
        let config = AppConfig.current
        balanceWarnItem.state = config.balanceWarnEnabled ? .on : .off
        balanceTitleItem.state = config.showBalanceInTitle ? .on : .off

        guard let info = preferredBalanceInfo(),
              let total = Double(info.total_balance) else {
            balanceLine.title = L.t("Balance: –")
            balanceSubLine.title = balanceError ?? L.t("Fetching …")
            return
        }

        let granted = Double(info.granted_balance) ?? 0
        let toppedUp = Double(info.topped_up_balance) ?? 0
        let low = config.balanceWarnEnabled && total > 0 && total < config.balanceWarnBelow

        let text: String
        if low {
            text = L.f("⚠ Low balance: %@", Fmt.money(total, currency: info.currency))
        } else {
            let status = balanceResponse?.is_available == false ? L.t(" – not enough for API calls") : ""
            text = L.f("Balance: %@%@", Fmt.money(total, currency: info.currency), status)
        }
        let attr = NSMutableAttributedString(string: text, attributes: [
            .foregroundColor: low ? NSColor.systemRed : NSColor.labelColor,
            .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        ])
        balanceLine.attributedTitle = attr

        var detail = L.f("granted %@ · topped up %@ · as of %@", Fmt.money(granted, currency: info.currency), Fmt.money(toppedUp, currency: info.currency), Fmt.localTime(now))
        if let infos = balanceResponse?.balance_infos, infos.count > 1 {
            let others = infos.filter { $0.currency != info.currency }
                .compactMap { other -> String? in
                    guard let t = Double(other.total_balance) else { return nil }
                    return "\(other.currency): \(Fmt.money(t, currency: other.currency))"
                }
            if !others.isEmpty { detail += " · " + others.joined(separator: " · ") }
        }
        balanceSubLine.title = detail
    }

    // MARK: Verbrauch

    /// Startet die Log-Auswertung (Hintergrund), wenn die Wartezeit abgelaufen ist.
    private func maybeScanUsageIfDue() {
        let config = AppConfig.current
        guard !usageScanning else { return }
        if let next = nextUsageScan, Date() < next { return }
        usageScanning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let (sessions, unreadable, warnings) = UsageScanner.scanAll(config: config)
            DispatchQueue.main.async {
                guard let self else { return }
                self.usageSessions = sessions.isEmpty ? nil : sessions
                self.usageWarnings = warnings
                self.usageUnreadable = unreadable
                self.usageScanning = false
                self.nextUsageScan = Date().addingTimeInterval(TimeInterval(max(1, config.usageRefreshMinutes) * 60))
                self.refresh()
            }
        }
    }

    @objc private func refreshUsageNow() {
        usageSessions = nil
        nextUsageScan = Date()
        maybeScanUsageIfDue()
    }

    private func updateUsageMenu(now: Date) {
        guard let sessions = usageSessions else {
            usageLine.title = usageWarnings.isEmpty ? L.t("Usage: loading …") : L.t("Usage: –")
            if !usageWarnings.isEmpty {
                usageSubLine.title = usageWarnings[0]
            } else if usageUnreadable > 0 {
                usageSubLine.title = L.f("%d running session(s) not readable right now – try again.", usageUnreadable)
            } else {
                usageSubLine.title = "Liest die DSH-Session-Logs …"
            }
            return
        }
        let config = AppConfig.current
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        let sevenAgo = cal.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        let today = UsageSummary.totals(of: sessions, newerThan: todayStart)
        let week = UsageSummary.totals(of: sessions, newerThan: sevenAgo)
        let all = UsageSummary.totals(of: sessions, newerThan: nil)

        let input = Fmt.formatTokens(today.inputTotal)
        let out = Fmt.formatTokens(today.out)
        let rate = today.inputTotal > 0
            ? String(format: "%.1f", today.cacheRate * 100).replacingOccurrences(of: ".", with: ",") + " %"
            : "–"
        usageLine.title = L.f("Usage today: %d sessions · input %@ (%@ cache) · output %@ · cost %@", today.sessions, input, rate, out, UsageSummary.costText(usd: today.usdActual, config: config))

        var sub = L.f("Last 7 days: %d sessions · %@ tokens · cost %@ · total %d sessions", week.sessions, Fmt.formatTokens(week.inputTotal), UsageSummary.costText(usd: week.usdActual, config: config), all.sessions)
        if usageUnreadable > 0 {
            sub += L.f(" · %d running not counted", usageUnreadable)
        } else if !usageWarnings.isEmpty {
            sub += " ⚠ \(usageWarnings[0])"
        }
        usageSubLine.title = sub
    }

    /// Öffnet die Detail-Liste (`--cost`) in einem Terminal-Fenster.
    @objc private func openCostInTerminal() {
        guard let bin = Bundle.main.executablePath, !bin.isEmpty else { return }
        let fm = FileManager.default
        let dir = AppConfig.fileURL.deletingLastPathComponent()
        let scriptURL = dir.appendingPathComponent("dsh-cost.command")
        let content = """
        #!/bin/bash
        "\(bin)" --cost
        echo
        echo "Done – window will close."
        sleep 3
        """
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try content.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            if !NSWorkspace.shared.open(scriptURL) {
                showAlert(title: L.t("Could not open Terminal"),
                          text: L.f("The file %@ could not be opened in Terminal.", scriptURL.path))
            }
        } catch {
            showAlert(title: L.t("Could not start usage details"),
                      text: L.f("The script could not be created: %@", error.localizedDescription))
        }
    }

    // MARK: Titel (Menüleiste)

    private func updateTitle(now: Date, tariff: Tariff, transition: Date?) {
        guard let button = statusButton else { return }

        // Nur farbiger Punkt + Countdown. Der Zustand steckt in der Farbe
        // (grün = off-peak, orange = Peak) und im Tooltip/Menü.
        var countdown = ""
        switch tariff {
        case .offPeak:
            if let end = transition {
                countdown = Fmt.compactCountdown(end.timeIntervalSince(now))
            }
        case .peak:
            if let start = transition {
                countdown = Fmt.compactCountdown(start.timeIntervalSince(now))
            }
        }

        let dotColor: NSColor = tariff.isOffPeak ? .systemGreen : .systemOrange
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(string: "● ", attributes: [
            .foregroundColor: dotColor,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .bold)
        ]))
        attributed.append(NSAttributedString(string: countdown, attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        ]))

        // Optional Guthaben in der Menüleiste anzeigen
        let config = AppConfig.current
        if config.showBalanceInTitle,
           let info = preferredBalanceInfo(),
           let total = Double(info.total_balance) {
            let low = config.balanceWarnEnabled && total > 0 && total < config.balanceWarnBelow
            let balanceText = " · " + (low ? "⚠ " : "") + Fmt.moneyCompact(total, currency: info.currency)
            attributed.append(NSAttributedString(string: balanceText, attributes: [
                .foregroundColor: low ? NSColor.systemRed : NSColor.labelColor,
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            ]))
        }
        button.attributedTitle = attributed

        switch tariff {
        case .offPeak:
            if let end = transition {
                button.toolTip = L.f("DeepSeek off-peak: cheap for another %@ (50%% off), ends %@", Fmt.durationWords(end.timeIntervalSince(now)), Fmt.localTime(end))
            } else {
                button.toolTip = "DeepSeek Off-Peak aktiv (50 % Rabatt)"
            }
        case .peak:
            if let start = transition {
                button.toolTip = L.f("DeepSeek peak pricing. Off-peak starts %@ (in %@)", Fmt.localTime(start), Fmt.durationWords(start.timeIntervalSince(now)))
            } else {
                button.toolTip = L.t("DeepSeek peak pricing active")
            }
        }
        if let info = preferredBalanceInfo(), let total = Double(info.total_balance) {
            let granted = Double(info.granted_balance) ?? 0
            let toppedUp = Double(info.topped_up_balance) ?? 0
            button.toolTip = (button.toolTip ?? "") + L.f("\nBalance: %@ (granted %@, topped up %@)", Fmt.money(total, currency: info.currency), Fmt.money(granted, currency: info.currency), Fmt.money(toppedUp, currency: info.currency))
        } else if let errorText = balanceError {
            button.toolTip = (button.toolTip ?? "") + L.f("\nBalance: %@", errorText)
        }
    }

    // MARK: Menü-Inhalte

    private func updateMenu(now: Date, tariff: Tariff, transition: Date?) {
        let headline: String
        let headlineColor: NSColor
        switch tariff {
        case .offPeak:
            headline = L.t("Off-peak · 50% off")
            headlineColor = .systemGreen
        case .peak:
            headline = L.t("Peak pricing · full price")
            headlineColor = .systemOrange
        }
        let attr = NSMutableAttributedString(string: headline, attributes: [
            .foregroundColor: headlineColor,
            .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        ])
        tariffLine.attributedTitle = attr

        switch tariff {
        case .offPeak:
            if let end = transition {
                detailLine.title = L.f("Cheap for another %@ – switching to peak at %@", Fmt.durationWords(end.timeIntervalSince(now)), Fmt.localTime(end))
            } else {
                detailLine.title = L.t("Cheap all day (50% off)")
            }
        case .peak:
            if let start = transition {
                detailLine.title = L.f("Off-peak (50%% off) starts %@", Fmt.untilWords(now: now, target: start))
            } else {
                detailLine.title = L.t("No off-peak in sight")
            }
        }

        todayLine.title = L.f("Today (%@): ", Fmt.weekdayDate(now)) + dayScheduleLabel(for: now)
        if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) {
            tomorrowLine.title = L.f("Tomorrow (%@): ", Fmt.weekdayDate(tomorrow)) + dayScheduleLabel(for: tomorrow)
        } else {
            tomorrowLine.title = ""
        }

        let dayFormatter = DateFormatter()
        dayFormatter.locale = L.locale
        dayFormatter.timeZone = .current
        dayFormatter.dateFormat = "EEEE, d. MMMM yyyy, HH:mm"
        let utcFormatter = DateFormatter()
        utcFormatter.locale = L.locale
        utcFormatter.timeZone = DSSchedule.utc
        utcFormatter.dateFormat = "HH:mm"
        nowLine.title = L.f("Now: %@ local · %@ UTC", dayFormatter.string(from: now), utcFormatter.string(from: now))

        let cfg = AppConfig.current
        notifyItem.state = cfg.notifyOnChange ? .on : .off
        reminderItem.state = (cfg.notifyOnChange && cfg.remindersEnabled) ? .on : .off
        autostartItem.state = autostartEnabled ? .on : .off

        updateBalanceMenu(now: now)
        updateUsageMenu(now: now)
    }

    /// Beschreibt den Tarifverlauf eines lokalen Tages, z. B.
    /// "Peak 05:00–08:00 und 10:00–14:00" oder L.t("off-peak all day (weekend)").
    private func dayScheduleLabel(for date: Date) -> String {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: date)
        guard let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) else { return "–" }
        let config = AppConfig.current

        var ranges: [(start: Date, end: Date)] = []
        var inPeak = false
        var runStart = startOfDay
        var cursor = startOfDay
        while cursor < endOfDay {
            let isPeak = DSSchedule.tariff(at: cursor, config: config).isPeak
            if isPeak && !inPeak {
                inPeak = true
                runStart = cursor
            } else if !isPeak && inPeak {
                inPeak = false
                ranges.append((runStart, cursor))
            }
            guard let next = cal.date(byAdding: .minute, value: 30, to: cursor) else { break }
            cursor = next
        }
        if inPeak { ranges.append((runStart, endOfDay)) }

        if ranges.isEmpty {
            return DSSchedule.isWeekendDay(date, config: config)
                ? L.t("off-peak all day (weekend)")
                : L.t("off-peak all day")
        }

        let pieces = ranges.map { "\(Fmt.localTime($0.start))–\(Fmt.localTime($0.end))" }
        return "Peak " + pieces.joined(separator: L.t(" and ")) + L.t(" (cheap afterwards)")
    }

    // MARK: Autostart

    private var autostartEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc private func toggleAutostart() {
        if #available(macOS 13.0, *) {
            do {
                if autostartEnabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = L.t("Cannot enable start at login")
                alert.informativeText = L.f("Start at login requires the app to be in /Applications (or ~/Applications): %@", Bundle.main.bundlePath)
                alert.alertStyle = .warning
                alert.runModal()
            }
        } else {
            let alert = NSAlert()
            alert.messageText = L.t("Start at login unavailable")
            alert.informativeText = L.t("This Mac does not support start at login via SMAppService.")
            alert.alertStyle = .warning
            alert.runModal()
        }
        refresh()
    }

    // MARK: Benachrichtigungen

    @objc private func toggleNotifications() {
        AppConfig.current.notifyOnChange.toggle()
        try? AppConfig.save()
        if AppConfig.current.notifyOnChange {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                DispatchQueue.main.async {
                    if !granted {
                        AppConfig.current.notifyOnChange = false
                        try? AppConfig.save()
                    }
                    self.refresh()
                }
            }
        }
        refresh()
    }

    @objc private func toggleReminders() {
        AppConfig.current.remindersEnabled.toggle()
        try? AppConfig.save()
        if AppConfig.current.remindersEnabled && AppConfig.current.notifyOnChange {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        refresh()
    }

    @objc private func refreshBalanceNow() {
        balanceError = nil
        nextBalanceFetch = Date()
        maybeFetchBalanceIfDue()
        refresh()
    }

    @objc private func toggleBalanceWarn() {
        AppConfig.current.balanceWarnEnabled.toggle()
        try? AppConfig.save()
        if AppConfig.current.balanceWarnEnabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        refresh()
    }

    @objc private func toggleBalanceInTitle() {
        AppConfig.current.showBalanceInTitle.toggle()
        try? AppConfig.save()
        refresh()
    }

    private func sendTransitionNotification(to tariff: Tariff, transition: Date?) {
        let content = UNMutableNotificationContent()
        switch tariff {
        case .offPeak:
            content.title = L.t("DeepSeek off-peak starts")
            content.body = L.t("Prices are 50% cheaper now.")
        case .peak:
            content.title = L.t("DeepSeek peak pricing starts")
            if let start = DSSchedule.nextTransition(after: Date()) {
                content.body = L.f("Off-peak starts again at %@.", Fmt.localTime(start))
            } else {
                content.body = L.t("The cheap tariff is over.")
            }
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Erinnerung, wenn die Restzeit eine konfigurierte Schwelle unterschreitet
    /// (pro Fenster und Schwelle genau einmal).
    private func sendReminderIfDue(now: Date, transition: Date, tariff: Tariff) {
        let config = AppConfig.current
        let remaining = transition.timeIntervalSince(now)
        guard remaining > 0 else { return }

        let thresholds = tariff.isOffPeak ? config.remindBeforeEndMinutes : config.remindBeforeStartMinutes
        let isEndReminder = tariff.isOffPeak
        let blockKey = Int(transition.timeIntervalSince1970)

        for minutes in thresholds {
            if Int(remaining) / 60 <= minutes {
                let key = "\(isEndReminder ? "end" : "start"):\(blockKey):\(minutes)"
                if firedReminders.contains(key) { continue }
                firedReminders.insert(key)

                let content = UNMutableNotificationContent()
                if isEndReminder {
                    content.title = L.t("Off-peak ends soon")
                    content.body = L.f("About %@ left at the cheap rate – switching to peak at %@.", Fmt.minutesWords(minutes), Fmt.localTime(transition))
                } else {
                    content.title = L.t("Off-peak starts soon")
                    content.body = L.f("The cheap rate (50%% off) starts in about %@.", Fmt.minutesWords(minutes))
                }
                content.sound = .default
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                UNUserNotificationCenter.current().add(request)
            }
        }

        // Alte Einträge aufräumen (Fenster, die länger als 3 Tage zurückliegen)
        if firedReminders.count > 200 {
            let cutoff = now.timeIntervalSince1970 - 3 * 86400
            firedReminders = firedReminders.filter { key in
                if let ts = key.split(separator: ":").dropFirst().first, let block = Int(ts) {
                    return Double(block) >= cutoff
                }
                return true
            }
        }
    }

    // MARK: Konfigurationsaktionen

    @objc private func openConfigFile() {
        AppConfig.ensureFileExists()
        // Immer mit TextEdit öffnen – nicht mit der System-Standard-App
        // (sonst landet die .json bei Xcode).
        if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([AppConfig.fileURL], withApplicationAt: textEdit,
                                    configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(AppConfig.fileURL)
        }
    }

    @objc private func resetConfig() {
        let alert = NSAlert()
        alert.messageText = L.t("Restore default window rules?")
        alert.informativeText = L.t("Your configuration will be reset to the official DeepSeek windows (Mon–Fri 01–04 & 06–10 UTC, off-peak all weekend).")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L.t("Reset"))
        alert.addButton(withTitle: L.t("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        AppConfig.resetToStandard()
        previousTariff = DSSchedule.tariff(at: Date())
        firedReminders.removeAll()
        refresh()
    }

    // MARK: Weitere Aktionen

    @objc private func openPricing() {
        NSWorkspace.shared.open(DSSchedule.pricingURL)
    }

    @objc private func openDSHWeb() {
        if let url = URL(string: "http://127.0.0.1:3080") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Startet "npx @deepseek-ai/dsh web" über den Alias »deepseek« aus ~/.bashrc
    /// in einem neuen Terminal-Fenster (sichtbare Logs, per Ctrl+C beendbar).
    ///
    /// Umsetzung ohne AppleScript/Automation-Berechtigung: Die App schreibt ein
    /// ausführbares .command-Skript und öffnet es per LaunchServices in Terminal.
    @objc private func startDSHWeb() {
        dshWebRunning { [weak self] running in
            guard let self else { return }
            if running {
                let alert = NSAlert()
                alert.messageText = L.t("DSH Web is already running")
                alert.informativeText = L.t("Something is already answering on 127.0.0.1:3080 (probably the instance you are using). A second start fails with \u{201E}EADDRINUSE\u{201C} \u{2013} open the running instance in the browser instead.")
                alert.addButton(withTitle: L.t("Open in browser"))
                alert.addButton(withTitle: "Trotzdem starten")
                if alert.runModal() == .alertFirstButtonReturn {
                    self.openDSHWeb()
                    return
                }
            }
            self.launchDSHWebCommand()
        }
    }

    /// Prüft kurz, ob auf 127.0.0.1:3080 bereits ein DSH-Web-Server antwortet.
    private func dshWebRunning(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:3080/") else {
            completion(false)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if response is HTTPURLResponse {
                    completion(true)
                    return
                }
                if let urlError = error as? URLError,
                   [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut].contains(urlError.code) {
                    completion(false)
                    return
                }
                completion(response != nil)
            }
        }.resume()
    }

    private func launchDSHWebCommand() {
        let fm = FileManager.default
        let dir = AppConfig.fileURL.deletingLastPathComponent()
        let scriptURL = dir.appendingPathComponent("start-dsh-web.command")
        let content = """
        #!/bin/bash
        # DeepSeek Off-Peak: start DSH Web via the "deepseek" alias (~/.bashrc)
        # or directly via npx. Runs in Terminal, stop with Ctrl+C.
        cd "$HOME" || exit 1
        bash -ic 'deepseek'
        code=$?
        if [ "$code" -eq 127 ]; then
          echo "Alias 'deepseek' not found (exit 127) – starting directly:"
          npx @deepseek-ai/dsh web
        fi
        echo
        echo "DSH Web finished – window will close."
        sleep 2
        """
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try content.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            if !NSWorkspace.shared.open(scriptURL) {
                showAlert(title: L.t("Could not open Terminal"),
                          text: L.f("The file %@ could not be opened in Terminal.", scriptURL.path))
            }
        } catch {
            showAlert(title: L.t("Could not start DSH Web"),
                      text: L.f("The start script could not be created: %@", error.localizedDescription))
        }
    }

    private func showAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func copyStatus() {
        let text = TextOutput.statusLine()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        refresh()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        refresh()
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Selbsttest

enum SelfTest {
    static func makeUTC(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = DSSchedule.utc
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static func expectTariff(_ date: Date, _ expected: Tariff, _ label: String,
                             config: AppConfigData = .standard) -> Bool {
        let actual = DSSchedule.tariff(at: date, config: config)
        let ok = actual == expected
        print(ok ? "PASS \(label)" : "FAIL \(label): erwartet \(expected), ist \(actual)")
        return ok
    }

    static func expectTransition(_ from: Date, _ expected: Date?, _ label: String,
                                 config: AppConfigData = .standard) -> Bool {
        let actual = DSSchedule.nextTransition(after: from, config: config)
        let ok = actual == expected
        let actualStr = actual.map { $0.description } ?? "nil"
        let expectedStr = expected.map { $0.description } ?? "nil"
        print(ok ? "PASS \(label)" : "FAIL \(label): erwartet \(expectedStr), ist \(actualStr)")
        return ok
    }

    /// Beijing-Regel (offizielle Ankündigung vom 23.08.2026):
    /// Wochenende = Samstag/Sonntag in Peking-Zeit (UTC+8) → ganztägig off-peak;
    /// Peking-Werktage: Peak 09–12 und 14–18 Peking-Zeit.
    static func beijingTariff(_ date: Date) -> Tariff {
        let beijing = TimeZone(identifier: "Asia/Shanghai")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = beijing
        let comps = cal.dateComponents([.weekday, .hour], from: date)
        let weekday = comps.weekday! // 1 = Sonntag … 7 = Samstag
        if weekday == 1 || weekday == 7 { return .offPeak }
        let hour = comps.hour!
        if (hour >= 9 && hour < 12) || (hour >= 14 && hour < 18) { return .peak }
        return .offPeak
    }

    /// Prüft, ob die UTC-Formulierung und die Peking-Regel identische Tarife liefern.
    static func verifyBeijingEquivalence(from: Date, to: Date) -> Bool {
        var cursor = from
        var samples = 0
        var mismatches = 0
        let step: TimeInterval = 15 * 60
        while cursor < to {
            samples += 1
            let appTariff = DSSchedule.tariff(at: cursor, config: .standard)
            if appTariff != beijingTariff(cursor) {
                mismatches += 1
                if mismatches <= 5 {
                    print("  MISMATCH: \(cursor) UTC → App \(appTariff), Beijing \(beijingTariff(cursor))")
                }
            }
            cursor = cursor.addingTimeInterval(step)
        }
        if mismatches == 0 {
            print("PASS Beijing vs UTC rule: \(samples) samples (every 15 min, \(from) bis \(to)) identical")
            return true
        } else {
            print("FAIL Beijing vs UTC rule: \(mismatches) of \(samples) samples differ")
            return false
        }
    }

    static func run() -> Bool {
        var ok = true

        // Äquivalenz zur offiziellen Peking-Regel über den Regelwechsel hinweg
        ok = verifyBeijingEquivalence(from: makeUTC(2026, 8, 21, 0, 0),
                                      to: makeUTC(2026, 9, 2, 0, 0)) && ok

        // 2026-09-07 ist ein Montag (UTC), 2026-09-05 ein Samstag, 2026-09-06 ein Sonntag
        ok = expectTariff(makeUTC(2026, 9, 7, 0, 30), .offPeak, "Mo 00:30 UTC = off-peak") && ok
        ok = expectTariff(makeUTC(2026, 9, 7, 1, 0), .peak, "Mo 01:00 UTC = peak (boundary inclusive)") && ok
        ok = expectTariff(makeUTC(2026, 9, 7, 2, 0), .peak, "Mo 02:00 UTC = peak") && ok
        ok = expectTariff(makeUTC(2026, 9, 7, 3, 59), .peak, "Mo 03:59 UTC = peak") && ok
        ok = expectTariff(makeUTC(2026, 9, 7, 4, 0), .offPeak, "Mo 04:00 UTC = off-peak") && ok
        ok = expectTariff(makeUTC(2026, 9, 7, 5, 0), .offPeak, "Mo 05:00 UTC = off-peak") && ok
        ok = expectTariff(makeUTC(2026, 9, 7, 6, 0), .peak, "Mo 06:00 UTC = peak") && ok
        ok = expectTariff(makeUTC(2026, 9, 7, 9, 59), .peak, "Mo 09:59 UTC = peak") && ok
        ok = expectTariff(makeUTC(2026, 9, 7, 10, 0), .offPeak, "Mo 10:00 UTC = off-peak") && ok
        ok = expectTariff(makeUTC(2026, 9, 7, 23, 0), .offPeak, "Mo 23:00 UTC = off-peak") && ok

        // Wochenende: ganztägig off-peak (Standard-Konfiguration)
        ok = expectTariff(makeUTC(2026, 9, 5, 2, 0), .offPeak, "Sa 02:00 UTC = off-peak") && ok
        ok = expectTariff(makeUTC(2026, 9, 5, 7, 0), .offPeak, "Sa 07:00 UTC = off-peak") && ok
        ok = expectTariff(makeUTC(2026, 9, 6, 4, 0), .offPeak, "So 04:00 UTC = off-peak") && ok

        // Übergänge (Standard-Konfiguration)
        ok = expectTransition(makeUTC(2026, 9, 7, 2, 0), makeUTC(2026, 9, 7, 4, 0), "transition Mon 02:00 → 04:00") && ok
        ok = expectTransition(makeUTC(2026, 9, 7, 5, 0), makeUTC(2026, 9, 7, 6, 0), "transition Mon 05:00 → 06:00") && ok
        ok = expectTransition(makeUTC(2026, 9, 7, 12, 0), makeUTC(2026, 9, 8, 1, 0), "transition Mon 12:00 → Di 01:00") && ok
        ok = expectTransition(makeUTC(2026, 9, 5, 12, 0), makeUTC(2026, 9, 7, 1, 0), "transition Sat 12:00 → Mo 01:00 (across the weekend)") && ok
        ok = expectTransition(makeUTC(2026, 9, 4, 12, 0), makeUTC(2026, 9, 7, 1, 0), "transition Fri 12:00 → Mo 01:00") && ok

        // Eigene Fenster aus der Konfiguration (z. B. neues Fenster 02–05 UTC,
        // Wochenenden nicht mehr ausgenommen)
        let custom = AppConfigData(
            peakWindowsUtc: [PeakWindow(startHour: 2, endHour: 5)],
            weekendsOffPeak: false,
            weekendTimeZone: "UTC",
            notifyOnChange: true,
            remindersEnabled: true,
            remindBeforeEndMinutes: [10],
            remindBeforeStartMinutes: [10]
        )
        ok = expectTariff(makeUTC(2026, 9, 7, 3, 0), .peak, "config 02–05 UTC: Mo 03:00 = peak", config: custom) && ok
        ok = expectTariff(makeUTC(2026, 9, 7, 6, 0), .offPeak, "config 02–05 UTC: Mo 06:00 = off-peak", config: custom) && ok
        ok = expectTariff(makeUTC(2026, 9, 5, 3, 0), .peak, "config without weekend exemption: Sa 03:00 = peak", config: custom) && ok
        ok = expectTransition(makeUTC(2026, 9, 5, 5, 0), makeUTC(2026, 9, 6, 2, 0),
                              "config 02–05 UTC: transition Sat 05:00 → So 02:00", config: custom) && ok

        // Erinnerungsschwellen: unsinnige Werte werden gefiltert/sortiert
        let weird = AppConfigData(
            peakWindowsUtc: [PeakWindow(startHour: 1, endHour: 4)],
            weekendsOffPeak: true,
            weekendTimeZone: "Asia/Shanghai",
            notifyOnChange: true,
            remindersEnabled: true,
            remindBeforeEndMinutes: [5, -3, 2000, 60],
            remindBeforeStartMinutes: [30, 30]
        )
        if weird.remindBeforeEndMinutes == [60, 5] && weird.remindBeforeStartMinutes == [30] {
            print("PASS reminder thresholds are sanitized")
        } else {
            print("FAIL reminder thresholds are sanitized: \(weird.remindBeforeEndMinutes) / \(weird.remindBeforeStartMinutes)")
            ok = false
        }
        if weird.peakWindowsUtc.count == 1 {
            print("PASS window rules are sanitized")
        } else {
            print("FAIL window rules are sanitized")
            ok = false
        }

        // Guthaben-Antwort (offizielles Schema) dekodieren + Geldformat prüfen
        let sample = """
        {"is_available":true,"balance_infos":[
          {"currency":"USD","total_balance":"12.34","granted_balance":"2.00","topped_up_balance":"10.34"},
          {"currency":"CNY","total_balance":"88.50","granted_balance":"0.00","topped_up_balance":"88.50"}]}
        """

        let decoded = try JSONDecoder().decod
        let decoded = try JSONDecoder().decod
        L.configure(language: "de")

        do {
            let decoded = try JSONDecoder().decode(BalanceResponse.self, from: Data(sample.utf8))
            let first = decoded.balance_infos[0]

            let total = Double(first.total_balance) ?? 0

            let checks = decoded.is_available
                && decoded.balance_infos.count == 2
                && first.total_balance == "12.34"
                && Fmt.money(total, currency: "USD") == "12,34 $"
                && Fmt.moneyCompact(total, currency: "USD") == "12,34$"
                && Fmt.moneyCompact(Double(first.granted_balance) ?? 0, currency: "USD") == "2$"
                && Fmt.moneyCompact(88.5, currency: "CNY") == "88,5¥"

            if checks {
                print("PASS balance decoding + money format")
            } else {
                print("FAIL balance decoding or money format")
                ok = false
            }
        } catch {
            print("FAIL balance decoding: \(error)")
            ok = false
        }

        // Session-Log-Namensvarianten (alt + v3)
        let namesOK = UsageScanner.isSessionLogFileName("session.jsonl.zstd")
            && UsageScanner.isSessionLogFileName("session.v3.jsonl.zstd")
            && UsageScanner.isSessionLogFileName("session.v4.jsonl.zstd")
            && !UsageScanner.isSessionLogFileName("other.jsonl.zstd")
            && !UsageScanner.isSessionLogFileName("session.lock")
        if namesOK {
            print("PASS session log file names recognized (session.jsonl.zstd, session.v3.jsonl.zstd, …)")
        } else {
            print("FAIL session log file name detection")
            ok = false
        }

        return ok
    }
}
