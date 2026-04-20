/*
 * libgit2 test server — creates and manages bare git repositories
 * for cross-verification testing with ziggit.
 *
 * This program:
 *   1. Initializes a bare repository
 *   2. Populates it with test commits, trees, and blobs
 *   3. Verifies repository integrity using libgit2's ODB
 *   4. Exports repository state for comparison with ziggit
 *
 * Build: make  (uses zig cc)
 * Usage: ./server <test-repo-path>
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <git2.h>

#define CHECK_LG2(error, msg) do { \
    int _err = (error); \
    if (_err < 0) { \
        const git_error *e = git_error_last(); \
        fprintf(stderr, "FAIL: %s: %s (error %d)\n", \
                (msg), e ? e->message : "unknown", _err); \
        exit(1); \
    } \
} while(0)

#define TEST_PASS(name) printf("  PASS: %s\n", (name))
#define TEST_FAIL(name, reason) do { \
    printf("  FAIL: %s — %s\n", (name), (reason)); \
    failures++; \
} while(0)

static int failures = 0;

/*
 * Create a blob in the repository and return its OID.
 */
static void create_blob(git_repository *repo, git_oid *out, const char *content)
{
    CHECK_LG2(git_blob_create_from_buffer(out, repo, content, strlen(content)),
              "create blob");
}

/*
 * Create a tree with one or more blob entries.
 */
static void create_tree_with_blobs(git_repository *repo, git_oid *out,
                                    const char **names, const git_oid *blob_oids,
                                    int count)
{
    git_treebuilder *tb = NULL;
    CHECK_LG2(git_treebuilder_new(&tb, repo, NULL), "create treebuilder");

    for (int i = 0; i < count; i++) {
        CHECK_LG2(git_treebuilder_insert(NULL, tb, names[i], &blob_oids[i],
                                          GIT_FILEMODE_BLOB),
                  "treebuilder insert");
    }

    CHECK_LG2(git_treebuilder_write(out, tb), "treebuilder write");
    git_treebuilder_free(tb);
}

/*
 * Create a commit on a branch.
 */
static void create_commit(git_repository *repo, git_oid *out,
                           const git_oid *tree_oid,
                           const git_oid *parent_oid,
                           const char *ref_name,
                           const char *message)
{
    git_signature *sig = NULL;
    git_tree *tree = NULL;
    const git_commit *parents[1];
    int parent_count = 0;

    CHECK_LG2(git_signature_now(&sig, "Test User", "test@example.com"),
              "create signature");
    CHECK_LG2(git_tree_lookup(&tree, repo, tree_oid), "lookup tree");

    if (parent_oid) {
        git_commit *parent = NULL;
        CHECK_LG2(git_commit_lookup(&parent, repo, parent_oid), "lookup parent");
        parents[0] = parent;
        parent_count = 1;
    }

    CHECK_LG2(git_commit_create(out, repo, ref_name, sig, sig, "UTF-8",
                                 message, tree, parent_count, parents),
              "create commit");

    git_tree_free(tree);
    git_signature_free(sig);
    /* Note: parent commit is leaked here for simplicity in test code */
}

/*
 * Test 1: Initialize a bare repository
 */
static git_repository *test_init_bare(const char *path)
{
    git_repository *repo = NULL;

    printf("Test: Initialize bare repository\n");
    CHECK_LG2(git_repository_init(&repo, path, 1), "init bare repo");

    if (git_repository_is_bare(repo)) {
        TEST_PASS("repository is bare");
    } else {
        TEST_FAIL("repository is bare", "expected bare repo");
    }

    return repo;
}

/*
 * Test 2: Create blobs and verify content roundtrip
 */
static void test_blob_roundtrip(git_repository *repo, git_oid *blob_oid)
{
    const char *content = "Hello from libgit2 test server!\n";
    git_blob *blob = NULL;

    printf("Test: Blob create and roundtrip\n");
    create_blob(repo, blob_oid, content);

    CHECK_LG2(git_blob_lookup(&blob, repo, blob_oid), "lookup blob");

    if (git_blob_rawsize(blob) == strlen(content)) {
        TEST_PASS("blob size matches");
    } else {
        TEST_FAIL("blob size matches", "size mismatch");
    }

    if (memcmp(git_blob_rawcontent(blob), content, strlen(content)) == 0) {
        TEST_PASS("blob content matches");
    } else {
        TEST_FAIL("blob content matches", "content mismatch");
    }

    char hex[GIT_OID_SHA1_HEXSIZE + 1];
    git_oid_tostr(hex, sizeof(hex), blob_oid);
    printf("  blob OID: %s\n", hex);

    git_blob_free(blob);
}

/*
 * Test 3: Create tree with multiple entries
 */
static void test_tree_creation(git_repository *repo, git_oid *tree_oid)
{
    git_oid blob_oids[3];
    const char *names[] = {"README.md", "hello.txt", "world.txt"};
    const char *contents[] = {
        "# Test Repository\nCreated by libgit2 test server\n",
        "Hello, World!\n",
        "This is a test file for cross-verification.\n"
    };
    git_tree *tree = NULL;

    printf("Test: Tree creation with multiple entries\n");

    for (int i = 0; i < 3; i++) {
        create_blob(repo, &blob_oids[i], contents[i]);
    }

    create_tree_with_blobs(repo, tree_oid, names, blob_oids, 3);

    CHECK_LG2(git_tree_lookup(&tree, repo, tree_oid), "lookup tree");

    if (git_tree_entrycount(tree) == 3) {
        TEST_PASS("tree has 3 entries");
    } else {
        TEST_FAIL("tree has 3 entries", "wrong entry count");
    }

    /* Verify entries are sorted (git requirement) */
    const git_tree_entry *e0 = git_tree_entry_byindex(tree, 0);
    const git_tree_entry *e1 = git_tree_entry_byindex(tree, 1);
    if (strcmp(git_tree_entry_name(e0), git_tree_entry_name(e1)) < 0) {
        TEST_PASS("tree entries are sorted");
    } else {
        TEST_FAIL("tree entries are sorted", "entries not in order");
    }

    char hex[GIT_OID_SHA1_HEXSIZE + 1];
    git_oid_tostr(hex, sizeof(hex), tree_oid);
    printf("  tree OID: %s\n", hex);

    git_tree_free(tree);
}

/*
 * Test 4: Create commit chain (3 commits)
 */
static void test_commit_chain(git_repository *repo, git_oid *head_oid)
{
    git_oid tree_oids[3], commit_oids[3], blob_oid;

    printf("Test: Commit chain creation\n");

    /* Commit 1: initial */
    create_blob(repo, &blob_oid, "version 1\n");
    const char *name1 = "file.txt";
    create_tree_with_blobs(repo, &tree_oids[0], &name1, &blob_oid, 1);
    create_commit(repo, &commit_oids[0], &tree_oids[0], NULL,
                  "refs/heads/main", "Initial commit");

    /* Commit 2 */
    create_blob(repo, &blob_oid, "version 2\n");
    create_tree_with_blobs(repo, &tree_oids[1], &name1, &blob_oid, 1);
    create_commit(repo, &commit_oids[1], &tree_oids[1], &commit_oids[0],
                  "refs/heads/main", "Second commit");

    /* Commit 3 */
    create_blob(repo, &blob_oid, "version 3\n");
    create_tree_with_blobs(repo, &tree_oids[2], &name1, &blob_oid, 1);
    create_commit(repo, &commit_oids[2], &tree_oids[2], &commit_oids[1],
                  "refs/heads/main", "Third commit");

    memcpy(head_oid, &commit_oids[2], sizeof(git_oid));

    /* Verify we can walk the chain */
    git_revwalk *walk = NULL;
    CHECK_LG2(git_revwalk_new(&walk, repo), "create revwalk");
    CHECK_LG2(git_revwalk_push(walk, head_oid), "push head");
    git_revwalk_sorting(walk, GIT_SORT_TOPOLOGICAL);

    int count = 0;
    git_oid oid;
    while (git_revwalk_next(&oid, walk) == 0) {
        count++;
    }

    if (count == 3) {
        TEST_PASS("commit chain has 3 commits");
    } else {
        char buf[64];
        snprintf(buf, sizeof(buf), "expected 3, got %d", count);
        TEST_FAIL("commit chain has 3 commits", buf);
    }

    char hex[GIT_OID_SHA1_HEXSIZE + 1];
    git_oid_tostr(hex, sizeof(hex), head_oid);
    printf("  HEAD OID: %s\n", hex);

    git_revwalk_free(walk);
}

/*
 * Test 5: Verify refs
 */
static void test_refs(git_repository *repo)
{
    git_reference *ref = NULL;

    printf("Test: Reference verification\n");

    int err = git_reference_lookup(&ref, repo, "refs/heads/main");
    if (err == 0) {
        TEST_PASS("refs/heads/main exists");
        char hex[GIT_OID_SHA1_HEXSIZE + 1];
        git_oid_tostr(hex, sizeof(hex), git_reference_target(ref));
        printf("  refs/heads/main -> %s\n", hex);
        git_reference_free(ref);
    } else {
        TEST_FAIL("refs/heads/main exists", "ref not found");
    }
}

/*
 * Test 6: Create a branch
 */
static void test_branch_creation(git_repository *repo, const git_oid *head_oid)
{
    git_commit *commit = NULL;
    git_reference *branch = NULL;

    printf("Test: Branch creation\n");

    CHECK_LG2(git_commit_lookup(&commit, repo, head_oid), "lookup commit");
    CHECK_LG2(git_branch_create(&branch, repo, "feature-test", commit, 0),
              "create branch");

    TEST_PASS("created feature-test branch");

    char hex[GIT_OID_SHA1_HEXSIZE + 1];
    git_oid_tostr(hex, sizeof(hex), git_reference_target(branch));
    printf("  refs/heads/feature-test -> %s\n", hex);

    git_reference_free(branch);
    git_commit_free(commit);
}

/*
 * Test 7: Create an annotated tag
 */
static void test_tag_creation(git_repository *repo, const git_oid *head_oid)
{
    git_commit *commit = NULL;
    git_signature *sig = NULL;
    git_oid tag_oid;

    printf("Test: Annotated tag creation\n");

    CHECK_LG2(git_commit_lookup(&commit, repo, head_oid), "lookup commit");
    CHECK_LG2(git_signature_now(&sig, "Test User", "test@example.com"),
              "create signature");
    CHECK_LG2(git_tag_create(&tag_oid, repo, "v1.0",
                              (git_object *)commit, sig,
                              "Release v1.0", 0),
              "create tag");

    TEST_PASS("created annotated tag v1.0");

    char hex[GIT_OID_SHA1_HEXSIZE + 1];
    git_oid_tostr(hex, sizeof(hex), &tag_oid);
    printf("  tag object OID: %s\n", hex);

    git_signature_free(sig);
    git_commit_free(commit);
}

static int odb_count_cb(const git_oid *id, void *payload)
{
    (void)id;
    (*(size_t *)payload)++;
    return 0;
}

/*
 * Test 8: Object database integrity check
 */
static void test_odb_integrity(git_repository *repo)
{
    git_odb *odb = NULL;

    printf("Test: ODB integrity\n");

    CHECK_LG2(git_repository_odb(&odb, repo), "get odb");

    /* Count objects */
    size_t count = 0;
    git_odb_foreach(odb, odb_count_cb, &count);

    if (count > 0) {
        char buf[64];
        snprintf(buf, sizeof(buf), "ODB contains %zu objects", count);
        TEST_PASS(buf);
    } else {
        TEST_FAIL("ODB has objects", "no objects found");
    }

    git_odb_free(odb);
}

/*
 * Test 9: Verify objects can be read back correctly
 */
static void test_object_readback(git_repository *repo, const git_oid *head_oid)
{
    git_commit *commit = NULL;
    git_tree *tree = NULL;

    printf("Test: Object readback verification\n");

    CHECK_LG2(git_commit_lookup(&commit, repo, head_oid), "lookup head");

    const char *msg = git_commit_message(commit);
    if (msg && strstr(msg, "Third commit")) {
        TEST_PASS("head commit message correct");
    } else {
        TEST_FAIL("head commit message correct", msg ? msg : "(null)");
    }

    CHECK_LG2(git_commit_tree(&tree, commit), "get commit tree");
    if (git_tree_entrycount(tree) > 0) {
        TEST_PASS("head commit has non-empty tree");
    } else {
        TEST_FAIL("head commit has non-empty tree", "empty tree");
    }

    git_tree_free(tree);
    git_commit_free(commit);
}

/*
 * Write a summary file with ref->OID mappings for cross-verification.
 */
static void write_ref_summary(git_repository *repo, const char *path)
{
    char filepath[1024];
    snprintf(filepath, sizeof(filepath), "%s/../ref_summary.txt", path);

    FILE *f = fopen(filepath, "w");
    if (!f) {
        fprintf(stderr, "WARNING: Could not write ref summary to %s\n", filepath);
        return;
    }

    git_reference_iterator *iter = NULL;
    git_reference *ref = NULL;

    if (git_reference_iterator_new(&iter, repo) == 0) {
        while (git_reference_next(&ref, iter) == 0) {
            if (git_reference_type(ref) == GIT_REFERENCE_DIRECT) {
                char hex[GIT_OID_SHA1_HEXSIZE + 1];
                git_oid_tostr(hex, sizeof(hex), git_reference_target(ref));
                fprintf(f, "%s %s\n", hex, git_reference_name(ref));
            }
            git_reference_free(ref);
        }
        git_reference_iterator_free(iter);
    }

    fclose(f);
    printf("  Wrote ref summary to %s\n", filepath);
}

int main(int argc, char *argv[])
{
    const char *repo_path;
    git_repository *repo;
    git_oid blob_oid, tree_oid, head_oid;

    if (argc < 2) {
        /* Default path for testing */
        repo_path = "/tmp/libgit2_test_repo.git";
    } else {
        repo_path = argv[1];
    }

    printf("=== libgit2 Test Server ===\n");
    printf("Repository: %s\n\n", repo_path);

    /* Clean up any previous test repo */
    char cmd[1024];
    snprintf(cmd, sizeof(cmd), "rm -rf %s", repo_path);
    system(cmd);

    git_libgit2_init();

    /* Print libgit2 version */
    int major, minor, rev;
    git_libgit2_version(&major, &minor, &rev);
    printf("libgit2 version: %d.%d.%d\n\n", major, minor, rev);

    /* Run tests */
    repo = test_init_bare(repo_path);
    test_blob_roundtrip(repo, &blob_oid);
    test_tree_creation(repo, &tree_oid);
    test_commit_chain(repo, &head_oid);
    test_refs(repo);
    test_branch_creation(repo, &head_oid);
    test_tag_creation(repo, &head_oid);
    test_odb_integrity(repo);
    test_object_readback(repo, &head_oid);

    /* Write summary for cross-verification */
    write_ref_summary(repo, repo_path);

    git_repository_free(repo);
    git_libgit2_shutdown();

    printf("\n=== Results ===\n");
    if (failures == 0) {
        printf("All tests PASSED\n");
    } else {
        printf("%d test(s) FAILED\n", failures);
    }

    return failures;
}
