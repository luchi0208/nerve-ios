#if DEBUG

import Foundation
import UIKit
import Security
import CoreData
import NerveObjC

// MARK: - Storage & Heap Commands

extension NerveEngine {

    @MainActor
    func handleStorage(_ command: NerveCommand) async -> NerveResponse {
        guard let type = command.stringParam("type") else {
            return .error(command.id, "Missing 'type' parameter. Use: defaults, keychain, cookies, files")
        }

        switch type {
        case "defaults": return readUserDefaults(command)
        case "cookies": return readCookies(command)
        case "files": return readSandboxFiles(command)
        case "keychain": return readKeychain(command)
        case "coredata": return readCoreData(command)
        default: return .error(command.id, "Unknown storage type: '\(type)'. Use: defaults, keychain, cookies, files, coredata")
        }
    }

    func handleHeap(_ command: NerveCommand) -> NerveResponse {
        guard let className = command.stringParam("class_name") else {
            return .error(command.id, "Missing 'class_name' parameter")
        }

        let limit = command.intParam("limit") ?? 20
        let index = command.intParam("index")
        let instances = NerveHeapInstances(className, UInt(limit))

        // Detail view: inspect a specific instance's properties
        if let index {
            guard index >= 1 && index <= instances.count else {
                return .error(command.id, "Instance #\(index) not found. Found \(instances.count) instances of '\(className)'")
            }
            let obj = instances[index - 1] as AnyObject
            guard let nsObj = obj as? NSObject else {
                return .error(command.id, "Instance is not an NSObject — cannot inspect properties")
            }
            let addr = String(format: "%p", unsafeBitCast(obj, to: UInt.self))
            var lines = ["heap inspect: \(NerveClassName(obj)) \(addr)", "---"]

            let cls: AnyClass = object_getClass(obj)!
            let allProps = NerveListProperties(cls) as? [String: String] ?? [:]

            for name in allProps.keys.sorted() {
                // NerveReadProperty uses @try/@catch in ObjC, returns nil on failure
                let value = NerveReadProperty(nsObj, name)
                lines.append("  \(name) = \(describeValue(value))")
            }

            if allProps.isEmpty {
                lines.append("  (no ObjC-visible properties)")
            }

            return .success(command.id, lines.joined(separator: "\n"))
        }

        // List view: show all instances
        var lines = ["heap: \(instances.count) instances of '\(className)'", "---"]
        for (i, obj) in instances.enumerated() {
            let desc = NerveClassName(obj as AnyObject)
            let addr = String(format: "%p", unsafeBitCast(obj as AnyObject, to: UInt.self))
            var line = "#\(i + 1) \(desc) \(addr)"

            if let readable = obj as? NSObject {
                if let desc = NerveReadProperty(readable, "description") as? String, desc.count < 80 {
                    line += " → \(desc)"
                }
            }
            lines.append(line)
        }

        return .success(command.id, lines.joined(separator: "\n"))
    }

    private func describeValue(_ value: Any?) -> String {
        guard let value else { return "nil" }
        if let str = value as? String { return str.count > 100 ? "\"\(str.prefix(100))...\"" : "\"\(str)\"" }
        if let num = value as? NSNumber { return "\(num)" }
        if let arr = value as? [Any] { return "[\(arr.count) items]" }
        if let dict = value as? [String: Any] { return "{\(dict.count) keys}" }
        if let data = value as? Data { return "<Data \(nerveFormatBytes(Int64(data.count)))>" }
        if let date = value as? Date { return "\(date)" }
        if value is NSNull { return "null" }
        return "\(value)"
    }

    func handleStatus(_ command: NerveCommand) -> NerveResponse {
        let appState: String
        switch UIApplication.shared.applicationState {
        case .active: appState = "active"
        case .inactive: appState = "inactive"
        case .background: appState = "background"
        @unknown default: appState = "unknown"
        }

        let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "unknown"
        let platform = ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil ? "simulator" : "device"
        let iosVersion = UIDevice.current.systemVersion

        return .success(command.id, [
            "status: connected",
            "  app: \(appName) (\(bundleId))",
            "  platform: \(platform)",
            "  iOS: \(iosVersion)",
            "  state: \(appState)",
            "  nerve: 0.1.0",
        ].joined(separator: "\n"))
    }

    // MARK: - Storage Helpers

    private func readUserDefaults(_ command: NerveCommand) -> NerveResponse {
        let key = command.stringParam("key")
        let dict = UserDefaults.standard.dictionaryRepresentation()

        if let key {
            let value = dict[key]
            return .success(command.id, "defaults[\"\(key)\"] = \(value.map { nerveDescribeValue($0) } ?? "nil")")
        }

        var lines = ["defaults: \(dict.count) keys", "---"]
        for (k, v) in dict.sorted(by: { $0.key < $1.key }).prefix(50) {
            lines.append("  \(k) = \(nerveDescribeValue(v))")
        }
        if dict.count > 50 { lines.append("  ... and \(dict.count - 50) more") }
        return .success(command.id, lines.joined(separator: "\n"))
    }

    private func readCookies(_ command: NerveCommand) -> NerveResponse {
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        var lines = ["cookies: \(cookies.count)", "---"]
        for cookie in cookies.prefix(50) {
            lines.append("  \(cookie.domain)\(cookie.path) \(cookie.name)=\(cookie.value.prefix(40))")
        }
        return .success(command.id, lines.joined(separator: "\n"))
    }

    private func readSandboxFiles(_ command: NerveCommand) -> NerveResponse {
        let subpath = command.stringParam("path") ?? ""
        let fm = FileManager.default
        let homeDir = NSHomeDirectory()
        let targetDir = subpath.isEmpty ? homeDir : (homeDir as NSString).appendingPathComponent(subpath)

        guard let contents = try? fm.contentsOfDirectory(atPath: targetDir) else {
            return .error(command.id, "Cannot read directory: \(subpath.isEmpty ? "~/" : subpath)")
        }

        var lines = ["files: \(targetDir.replacingOccurrences(of: homeDir, with: "~/"))", "---"]
        for name in contents.sorted().prefix(100) {
            let fullPath = (targetDir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: fullPath, isDirectory: &isDir)
            let size = (try? fm.attributesOfItem(atPath: fullPath)[.size] as? UInt64) ?? 0
            lines.append(isDir.boolValue ? "  \(name)/" : "  \(name) (\(nerveFormatBytes(Int64(size))))")
        }
        return .success(command.id, lines.joined(separator: "\n"))
    }

    private func readKeychain(_ command: NerveCommand) -> NerveResponse {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return .success(command.id, "keychain: 0 items (or access denied)")
        }

        var lines = ["keychain: \(items.count) items", "---"]
        for item in items.prefix(50) {
            let account = item[kSecAttrAccount as String] as? String ?? "?"
            let service = item[kSecAttrService as String] as? String ?? "?"
            lines.append("  \(service) / \(account)")
        }
        return .success(command.id, lines.joined(separator: "\n"))
    }

    // MARK: - Core Data

    private func readCoreData(_ command: NerveCommand) -> NerveResponse {
        let entity = command.stringParam("entity")
        let limit = command.intParam("limit") ?? 20
        let predicate = command.stringParam("predicate")

        // Find NSManagedObjectContext on the heap
        let contexts = NerveHeapInstances("NSManagedObjectContext", 10)
        guard let context = contexts.first as? NSManagedObjectContext else {
            return .error(command.id, "No NSManagedObjectContext found. App may not use Core Data.")
        }

        // No entity specified → list all entities
        guard let entity else {
            guard let model = context.persistentStoreCoordinator?.managedObjectModel else {
                return .error(command.id, "Could not access managed object model")
            }
            var lines = ["coredata: \(model.entities.count) entities", "---"]
            for entityDesc in model.entities.sorted(by: { ($0.name ?? "") < ($1.name ?? "") }) {
                let name = entityDesc.name ?? "?"
                let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: name)
                let count = (try? context.count(for: fetchRequest)) ?? 0
                let attrs = entityDesc.attributesByName.keys.sorted().joined(separator: ", ")
                lines.append("  \(name) (\(count) records) — \(attrs)")
            }
            return .success(command.id, lines.joined(separator: "\n"))
        }

        // Fetch records for a specific entity
        let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: entity)
        fetchRequest.fetchLimit = limit
        if let predicate {
            fetchRequest.predicate = NSPredicate(format: predicate)
        }

        do {
            let results = try context.fetch(fetchRequest)
            guard let entityDesc = context.persistentStoreCoordinator?.managedObjectModel
                .entitiesByName[entity] else {
                return .error(command.id, "Entity '\(entity)' not found")
            }
            let attrNames = entityDesc.attributesByName.keys.sorted()
            var lines = ["coredata: \(entity) — \(results.count) records", "---"]
            for (i, obj) in results.enumerated() {
                lines.append("#\(i + 1)")
                for attr in attrNames {
                    let value = obj.value(forKey: attr)
                    lines.append("  \(attr) = \(describeValue(value))")
                }
            }
            return .success(command.id, lines.joined(separator: "\n"))
        } catch {
            return .error(command.id, "Core Data fetch failed: \(error.localizedDescription)")
        }
    }
}

#endif
