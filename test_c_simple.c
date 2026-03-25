#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include "ziggit.h"

int run_command(const char** argv, const char* cwd) {
    pid_t pid = fork();
    if (pid == 0) {
        if (cwd) chdir(cwd);
        execvp(argv[0], (char* const*)argv);
        exit(127);
    } else if (pid > 0) {
        int status;
        waitpid(pid, &status, 0);
        return WEXITSTATUS(status);
    }
    return -1;
}

int main() {
    printf("=== Simple C Git Integration Test ===\n");
    
    const char* test_dir = "/tmp/ziggit_c_test";
    
    // Clean up and create test directory
    system("rm -rf /tmp/ziggit_c_test");
    mkdir(test_dir, 0755);
    
    // Initialize git repo
    const char* git_init[] = {"git", "init", NULL};
    run_command(git_init, test_dir);
    
    const char* git_config_name[] = {"git", "config", "user.name", "Test", NULL};
    run_command(git_config_name, test_dir);
    
    const char* git_config_email[] = {"git", "config", "user.email", "test@test.com", NULL};
    run_command(git_config_email, test_dir);
    
    // Create and commit a file
    char test_file[256];
    snprintf(test_file, sizeof(test_file), "%s/test.txt", test_dir);
    
    FILE* f = fopen(test_file, "w");
    if (f) {
        fprintf(f, "Hello, World!\n");
        fclose(f);
    }
    
    const char* git_add[] = {"git", "add", "test.txt", NULL};
    run_command(git_add, test_dir);
    
    const char* git_commit[] = {"git", "commit", "-m", "Initial commit", NULL};
    run_command(git_commit, test_dir);
    
    const char* git_tag[] = {"git", "tag", "v1.0.0", NULL};
    run_command(git_tag, test_dir);
    
    printf("Git repository created successfully!\n");
    
    // Test ziggit functions
    ZiggitRepository* repo = ziggit_repo_open(test_dir);
    if (repo) {
        printf("Ziggit repo opened successfully!\n");
        
        // Test status
        char status_buffer[1024];
        int status_result = ziggit_status_porcelain(repo, status_buffer, sizeof(status_buffer));
        if (status_result == 0) {
            printf("Ziggit status output: '%s'\n", status_buffer);
        } else {
            printf("Ziggit status failed with error: %d\n", status_result);
        }
        
        // Test rev-parse
        char rev_buffer[64];
        int rev_result = ziggit_rev_parse_head(repo, rev_buffer, sizeof(rev_buffer));
        if (rev_result == 0) {
            printf("Ziggit rev-parse HEAD: '%s'\n", rev_buffer);
        } else {
            printf("Ziggit rev-parse failed with error: %d\n", rev_result);
        }
        
        // Test describe tags
        char tag_buffer[256];
        int tag_result = ziggit_describe_tags(repo, tag_buffer, sizeof(tag_buffer));
        if (tag_result == 0) {
            printf("Ziggit describe tags: '%s'\n", tag_buffer);
        } else {
            printf("Ziggit describe failed with error: %d\n", tag_result);
        }
        
        ziggit_repo_close(repo);
    } else {
        printf("Failed to open repository with ziggit!\n");
    }
    
    // Clean up
    system("rm -rf /tmp/ziggit_c_test");
    
    printf("Test completed!\n");
    return 0;
}