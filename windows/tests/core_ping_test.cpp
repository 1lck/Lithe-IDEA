#include "core_client.h"

#include <cassert>
#include <string>

int main() {
    lithe::windows::CoreClient client;
    const auto response = client.execute("core.ping");
    assert(response && response->isValid());
    assert(response->json.find("\"ok\":true") != std::string::npos);
    assert(response->json.find("\"protocolVersion\":1") != std::string::npos);
    assert(response->json.find("\"coreVersion\":\"0.1.0\"") != std::string::npos);
    return 0;
}
