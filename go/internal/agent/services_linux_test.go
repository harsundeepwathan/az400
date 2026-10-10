//go:build linux

package agent

import "testing"

func TestParseSystemctlShow(t *testing.T) {
	out := []byte("Id=nginx.service\nDescription=A high performance web server\nLoadState=loaded\nActiveState=failed\nSubState=failed\nMainPID=0\nNRestarts=3\nUnitFileState=enabled\n\n" +
		"Id=nope.service\nLoadState=not-found\nActiveState=inactive\nSubState=dead\nMainPID=0\n")
	s := ParseSystemctlShow(out)
	if len(s) != 2 {
		t.Fatalf("got %d", len(s))
	}
	if s[0].State != "failed" || s[0].Restarts != 3 || s[0].StartupType != "enabled" {
		t.Errorf("nginx = %+v", s[0])
	}
	if s[1].State != "unknown" {
		t.Errorf("not-found unit must be unknown, got %s", s[1].State)
	}
	if MapSystemdState("active", "loaded") != "running" || MapSystemdState("inactive", "loaded") != "stopped" {
		t.Error("state mapping")
	}
}
