package sysinfo

import (
	"net"
	"os"
	"runtime"
	"slices"
	"testing"
)

func TestListeningSocketsDetectsLiveLoopbackAndStopsAfterClose(t *testing.T) {
	if runtime.GOOS != "darwin" && runtime.GOOS != "linux" && runtime.GOOS != "windows" {
		t.Skipf("no native listener probe on %s", runtime.GOOS)
	}

	v4, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port4 := uint16(v4.Addr().(*net.TCPAddr).Port)
	defer v4.Close()

	sockets, err := ListeningSockets([]int{os.Getpid()})
	if err != nil {
		t.Fatal(err)
	}
	if !slices.ContainsFunc(sockets, func(s ListeningSocket) bool {
		return s.PID == os.Getpid() && s.Port == port4 && s.Address == "127.0.0.1"
	}) {
		t.Fatalf("ListeningSockets missing tcp4 127.0.0.1:%d in %+v", port4, sockets)
	}

	if v6, err6 := net.Listen("tcp6", "[::1]:0"); err6 == nil {
		port6 := uint16(v6.Addr().(*net.TCPAddr).Port)
		defer v6.Close()
		sockets, err = ListeningSockets([]int{os.Getpid()})
		if err != nil {
			t.Fatal(err)
		}
		if !slices.ContainsFunc(sockets, func(s ListeningSocket) bool {
			return s.PID == os.Getpid() && s.Port == port6 && s.Address == "::1"
		}) {
			t.Fatalf("ListeningSockets missing tcp6 [::1]:%d in %+v", port6, sockets)
		}
	}

	if err := v4.Close(); err != nil {
		t.Fatal(err)
	}
	after, err := ListeningSockets([]int{os.Getpid()})
	if err != nil {
		t.Fatal(err)
	}
	if slices.ContainsFunc(after, func(s ListeningSocket) bool {
		return s.Port == port4
	}) {
		t.Fatalf("ListeningSockets still reports closed port %d: %+v", port4, after)
	}
}

func TestParseProcNetTCPRecognizesIPv4IPv6AndFiltersNonListeningStates(t *testing.T) {
	v4Sample := []byte(
		"  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n" +
			"   0: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 41234 1 00000000 100 0 0 10 0\n" +
			"   1: 0100007F:C350 00000000:0000 01 00000000:00000000 00:00000000 00000000  1000        0 41235 1 00000000 100 0 0 10 0\n",
	)
	v4 := parseProcNetTCP(v4Sample, false)
	if len(v4) != 1 || v4[41234] != (procTCPListener{address: "0.0.0.0", port: 8080}) {
		t.Fatalf("v4 listeners = %+v", v4)
	}

	v6Sample := []byte(
		"  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n" +
			"   0: 00000000000000000000000001000000:2382 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 51234 1 00000000 100 0 0 10 0\n" +
			"   1: 0000000000000000FFFF00000100007F:1F90 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 51235 1 00000000 100 0 0 10 0\n",
	)
	v6 := parseProcNetTCP(v6Sample, true)
	if v6[51234] != (procTCPListener{address: "::1", port: 9090}) {
		t.Fatalf("v6 loopback listener = %+v", v6)
	}
	if _, ok := v6[51235]; !ok || v6[51235].port != 8080 {
		t.Fatalf("v6 mapped listener = %+v", v6)
	}
}
