// Minimal static+CGI HTTP server for SurfGate standalone panel on Asuswrt-Merlin.
// Bundled into the package so the panel works when opkg/BusyBox httpd/lighttpd are unavailable.
//
// Critical endpoints (/cgi-bin/bootstrap|status|api) call the addon script via /bin/sh
// (not via CGI shebang exec on /jffs) so missing +x / noexec cannot yield HTTP 500.
package main

import (
	"bytes"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/cgi"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"
	"time"
)

const defaultPATH = "/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin"

func main() {
	root := flag.String("root", ".", "document root (panel web root)")
	listen := flag.String("listen", ":1131", "listen address ([ip]:port)")
	addon := flag.String("addon", "/jffs/scripts/stealthsurf", "path to SurfGate addon script")
	flag.Parse()

	absRoot, err := filepath.Abs(*root)
	if err != nil {
		log.Fatalf("root: %v", err)
	}
	cgiDir := filepath.Join(absRoot, "cgi-bin")
	_ = os.MkdirAll(cgiDir, 0755)

	addonPath := resolveAddon(*addon)

	mux := http.NewServeMux()

	mux.HandleFunc("/cgi-bin/bootstrap", func(w http.ResponseWriter, r *http.Request) {
		runAddonJSON(w, addonPath, nil, nil, "panel", "bootstrap")
	})
	mux.HandleFunc("/cgi-bin/status", func(w http.ResponseWriter, r *http.Request) {
		runAddonJSON(w, addonPath, nil, nil, "panel", "live")
	})
	mux.HandleFunc("/cgi-bin/api", func(w http.ResponseWriter, r *http.Request) {
		var stdin io.Reader
		extra := []string{"REQUEST_METHOD=" + r.Method}
		if r.Method == http.MethodPost || r.Method == http.MethodPut {
			stdin = r.Body
			if r.ContentLength > 0 {
				extra = append(extra, fmt.Sprintf("CONTENT_LENGTH=%d", r.ContentLength))
			}
		}
		runAddonJSON(w, addonPath, stdin, extra, "panel", "api")
	})

	// Generic CGI fallback via /bin/sh (works even when script lacks +x / noexec).
	mux.HandleFunc("/cgi-bin/", func(w http.ResponseWriter, r *http.Request) {
		name := strings.TrimPrefix(r.URL.Path, "/cgi-bin/")
		name = path.Clean("/" + name)
		name = strings.TrimPrefix(name, "/")
		if name == "" || name == "." || strings.HasPrefix(name, "../") || strings.Contains(name, "/") {
			http.NotFound(w, r)
			return
		}
		script := filepath.Join(cgiDir, name)
		if st, err := os.Stat(script); err != nil || st.IsDir() {
			http.NotFound(w, r)
			return
		}
		h := &cgi.Handler{
			Path:       "/bin/sh",
			Args:       []string{script},
			Dir:        cgiDir,
			InheritEnv: []string{"HOME", "USER", "TZ", "LANG"},
			Env:        []string{"PATH=" + defaultPATH, "ADDON_SCRIPT=" + addonPath},
		}
		h.ServeHTTP(w, r)
	})

	fileServer := http.FileServer(http.Dir(absRoot))
	mux.Handle("/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/cgi-bin/") {
			http.NotFound(w, r)
			return
		}
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
	fmt.Fprintf(os.Stderr, "panel-httpd listening on %s root=%s addon=%s\n", ln.Addr().String(), absRoot, addonPath)
	if err := http.Serve(ln, mux); err != nil {
		log.Fatal(err)
	}
}

func resolveAddon(preferred string) string {
	cands := []string{
		preferred,
		"/jffs/scripts/stealthsurf",
		"/opt/bin/surfgate",
		"/opt/bin/stealthsurf",
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

func runAddonJSON(w http.ResponseWriter, addon string, stdin io.Reader, extraEnv []string, argv ...string) {
	if addon == "" {
		writeJSON(w, `{"ok":false,"error":"addon script missing"}`)
		return
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

	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	out, err := runCmdOutput(cmd, 45*time.Second)
	if err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		if len(msg) > 200 {
			msg = msg[:200]
		}
		log.Printf("addon %v: %v (%s)", argv, err, msg)
		writeJSON(w, fmt.Sprintf(`{"ok":false,"error":%q}`, "addon: "+msg))
		return
	}

	trimmed := strings.TrimSpace(string(out))
	if trimmed == "" {
		writeJSON(w, `{"ok":false,"error":"empty addon response"}`)
		return
	}
	// Addon may leak log lines on stdout before JSON — keep the last object.
	if !strings.HasPrefix(trimmed, "{") {
		if i := strings.LastIndex(trimmed, "{"); i >= 0 {
			trimmed = trimmed[i:]
		}
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, trimmed)
	if !strings.HasSuffix(trimmed, "\n") {
		_, _ = io.WriteString(w, "\n")
	}
}

func runCmdOutput(cmd *exec.Cmd, d time.Duration) ([]byte, error) {
	type result struct {
		out []byte
		err error
	}
	ch := make(chan result, 1)
	go func() {
		out, err := cmd.Output()
		ch <- result{out, err}
	}()
	select {
	case r := <-ch:
		return r.out, r.err
	case <-time.After(d):
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		return nil, fmt.Errorf("timeout after %s", d)
	}
}

func writeJSON(w http.ResponseWriter, body string) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, body)
	if !strings.HasSuffix(body, "\n") {
		_, _ = io.WriteString(w, "\n")
	}
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
