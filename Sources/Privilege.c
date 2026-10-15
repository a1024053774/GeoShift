#include "Privilege.h"
#include <Security/Authorization.h>
#include <Security/AuthorizationTags.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static AuthorizationRef authorization = NULL;

char *execute_location_request(const char *script_path, const char *request, int32_t *authorization_status) {
    OSStatus status = errAuthorizationSuccess;
    if (!authorization) status = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment,
                                                     kAuthorizationFlagDefaults, &authorization);
    if (status == errAuthorizationSuccess) {
        const char *python = "/usr/bin/python3";
        AuthorizationItem item = {kAuthorizationRightExecute, strlen(python), (void *)python, 0};
        AuthorizationRights rights = {1, &item};
        const char *prompt = "GeoShift需要管理员权限来设置或恢复本机系统定位。";
        AuthorizationItem prompt_item = {kAuthorizationEnvironmentPrompt, strlen(prompt), (void *)prompt, 0};
        AuthorizationEnvironment environment = {1, &prompt_item};
        status = AuthorizationCopyRights(authorization, &rights, &environment,
            kAuthorizationFlagInteractionAllowed | kAuthorizationFlagExtendRights | kAuthorizationFlagPreAuthorize, NULL);
    }
    if (status != errAuthorizationSuccess) { *authorization_status = status; return NULL; }
    char *arguments[] = {(char *)script_path, (char *)request, NULL};
    FILE *stream = NULL;
    // This local build uses Apple's deprecated one-shot executor. It installs
    // no daemon or sudo rule. Replace this boundary with SMAppService before
    // distributing a supported release; the root helper's contract stays small.
    status = AuthorizationExecuteWithPrivileges(authorization, "/usr/bin/python3",
                                                kAuthorizationFlagDefaults, arguments, &stream);
    *authorization_status = status;
    if (status != errAuthorizationSuccess || !stream) return NULL;
    char *response = calloc(65536, 1);
    if (!response) { fclose(stream); return NULL; }
    size_t length = 0;
    char line[2048];
    while (fgets(line, sizeof(line), stream)) {
        size_t count = strlen(line);
        if (length + count >= 65536) { free(response); fclose(stream); return NULL; }
        memcpy(response + length, line, count);
        length += count;
    }
    fclose(stream);
    return response;
}

void release_location_authorization(void) {
    if (authorization) {
        AuthorizationFree(authorization, kAuthorizationFlagDestroyRights);
        authorization = NULL;
    }
}
