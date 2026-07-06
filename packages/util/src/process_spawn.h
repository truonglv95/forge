#ifndef FORGE_PROCESS_SPAWN_H
#define FORGE_PROCESS_SPAWN_H

#include <sys/types.h>

typedef enum {
    FORGE_STDIO_INHERIT = 0,
    FORGE_STDIO_IGNORE = 1,
    FORGE_STDIO_PIPE = 2,
} forge_stdio_mode;

typedef struct {
    pid_t pid;
    int stdin_fd;
    int stdout_fd;
    int stderr_fd;
} forge_process_child;

extern char **environ;

int forge_process_spawn(
    const char *cwd,
    const char *const argv[],
    forge_stdio_mode stdin_mode,
    forge_stdio_mode stdout_mode,
    forge_stdio_mode stderr_mode,
    forge_process_child *out
);

/// When envp is NULL, uses the process environ. Otherwise envp must be NULL-terminated.
int forge_process_spawn_env(
    const char *cwd,
    const char *const argv[],
    char *const envp[],
    forge_stdio_mode stdin_mode,
    forge_stdio_mode stdout_mode,
    forge_stdio_mode stderr_mode,
    forge_process_child *out
);

int forge_process_wait(pid_t pid);
void forge_process_kill(pid_t pid);

#endif
