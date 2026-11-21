// Minimal static HTTP server for SurfGate standalone panel on Asuswrt-Merlin.
// Bundled into the package so the panel works when opkg/BusyBox httpd/lighttpd are unavailable.
//
// /cgi-bin/bootstrap|status|api are handled in-process (addon via /bin/sh).
// Never returns opaque HTTP 500 for those endpoints — JSON errors or a minimal
// bootstrap fallback so the SPA can always load after an upgrade.
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"
	"time"
)

const (
	version     = "1.4.43"
	defaultPATH = "/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin"
)

func main() {
	root := flag.String("root", ".", "document root (panel web root)")
	listen := flag.String("listen", ":1131", "listen address ([ip]:port)")
	addon := flag.String("addon", "/jffs/scripts/ssurf", "path to SurfGate addon script")
	webdir := flag.String("webdir", "/www/user/ssurf", "live JSON/CAB dir for /ext/ssurf/ (API keys, catalog, …)")
	flag.Parse()

	absRoot, err := filepath.Abs(*root)
	if err != nil {
		log.Fatalf("root: %v", err)
	}
	cgiDir := filepath.Join(absRoot, "cgi-bin")
	_ = os.MkdirAll(cgiDir, 0755)

	addonPath := resolveAddon(*addon)
	absWeb := resolveWebDir(*webdir)

	mux := http.NewServeMux()

	// Live addon web files — must NOT be a frozen symlink snapshot from panel start,
	// otherwise newly saved api_keys.json / ss_configs.json are invisible to the SPA.
	if absWeb != "" {
		extFS := http.StripPrefix("/ext/ssurf/", http.FileServer(http.Dir(absWeb)))
		mux.Handle("/ext/ssurf/", withRecover(func(w http.ResponseWriter, r *http.Request) {
			// Ensure directory listings are disabled; FileServer 404s missing files.
			extFS.ServeHTTP(w, r)
		}))
	}

	// Exact paths (+ trailing-slash variants) — never CGI shebang exec.
	for _, patt := range []string{"/cgi-bin/bootstrap", "/cgi-bin/bootstrap/"} {
		mux.HandleFunc(patt, withRecover(func(w http.ResponseWriter, r *http.Request) {
			handleBootstrap(w, addonPath)
		}))
	}
	for _, patt := range []string{"/cgi-bin/status", "/cgi-bin/status/"} {
		mux.HandleFunc(patt, withRecover(func(w http.ResponseWriter, r *http.Request) {
			runAddonJSON(w, addonPath, nil, nil, false, "panel", "live")
		}))
	}
	for _, patt := range []string{"/cgi-bin/api", "/cgi-bin/api/"} {
		mux.HandleFunc(patt, withRecover(func(w http.ResponseWriter, r *http.Request) {
			var stdin io.Reader
			extra := []string{"REQUEST_METHOD=" + r.Method}
			if r.Method == http.MethodPost || r.Method == http.MethodPut {
				stdin = r.Body
				if r.ContentLength > 0 {
					extra = append(extra, fmt.Sprintf("CONTENT_LENGTH=%d", r.ContentLength))
				}
			}
			runAddonJSON(w, addonPath, stdin, extra, false, "panel", "api")
		}))
	}
	mux.HandleFunc("/cgi-bin/ping", withRecover(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, fmt.Sprintf(`{"ok":true,"panel_httpd":%q,"addon":%q}`, version, addonPath))
	}))

	// Unknown CGI names → 404 JSON (never fork CGI shebang on /jffs).
	mux.HandleFunc("/cgi-bin/", withRecover(func(w http.ResponseWriter, r *http.Request) {
		name := strings.TrimPrefix(r.URL.Path, "/cgi-bin/")
		name = strings.Trim(path.Clean("/"+name), "/")
		writeJSON(w, fmt.Sprintf(`{"ok":false,"error":"unknown cgi %q"}`, name))
	}))

	fileServer := http.FileServer(http.Dir(absRoot))
	mux.Handle("/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/cgi-bin/") {
			writeJSON(w, `{"ok":false,"error":"not found"}`)
			return
		}
		// Safari/iOS aggressively caches panel SPA assets; without this, users
		// keep seeing the pre-upgrade UI after installing a new addon version.
		setNoStoreStatic(w, r.URL.Path)
		fileServer.ServeHTTP(w, r)
	}))

	addr := *listen
	if addr != "" && !strings.Contains(addr, ":") {
		addr = net.JoinHostPort(addr, "1131")
	}

	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatalf("listen %s: %v", addr, err)
	}
	fmt.Fprintf(os.Stderr, "panel-httpd %s listening on %s root=%s addon=%s webdir=%s\n", version, ln.Addr().String(), absRoot, addonPath, absWeb)
	if err := http.Serve(ln, mux); err != nil {
		log.Fatal(err)
	}
}

func resolveWebDir(preferred string) string {
	cands := []string{preferred, "/www/user/ssurf"}
	for _, cand := range cands {
		if cand == "" {
			continue
		}
		st, err := os.Stat(cand)
		if err == nil && st.IsDir() {
			abs, err := filepath.Abs(cand)
			if err == nil {
				return abs
			}
			return cand
		}
	}
	// Create preferred so first key save can land under a live path.
	if preferred != "" {
		_ = os.MkdirAll(preferred, 0755)
		abs, err := filepath.Abs(preferred)
		if err == nil {
			return abs
		}
		return preferred
	}
	return ""
}

func withRecover(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				log.Printf("panic on %s: %v", r.URL.Path, rec)
				writeJSON(w, fmt.Sprintf(`{"ok":false,"error":%q}`, fmt.Sprintf("panic: %v", rec)))
			}
		}()
		next(w, r)
	}
}

func resolveAddon(preferred string) string {
	cands := []string{
		preferred,
		"/jffs/scripts/ssurf",
		"/opt/bin/surfgate",
		"/opt/bin/surfgate",
		"/opt/bin/ssurf",
	}
	for _, cand := range cands {
		if cand == "" {
			continue
		}
		if st, err := os.Stat(cand); err == nil && !st.IsDir() {
			return cand
		}
	}
	return preferred
}

func handleBootstrap(w http.ResponseWriter, addon string) {
	// Prefer live addon JSON; on any failure serve a minimal valid bootstrap
	// so the SPA can load (router fields empty / defaults).
	ok := runAddonJSON(w, addon, nil, nil, true, "panel", "bootstrap")
	if ok {
		return
	}
	log.Printf("bootstrap: addon failed — serving minimal fallback")
	writeJSON(w, minimalBootstrapJSON())
}

// runAddonJSON returns true when a usable JSON object was written.
// When allowEmptyFail is true and the addon fails, it writes nothing (caller falls back).
func runAddonJSON(w http.ResponseWriter, addon string, stdin io.Reader, extraEnv []string, allowEmptyFail bool, argv ...string) bool {
	if addon == "" {
		if allowEmptyFail {
			return false
		}
		writeJSON(w, `{"ok":false,"error":"addon script missing"}`)
		return true
	}

	cmd := exec.Command("/bin/sh", append([]string{addon}, argv...)...)
	cmd.Env = mergeEnv(os.Environ(), append([]string{
		"PATH=" + defaultPATH,
		"LC_ALL=C",
		"ADDON_SCRIPT=" + addon,
	}, extraEnv...)...)
	if stdin != nil {
		cmd.Stdin = stdin
	}

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := runCmd(cmd, 45*time.Second)
	out := stdout.Bytes()
	if err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		if len(msg) > 200 {
			msg = msg[:200]
		}
		log.Printf("addon %v: %v (%s)", argv, err, msg)
		if allowEmptyFail {
			return false
		}
		writeJSON(w, fmt.Sprintf(`{"ok":false,"error":%q}`, "addon: "+msg))
		return true
	}

	trimmed := strings.TrimSpace(string(out))
	if trimmed == "" {
		if allowEmptyFail {
			return false
		}
		writeJSON(w, `{"ok":false,"error":"empty addon response"}`)
		return true
	}
	if !strings.HasPrefix(trimmed, "{") {
		if i := strings.LastIndex(trimmed, "{"); i >= 0 {
			trimmed = trimmed[i:]
		}
	}
	if !json.Valid([]byte(trimmed)) {
		log.Printf("addon %v: invalid JSON: %q", argv, truncate(trimmed, 120))
		if allowEmptyFail {
			return false
		}
		writeJSON(w, `{"ok":false,"error":"invalid addon JSON"}`)
		return true
	}
	// For bootstrap, require ok+xray shape when possible.
	if allowEmptyFail {
		var probe struct {
			OK   bool            `json:"ok"`
			Xray json.RawMessage `json:"xray"`
		}
		if err := json.Unmarshal([]byte(trimmed), &probe); err != nil || !probe.OK || len(probe.Xray) == 0 {
			return false
		}
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Panel-Httpd", version)
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, trimmed)
	if !strings.HasSuffix(trimmed, "\n") {
		_, _ = io.WriteString(w, "\n")
	}
	return true
}

func minimalBootstrapJSON() string {
	return `{"ok":true,"standalone":true,"panel":{"url":"http://0.0.0.0:1131/","ip":"0.0.0.0","port":1131},"xray":{"router":{"name":"","firmware":"","language":"en","ip":"","territory":"","wan_ip":"","wan_connected":false,"features":"","is_gnuton":false,"cpu":1,"devices_online":{},"devices":{}},"server":{"isRunning":false,"b4sni_isRunning":false},"custom_settings":{"stealthsurf_startup":"y"}},"panel_httpd":"` + version + `","fallback":true}`
}

func runCmd(cmd *exec.Cmd, d time.Duration) error {
	if err := cmd.Start(); err != nil {
		return err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		return err
	case <-time.After(d):
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		<-done
		return fmt.Errorf("timeout after %s", d)
	}
}

func writeJSON(w http.ResponseWriter, body string) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Panel-Httpd", version)
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, body)
	if !strings.HasSuffix(body, "\n") {
		_, _ = io.WriteString(w, "\n")
	}
}

// setNoStoreStatic disables browser caching for SPA entry points and JS/CSS.
// HTML/JS must not be sticky across addon upgrades (iPhone Safari keeps old app.js).
func setNoStoreStatic(w http.ResponseWriter, urlPath string) {
	ext := strings.ToLower(path.Ext(urlPath))
	switch ext {
	case ".html", ".js", ".mjs", ".css", ".map", "":
		w.Header().Set("Cache-Control", "no-store, no-cache, must-revalidate")
		w.Header().Set("Pragma", "no-cache")
	}
	if urlPath == "/" || strings.HasSuffix(urlPath, "/") {
		w.Header().Set("Cache-Control", "no-store, no-cache, must-revalidate")
		w.Header().Set("Pragma", "no-cache")
	}
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

func mergeEnv(base []string, overrides ...string) []string {
	out := make([]string, 0, len(base)+len(overrides))
	seen := map[string]bool{}
	for i := len(overrides) - 1; i >= 0; i-- {
		kv := overrides[i]
		key, _, ok := strings.Cut(kv, "=")
		if !ok || key == "" || seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, kv)
	}
	for _, kv := range base {
		key, _, ok := strings.Cut(kv, "=")
		if !ok || key == "" || seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, kv)
	}
	return out
}
