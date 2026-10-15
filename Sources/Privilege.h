#include <stdint.h>
char *execute_location_request(const char *script_path, const char *request, int32_t *authorization_status);
void release_location_authorization(void);
