//go:build darwin

package sysinfo

/*
#include <arpa/inet.h>
#include <libproc.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/proc_info.h>

typedef struct {
	char address[INET6_ADDRSTRLEN];
	uint16_t port;
} lithe_darwin_socket_t;

// Queries listening TCP sockets of pid via libproc. Exited or inaccessible
// processes return count=0 without failing the snapshot.
static int lithe_list_pid_tcp_listeners(int pid, lithe_darwin_socket_t **out_items, int *out_count) {
	*out_items = NULL;
	*out_count = 0;

	int buf_bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
	if (buf_bytes <= 0) {
		return 0;
	}
	// Pad slightly so FDs opened concurrently between sizing and read still fit cleanly.
	buf_bytes += (int)sizeof(struct proc_fdinfo) * 8;
	struct proc_fdinfo *fds = (struct proc_fdinfo *)malloc((size_t)buf_bytes);
	if (fds == NULL) {
		return -1;
	}
	int used_bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, buf_bytes);
	if (used_bytes <= 0) {
		free(fds);
		return 0;
	}

	int nfds = used_bytes / (int)sizeof(struct proc_fdinfo);
	int cap = 8;
	int count = 0;
	lithe_darwin_socket_t *items = (lithe_darwin_socket_t *)calloc((size_t)cap, sizeof(lithe_darwin_socket_t));
	if (items == NULL) {
		free(fds);
		return -1;
	}

	for (int i = 0; i < nfds; i++) {
		if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) {
			continue;
		}
		struct socket_fdinfo si;
		int n = proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &si, (int)sizeof(si));
		if (n != (int)sizeof(si)) {
			continue;
		}
		if (si.psi.soi_kind != SOCKINFO_TCP || si.psi.soi_proto.pri_tcp.tcpsi_state != TSI_S_LISTEN) {
			continue;
		}
		int family = si.psi.soi_family;
		if (family != AF_INET && family != AF_INET6) {
			continue;
		}
		uint16_t port = ntohs((uint16_t)si.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport);
		if (port == 0) {
			continue;
		}
		char addr[INET6_ADDRSTRLEN] = {0};
		const void *src = family == AF_INET
			? (const void *)&si.psi.soi_proto.pri_tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4
			: (const void *)&si.psi.soi_proto.pri_tcp.tcpsi_ini.insi_laddr.ina_6;
		if (inet_ntop(family, src, addr, sizeof(addr)) == NULL) {
			continue;
		}
		if (count == cap) {
			int next_cap = cap * 2;
			lithe_darwin_socket_t *grown = (lithe_darwin_socket_t *)realloc(items, (size_t)next_cap * sizeof(lithe_darwin_socket_t));
			if (grown == NULL) {
				free(items);
				free(fds);
				return -1;
			}
			items = grown;
			cap = next_cap;
		}
		snprintf(items[count].address, INET6_ADDRSTRLEN, "%s", addr);
		items[count].port = port;
		count++;
	}

	free(fds);
	*out_items = items;
	*out_count = count;
	return 0;
}
*/
import "C"

import (
	"fmt"
	"unsafe"
)

func listeningSockets(pids []int) ([]ListeningSocket, error) {
	var out []ListeningSocket
	for _, pid := range pids {
		var cItems *C.lithe_darwin_socket_t
		var cCount C.int
		if rc := C.lithe_list_pid_tcp_listeners(C.int(pid), &cItems, &cCount); rc != 0 {
			return nil, fmt.Errorf("sysinfo: enumerate listening sockets for pid %d", pid)
		}
		if cItems != nil {
			if cCount > 0 {
				items := unsafe.Slice(cItems, int(cCount))
				for _, item := range items {
					out = append(out, ListeningSocket{
						PID:     pid,
						Address: C.GoString(&item.address[0]),
						Port:    uint16(item.port),
					})
				}
			}
			C.free(unsafe.Pointer(cItems))
		}
	}
	return out, nil
}
