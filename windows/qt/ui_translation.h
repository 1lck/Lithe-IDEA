#pragma once

#include <string>

class QString;

namespace lithe::windows {

std::string effectiveUiLanguage(const std::string& configuredLanguage);
bool installUiTranslator(const std::string& language);
QString uiText(const QString& source);

}
