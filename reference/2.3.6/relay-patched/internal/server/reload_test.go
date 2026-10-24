package server

import (
	"encoding/hex"
	"fmt"
	"github.com/telegramdesktop/tproxy-server/internal/config"
	"github.com/telegramdesktop/tproxy-server/internal/frame"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestReloadPreservesOpenStreamAndRejectsInvalidFile(t *testing.T) {
	backend := startEchoBackend(t)
	file := filepath.Join(t.TempDir(), "profiles.json")
	app, _ := newConfiguredTestServer(t, backend, func(c *config.Config) { c.ProfilesFile = file })
	defer app.Shutdown()
	hosted := httptest.NewServer(app.Handler())
	defer hosted.Close()
	admin := httptest.NewServer(app.AdminHandler())
	defer admin.Close()
	create := func(p config.Profile) string {
		bootstrap, err := app.manager.IssueBootstrap(&p, "127.0.0.1")
		if err != nil {
			t.Fatal(err)
		}
		r := perform(t, hosted.Client(), apiRequest(t, "POST", hosted.URL+"/api/v1/session", bootstrap, frame.Encode(frame.Hello, 0, []byte{1})))
		readResponse(t, r)
		if r.StatusCode != 200 {
			t.Fatal(r.StatusCode)
		}
		return r.Header.Get("X-Session-Token")
	}
	old := app.manager.Profiles()[0]
	token := create(old)
	cursor := "0"
	exchange := func(seq int, open bool) {
		payload := []byte(fmt.Sprintf("same-stream-%d", seq))
		body := frame.Encode(frame.Data, 17, payload)
		if open {
			body = append(frame.Encode(frame.Open, 17, nil), body...)
		}
		req := apiRequest(t, "POST", hosted.URL+"/api/v1/up", token, body)
		req.Header.Set("X-Up-Seq", fmt.Sprint(seq))
		r := perform(t, hosted.Client(), req)
		readResponse(t, r)
		if r.StatusCode != 204 {
			t.Fatal(r.StatusCode)
		}
		_, _, cursor = pollForData(t, hosted.Client(), hosted.URL, token, cursor, map[uint32][]byte{17: payload})
	}
	reload := func(status int) {
		req, _ := http.NewRequest("POST", admin.URL+"/profiles/reload", nil)
		req.Header.Set("X-WPP-Reload", "1")
		r := perform(t, admin.Client(), req)
		readResponse(t, r)
		if r.StatusCode != status {
			t.Fatalf("reload %d want %d", r.StatusCode, status)
		}
	}
	first := fmt.Sprintf(`{"name":"default","secret":"000102030405060708090a0b0c0d0e0f","backend":%q}`, backend)
	second := fmt.Sprintf(`{"name":"new","secret":"101112131415161718191a1b1c1d1e1f","backend":%q}`, backend)
	write := func(s string) {
		if err := os.WriteFile(file, []byte(s), 0600); err != nil {
			t.Fatal(err)
		}
	}
	exchange(1, true)
	write(`{"profiles":[` + first + `,` + second + `]}`)
	reload(204)
	exchange(2, false)
	secret, _ := hex.DecodeString("101112131415161718191a1b1c1d1e1f")
	cap := config.DeriveCapability(testHost, secret)
	p := app.manager.MatchCapability(cap[:])
	if p == nil {
		t.Fatal("new key absent")
	}
	newToken := create(*p)
	write(`{"profiles":[BROKEN]}`)
	reload(400)
	exchange(3, false)
	if app.manager.MatchCapability(cap[:]) == nil {
		t.Fatal("invalid reload changed profiles")
	}
	write(`{"profiles":[` + first + `]}`)
	reload(204)
	exchange(4, false)
	if app.manager.MatchCapability(cap[:]) != nil {
		t.Fatal("removed capability still accepted")
	}
	if _, err := app.manager.Get(newToken); err == nil {
		t.Fatal("removed profile session still active")
	}
	req, _ := http.NewRequest("POST", admin.URL+"/profiles/reload", nil)
	r := perform(t, admin.Client(), req)
	readResponse(t, r)
	if r.StatusCode != 403 {
		t.Fatal("missing reload header accepted")
	}
}
