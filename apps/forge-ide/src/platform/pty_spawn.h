#ifndef FORGE_PTY_SPAWN_H
#define FORGE_PTY_SPAWN_H

#include <sys/types.h>

// Spawns an interactive shell in a new PTY. Returns 0 on success.
int forge_pty_spawn(const char *cwd, const char *shell, int *master_out, pid_t *pid_out);

#endif
