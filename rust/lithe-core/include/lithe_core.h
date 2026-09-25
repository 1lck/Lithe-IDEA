#ifndef LITHE_CORE_PUBLIC_H
#define LITHE_CORE_PUBLIC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

const char *lithe_core_version(void);
int32_t lithe_core_git_askpass(const char *prompt);
char *lithe_core_execute_json(const char *request);
char *lithe_core_execute_json_with_events(const char *request, void (*callback)(const char *, void *), void *context);
char *lithe_core_lsp_provider_catalog_json(const char *workspace_root);
int32_t lithe_core_cancel(const char *operation_id);
void lithe_core_free_string(char *value);
void *lithe_agent_open_json(const char *configuration, void (*callback)(const char *, void *), void *context);
int32_t lithe_agent_send_json(void *handle, const char *command);
void lithe_agent_close(void *handle);

#ifdef __cplusplus
}
#endif

#endif
