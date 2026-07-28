#include "shim.h"

#include <errno.h>
#include <spawn.h>
#include <unistd.h>

// Undeclared in the SDK like the one in shim.h, but needed only here.
extern int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t *attrs, int disclaim);

extern char **environ;

int imp_spawn(char *const argv[], int disclaim, pid_t *out_pid) {
    posix_spawnattr_t attr;
    int rc = posix_spawnattr_init(&attr);
    if (rc) return rc;
    if (disclaim) responsibility_spawnattrs_setdisclaim(&attr, 1);
    rc = posix_spawnp(out_pid, argv[0], NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
    return rc;
}
