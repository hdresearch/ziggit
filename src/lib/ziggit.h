#ifndef ZIGGIT_H
#define ZIGGIT_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>
#include <stdint.h>

// Forward declaration of opaque repository handle
typedef struct ZiggitRepository ZiggitRepository;

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
} ZiggitError;

// Repository operations
int ziggit_repo_init(const char* path, int bare);
ZiggitRepository* ziggit_repo_open(const char* path);
int ziggit_repo_clone(const char* url, const char* path, int bare);
void ziggit_repo_close(ZiggitRepository* repo);

// Commit operations
int ziggit_commit_create(
    ZiggitRepository* repo, 
    const char* message,
    const char* author_name,
    const char* author_email
);

// Branch operations
int ziggit_branch_list(ZiggitRepository* repo, char* buffer, size_t buffer_size);

// Status and diff operations
int ziggit_status(ZiggitRepository* repo, char* buffer, size_t buffer_size);
int ziggit_diff(ZiggitRepository* repo, char* buffer, size_t buffer_size);

// Version information
const char* ziggit_version(void);
int ziggit_version_major(void);
int ziggit_version_minor(void);
int ziggit_version_patch(void);

#ifdef __cplusplus
}
#endif

#endif // ZIGGIT_H