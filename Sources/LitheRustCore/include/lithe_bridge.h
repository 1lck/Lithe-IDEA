#ifndef LITHE_BRIDGE_H
#define LITHE_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

const char *lithe_bridge_version(void);
char *lithe_bridge_execute_json(const char *request);
void lithe_bridge_free_string(char *value);

#ifdef __cplusplus
}
#endif

#endif
