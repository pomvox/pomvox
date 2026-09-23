import Foundation

/// Canonical locations, with env overrides mirroring `POMVOX_CONFIG_PATH`
/// (see `SettingsModel.defaultPath()`) so tests and rigs can redirect them.
enum DictionaryPaths {
    static func dictionaryPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let o = environment["POMVOX_DICTIONARY_PATH"], !o.isEmpty {
            return o
        }
        return NSString(string: "~/.pomvox/dictionary.toml").expandingTildeInPath
    }

    static func statsPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let o = environment["POMVOX_DICTIONARY_STATS_PATH"], !o.isEmpty {
            return o
        }
        return NSString(string: "~/.pomvox/dictionary-stats.json").expandingTildeInPath
    }
}

struct DictionaryLoadResult: Equatable {
    var file: DictionaryFile
    var fromLegacy: Bool
    var parseError: String?
}

/// Read-only resolution of the effective dictionary. Shared by the engine
/// (at arm and on reload) and by `DictionaryStore` (which additionally owns
/// the one-time legacy→file migration write — this loader never writes).
enum DictionaryLoader {

    static func load(configPath: String, dictionaryPath: String) -> DictionaryLoadResult {
        if let text = try? String(contentsOfFile: dictionaryPath, encoding: .utf8) {
            do {
                return DictionaryLoadResult(
                    file: try DictionaryDocument.parse(text), fromLegacy: false, parseError: nil)
            } catch let DictionaryParseError.malformed(line, reason) {
                NSLog("dictionary: %@ line %d: %@ — keeping last-good/empty set",
                      dictionaryPath, line, reason)
                return DictionaryLoadResult(
                    file: DictionaryFile(), fromLegacy: false,
                    parseError: "Line \(line): \(reason)")
            } catch {
                return DictionaryLoadResult(
                    file: DictionaryFile(), fromLegacy: false,
                    parseError: String(describing: error))
            }
        }
        let legacy = legacyFile(configPath: configPath)
        let hasLegacy = !legacy.words.isEmpty || !legacy.rules.isEmpty
        return DictionaryLoadResult(file: legacy, fromLegacy: hasLegacy, parseError: nil)
    }

    /// The pre-v2 `[dictionary]` shape inside config.toml, mapped 1:1 into the
    /// new model (each replacement pair becomes a single-source manual rule).
    static func legacyFile(configPath: String) -> DictionaryFile {
        let doc = ConfigDocument.load(path: configPath)
        let words = doc.stringArray("dictionary", "words") ?? []
        let rules = doc.stringTable("dictionary.replacements").map {
            DictionaryRule(sources: [$0.key], target: $0.value, enabled: true, origin: "manual")
        }
        return DictionaryFile(schema: 1, words: words, rules: rules)
    }
}
