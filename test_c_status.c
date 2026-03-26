#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

// Declare the ziggit functions we need
extern void* ziggit_repo_open(const char* path);
extern void ziggit_repo_close(void* repo);
extern int ziggit_status_porcelain(void* repo, char* buffer, size_t buffer_size);

int run_git_command(const char* repo_path, const char* command, char* output, size_t output_size) {
    int pipefd[2];
    if (pipe(pipefd) == -1) {
        perror("pipe");
        return -1;
    }
    
    pid_t pid = fork();
    if (pid == -1) {
        perror("fork");
        return -1;
    }
    
    if (pid == 0) {
        // Child process
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        close(pipefd[1]);
        
        if (chdir(repo_path) != 0) {
            perror("chdir");
            exit(1);
        }
        
        execl("/bin/sh", "sh", "-c", command, (char *)NULL);
        perror("execl");
        exit(1);
    } else {
        // Parent process
        close(pipefd[1]);
        
        size_t total_read = 0;
        ssize_t bytes_read;
        while ((bytes_read = read(pipefd[0], output + total_read, output_size - total_read - 1)) > 0) {
            total_read += bytes_read;
        }
        output[total_read] = '\0';
        
        close(pipefd[0]);
        
        int status;
        waitpid(pid, &status, 0);
        return WEXITSTATUS(status);
    }
}

int main() {
    const char* repo_path = "/tmp/test_c_repo";
    char git_output[4096] = {0};
    char lib_output[4096] = {0};
    
    // Clean up any previous test repo
    system("rm -rf /tmp/test_c_repo");
    system("mkdir -p /tmp/test_c_repo");
    
    // Create test repository
    if (run_git_command(repo_path, "git init", git_output, sizeof(git_output)) != 0) {
        printf("Failed to init git repo\n");
        return 1;
    }
    
    if (run_git_command(repo_path, "git config user.email 'test@example.com'", git_output, sizeof(git_output)) != 0) {
        printf("Failed to set git config email\n");
        return 1;
    }
    
    if (run_git_command(repo_path, "git config user.name 'Test User'", git_output, sizeof(git_output)) != 0) {
        printf("Failed to set git config name\n");
        return 1;
    }
    
    // Create and commit a file
    if (run_git_command(repo_path, "echo 'Initial content' > test.txt", git_output, sizeof(git_output)) != 0) {
        printf("Failed to create test file\n");
        return 1;
    }
    
    if (run_git_command(repo_path, "git add test.txt", git_output, sizeof(git_output)) != 0) {
        printf("Failed to add test file\n");
        return 1;
    }
    
    if (run_git_command(repo_path, "git commit -m 'Initial commit'", git_output, sizeof(git_output)) != 0) {
        printf("Failed to commit\n");
        return 1;
    }
    
    // Modify the file
    if (run_git_command(repo_path, "echo 'Modified content' > test.txt", git_output, sizeof(git_output)) != 0) {
        printf("Failed to modify test file\n");
        return 1;
    }
    
    // Get git status --porcelain
    if (run_git_command(repo_path, "git status --porcelain", git_output, sizeof(git_output)) != 0) {
        printf("Failed to get git status\n");
        return 1;
    }
    
    // Remove trailing whitespace/newlines from git output
    size_t len = strlen(git_output);
    while (len > 0 && (git_output[len-1] == ' ' || git_output[len-1] == '\n' || git_output[len-1] == '\r' || git_output[len-1] == '\t')) {
        git_output[--len] = '\0';
    }
    
    // Get library status
    void* repo = ziggit_repo_open(repo_path);
    if (!repo) {
        printf("Failed to open repository with library\n");
        return 1;
    }
    
    int result = ziggit_status_porcelain(repo, lib_output, sizeof(lib_output));
    if (result != 0) {
        printf("Library status call failed with code: %d\n", result);
        ziggit_repo_close(repo);
        return 1;
    }
    
    ziggit_repo_close(repo);
    
    // Remove trailing whitespace/newlines from lib output
    len = strlen(lib_output);
    while (len > 0 && (lib_output[len-1] == ' ' || lib_output[len-1] == '\n' || lib_output[len-1] == '\r' || lib_output[len-1] == '\t')) {
        lib_output[--len] = '\0';
    }
    
    // Compare outputs
    printf("Git status --porcelain: '%s' (len=%zu)\n", git_output, strlen(git_output));
    printf("Library status:         '%s' (len=%zu)\n", lib_output, strlen(lib_output));
    
    if (strcmp(git_output, lib_output) == 0) {
        printf("✓ Outputs match!\n");
        return 0;
    } else {
        printf("✗ Outputs differ!\n");
        return 1;
    }
}