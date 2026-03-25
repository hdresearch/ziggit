#ifndef ZIGGIT_H
#define ZIGGIT_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>

// Error codes
typedef enum {
    ZIGGIT_SUCCESS = 0,
    ZIGGIT_ERROR_NOT_A_REPOSITORY = -1,
    ZIGGIT_ERROR_ALREADY_EXISTS = -2,
    ZIGGIT_ERROR_INVALID_PATH = -3,
    ZIGGIT_ERROR_NOT_FOUND = -4,
    ZIGGIT_ERROR_PERMISSION_DENIED = -5,
    ZIGGIT_ERROR_OUT_OF_MEMORY = -6,
    ZIGGIT_ERROR_NETWORK_ERROR = -7,
    ZIGGIT_ERROR_INVALID_REF = -8,
    ZIGGIT_ERROR_GENERIC = -100
} ziggit_error_t;

// Opaque repository handle
typedef struct ziggit_repository ziggit_repository_t;

// Version information
const char* ziggit_version(void);
int ziggit_version_major(void);
int ziggit_version_minor(void);
int ziggit_version_patch(void);

// Repository management
int ziggit_repo_init(const char* path, int bare);
ziggit_repository_t* ziggit_repo_open(const char* path);
int ziggit_repo_clone(const char* url, const char* path, int bare);
void ziggit_repo_close(ziggit_repository_t* repo);

// Core git operations
int ziggit_commit_create(ziggit_repository_t* repo, const char* message, const char* author_name, const char* author_email);
int ziggit_branch_list(ziggit_repository_t* repo, char* buffer, size_t buffer_size);
int ziggit_status(ziggit_repository_t* repo, char* buffer, size_t buffer_size);
int ziggit_diff(ziggit_repository_t* repo, char* buffer, size_t buffer_size);
int ziggit_add(ziggit_repository_t* repo, const char* pathspec);

// Remote operations
int ziggit_remote_get_url(ziggit_repository_t* repo, const char* remote_name, char* buffer, size_t buffer_size);
int ziggit_remote_set_url(ziggit_repository_t* repo, const char* remote_name, const char* url);

// Extended operations (commonly needed by Bun)
int ziggit_is_clean(ziggit_repository_t* repo);
int ziggit_get_latest_tag(ziggit_repository_t* repo, char* buffer, size_t buffer_size);
int ziggit_create_tag(ziggit_repository_t* repo, const char* tag_name, const char* message);

#ifdef __cplusplus
}
#endif

#endif // ZIGGIT_H