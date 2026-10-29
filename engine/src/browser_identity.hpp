#pragma once
inline constexpr const wchar_t* ame_browser_origin = L"chrome-extension://gckcbijchchbeeijjcmgaiifcchhhbjl/";
#include <string_view>
inline constexpr const wchar_t* ame_firefox_id = L"ame@advancedmemoryengine.local";
inline bool ame_browser_launch_allowed(int argc, const wchar_t* const* argv, bool firefox_manifest_matches) {
    if(argc < 2 || !argv || !argv[1]) return false;
    if(std::wstring_view(argv[1]) == ame_browser_origin) return true;
    return argc == 3 && argv[2] && std::wstring_view(argv[2]) == ame_firefox_id && firefox_manifest_matches;
}
