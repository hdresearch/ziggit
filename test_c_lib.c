#include "src/lib/ziggit.h"
#include <stdio.h>
#include <stdlib.h>

int main() {
    printf("Testing ziggit C library...\n");
    
    // Test version
    printf("ziggit version: %s\n", ziggit_version());
    
    // Test repo init
    const char* test_path = "/tmp/c_test_repo";
    int result = ziggit_repo_init(test_path, 0);
    printf("ziggit_repo_init result: %d\n", result);
    
    return 0;
}