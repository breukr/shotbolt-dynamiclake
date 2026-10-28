import XCTest
@testable import ShotboltLakeCore

/// DynamicLake validates every message and rejects the whole thing over one bad field, so each command the plugin can send is
/// held to the documented limits here (docs.dynamiclake.com: JSON Plugin API and Lakes).
final class LimitsTests: XCTestCase {
    static let tints: Set<String> = ["blue", "cyan", "teal", "indigo", "purple", "pink", "green", "orange", "yellow", "red", "gray", "white"]
    static let containers: Set<String> = ["vstack", "hstack", "zstack", "scroll"]
    static let types: Set<String> = Set(["text", "image", "button", "progress", "timer", "status", "spacer"]).union(containers)

    func testEveryDemoCommandIsWithinDynamicLakesLimits() throws {
        let commands = DemoPayloads.all(now: Date())
        XCTAssertGreaterThan(commands.count, 20)
        for command in commands {
            var problems: [String] = []
            check(command: command, into: &problems)
            let size = try JSONSerialization.data(withJSONObject: command).count
            if size > 64 * 1024 { problems.append("\(size) bytes: over the 64 KB an older host takes") }
            XCTAssertEqual(problems, [], "\(command["type"] ?? "?"): \(problems.joined(separator: "; "))")
        }
    }

    func testTheCheckerCatchesWhatDynamicLakeRejects() {
        var problems: [String] = []
        let bad: JSON = ["schemaVersion": 1, "type": "lake", "lake": ["hideHeader": true, "title": ["type": "text", "text": "x"], "content": [
            ["type": "hstack", "children": Array(repeating: ["type": "spacer"], count: 17), "tint": "magenta"],
            ["type": "image", "source": "sfSymbol", "systemImage": "x", "size": 90],
            ["type": "text", "text": "a\nb", "drag": ["text": "x", "url": "https://x"]],
        ]]]
        check(command: bad, into: &problems)
        XCTAssertGreaterThanOrEqual(problems.count, 5, problems.joined(separator: "\n"))
    }

    // MARK: Checker

    func check(command: JSON, into problems: inout [String]) {
        guard command["schemaVersion"] as? Int == 1 else { return problems.append("schemaVersion") }
        switch command["type"] as? String {
        case "create", "update":
            checkActivity(command, into: &problems)
        case "lake":
            guard let lake = command["lake"] as? JSON else { return problems.append("lake missing") }
            checkLake(lake, glance: false, into: &problems)
            if let glance = lake["glance"] as? JSON { checkLake(glance, glance: true, into: &problems) }
            // lakePatch finds components by id anywhere in the lake and its glance.
            var ids: [String] = []
            collectIDs(lake, into: &ids)
            let repeated = Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
            if !repeated.isEmpty { problems.append("ids used twice: \(repeated.joined(separator: ", "))") }
        case "lakePatch":
            let components = command["components"] as? [JSON] ?? []
            if !(1...16).contains(components.count) { problems.append("lakePatch has \(components.count) components") }
            for component in components {
                if component["id"] as? String == nil { problems.append("patched component without id") }
                checkComponent(component, depth: 1, inLake: true, count: Counter(), into: &problems)
            }
        case "dismiss", "closeLake":
            break
        default:
            problems.append("unknown type \(command["type"] ?? "nil")")
        }
    }

    func checkActivity(_ command: JSON, into problems: inout [String]) {
        if let id = command["activityID"] as? String { checkIdentifier(id, into: &problems) } else { problems.append("activityID") }
        if let title = command["title"] as? String, title.count > 80 { problems.append("title over 80") }
        if let present = command["presentSneakPeek"] as? Int, !(1...10).contains(present) { problems.append("presentSneakPeek \(present)") }
        if let priority = command["priority"] as? String, !["low", "normal", "high"].contains(priority) { problems.append("priority") }
        if let size = command["size"] as? String, !["small", "normal", "large"].contains(size) { problems.append("size") }
        let surfaces = command["surfaces"] as? JSON ?? [:]
        if command["type"] as? String == "create", surfaces["compactLiveActivity"] == nil { problems.append("create without compact") }
        let slots: [String: Set<String>] = ["compactLiveActivity": ["leftSlot", "rightSlot"], "sneakPeek": ["leftSlot", "center", "rightSlot"],
                                            "extraLiveActivity": ["leftSlot", "rightSlot"]]
        for (name, value) in surfaces {
            guard let allowed = slots[name], let surface = value as? JSON else { problems.append("surface \(name)"); continue }
            if name == "extraLiveActivity", surface.count != 1 { problems.append("extra live activity shows one glyph") }
            for (slot, component) in surface {
                guard allowed.contains(slot), let component = component as? JSON else { problems.append("\(name).\(slot)"); continue }
                let type = component["type"] as? String ?? ""
                if Self.containers.contains(type) || type == "spacer" { problems.append("\(type) in a live activity") }
                if name == "compactLiveActivity", type == "text", !["timer", "numeric"].contains(component["style"] as? String ?? "") {
                    problems.append("descriptive text in the compact live activity")
                }
                if component["shape"] as? String == "plain" { problems.append("plain button in a live activity") }
                // Our own rule: live activity slots size their pictures, so no size or rounding is sent there.
                if component["size"] != nil || component["cornerRadius"] != nil { problems.append("sized image in \(name)") }
                checkComponent(component, depth: 1, inLake: false, count: Counter(), into: &problems)
            }
        }
    }

    func checkLake(_ lake: JSON, glance: Bool, into problems: inout [String]) {
        let header = ["leftSlot", "title", "subtitle", "rightSlot"].filter { lake[$0] != nil }
        if lake["hideHeader"] as? Bool == true, !header.isEmpty { problems.append("hideHeader with a header row") }
        if glance, lake["bottom"] != nil { problems.append("bottom in the glance") }
        let count = Counter()
        for part in ["content", "bottom"] {
            let components = lake[part] as? [JSON] ?? []
            if components.count > 16 { problems.append("\(part) has \(components.count) top-level components") }
            for component in components { checkComponent(component, depth: 1, inLake: true, count: count, into: &problems) }
        }
        if count.value > 160 { problems.append("\(count.value) components, over the 160 budget") }
        for slot in header {
            guard let component = lake[slot] as? JSON else { continue }
            if Self.containers.contains(component["type"] as? String ?? "") { problems.append("stack in the header") }
            checkComponent(component, depth: 1, inLake: false, count: Counter(), into: &problems)
        }
    }

    final class Counter { var value = 0 }

    func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

    func checkComponent(_ component: JSON, depth: Int, inLake: Bool, count: Counter, into problems: inout [String]) {
        count.value += 1
        let type = component["type"] as? String ?? ""
        guard Self.types.contains(type) else { return problems.append("type \(type)") }
        if let id = component["id"] as? String { checkIdentifier(id, into: &problems) }
        if let tint = component["tint"] as? String, !Self.tints.contains(tint) { problems.append("tint \(tint)") }
        if let value = number(component["size"]), !(12...80).contains(value) { problems.append("\(type) size \(value)") }
        for key in ["spacing", "cornerRadius"] {
            if let value = number(component[key]), !(0...40).contains(value) { problems.append("\(key) \(value)") }
        }
        if let padding = component["padding"] {
            let edges = (padding as? JSON)?.values.compactMap { number($0) } ?? [number(padding) ?? 0]
            if edges.contains(where: { !(0...40).contains($0) }) { problems.append("padding") }
        }
        if !inLake, component["contextMenu"] != nil || component["drag"] != nil { problems.append("menu or drag outside the lake") }
        if let menu = component["contextMenu"] as? [JSON] {
            if !(1...8).contains(menu.count) { problems.append("contextMenu has \(menu.count) items") }
            for item in menu {
                if (item["title"] as? String ?? "").count > 40 || (item["title"] as? String ?? "").isEmpty { problems.append("menu title") }
                if item["actionID"] as? String == nil { problems.append("menu actionID") }
            }
        }
        if let drag = component["drag"] as? JSON {
            if drag.count != 1 { problems.append("drag needs exactly one of text, url, filePath") }
            if let path = drag["filePath"] as? String, !path.hasPrefix("/") { problems.append("drag filePath not absolute") }
        }
        switch type {
        case "text":
            let text = component["text"] as? String ?? ""
            if text.isEmpty || text.contains("\n") { problems.append("text must be one line: \(text)") }
            if let weight = component["weight"] as? String, !["regular", "medium", "semibold", "bold"].contains(weight) { problems.append("weight") }
            if let style = component["style"] as? String, !["plain", "marquee", "compact", "timer", "numeric", "large"].contains(style) {
                problems.append("style \(style)")
            }
        case "image":
            if component["title"] != nil, component["actionID"] == nil { problems.append("image tooltip without an action") }
            switch component["source"] as? String {
            case "sfSymbol": if (component["systemImage"] as? String ?? "").isEmpty { problems.append("systemImage") }
            case "asset": if component["assetID"] as? String == nil { problems.append("assetID") }
            case "appIcon": break
            default: problems.append("image source")
            }
        case "button":
            if component["actionID"] as? String == nil { problems.append("button actionID") }
            if let shape = component["shape"] as? String, !["circle", "roundedRect", "plain"].contains(shape) { problems.append("shape") }
            if let role = component["role"] as? String, !["normal", "destructive", "confirm"].contains(role) { problems.append("role") }
        case "timer":
            guard let start = (component["startDate"] as? String).flatMap({ try? Date($0, strategy: .iso8601) }),
                  let end = (component["endDate"] as? String).flatMap({ try? Date($0, strategy: .iso8601) }) else {
                return problems.append("timer dates")
            }
            if start >= end { problems.append("timer start is not before its end") }
        default:
            break
        }
        if Self.containers.contains(type) {
            if depth > 4 { problems.append("stacks nested deeper than 4") }
            let children = component["children"] as? [JSON] ?? []
            let limit = type == "scroll" ? 50 : 16
            if let axis = component["axis"] as? String, type != "scroll" || !["vertical", "horizontal"].contains(axis) { problems.append("axis") }
            if children.isEmpty || children.count > limit { problems.append("\(type) has \(children.count) children") }
            for child in children { checkComponent(child, depth: depth + 1, inLake: inLake, count: count, into: &problems) }
        }
    }

    func collectIDs(_ value: Any, into ids: inout [String]) {
        if let object = value as? JSON {
            if let id = object["id"] as? String, object["type"] != nil { ids.append(id) }
            for child in object.values { collectIDs(child, into: &ids) }
        } else if let array = value as? [Any] {
            for child in array { collectIDs(child, into: &ids) }
        }
    }

    func checkIdentifier(_ id: String, into problems: inout [String]) {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:-"))
        if id.isEmpty || id.unicodeScalars.contains(where: { !allowed.contains($0) }) { problems.append("identifier \(id)") }
    }
}
