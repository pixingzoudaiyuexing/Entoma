package main

import (
	"errors"
	"io"
	"sync"
	"sync/atomic"
	"testing"
)

type lifecycleCloser struct {
	closes  atomic.Int32
	entered chan struct{}
	leave   chan struct{}
}

func (c *lifecycleCloser) Close() error {
	c.closes.Add(1)
	if c.entered != nil {
		close(c.entered)
		<-c.leave
	}
	return nil
}

func TestTunCallbackOwnership(t *testing.T) {
	for _, tc := range []struct {
		name  string
		ready bool
		fd    int
		kind  string
		ok    bool
	}{
		{"no config", false, 4, "", false}, {"non VPN", true, 0, "", true},
		{"failed start", true, 4, "error", false}, {"missing listener", true, 4, "nil", false},
		{"partial failed listener", true, 4, "partial", false}, {"normal", true, 4, "ok", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var lifecycle tunLifecycle
			var released atomic.Int32
			resource := &lifecycleCloser{}
			opened := 0
			ok := lifecycle.start(tc.ready, tc.fd, func() { released.Add(1) }, func() (io.Closer, error) {
				opened++
				switch tc.kind {
				case "error":
					return nil, errors.New("start failed")
				case "nil":
					return nil, nil
				case "partial":
					return resource, errors.New("partial start")
				default:
					return resource, nil
				}
			})
			if ok != tc.ok {
				t.Fatalf("result=%v", ok)
			}
			retained := tc.kind == "ok"
			if (released.Load() == 0) != retained {
				t.Fatal("incorrect transfer")
			}
			if (!tc.ready || tc.fd == 0) && opened != 0 {
				t.Fatal("unexpected listener open")
			}
			if (lifecycle.runtime() != nil) != tc.ok {
				t.Fatal("incorrect running state")
			}
			lifecycle.stop()
			lifecycle.stop()
			if released.Load() != 1 {
				t.Fatalf("reference released %d times", released.Load())
			}
			wantClose := int32(0)
			if retained || tc.kind == "partial" {
				wantClose = 1
			}
			if resource.closes.Load() != wantClose {
				t.Fatal("incorrect listener ownership")
			}
			if lifecycle.runtime() != nil {
				t.Fatal("running after stop")
			}
		})
	}
}

func TestTunConcurrentReplacementReleasesEveryReferenceOnce(t *testing.T) {
	var lifecycle tunLifecycle
	const count = 20
	releases := make([]atomic.Int32, count)
	resources := make([]lifecycleCloser, count)
	var starts sync.WaitGroup
	starts.Add(count)
	for i := 0; i < count; i++ {
		i := i
		go func() {
			defer starts.Done()
			lifecycle.start(true, 4, func() { releases[i].Add(1) }, func() (io.Closer, error) { return &resources[i], nil })
		}()
	}
	starts.Wait()
	lifecycle.stop()
	for i := 0; i < count; i++ {
		i := i
		if releases[i].Load() != 1 || resources[i].closes.Load() != 1 {
			t.Fatalf("resource %d not closed exactly once", i)
		}
	}
}

func TestTunStopDrainsResourceBeforeReleasingReference(t *testing.T) {
	var lifecycle tunLifecycle
	var released atomic.Int32
	resource := &lifecycleCloser{entered: make(chan struct{}), leave: make(chan struct{})}
	lifecycle.start(true, 4, func() { released.Add(1) }, func() (io.Closer, error) { return resource, nil })
	stopped := make(chan struct{})
	go func() { lifecycle.stop(); close(stopped) }()
	<-resource.entered
	if released.Load() != 0 {
		t.Fatal("reference freed before callbacks drained")
	}
	select {
	case <-stopped:
		t.Fatal("stop returned before drain")
	default:
	}
	close(resource.leave)
	<-stopped
	if released.Load() != 1 {
		t.Fatal("stop did not release reference synchronously")
	}
}
