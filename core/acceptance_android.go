//go:build android && cgo && entoma_acceptance

package main

import "C"
import (
	"encoding/json"
	MC "github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/tunnel"
	"golang.org/x/sys/unix"
	"net/netip"
	"reflect"
)

//export entomaAcceptanceInvalidTunCleanup
func entomaAcceptanceInvalidTunCleanup() *C.char {
	var pipe [2]int
	result := map[string]any{}
	if err := unix.Pipe(pipe[:]); err != nil {
		encoded, _ := json.Marshal(map[string]any{"fixtureUnavailable": true})
		return C.CString(string(encoded))
	}
	defer unix.Close(pipe[1])
	listener, err := sing_tun.New(LC.Tun{
		Enable: true, FileDescriptor: pipe[0], Device: "fixture",
		Stack: MC.TunMixed, MTU: 9000,
		Inet4Address: []netip.Prefix{netip.MustParsePrefix("198.18.254.1/30")},
	}, tunnel.Tunnel)
	result["rejected"] = err != nil
	if listener != nil {
		_ = listener.Close()
	}
	_, fdErr := unix.FcntlInt(uintptr(pipe[0]), unix.F_GETFD, 0)
	result["ownedFdClosed"] = fdErr == unix.EBADF
	if fdErr != unix.EBADF {
		_ = unix.Close(pipe[0])
	}
	encoded, _ := json.Marshal(result)
	return C.CString(string(encoded))
}

// Read immutable listener metadata under the lifecycle lock. Reflection stays
// test-only and read-only; it never writes pointers or vendor state.
func acceptanceForwarder(listener any, tunFd int) (result map[string]any) {
	result = map[string]any{}
	defer func() {
		if recover() != nil {
			result = map[string]any{"diagnosticUnavailable": true}
		}
	}()
	value := reflect.ValueOf(listener).Elem().FieldByName("tunStack")
	if !value.IsValid() || value.IsNil() {
		return result
	}
	value = value.Elem().Elem()
	if system := value.FieldByName("System"); system.IsValid() {
		value = system.Elem()
	}
	port := value.FieldByName("tcpPort")
	if !port.IsValid() {
		return result
	}
	result["port"] = port.Uint()
	result["configuredName"] = value.FieldByName("tunName").String()
	result["bindConfigured"] = value.FieldByName("bindInterface").Bool()
	tcp := value.FieldByName("tcpListener")
	if !tcp.IsValid() || tcp.IsNil() {
		return result
	}
	fd := int(tcp.Elem().Elem().FieldByName("fd").Elem().FieldByName("pfd").FieldByName("Sysfd").Int())
	listening, err := unix.GetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_ACCEPTCONN)
	result["listening"] = err == nil && listening == 1
	if err != nil {
		result["listenReadError"] = err.Error()
	}
	address, addrErr := unix.Getsockname(fd)
	if addr, ok := address.(*unix.SockaddrInet4); ok && addrErr == nil {
		result["listenPortMatches"] = addr.Port == int(port.Uint())
		result["wildcardListen"] = addr.Addr == [4]byte{}
	}
	mark, markErr := unix.GetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_MARK)
	if markErr == nil {
		result["socketMark"] = mark
	}
	device, bindErr := unix.GetsockoptString(fd, unix.SOL_SOCKET, unix.SO_BINDTODEVICE)
	result["boundDevice"] = device
	result["bindReadOK"] = bindErr == nil
	if ifreq, err := unix.NewIfreq(""); err == nil {
		if err = unix.IoctlIfreq(tunFd, unix.TUNGETIFF, ifreq); err == nil {
			result["tunDevice"] = ifreq.Name()
			result["bindingMatchesTun"] = device != "" && device == ifreq.Name()
		}
	}
	return result
}

// Test-only readback of the active private Android TUN listener. Ordinary
// product builds do not contain this symbol or any external diagnostic channel.
//
//export entomaAcceptanceTunSnapshot
func entomaAcceptanceTunSnapshot() *C.char {
	androidTun.mu.Lock()
	defer androidTun.mu.Unlock()
	state := map[string]any{"active": false}
	if handler, ok := androidTun.active.(*TunHandler); ok && handler.listener != nil {
		state["active"] = true
		state["stack"] = handler.listener.Config().Stack.String()
		state["forwarder"] = acceptanceForwarder(handler.listener, handler.listener.Config().FileDescriptor)
	}
	encoded, _ := json.Marshal(state)
	return C.CString(string(encoded))
}
