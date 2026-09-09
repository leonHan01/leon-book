/// Stable round-robin columns: appending a page never moves existing cards.
/// Visit each element once instead of filtering the entire day for each column.
enum NativeMomentColumns {
    static func distribute<Element>(_ elements: [Element], columnCount: Int) -> [[Element]] {
        let count = min(max(1, columnCount), max(1, elements.count))
        var columns = Array(repeating: [Element](), count: count)
        let capacity = elements.count / count + (elements.count % count == 0 ? 0 : 1)
        for index in columns.indices {
            columns[index].reserveCapacity(capacity)
        }
        for (index, element) in elements.enumerated() {
            columns[index % count].append(element)
        }
        return columns
    }
}
