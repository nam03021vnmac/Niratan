// test-skip: Run through test_lookup_language_bridge.sh (needs the C++ bridging header).
import CHoshiDicts
import CxxStdlib

// Repeated construction/destruction must not materialize or destroy the
// process-owned polymorphic LanguageProcessor through Swift's pointee getter.
for languageID in ["ja", "en", "ja", "en"] {
    var query = DictionaryQuery()
    let lookup = languageID.withCString { hoshiMakeLookup(&query, $0) }
    let results = lookup.lookup(std.string("日本語"), 16, 16)
    precondition(results.empty())
}
print("Shared lookup C++ language lifetime bridge passed")
