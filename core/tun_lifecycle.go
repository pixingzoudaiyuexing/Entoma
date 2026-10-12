package main

import (
	"io"
	"sync"
	"time"
)

// A start call transfers one JNI reference to this lifecycle, including failed
// and non-VPN starts. The Android handler drains callbacks before Close returns.
type tunLifecycle struct {
	mu        sync.Mutex
	active    io.Closer
	release   func()
	startedAt *time.Time
}

func (s *tunLifecycle) stopLocked() {
	s.startedAt = nil
	if s.active != nil {
		_ = s.active.Close()
		s.active = nil
	}
	if s.release != nil {
		s.release()
		s.release = nil
	}
}

func (s *tunLifecycle) start(ready bool, fd int, release func(), open func() (io.Closer, error)) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.stopLocked()
	transferred := false
	defer func() {
		if !transferred {
			release()
		}
	}()
	if !ready {
		return false
	}
	if fd != 0 {
		resource, err := open()
		if err != nil || resource == nil {
			if resource != nil {
				_ = resource.Close()
			}
			return false
		}
		s.active, s.release = resource, release
		transferred = true
	}
	now := time.Now()
	s.startedAt = &now
	return true
}

func (s *tunLifecycle) stop() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.stopLocked()
}

func (s *tunLifecycle) runtime() *time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.startedAt == nil {
		return nil
	}
	value := *s.startedAt
	return &value
}
