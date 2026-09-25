#ifndef LITHE_BRIDGE_H
#define LITHE_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

const char *lithe_bridge_version(void);
int32_t lithe_bridge_git_askpass(const char *prompt);
char *lithe_bridge_execute_json(const char *request);
char *lithe_bridge_execute_json_with_events(const char *request, void (*callback)(const char *, void *), void *context);
char *lithe_bridge_lsp_provider_catalog_json(const char *workspace_root);
int32_t lithe_bridge_cancel(const char *operation_id);
void lithe_bridge_free_string(char *value);
void *lithe_bridge_agent_open_json(const char *configuration, void (*callback)(const char *, void *), void *context);
int32_t lithe_bridge_agent_prompt(void *handle, const char *prompt);
int32_t lithe_bridge_agent_cancel(void *handle);
int32_t lithe_bridge_agent_permission(void *handle, const char *request_id, const char *option_id);
void lithe_bridge_agent_close(void *handle);

#ifdef __cplusplus
}
#endif

#endif
