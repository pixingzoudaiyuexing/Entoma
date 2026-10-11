package main

import (
	"net"
	"strconv"
	"testing"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/listener"
)

func testConfig(t *testing.T, port int) *SetupParams {
	t.Helper()
	constant.SetHomeDir(t.TempDir())
	raw := config.DefaultRawConfig()
	raw.MixedPort = port
	raw.BindAddress = "127.0.0.1"
	raw.AllowLan = false
	raw.DNS.Enable = false
	raw.ExternalController = ""
	raw.Tun.Enable = false
	return &SetupParams{Config: raw, SelectedMap: map[string]string{}, TestURL: "https://www.gstatic.com/generate_204"}
}

func TestInvalidConfigPreservesLastGood(t *testing.T) {
	handleStopListener()
	if err := setupConfig(testConfig(t, 0)); err != nil {
		t.Fatal(err)
	}
	good := currentConfig
	bad, err := config.UnmarshalRawConfig([]byte("proxies:\n  - {name: fixture, type: ss, server: 127.0.0.1, port: 443, cipher: invalid, password: fixture}\n"))
	if err != nil {
		t.Fatal(err)
	}
	if err = setupConfig(&SetupParams{Config: bad}); err == nil {
		t.Fatal("invalid proxy was accepted")
	}
	if currentConfig != good {
		t.Fatal("last good configuration was replaced")
	}
}

func TestValidateChecksProxySemantics(t *testing.T) {
	constant.SetHomeDir(t.TempDir())
	message := handleValidateConfig([]byte("proxies:\n  - {name: fixture, type: ss, server: 127.0.0.1, port: 443, cipher: invalid, password: fixture}\n"))
	if message == "" {
		t.Fatal("unmarshal-only validation accepted invalid cipher")
	}
}

func TestInvalidSetupJSONPreservesLastGood(t *testing.T) {
	handleStopListener()
	if err := setupConfig(testConfig(t, 0)); err != nil {
		t.Fatal(err)
	}
	good := currentConfig
	if handleSetupConfig([]byte("{")) == "" {
		t.Fatal("malformed setup accepted")
	}
	if currentConfig != good {
		t.Fatal("malformed JSON reset the active configuration")
	}
}

func TestStartRequiresValidConfiguration(t *testing.T) {
	handleStopListener()
	currentConfig = nil
	if handleStartListener() {
		t.Fatal("started without configuration")
	}
}

func TestOccupiedTCPIsNotConnected(t *testing.T) {
	handleStopListener()
	socket, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer socket.Close()
	_, portText, _ := net.SplitHostPort(socket.Addr().String())
	port, _ := strconv.Atoi(portText)
	if err := setupConfig(testConfig(t, port)); err != nil {
		t.Fatal(err)
	}
	if handleStartListener() {
		t.Fatal("reported connected while TCP bind failed")
	}
	if isRunning {
		t.Fatal("running state was set after bind failure")
	}
}

func TestOccupiedUDPReleasesTCPAndCanRetry(t *testing.T) {
	handleStopListener()
	socket, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	_, portText, _ := net.SplitHostPort(socket.LocalAddr().String())
	port, _ := strconv.Atoi(portText)
	if err := setupConfig(testConfig(t, port)); err != nil {
		t.Fatal(err)
	}
	if handleStartListener() {
		socket.Close()
		t.Fatal("reported connected while UDP bind failed")
	}
	if listener.GetPorts().MixedPort != 0 {
		socket.Close()
		t.Fatal("closed TCP listener remained registered")
	}
	socket.Close()
	if !handleStartListener() {
		t.Fatal("valid retry did not start")
	}
	defer handleStopListener()
	if listener.GetPorts().MixedPort != port {
		t.Fatal("expected mixed listener was not owned")
	}
	if !handleStopListener() {
		t.Fatal("disconnect failed")
	}
	if listener.GetPorts().MixedPort != 0 {
		t.Fatal("disconnect retained listener")
	}
}
