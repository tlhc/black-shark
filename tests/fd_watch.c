/*
 * Waits until descriptor FD of process PID stops being a pipe (closed, or reused for something else) or the
 * process is gone. Used to resume a stopped controller the moment its watchdog starts a takeover.
 * Usage: fd_watch PID FD TIMEOUT_MS   exit 0 when the pipe is gone, 1 on timeout, 2 on bad arguments
 */
#include <libproc.h>
#include <stdlib.h>
#include <sys/proc_info.h>
#include <unistd.h>

static int IsPipe(pid_t pid, int fd)
{
    struct pipe_fdinfo info;
    return proc_pidfdinfo(pid, fd, PROC_PIDFDPIPEINFO, &info, sizeof(info)) == (int)sizeof(info);
}

int main(int argc, char **argv)
{
    if (argc != 4) {
        return 2;
    }
    pid_t pid = (pid_t)atoi(argv[1]);
    int fd = atoi(argv[2]);
    long timeoutMs = atol(argv[3]);
    for (long waited = 0; waited < timeoutMs; waited += 10) {
        if (!IsPipe(pid, fd)) {
            return 0;
        }
        usleep(10000);
    }
    return 1;
}
