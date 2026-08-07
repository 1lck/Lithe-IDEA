#pragma once

#include "ports.h"

namespace lithe::windows {

class Win32RuntimeLocator final : public RuntimeLocator {
public:
    std::map<std::string, std::string> environment() const override;
    RuntimeDiscoveryResult discover() const override;
    std::optional<std::string> validJavaHome(const std::string& path) const override;
    bool isExecutable(const std::string& path) const override;
    std::optional<std::string> systemMavenExecutable() const override;
    std::optional<std::string> mavenExecutableForHomePath(const std::string& path) const override;
    std::optional<std::string> systemJDBExecutable() const override;
    std::optional<std::string> javaLanguageServerExecutable() const override;
};

} // namespace lithe::windows
