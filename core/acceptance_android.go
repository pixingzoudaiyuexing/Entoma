//go:build android && cgo && entoma_acceptance

package main

import "C"
import (
	"encoding/json"
	"golang.org/x/sys/unix"
	"reflect"
)

// Read immutable listener metadata under the lifecycle lock. Reflection stays
// test-only and read-only; it never writes pointers or vendor state.
func acceptanceForwarder(listener any, tunFd int) map[string]any {
	result := map[string]any{}
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
