#include "include/lithe_bridge.h"
#include "../../../rust/lithe-core/include/lithe_core.h"
#include <stddef.h>

__attribute__((weak)) const char *lithe_core_version(void) {
    return "unlinked";
}

__attribute__((weak)) char *lithe_core_execute_json(const char *request) {
    (void)request;
    return NULL;
}

__attribute__((weak)) char *lithe_core_lsp_provider_catalog_json(const char *workspace_root) {
    (void)workspace_root;
    return NULL;
}

__attribute__((weak)) int32_t lithe_core_cancel(const char *operation_id) {
    (void)operation_id;
    return 0;
}

__attribute__((weak)) void lithe_core_free_string(char *value) {
    (void)value;
}

const char *lithe_bridge_version(void) {
    return lithe_core_version();
}

char *lithe_bridge_execute_json(const char *request) {
    return lithe_core_execute_json(request);
}

char *lithe_bridge_lsp_provider_catalog_json(const char *workspace_root) {
    return lithe_core_lsp_provider_catalog_json(workspace_root);
}

int32_t lithe_bridge_cancel(const char *operation_id) {
    return lithe_core_cancel(operation_id);
}

void lithe_bridge_free_string(char *value) {
    lithe_core_free_string(value);
}
