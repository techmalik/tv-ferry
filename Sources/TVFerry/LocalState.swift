import SwiftUI

/// Stand-in for SwiftUI's `@State`, which is a compiler macro in this SDK and needs
/// Xcode's macro plugin. This builds with just the Command Line Tools.
@propertyWrapper
struct LocalState<Value>: DynamicProperty {
    final class Storage: ObservableObject {
        @Published var value: Value
        init(_ v: Value) { value = v }
    }

    @StateObject private var storage: Storage

    init(wrappedValue: Value) {
        _storage = StateObject(wrappedValue: Storage(wrappedValue))
    }

    var wrappedValue: Value {
        get { storage.value }
        nonmutating set { storage.value = newValue }
    }

    var projectedValue: Binding<Value> {
        let s = storage
        return Binding(get: { s.value }, set: { s.value = $0 })
    }
}
