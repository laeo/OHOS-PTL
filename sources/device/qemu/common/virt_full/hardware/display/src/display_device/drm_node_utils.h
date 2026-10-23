/*
 * Copyright (c) 2021-2023 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef DRM_NODE_UTILS_H
#define DRM_NODE_UTILS_H

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <string>
#include <unistd.h>
#include <vector>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include "display_log.h"

namespace OHOS {
namespace HDI {
namespace DISPLAY {

// QEMU default node, kept as the last-resort fallback.
constexpr const char *DEFAULT_DRM_NODE = "/dev/dri/card0";
// Optional override file: first non-comment line is the DRM node to use.
constexpr const char *DRM_NODE_CONF_FILE = "/vendor/etc/display/drm_node.conf";
// Optional environment override (mainly for debugging / container bring-up).
constexpr const char *DRM_NODE_ENV = "OHOS_DRM_DEVICE";

// Read the DRM driver name for a card node, e.g. "xe", "i915", "virtio_gpu".
static inline std::string GetDrmDriverName(const std::string &node)
{
    // /dev/dri/card1 -> /sys/class/drm/card1/device/uevent
    std::string base = node.substr(node.find_last_of('/') + 1);
    std::string path = "/sys/class/drm/" + base + "/device/uevent";
    FILE *fp = fopen(path.c_str(), "r");
    if (fp == nullptr) {
        return "";
    }
    char line[256] = {0};
    std::string driver;
    while (fgets(line, sizeof(line), fp) != nullptr) {
        if (strncmp(line, "DRIVER=", strlen("DRIVER=")) == 0) {
            driver = line + strlen("DRIVER=");
            while (!driver.empty() && (driver.back() == '\n' || driver.back() == '\r')) {
                driver.pop_back();
            }
            break;
        }
    }
    fclose(fp);
    return driver;
}

static inline bool IsCardNodeName(const char *name)
{
    if (name == nullptr || strncmp(name, "card", strlen("card")) != 0) {
        return false;
    }
    const char *p = name + strlen("card");
    if (*p == '\0') {
        return false;
    }
    while (*p != '\0') {
        if (!std::isdigit(static_cast<unsigned char>(*p))) {
            return false;
        }
        p++;
    }
    return true;
}

// Count connected connectors that also expose at least one mode.
// Returns -1 when the node is not a usable DRM device.
static inline int CountConnectedConnectors(int fd)
{
    drmModeResPtr res = drmModeGetResources(fd);
    if (res == nullptr) {
        return -1;
    }
    int count = 0;
    for (int i = 0; i < res->count_connectors; i++) {
        drmModeConnectorPtr connector = drmModeGetConnector(fd, res->connectors[i]);
        if (connector == nullptr) {
            continue;
        }
        if ((connector->connection == DRM_MODE_CONNECTED) && (connector->count_modes > 0)) {
            count++;
        }
        drmModeFreeConnector(connector);
    }
    drmModeFreeResources(res);
    return count;
}

// Resolve an explicit override (env var first, then config file). Empty if none.
static inline std::string GetDrmNodeOverride()
{
    const char *env = getenv(DRM_NODE_ENV);
    if ((env != nullptr) && (env[0] != '\0')) {
        return std::string(env);
    }
    FILE *fp = fopen(DRM_NODE_CONF_FILE, "r");
    if (fp == nullptr) {
        return "";
    }
    char line[256] = {0};
    std::string result;
    while (fgets(line, sizeof(line), fp) != nullptr) {
        std::string text(line);
        size_t comment = text.find('#');
        if (comment != std::string::npos) {
            text = text.substr(0, comment);
        }
        size_t begin = text.find_first_not_of(" \t\r\n");
        if (begin == std::string::npos) {
            continue;
        }
        size_t end = text.find_last_not_of(" \t\r\n");
        text = text.substr(begin, end - begin + 1);
        if (text.rfind("/dev/dri/", 0) == 0) {
            result = text;
            break;
        }
    }
    fclose(fp);
    return result;
}

// Enumerate /dev/dri/card*, prefer an override, otherwise pick the node with the
// most connected connectors (QEMU virtio-gpu has exactly one -> still card0).
static inline std::string FindPreferredDrmNode()
{
    std::string override = GetDrmNodeOverride();
    if (!override.empty()) {
        int fd = open(override.c_str(), O_RDWR | O_CLOEXEC);
        if (fd >= 0) {
            close(fd);
            DISPLAY_LOGI("DRM node override: %{public}s", override.c_str());
            return override;
        }
        DISPLAY_LOGW("DRM node override %{public}s open failed, fallback to enumeration", override.c_str());
    }

    std::vector<std::string> nodes;
    DIR *dir = opendir("/dev/dri");
    if (dir != nullptr) {
        struct dirent *entry = nullptr;
        while ((entry = readdir(dir)) != nullptr) {
            if (IsCardNodeName(entry->d_name)) {
                nodes.push_back(std::string("/dev/dri/") + entry->d_name);
            }
        }
        closedir(dir);
    }
    std::sort(nodes.begin(), nodes.end());

    std::string best;
    int bestScore = -1;
    for (const auto &node : nodes) {
        int fd = open(node.c_str(), O_RDWR | O_CLOEXEC);
        if (fd < 0) {
            continue;
        }
        int score = CountConnectedConnectors(fd);
        close(fd);
        DISPLAY_LOGI("DRM node %{public}s driver %{public}s connectedConnectors %{public}d",
            node.c_str(), GetDrmDriverName(node).c_str(), score);
        if (score > bestScore) {
            bestScore = score;
            best = node;
        }
    }

    if (best.empty()) {
        DISPLAY_LOGW("no usable DRM card found, fallback to %{public}s", DEFAULT_DRM_NODE);
        return std::string(DEFAULT_DRM_NODE);
    }
    DISPLAY_LOGI("selected DRM node %{public}s (score %{public}d)", best.c_str(), bestScore);
    return best;
}

} // namespace DISPLAY
} // namespace HDI
} // namespace OHOS

#endif // DRM_NODE_UTILS_H
