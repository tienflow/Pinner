import Foundation

/// Fast, zero-dependency Chinese Pinyin and fuzzy acronym matcher using
/// macOS CoreFoundation string transforms.
public enum PinyinMatcher {
    private static let cacheLock = NSLock()
    private static var pinyinCache: [String: (compactFull: String, initials: String)] = [:]

    /// Converts Chinese text to compact lowercase Pinyin and first-letter initials.
    public static func pinyin(for string: String) -> (compactFull: String, initials: String) {
        cacheLock.lock()
        if let hit = pinyinCache[string] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        let mutable = NSMutableString(string: string) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        let latin = mutable as String

        var compact = ""
        var initials = ""
        var isNewWord = true

        for scalar in latin.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                let lower = Character(scalar).lowercased()
                compact.append(lower)
                if isNewWord {
                    initials.append(lower)
                    isNewWord = false
                }
            } else {
                isNewWord = true
            }
        }

        let result = (compactFull: compact, initials: initials)
        cacheLock.lock()
        if pinyinCache.count > 2000 {
            pinyinCache.removeAll(keepingCapacity: true)
        }
        pinyinCache[string] = result
        cacheLock.unlock()
        return result
    }

    /// Tests if `target` matches `query`.
    /// Matches via:
    /// 1. Direct case-insensitive substring
    /// 2. Pinyin full string substring (e.g. "zhoubao" matches "项目周报.xlsx")
    /// 3. Pinyin acronym/initials substring (e.g. "zb" matches "项目周报.xlsx")
    /// 4. Subsequence fuzzy match (e.g. "pnr" matches "Pinner")
    public static func matches(query: String, in target: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        let t = target.lowercased()

        // 1. Direct case-insensitive substring
        if t.contains(q) { return true }

        // Check for Chinese characters
        let hasChinese = target.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
        }

        if hasChinese {
            let (compact, initials) = pinyin(for: target)
            // 2. Full pinyin substring
            if compact.contains(q) { return true }
            // 3. Initials substring
            if initials.contains(q) { return true }
        }

        // 4. Fuzzy subsequence match (letters appearing in same order)
        return fuzzySubsequenceMatch(query: q, target: t)
    }

    private static func fuzzySubsequenceMatch(query: String, target: String) -> Bool {
        guard query.count <= target.count else { return false }
        var queryIdx = query.startIndex
        var targetIdx = target.startIndex

        while queryIdx < query.endIndex && targetIdx < target.endIndex {
            if query[queryIdx] == target[targetIdx] {
                queryIdx = query.index(after: queryIdx)
            }
            targetIdx = target.index(after: targetIdx)
        }
        return queryIdx == query.endIndex
    }
}
