#pragma once

#ifdef __cplusplus
#include <hoshidicts/lookup.hpp>

// Keep the polymorphic, process-owned language processor entirely in C++.
// Materializing language::get(...).pointee in Swift copies an abstract base
// object on Swift 6.2 and attempts to destroy the borrowed processor.
inline Lookup hoshiMakeLookup(DictionaryQuery *query, const char *languageID) {
    return Lookup(*query, language::get(std::string_view(languageID)));
}
#endif
