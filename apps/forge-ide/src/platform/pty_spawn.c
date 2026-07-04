#include "pty_spawn.h"

#include <fcntl.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <util.h>

extern char **environ;

static void forge_pty_prepare_env(void) {
    setenv("TERM", "xterm-256color", 1);
    setenv("COLORTERM", "truecolor", 1);
    unsetenv("ITERM_SESSION_ID");
    unsetenv("TERM_PROGRAM");
    unsetenv("TERM_SESSION_ID");
    unsetenv("STARSHIP_SHELL");
    unsetenv("STARSHIP_SESSION_KEY");
    setenv("FORGE_IDE_TERMINAL", "1", 1);
}

static int forge_pty_spawn_posix(const char *cwd, const char *shell, int *master_out, pid_t *pid_out) {
    struct winsize ws = {
        .ws_row = 24,
        .ws_col = 120,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    int master = -1;
    int slave = -1;
    if (openpty(&master, &slave, NULL, NULL, &ws) != 0) {
        return -1;
    }

    forge_pty_prepare_env();

    const char *name = strrchr(shell, '/');
    name = name ? name + 1 : shell;

    const char *argv[16];
    int argc = 0;
    argv[argc++] = name;

    if (strstr(shell, "zsh") != NULL) {
        setenv("PS1", "", 1);
        setenv("PS2", "", 1);
        setenv("PROMPT", "", 1);
        setenv("RPROMPT", "", 1);
        argv[argc++] = "-i";
        argv[argc++] = "--no-rcs";
    } else if (strstr(shell, "fish") != NULL) {
        setenv("FISH_NO_WELCOME", "1", 1);
        argv[argc++] = "-i";
        argv[argc++] = "--no-config";
        argv[argc++] = "-C";
        argv[argc++] = "set fish_greeting";
        argv[argc++] = "-C";
        argv[argc++] = "function fish_prompt; printf \"$ \"; end";
        argv[argc++] = "-C";
        argv[argc++] = "function fish_right_prompt; end";
    } else {
        argv[argc++] = "-i";
    }
    argv[argc] = NULL;

    posix_spawn_file_actions_t actions;
    if (posix_spawn_file_actions_init(&actions) != 0) {
        close(master);
        close(slave);
        return -1;
    }

    if (posix_spawn_file_actions_addchdir_np(&actions, cwd) != 0) {
        posix_spawn_file_actions_destroy(&actions);
        close(master);
        close(slave);
        return -1;
    }
    if (posix_spawn_file_actions_adddup2(&actions, slave, STDIN_FILENO) != 0 ||
        posix_spawn_file_actions_adddup2(&actions, slave, STDOUT_FILENO) != 0 ||
        posix_spawn_file_actions_adddup2(&actions, slave, STDERR_FILENO) != 0 ||
        posix_spawn_file_actions_addclose(&actions, slave) != 0 ||
        posix_spawn_file_actions_addclose(&actions, master) != 0) {
        posix_spawn_file_actions_destroy(&actions);
        close(master);
        close(slave);
        return -1;
    }

    pid_t pid = -1;
    const int spawn_err = posix_spawn(&pid, shell, &actions, NULL, (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(slave);

    if (spawn_err != 0) {
        close(master);
        return -1;
    }

    if (ioctl(master, TIOCSWINSZ, &ws) != 0) {
        /* non-fatal */
    }

    int flags = fcntl(master, F_GETFD);
    if (flags >= 0) {
        (void)fcntl(master, F_SETFD, flags | FD_CLOEXEC);
    }

    *master_out = master;
    *pid_out = pid;
    return 0;
}

int forge_pty_spawn(const char *cwd, const char *shell, int *master_out, pid_t *pid_out) {
#if defined(__APPLE__)
    return forge_pty_spawn_posix(cwd, shell, master_out, pid_out);
#else
    struct winsize ws = {
        .ws_row = 24,
        .ws_col = 120,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    int master = -1;
    const pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) {
        return -1;
    }

    if (pid == 0) {
        if (chdir(cwd) != 0) {
            _exit(127);
        }
        forge_pty_prepare_env();
        const char *name = strrchr(shell, '/');
        name = name ? name + 1 : shell;
        if (strstr(shell, "zsh") != NULL) {
            setenv("PS1", "", 1);
            setenv("PROMPT", "", 1);
            execl(shell, name, "-i", "--no-rcs", (char *)NULL);
        }
        execl(shell, name, "-i", (char *)NULL);
        _exit(127);
    }

    if (ioctl(master, TIOCSWINSZ, &ws) != 0) {
        /* non-fatal */
    }

    *master_out = master;
    *pid_out = pid;
    return 0;
#endif
}
