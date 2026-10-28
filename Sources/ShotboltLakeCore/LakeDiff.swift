import Foundation

/// How to bring the lake on screen from what was sent last to what it should show now. DynamicLake replaces the whole lake on
/// a `lake` command, which can throw away where the person scrolled to; a `lakePatch` replaces only the components that
/// changed, by `id` (DynamicLake's design guidelines ask for it for small, frequent changes: a Copy that turns into a check,
/// "Just now" becoming "1 min ago").
public enum LakeDiff {
    /// DynamicLake's limit for one `lakePatch`.
    public static let maxPatchComponents = 16
    /// Past this many changed components, one whole lake is cheaper than several patches.
    public static let maxPatchedComponents = 32

    /// The components to patch: empty when nothing changed, nil when the lake must be sent whole because its shape changed
    /// (rows came or went, a stack's children changed, the header or bottom section changed). Every patched component has an
    /// `id`, which lakePatch needs, and ids are unique in the lake and its glance.
    public static func patches(from old: JSON?, to new: JSON) -> [JSON]? {
        guard let old else { return nil }
        if equal(old, new) { return [] }
        var patches: [JSON] = []
        guard sameApartFromContent(old, new), list(old["content"], new["content"], into: &patches) else { return nil }
        switch (old["glance"] as? JSON, new["glance"] as? JSON) {
        case (nil, nil): break
        case (let a?, let b?):
            guard sameApartFromContent(a, b), list(a["content"], b["content"], into: &patches) else { return nil }
        default: return nil
        }
        return patches.count <= maxPatchedComponents ? patches : nil
    }

    /// The `lakePatch` commands for `components`, in order.
    public static func commands(_ components: [JSON]) -> [JSON] {
        stride(from: 0, to: components.count, by: maxPatchComponents).map { start in
            ["schemaVersion": pluginSchemaVersion, "type": "lakePatch",
             "components": Array(components[start..<min(start + maxPatchComponents, components.count)])]
        }
    }

    /// Header, bottom section and flags: a change there needs the whole lake.
    private static func sameApartFromContent(_ a: JSON, _ b: JSON) -> Bool {
        var a = a, b = b
        for key in ["content", "glance"] { a[key] = nil; b[key] = nil }
        return equal(a, b)
    }

    /// Two lists with the same components in the same places; the changes go into `patches`. False when the list itself changed.
    private static func list(_ old: Any?, _ new: Any?, into patches: inout [JSON]) -> Bool {
        let a = old as? [JSON] ?? [], b = new as? [JSON] ?? []
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            guard node(x, y, into: &patches) else { return false }
        }
        return true
    }

    /// False when `new` cannot replace `old` by id: a different type or id, or a change in a component without an id.
    private static func node(_ old: JSON, _ new: JSON, into patches: inout [JSON]) -> Bool {
        if equal(old, new) { return true }
        guard let id = new["id"] as? String, old["id"] as? String == id, old["type"] as? String == new["type"] as? String else {
            return false
        }
        var ownOld = old, ownNew = new
        ownOld["children"] = nil
        ownNew["children"] = nil
        if equal(ownOld, ownNew) {
            // Only the children changed: patch them, or this stack whole when they cannot be patched one by one.
            var inner: [JSON] = []
            if list(old["children"], new["children"], into: &inner) {
                patches += inner
                return true
            }
        }
        patches.append(new)
        return true
    }

    private static func equal(_ a: JSON, _ b: JSON) -> Bool { NSDictionary(dictionary: a).isEqual(to: b) }
}
