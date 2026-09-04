// A tiny stateful HTTP server. It keeps a request counter in memory —
// state that dies with the process unless we checkpoint it.
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"
)

var (
	counter   int
	startedAt = time.Now()
)

func main() {
	// Simulate an expensive warmup: loading model weights, JIT compilation,
	// filling an in-memory cache. This is the work a restored process skips.
	warmup := 10
	if v, err := strconv.Atoi(os.Getenv("WARMUP_SECONDS")); err == nil {
		warmup = v
	}
	log.Printf("warming up for %ds...", warmup)
	time.Sleep(time.Duration(warmup) * time.Second)
	log.Println("ready to serve")

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		counter++
		// Hostname is read per request so it reflects the pod we are
		// currently running in — even after a checkpoint/restore.
		hostname, _ := os.Hostname()
		fmt.Fprintf(w, "counter: %d | pod: %s | process up: %s\n",
			counter, hostname, time.Since(startedAt).Round(time.Second))
	})
	log.Fatal(http.ListenAndServe(":8080", nil))
}
