// Declarations Swift cannot get from the SDK: two libSystem functions Apple exports but
// declares in no header, and the wait(2) status macros, which Swift cannot import at all.
#ifndef IMP_SHIM_H
#define IMP_SHIM_H

#include <sys/types.h>
#include <sys/wait.h>

// Which process macOS holds responsible for `pid`, i.e. whose TCC grants apply to it.
extern pid_t responsibility_get_pid_responsible_for_pid(pid_t pid);

// Spawn `argv[0]`, searched on PATH like a shell, inheriting our environment exactly.
// With `disclaim`, the child becomes its own responsible process instead of inheriting ours.
// Returns 0 and sets `*out_pid`, or an errno value.
int imp_spawn(char *const argv[], int disclaim, pid_t *out_pid);

// A process's exit code, or 128 + signal if it was killed: WIFEXITED and friends are macros,
// so Swift cannot see them and would otherwise decode the bits by hand.
static inline int imp_exit_status(int status) {
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

#endif
