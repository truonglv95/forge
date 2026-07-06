#include "process_spawn.h"

#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

extern char **environ;

static void forge_close_pipe_pair(int pipe_fds[2]) {
    if (pipe_fds[0] >= 0) {
        close(pipe_fds[0]);
    }
    if (pipe_fds[1] >= 0) {
        close(pipe_fds[1]);
    }
    pipe_fds[0] = -1;
    pipe_fds[1] = -1;
}

static int forge_add_stdio_action(
    posix_spawn_file_actions_t *actions,
    forge_stdio_mode mode,
    int pipe_fds[2],
    int std_no,
    int null_flags
) {
    switch (mode) {
    case FORGE_STDIO_INHERIT:
        return 0;
    case FORGE_STDIO_IGNORE:
        return posix_spawn_file_actions_addopen(actions, std_no, "/dev/null", null_flags, 0);
    case FORGE_STDIO_PIPE: {
        const int child_fd = (std_no == STDIN_FILENO) ? pipe_fds[0] : pipe_fds[1];
        const int parent_fd = (std_no == STDIN_FILENO) ? pipe_fds[1] : pipe_fds[0];
        if (posix_spawn_file_actions_adddup2(actions, child_fd, std_no) != 0) {
            return -1;
        }
        return posix_spawn_file_actions_addclose(actions, parent_fd);
    }
    default:
        return -1;
    }
}

static int forge_process_spawn_impl(
    const char *cwd,
    const char *const argv[],
    char *const envp[],
    forge_stdio_mode stdin_mode,
    forge_stdio_mode stdout_mode,
    forge_stdio_mode stderr_mode,
    forge_process_child *out
) {
    if (argv == NULL || argv[0] == NULL || out == NULL) {
        return -1;
    }

    int stdin_pipe[2] = {-1, -1};
    int stdout_pipe[2] = {-1, -1};
    int stderr_pipe[2] = {-1, -1};

    if (stdin_mode == FORGE_STDIO_PIPE && pipe(stdin_pipe) != 0) {
        return -1;
    }
    if (stdout_mode == FORGE_STDIO_PIPE && pipe(stdout_pipe) != 0) {
        forge_close_pipe_pair(stdin_pipe);
        return -1;
    }
    if (stderr_mode == FORGE_STDIO_PIPE && pipe(stderr_pipe) != 0) {
        forge_close_pipe_pair(stdin_pipe);
        forge_close_pipe_pair(stdout_pipe);
        return -1;
    }

    posix_spawn_file_actions_t actions;
    if (posix_spawn_file_actions_init(&actions) != 0) {
        forge_close_pipe_pair(stdin_pipe);
        forge_close_pipe_pair(stdout_pipe);
        forge_close_pipe_pair(stderr_pipe);
        return -1;
    }

    int setup_err = 0;
    if (cwd != NULL && cwd[0] != '\0') {
        setup_err = posix_spawn_file_actions_addchdir_np(&actions, cwd);
    }
    if (setup_err == 0) {
        setup_err = forge_add_stdio_action(&actions, stdin_mode, stdin_pipe, STDIN_FILENO, O_RDONLY);
    }
    if (setup_err == 0) {
        setup_err = forge_add_stdio_action(&actions, stdout_mode, stdout_pipe, STDOUT_FILENO, O_WRONLY);
    }
    if (setup_err == 0) {
        setup_err = forge_add_stdio_action(&actions, stderr_mode, stderr_pipe, STDERR_FILENO, O_WRONLY);
    }

    pid_t pid = -1;
    const char *const *use_env = (envp != NULL) ? (const char *const *)envp : (const char *const *)environ;
    const int spawn_err = (setup_err == 0)
        ? posix_spawnp(&pid, argv[0], &actions, NULL, (char *const *)argv, (char *const *)use_env)
        : setup_err;
    posix_spawn_file_actions_destroy(&actions);

    if (spawn_err != 0) {
        forge_close_pipe_pair(stdin_pipe);
        forge_close_pipe_pair(stdout_pipe);
        forge_close_pipe_pair(stderr_pipe);
        return -1;
    }

    out->pid = pid;
    out->stdin_fd = -1;
    out->stdout_fd = -1;
    out->stderr_fd = -1;

    if (stdin_mode == FORGE_STDIO_PIPE) {
        close(stdin_pipe[0]);
        out->stdin_fd = stdin_pipe[1];
        stdin_pipe[1] = -1;
    }
    if (stdout_mode == FORGE_STDIO_PIPE) {
        close(stdout_pipe[1]);
        out->stdout_fd = stdout_pipe[0];
        stdout_pipe[0] = -1;
    }
    if (stderr_mode == FORGE_STDIO_PIPE) {
        close(stderr_pipe[1]);
        out->stderr_fd = stderr_pipe[0];
        stderr_pipe[0] = -1;
    }

    forge_close_pipe_pair(stdin_pipe);
    forge_close_pipe_pair(stdout_pipe);
    forge_close_pipe_pair(stderr_pipe);
    return 0;
}

int forge_process_spawn(
    const char *cwd,
    const char *const argv[],
    forge_stdio_mode stdin_mode,
    forge_stdio_mode stdout_mode,
    forge_stdio_mode stderr_mode,
    forge_process_child *out
) {
    return forge_process_spawn_impl(cwd, argv, NULL, stdin_mode, stdout_mode, stderr_mode, out);
}

int forge_process_spawn_env(
    const char *cwd,
    const char *const argv[],
    char *const envp[],
    forge_stdio_mode stdin_mode,
    forge_stdio_mode stdout_mode,
    forge_stdio_mode stderr_mode,
    forge_process_child *out
) {
    return forge_process_spawn_impl(cwd, argv, envp, stdin_mode, stdout_mode, stderr_mode, out);
}

int forge_process_wait(pid_t pid) {
    if (pid <= 0) {
        return 1;
    }

    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        return 1;
    }
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }
    return 1;
}

void forge_process_kill(pid_t pid) {
    if (pid > 0) {
        kill(pid, SIGTERM);
    }
}
