#ifndef LITHE_CORE_PUBLIC_H
#define LITHE_CORE_PUBLIC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

const char *lithe_core_version(void);
char *lithe_core_execute_json(const char *request);
int32_t lithe_core_cancel(const char *operation_id);
void lithe_core_free_string(char *value);

#ifdef __cplusplus
}
#endif

#endif
