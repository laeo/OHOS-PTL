// Compatibility header force-included into host (clang_x64) C++ compiles only.
//
// OpenHarmony was developed against older libstdc++/libc++ releases whose
// standard headers pulled in a broad set of transitive includes. Newer host
// toolchains (GCC 15 libstdc++ on Ubuntu 26.04) no longer do, so translation
// units that use e.g. std::sort / std::all_of / std::count / std::find without
// an explicit #include <algorithm> fail to compile.
//
// This header restores the most commonly relied-upon transitive includes. It
// is wired into the host toolchain only (see //build/toolchain/linux/BUILD.gn,
// clang_x64 target); target/ohos builds keep using the in-tree libc++ and are
// deliberately unaffected.

#ifndef OHOS_HOST_STD_COMPAT_H
#define OHOS_HOST_STD_COMPAT_H

// Container / iterator / algorithm family: the most frequently missing.
#include <algorithm>
#include <array>
#include <deque>
#include <forward_list>
#include <iterator>
#include <list>
#include <map>
#include <numeric>
#include <queue>
#include <set>
#include <stack>
#include <unordered_map>
#include <unordered_set>
#include <vector>

// Utility / memory / functional.
#include <functional>
#include <memory>
#include <tuple>
#include <type_traits>
#include <utility>

// Strings / streams / formatting.
#include <iomanip>
#include <sstream>
#include <string>

// Numeric / limits / traits.
#include <bitset>
#include <cmath>
#include <complex>
#include <cstddef>
#include <cstdint>
#include <limits>

// C library wrappers that used to leak transitively.
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>

// Error handling / concurrency.
#include <exception>
#include <mutex>
#include <stdexcept>
#include <thread>

#if __cplusplus >= 201703L
// C++17-only headers (host targets are normally -std=c++17, but this header
// must stay usable if a host target still builds with -std=c++11).
#include <optional>
#include <string_view>
#include <variant>
#endif

#endif  // OHOS_HOST_STD_COMPAT_H
