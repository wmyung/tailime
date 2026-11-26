#define __APPLE_USE_RFC_3542 1
#include "CSystemBridge.h"

#include <arpa/inet.h>
#include <ctype.h>
#include <ifaddrs.h>
#include <libproc.h>
#include <mach/mach.h>
#include <net/if.h>
#include <netinet/in.h>
#include <servers/bootstrap.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <IOKit/IOKitLib.h>

static bool contains_case_insensitive(const char *haystack, const char *needle) {
    if (!haystack || !needle || !*needle) return false;
    size_t nlen = strlen(needle);
    for (const char *p = haystack; *p; p++) {
        size_t i = 0;
        while (i < nlen && p[i] && tolower((unsigned char)p[i]) == tolower((unsigned char)needle[i])) {
            i++;
        }
        if (i == nlen) return true;
    }
    return false;
}

bool tailime_mach_service_exists(const char *service_name) {
    if (!service_name || !*service_name) return false;
    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr = bootstrap_look_up(bootstrap_port, service_name, &port);
    if (kr != KERN_SUCCESS) return false;
    mach_port_deallocate(mach_task_self(), port);
    return true;
}

static bool format_socket_ip(
    int family,
    uint8_t vflag,
    const struct in_addr *addr4,
    const struct in6_addr *addr6,
    char *out_buf,
    size_t out_size,
    bool *out_is_v4
) {
    if (!out_buf || out_size == 0) return false;
    out_buf[0] = '\0';

    bool vflag_v4_only = ((vflag & INI_IPV4) != 0) && ((vflag & INI_IPV6) == 0);
    if (family == AF_INET || vflag_v4_only) {
        if (out_is_v4) *out_is_v4 = true;
        return inet_ntop(AF_INET, addr4, out_buf, (socklen_t)out_size) != NULL;
    }

    if (addr6 != NULL) {
        // Unwrap IPv4-mapped (::ffff:a.b.c.d) and non-loopback/non-zero IPv4-compatible (::a.b.c.d) dual-stack addresses.
        bool is_v4_mapped = IN6_IS_ADDR_V4MAPPED(addr6);
        bool is_v4_compat = IN6_IS_ADDR_V4COMPAT(addr6);
        if (is_v4_mapped || is_v4_compat) {
            struct in_addr v4;
            memcpy(&v4, &addr6->s6_addr[12], sizeof(v4));
            uint32_t host_v4 = ntohl(v4.s_addr);
            if (is_v4_mapped || (host_v4 != 0 && host_v4 != 1)) {
                if (out_is_v4) *out_is_v4 = true;
                return inet_ntop(AF_INET, &v4, out_buf, (socklen_t)out_size) != NULL;
            }
        }
        if (out_is_v4) *out_is_v4 = false;
        return inet_ntop(AF_INET6, addr6, out_buf, (socklen_t)out_size) != NULL;
    }

    return false;
}

int32_t tailime_list_pid_sockets(pid_t pid, TailIMESocketInfo *out_list, int32_t max_count) {
    if (pid <= 0 || !out_list || max_count <= 0) return 0;

    int buf_size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (buf_size <= 0) return 0;

    struct proc_fdinfo *fds = (struct proc_fdinfo *)malloc((size_t)buf_size);
    if (!fds) return 0;

    int filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, buf_size);
    if (filled <= 0) {
        free(fds);
        return 0;
    }

    int fd_count = filled / (int)sizeof(struct proc_fdinfo);
    int32_t written = 0;

    for (int i = 0; i < fd_count && written < max_count; i++) {
        if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;

        struct socket_fdinfo si;
        int sz = proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &si, (int)sizeof(si));
        if (sz != (int)sizeof(si)) continue;

        int family = si.psi.soi_family;
        if (family != AF_INET && family != AF_INET6) continue;

        int kind = si.psi.soi_kind;
        if (kind != SOCKINFO_TCP && kind != SOCKINFO_IN) continue;

        int proto = si.psi.soi_protocol;
        if (proto != IPPROTO_TCP && proto != IPPROTO_UDP) continue;

        struct in_sockinfo *insi = (kind == SOCKINFO_TCP)
            ? &si.psi.soi_proto.pri_tcp.tcpsi_ini
            : &si.psi.soi_proto.pri_in;

        TailIMESocketInfo entry;
        memset(&entry, 0, sizeof(entry));
        entry.pid = pid;
        entry.family = family;
        entry.proto = proto;
        entry.tcp_state = (kind == SOCKINFO_TCP) ? si.psi.soi_proto.pri_tcp.tcpsi_state : -1;
        entry.local_port = ntohs((uint16_t)insi->insi_lport);
        entry.remote_port = ntohs((uint16_t)insi->insi_fport);

        bool local_v4 = false;
        bool remote_v4 = false;
        (void)format_socket_ip(
            family,
            insi->insi_vflag,
            &insi->insi_laddr.ina_46.i46a_addr4,
            &insi->insi_laddr.ina_6,
            entry.local_ip,
            sizeof(entry.local_ip),
            &local_v4
        );
        (void)format_socket_ip(
            family,
            insi->insi_vflag,
            &insi->insi_faddr.ina_46.i46a_addr4,
            &insi->insi_faddr.ina_6,
            entry.remote_ip,
            sizeof(entry.remote_ip),
            &remote_v4
        );
        if (local_v4 && remote_v4) {
            entry.family = AF_INET;
        }

        if (entry.remote_ip[0] == '\0') continue;
        out_list[written++] = entry;
    }

    free(fds);
    return written;
}

int32_t tailime_find_pids_matching_path(const char *path_substring, pid_t *out_pids, int32_t max_count) {
    if (!path_substring || !*path_substring || !out_pids || max_count <= 0) return 0;

    // Note: proc_listallpids() returns the NUMBER OF PIDS (not bytes), while its buffer size parameter is in bytes.
    int est_count = proc_listallpids(NULL, 0);
    if (est_count <= 0) return 0;

    int capacity = est_count + 128;
    pid_t *pids = (pid_t *)calloc((size_t)capacity, sizeof(pid_t));
    if (!pids) return 0;

    int actual_count = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
    if (actual_count <= 0) {
        free(pids);
        return 0;
    }
    if (actual_count > capacity) {
        actual_count = capacity;
    }

    int32_t matched = 0;
    char pathbuf[PROC_PIDPATHINFO_MAXSIZE];
    for (int i = 0; i < actual_count && matched < max_count; i++) {
        pid_t p = pids[i];
        if (p <= 0) continue;
        if (proc_pidpath(p, pathbuf, sizeof(pathbuf)) > 0) {
            if (contains_case_insensitive(pathbuf, path_substring)) {
                out_pids[matched++] = p;
            }
        }
    }

    free(pids);
    return matched;
}

bool tailime_pid_path(pid_t pid, char *out_buf, int32_t buf_size) {
    if (pid <= 0 || !out_buf || buf_size <= 1) return false;
    int ret = proc_pidpath(pid, out_buf, (uint32_t)buf_size);
    return ret > 0;
}

bool tailime_pid_cmdline(pid_t pid, char *out_buf, int32_t buf_size) {
    if (pid <= 0 || !out_buf || buf_size <= 1) return false;
    out_buf[0] = '\0';

    int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size < sizeof(int)) return false;

    char *buf = (char *)malloc(size);
    if (!buf) return false;

    if (sysctl(mib, 3, buf, &size, NULL, 0) != 0) {
        free(buf);
        return false;
    }

    int argc = 0;
    memcpy(&argc, buf, sizeof(int));
    if (argc <= 0 || argc > 128) {
        free(buf);
        return false;
    }

    char *cursor = buf + sizeof(int);
    char *end = buf + size;

    // Skip exec_path and trailing NUL padding
    while (cursor < end && *cursor != '\0') cursor++;
    while (cursor < end && *cursor == '\0') cursor++;

    int32_t written = 0;
    for (int i = 0; i < argc && cursor < end; i++) {
        size_t len = strnlen(cursor, (size_t)(end - cursor));
        if (i > 0 && written + 1 < buf_size) {
            out_buf[written++] = ' ';
        }
        int32_t remain = buf_size - 1 - written;
        if (remain <= 0) break;
        size_t copy_len = len < (size_t)remain ? len : (size_t)remain;
        memcpy(out_buf + written, cursor, copy_len);
        written += (int32_t)copy_len;
        cursor += len + 1;
    }
    out_buf[written] = '\0';
    free(buf);
    return written > 0;
}

bool tailime_ifindex_to_name(uint32_t ifindex, char *out_buf, int32_t buf_size) {
    if (ifindex == 0 || !out_buf || buf_size < IF_NAMESIZE) return false;
    char tmp[IF_NAMESIZE];
    if (!if_indextoname(ifindex, tmp)) return false;
    strncpy(out_buf, tmp, (size_t)(buf_size - 1));
    out_buf[buf_size - 1] = '\0';
    return true;
}

bool tailime_interface_name_for_ip(const char *ip_str, char *out_ifname, int32_t buf_size) {
    if (!ip_str || !out_ifname || buf_size <= 1) return false;
    struct ifaddrs *ifaddr = NULL;
    if (getifaddrs(&ifaddr) != 0) return false;

    bool found = false;
    char addr_buf[INET6_ADDRSTRLEN];

    for (struct ifaddrs *ifa = ifaddr; ifa != NULL; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || !ifa->ifa_name) continue;
        int fam = ifa->ifa_addr->sa_family;
        if (fam == AF_INET) {
            struct sockaddr_in *sin = (struct sockaddr_in *)ifa->ifa_addr;
            if (inet_ntop(AF_INET, &sin->sin_addr, addr_buf, sizeof(addr_buf)) &&
                strcmp(addr_buf, ip_str) == 0) {
                strncpy(out_ifname, ifa->ifa_name, (size_t)(buf_size - 1));
                out_ifname[buf_size - 1] = '\0';
                found = true;
                break;
            }
        } else if (fam == AF_INET6) {
            struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)ifa->ifa_addr;
            if (inet_ntop(AF_INET6, &sin6->sin6_addr, addr_buf, sizeof(addr_buf)) &&
                strcasecmp(addr_buf, ip_str) == 0) {
                strncpy(out_ifname, ifa->ifa_name, (size_t)(buf_size - 1));
                out_ifname[buf_size - 1] = '\0';
                found = true;
                break;
            }
        }
    }

    freeifaddrs(ifaddr);
    return found;
}

int32_t tailime_secure_input_pid(void) {
    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    if (root == IO_OBJECT_NULL) return 0;

    CFTypeRef prop = IORegistryEntryCreateCFProperty(
        root,
        CFSTR("IOConsoleUsers"),
        kCFAllocatorDefault,
        0
    );
    IOObjectRelease(root);
    if (!prop) return 0;

    int32_t result_pid = 0;
    if (CFGetTypeID(prop) == CFArrayGetTypeID()) {
        CFArrayRef users = (CFArrayRef)prop;
        CFIndex count = CFArrayGetCount(users);
        for (CFIndex i = 0; i < count; i++) {
            CFTypeRef item = CFArrayGetValueAtIndex(users, i);
            if (!item || CFGetTypeID(item) != CFDictionaryGetTypeID()) continue;
            CFDictionaryRef dict = (CFDictionaryRef)item;
            CFTypeRef pidVal = CFDictionaryGetValue(dict, CFSTR("kCGSSessionSecureInputPID"));
            if (pidVal && CFGetTypeID(pidVal) == CFNumberGetTypeID()) {
                int32_t pid = 0;
                if (CFNumberGetValue((CFNumberRef)pidVal, kCFNumberSInt32Type, &pid) && pid > 0) {
                    result_pid = pid;
                    break;
                }
            }
        }
    }
    CFRelease(prop);
    return result_pid;
}

bool tailime_enable_ipv6_pktinfo(int32_t fd) {
    int one = 1;
    return setsockopt(fd, IPPROTO_IPV6, IPV6_RECVPKTINFO, &one, (socklen_t)sizeof(one)) == 0;
}

int32_t tailime_ipv6_pktinfo_cmsg_type(void) {
    return IPV6_PKTINFO;
}
