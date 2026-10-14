//go:build android && cgo && entoma_acceptance

package main

import "C"
import "encoding/json"

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
	}
	encoded, _ := json.Marshal(state)
	return C.CString(string(encoded))
}
