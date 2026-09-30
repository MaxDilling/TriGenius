/// The last value computed for a key. Held in `@State`, it spares a view that
/// re-renders on every pointer move from recomputing what only its inputs
/// change; a class, so refreshing it triggers no update.
final class Memo<Key: Equatable, Value> {
    private var last: (key: Key, value: Value)?

    func callAsFunction(_ key: Key, _ compute: () -> Value) -> Value {
        if let last, last.key == key { return last.value }
        let value = compute()
        last = (key, value)
        return value
    }
}
