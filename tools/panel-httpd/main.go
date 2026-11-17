// Minimal static+CGI HTTP server for SurfGate standalone panel on Asuswrt-Merlin.
// Bundled into the package so the panel works when opkg/BusyBox httpd/lighttpd are unavailable.
package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/http/cgi"
	"os"
	"path"
	"path/filepath"
	"strings"
)

func main() {
	root := flag.String("root", ".", "document root (panel web root)")
	listen := flag.String("listen", ":1131", "listen address ([ip]:port)")
	flag.Parse()

	absRoot, err := filepath.Abs(*root)
	if err != nil {
		log.Fatalf("root: %v", err)
	}
	cgiDir := filepath.Join(absRoot, "cgi-bin")
	if st, err := os.Stat(cgiDir); err != nil || !st.IsDir() {
		log.Fatalf("cgi-bin missing under %s", absRoot)
	}

	mux := http.NewServeMux()
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
		h := &cgi.Handler{Path: script, Dir: cgiDir}
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
	fmt.Fprintf(os.Stderr, "panel-httpd listening on %s root=%s\n", ln.Addr().String(), absRoot)
	if err := http.Serve(ln, mux); err != nil {
		log.Fatal(err)
	}
}
