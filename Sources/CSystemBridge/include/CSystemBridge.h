#ifndef CSYSTEMBRIDGE_H
#define CSYSTEMBRIDGE_H

#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <IOKit/hidsystem/IOHIDParameter.h>
#include <IOKit/hidsystem/IOHIDShared.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int32_t pid;
    int32_t family;          // AF_INET (2) or AF_INET6 (30)
    int32_t proto;           // IPPROTO_TCP (6) or IPPROTO_UDP (17)
    int32_t tcp_state;       // TSI_S_ESTABLISHED (4), TSI_S_LISTEN (1), etc. (-1 for UDP)
    uint16_t local_port;
    uint16_t remote_port;
    char local_ip[64];
    char remote_ip[64];
} TailIMESocketInfo;

/// Checks if a Mach bootstrap service is currently registered (used for TextInputSwitcher on macOS 26+).
bool tailime_mach_service_exists(const char *service_name);

/// Lists open IPv4/IPv6 TCP & UDP sockets for a given PID. Returns count written (up to max_count).
int32_t tailime_list_pid_sockets(pid_t pid, TailIMESocketInfo *out_list, int32_t max_count);

/// Lists PIDs whose executable path contains the given case-insensitive substring (e.g., "RustDesk.app").
int32_t tailime_find_pids_matching_path(const char *path_substring, pid_t *out_pids, int32_t max_count);

/// Returns process executable basename or path into out_buf. Returns true on success.
bool tailime_pid_path(pid_t pid, char *out_buf, int32_t buf_size);

/// Returns command-line arguments joined by spaces (up to buf_size) via KERN_PROCARGS2. Returns true on success.
bool tailime_pid_cmdline(pid_t pid, char *out_buf, int32_t buf_size);

/// Resolves an interface index (e.g. from IP_RECVIF / IPV6_PKTINFO) to its interface name (e.g. "utun4", "lo0").
bool tailime_ifindex_to_name(uint32_t ifindex, char *out_buf, int32_t buf_size);

/// Checks if the interface name for a given IPv4/IPv6 address is a utun or loopback interface.
bool tailime_interface_name_for_ip(const char *ip_str, char *out_ifname, int32_t buf_size);

/// Reads the PID currently holding Secure Input via IORegistry (kCGSSessionSecureInputPID), or 0 if none.
int32_t tailime_secure_input_pid(void);

/// Enables RFC 3542 IPV6_RECVPKTINFO on a UDP IPv6 socket. Returns true on success.
bool tailime_enable_ipv6_pktinfo(int32_t fd);

/// Returns RFC 3542 IPV6_PKTINFO cmsg_type constant on macOS.
int32_t tailime_ipv6_pktinfo_cmsg_type(void);

#ifdef __cplusplus
}
#endif

#endif /* CSYSTEMBRIDGE_H */
