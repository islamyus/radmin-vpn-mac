// SPDX-License-Identifier: GPL-3.0-only
#include "CUtun.h"
#include <sys/socket.h>
#include <sys/kern_control.h>
#include <sys/sys_domain.h>
#include <sys/ioctl.h>
#include <net/if_utun.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/un.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <poll.h>

int rvpn_open_utun(char *name, size_t capacity) {
    int fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (fd < 0) return -1;
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) goto fail;
    struct ctl_info info = {0};
    strlcpy(info.ctl_name, UTUN_CONTROL_NAME, sizeof(info.ctl_name));
    if (ioctl(fd, CTLIOCGINFO, &info) < 0) goto fail;
    struct sockaddr_ctl address = {0};
    address.sc_len = sizeof(address);
    address.sc_family = AF_SYSTEM;
    address.ss_sysaddr = AF_SYS_CONTROL;
    address.sc_id = info.ctl_id;
    address.sc_unit = 0; // Kernel selects an unused interface; never take over another VPN.
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) < 0) goto fail;
    socklen_t length = (socklen_t)capacity;
    if (getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, name, &length) < 0) goto fail;
    return fd;
fail: {
    int saved = errno;
    close(fd);
    errno = saved;
    return -1;
}

}

int rvpn_connect_bridge(const char *path, unsigned int owner) {
    struct sockaddr_un address = {0};
    if (strlen(path) >= sizeof(address.sun_path)) { errno = ENAMETOOLONG; return -1; }
    address.sun_len = sizeof(address);
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) goto fail;
    if (fcntl(fd, F_SETFL, O_NONBLOCK) < 0) goto fail;
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        if (errno != EINPROGRESS) goto fail;
        struct pollfd pending = {.fd = fd, .events = POLLOUT};
        if (poll(&pending, 1, 5000) <= 0) { errno = ETIMEDOUT; goto fail; }
        int error = 0; socklen_t size = sizeof(error);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) < 0) goto fail;
        if (error) { errno = error; goto fail; }
    }
    if (fcntl(fd, F_SETFL, 0) < 0) goto fail;
    uid_t uid;
    gid_t gid;
    if (getpeereid(fd, &uid, &gid) < 0) goto fail;
    if (uid != owner || owner == 0) { errno = EPERM; goto fail; }
    int enabled = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
    struct timeval timeout = {.tv_sec = 5};
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    return fd;
fail: {
    int saved = errno;
    close(fd);
    errno = saved;
    return -1;
}

}

// Fixed root-owned parent prevents an unprivileged process replacing the
// service socket. Both sides still authenticate each connection with getpeereid.
int rvpn_listen_service(unsigned int owner) {
    const char *directory = "/private/var/run/radmin-vpn-mac";
    const char *path = "/private/var/run/radmin-vpn-mac/bridge.sock";
    if (geteuid() != 0 || owner == 0) { errno = EPERM; return -1; }
    if (mkdir(directory, 0755) < 0 && errno != EEXIST) return -1;
    struct stat entry;
    if (lstat(directory, &entry) < 0) return -1;
    if (!S_ISDIR(entry.st_mode) || entry.st_uid != 0 || (entry.st_mode & 0022)) { errno = EPERM; return -1; }
    struct sockaddr_un address = {0};
    address.sun_len = sizeof(address); address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    if (lstat(path, &entry) == 0) {
        if (!S_ISSOCK(entry.st_mode) || (entry.st_uid != owner && entry.st_uid != 0)) { errno = EPERM; return -1; }
        int probe = socket(AF_UNIX, SOCK_STREAM, 0);
        if (probe < 0) return -1;
        if (fcntl(probe, F_SETFL, O_NONBLOCK) < 0) { close(probe); return -1; }
        int status = connect(probe, (struct sockaddr *)&address, sizeof(address));
        int saved = errno; close(probe);
        if (status == 0) { errno = EADDRINUSE; return -1; }
        if (saved != ECONNREFUSED) { errno = saved; return -1; }
        if (unlink(path) < 0) return -1; // Only our proven-stale runtime socket.
    } else if (errno != ENOENT) return -1;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 || bind(fd, (struct sockaddr *)&address, sizeof(address)) < 0 ||
        chown(path, owner, 0) < 0 || chmod(path, 0600) < 0 || listen(fd, 4) < 0) {
        int saved = errno; close(fd); errno = saved; return -1;
    }
    return fd;
}

int rvpn_accept_service(int listener, unsigned int owner) {
    int fd = accept(listener, NULL, NULL);
    if (fd < 0) return -1;
    uid_t uid; gid_t gid;
    if (getpeereid(fd, &uid, &gid) < 0 || uid != owner || owner == 0) {
        close(fd); errno = EPERM; return -1;
    }
    int enabled = 1;
    struct timeval timeout = {.tv_sec = 2};
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 ||
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) < 0 ||
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) < 0 ||
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) < 0) {
        int saved = errno; close(fd); errno = saved; return -1;
    }
    return fd;
}
