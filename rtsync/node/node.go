// Package node runs one laptop's sync sidecar: it serves this laptop's changes
// to the peer over the shop LAN, pulls and applies the peer's, falls back to
// signed files in the shared OneDrive folder when the LAN is down, and turns
// the capture triggers on and off around Aronium.
package node

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/huenique/ar-sync/rtsync/rt"
)

// Config is one laptop's sidecar settings.
type Config struct {
	Node     string   `json:"node"`     // this laptop's name in global ids, e.g. "A"
	Peer     string   `json:"peer"`     // the other laptop's node name
	DBPath   string   `json:"dbPath"`   // Aronium's pos.db
	Listen   string   `json:"listen"`   // e.g. ":47800"
	PeerURLs []string `json:"peerUrls"` // e.g. http://LAPTOP-MB7LH62P:47800
	Key      string   `json:"key"`      // shared secret (hex), same on both laptops
	ShareDir string   `json:"shareDir"` // OneDrive folder both laptops sync; "" disables the fallback
	PollMs   int      `json:"pollMs"`   // how often to pull (default 1500)
	SettleMs int64    `json:"settleMs"` // hold changes this long before sending (default 2000)
	PageSize int      `json:"pageSize"` // log rows per batch (default 500)
	// StableSec: Aronium must have run this long with an unchanged Migration
	// count before the triggers go back on (default 15).
	StableSec int `json:"stableSec"`
	// AroniumImage is the process watched for the trigger lifecycle
	// (default Aronium.Pos.exe).
	AroniumImage string `json:"aroniumImage"`
	// Role is "till" (sells, owns End of day) or "office".
	Role string `json:"role"`
	// NotifyCmd runs ar-sync's rt-notify.ps1; the sidecar appends
	// -Kind <kind> -Text <text> [-Buttons a,b]. Empty: notices go to the log only.
	NotifyCmd []string `json:"notifyCmd"`
	// LaterFile is written by ar-sync when the cashier clicks Later.
	LaterFile string `json:"laterFile"`
	// OpenHour: before this local hour a pending till restart runs by itself (default 8).
	OpenHour int `json:"openHour"`
}

func (c *Config) defaults() {
	if c.PollMs == 0 {
		c.PollMs = 1500
	}
	if c.SettleMs == 0 {
		c.SettleMs = 2000
	}
	if c.PageSize == 0 {
		c.PageSize = 500
	}
	if c.StableSec == 0 {
		c.StableSec = 15
	}
	if c.OpenHour == 0 {
		c.OpenHour = 8
	}
	if c.Role == "" {
		c.Role = "till"
	}
	if c.AroniumImage == "" {
		c.AroniumImage = "Aronium.Pos.exe"
	}
	if c.Listen == "" {
		c.Listen = ":47800"
	}
}

// Status is what the sidecar reports about itself.
type Status struct {
	LastPull    time.Time `json:"lastPull"`
	LastPullVia string    `json:"lastPullVia"` // lan, share, deferred
	LastError   string    `json:"lastError,omitempty"`
	Applied     int64     `json:"applied"`
	Paused      string    `json:"paused,omitempty"` // why sync is paused, if it is
	Killed      bool      `json:"killed,omitempty"`
	RestartDue  bool      `json:"restartDue,omitempty"`
	PeerLastSeq int64     `json:"peerLastSeq"`
	TriggersOn  bool      `json:"triggersOn"`
}

// Node is a running sidecar.
type Node struct {
	cfg Config
	eng *rt.DB
	mu  sync.Mutex // the engine has one connection: serialize all use
	log *log.Logger

	// AroniumRunning reports whether Aronium is open on this laptop.
	AroniumRunning func() bool
	// OnApplied is called after peer changes were written (Phase 3 hooks the
	// till's "restart Aronium" toast here). Receives the changed tables.
	OnApplied func(tables map[string]int)

	// Notify shows a toast through ar-sync (kind, text, buttons).
	Notify func(kind, text string, buttons ...string)
	// RestartAronium closes Aronium gracefully and reopens it.
	RestartAronium func() error
	// UpdaterRunning reports an Aronium installer or uninstaller running.
	UpdaterRunning func() bool
	// AroniumStarted returns when the running Aronium process started.
	AroniumStarted func() (time.Time, bool)
	// Now is the clock (tests move it).
	Now func() time.Time

	lastToast map[string]time.Time
	killed    bool

	client    *http.Client
	startSeen time.Time
	startMig  int64
	status    Status
	statusMu  sync.Mutex
	lastShare time.Time
}

// New opens the database and prepares the node. The database must be seeded.
func New(cfg Config, lg *log.Logger) (*Node, error) {
	cfg.defaults()
	if cfg.Node == "" || cfg.Peer == "" || cfg.Key == "" {
		return nil, errors.New("config needs node, peer and key")
	}
	eng, err := rt.Open(cfg.DBPath)
	if err != nil {
		return nil, err
	}
	if n, err := eng.Node(); err != nil || n != cfg.Node {
		eng.Close()
		return nil, fmt.Errorf("database node %q does not match config %q (%v)", n, cfg.Node, err)
	}
	if lg == nil {
		lg = log.New(io.Discard, "", 0)
	}
	nd := &Node{cfg: cfg, eng: eng, log: lg, AroniumRunning: func() bool { return ProcessRunning(cfg.AroniumImage) },
		client: &http.Client{Timeout: 10 * time.Second}, lastToast: map[string]time.Time{}, Now: time.Now,
		UpdaterRunning: func() bool { return UpdaterRunning() },
		AroniumStarted: func() (time.Time, bool) { return ProcessStarted(cfg.AroniumImage) }}
	nd.Notify = nd.runNotify
	nd.RestartAronium = func() error { return nd.runNotifyErr("restart", "Restarting Aronium to load the office's changes.") }
	return nd, nil
}

// Close stops using the database.
func (n *Node) Close() error {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.eng.Close()
}

// Engine runs f with exclusive use of the engine.
func (n *Node) Engine(f func(*rt.DB) error) error {
	n.mu.Lock()
	defer n.mu.Unlock()
	return f(n.eng)
}

// Status returns a copy of the current status.
func (n *Node) Status() Status {
	n.statusMu.Lock()
	defer n.statusMu.Unlock()
	return n.status
}

func (n *Node) setStatus(f func(*Status)) {
	n.statusMu.Lock()
	f(&n.status)
	n.statusMu.Unlock()
}

// ---------------------------------------------------------------- auth

func (n *Node) mac(parts ...string) string {
	key, _ := hex.DecodeString(n.cfg.Key)
	if len(key) == 0 {
		key = []byte(n.cfg.Key)
	}
	m := hmac.New(sha256.New, key)
	m.Write([]byte(strings.Join(parts, "\n")))
	return hex.EncodeToString(m.Sum(nil))
}

func (n *Node) signRequest(r *http.Request) {
	ts := strconv.FormatInt(time.Now().Unix(), 10)
	r.Header.Set("X-RT-Node", n.cfg.Node)
	r.Header.Set("X-RT-Time", ts)
	r.Header.Set("X-RT-Sig", n.mac(r.Method, r.URL.RequestURI(), ts, n.cfg.Node))
}

func (n *Node) checkRequest(r *http.Request) error {
	ts, err := strconv.ParseInt(r.Header.Get("X-RT-Time"), 10, 64)
	if err != nil {
		return errors.New("no timestamp")
	}
	if d := time.Since(time.Unix(ts, 0)); d > 5*time.Minute || d < -5*time.Minute {
		return errors.New("clock skew over 5 minutes")
	}
	from := r.Header.Get("X-RT-Node")
	if from != n.cfg.Peer {
		return fmt.Errorf("unknown peer %q", from)
	}
	want := n.mac(r.Method, r.URL.RequestURI(), r.Header.Get("X-RT-Time"), from)
	if !hmac.Equal([]byte(want), []byte(r.Header.Get("X-RT-Sig"))) {
		return errors.New("bad signature")
	}
	return nil
}

// ---------------------------------------------------------------- server

type hello struct {
	Node   string `json:"node"`
	Seed   string `json:"seed"`
	Schema string `json:"schema"`
}

// Handler serves /hello and /changes to the peer.
func (n *Node) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/hello", func(w http.ResponseWriter, r *http.Request) {
		if err := n.checkRequest(r); err != nil {
			http.Error(w, err.Error(), http.StatusUnauthorized)
			return
		}
		var h hello
		n.Engine(func(e *rt.DB) error {
			h = hello{n.cfg.Node, e.SeedTag(), e.SchemaTag()}
			return nil
		})
		n.writeSigned(w, h)
	})
	mux.HandleFunc("/changes", func(w http.ResponseWriter, r *http.Request) {
		if err := n.checkRequest(r); err != nil {
			http.Error(w, err.Error(), http.StatusUnauthorized)
			return
		}
		after, err := strconv.ParseInt(r.URL.Query().Get("after"), 10, 64)
		if err != nil || after < 0 {
			http.Error(w, "bad after", http.StatusBadRequest)
			return
		}
		var b *rt.Batch
		err = n.Engine(func(e *rt.DB) error {
			// The peer asking for after=N has applied everything up to N.
			e.SetMeta("ack."+n.cfg.Peer, strconv.FormatInt(after, 10))
			var err error
			b, err = e.ExtractSettled(after, n.cfg.PageSize, n.cfg.SettleMs)
			return err
		})
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		n.writeSigned(w, b)
	})
	return mux
}

func (n *Node) writeSigned(w http.ResponseWriter, v any) {
	body, err := json.Marshal(v)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-RT-Body-Sig", n.mac("body", string(body)))
	w.Write(body)
}

// ---------------------------------------------------------------- pull

func (n *Node) get(ctx context.Context, base, path string, v any) error {
	req, err := http.NewRequestWithContext(ctx, "GET", strings.TrimRight(base, "/")+path, nil)
	if err != nil {
		return err
	}
	n.signRequest(req)
	resp, err := n.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64<<20))
	if err != nil {
		return err
	}
	if resp.StatusCode != 200 {
		return fmt.Errorf("%s: %s %s", base, resp.Status, strings.TrimSpace(string(body)))
	}
	if !hmac.Equal([]byte(n.mac("body", string(body))), []byte(resp.Header.Get("X-RT-Body-Sig"))) {
		return fmt.Errorf("%s: response signature does not match", base)
	}
	return json.Unmarshal(body, v)
}

// peerCandidates are the configured URLs, then addresses the peer last
// published in the shared folder.
func (n *Node) peerCandidates() []string {
	seen := map[string]bool{}
	var out []string
	for _, u := range n.cfg.PeerURLs {
		if !seen[u] {
			seen[u] = true
			out = append(out, u)
		}
	}
	if n.cfg.ShareDir != "" {
		var a addrFile
		if raw, err := os.ReadFile(filepath.Join(n.shareDir(), "addr-"+n.cfg.Peer+".json")); err == nil && json.Unmarshal(raw, &a) == nil {
			for _, u := range a.URLs {
				if !seen[u] {
					seen[u] = true
					out = append(out, u)
				}
			}
		}
	}
	return out
}

// PullOnce brings in everything new from the peer: over the LAN if any peer
// address answers, else from the shared folder. Changes are only applied
// while the capture triggers are on (see Tick).
func (n *Node) PullOnce(ctx context.Context) (applied int, via string, err error) {
	defer func() {
		n.setStatus(func(s *Status) {
			s.LastPull = time.Now()
			s.LastPullVia = via
			s.Applied += int64(applied)
			s.LastError = ""
			if err != nil {
				s.LastError = err.Error()
			}
		})
	}()
	var on bool
	n.Engine(func(e *rt.DB) error { on = e.TriggersOn(); return nil })
	if !on {
		return 0, "deferred", nil
	}
	var lanErr error
	for _, base := range n.peerCandidates() {
		a, err := n.pullFrom(ctx, base)
		applied += a
		if err == nil {
			return applied, "lan", nil
		}
		if errors.Is(err, rt.ErrMismatch) {
			return applied, "lan", err
		}
		lanErr = err
	}
	if n.cfg.ShareDir == "" {
		if lanErr == nil {
			lanErr = errors.New("no peer address configured")
		}
		return applied, "", lanErr
	}
	a, err := n.ReadShare()
	applied += a
	if err != nil {
		return applied, "share", fmt.Errorf("lan: %v; share: %w", lanErr, err)
	}
	return applied, "share", nil
}

func (n *Node) pullFrom(ctx context.Context, base string) (int, error) {
	total := 0
	for page := 0; page < 10000; page++ {
		var last int64
		n.Engine(func(e *rt.DB) error { var err error; last, err = e.LastSeq(n.cfg.Peer); return err })
		var b rt.Batch
		if err := n.get(ctx, base, "/changes?after="+strconv.FormatInt(last, 10), &b); err != nil {
			return total, err
		}
		if b.Origin != n.cfg.Peer {
			return total, fmt.Errorf("%s answered as %q, expected %q", base, b.Origin, n.cfg.Peer)
		}
		if b.To <= last {
			return total, nil
		}
		a, err := n.apply(&b)
		total += a
		if err != nil {
			return total, err
		}
		n.setStatus(func(s *Status) { s.PeerLastSeq = b.To })
	}
	return total, nil
}

func (n *Node) apply(b *rt.Batch) (int, error) {
	var a int
	err := n.Engine(func(e *rt.DB) error {
		var err error
		a, err = e.Apply(b)
		return err
	})
	if a > 0 {
		n.log.Printf("applied %d changes from %s (seq %d..%d)", a, b.Origin, b.From, b.To)
		tables := map[string]int{}
		for _, c := range b.Changes {
			tables[c.Table]++
		}
		n.catalogChanged(tables)
		if n.OnApplied != nil {
			n.OnApplied(tables)
		}
	}
	return a, err
}

// ---------------------------------------------------------------- shared folder

type addrFile struct {
	Node string    `json:"node"`
	URLs []string  `json:"urls"`
	At   time.Time `json:"at"`
}

type segFile struct {
	Sig   string          `json:"sig"`
	Batch json.RawMessage `json:"batch"`
}

type ackFile struct {
	Node    string `json:"node"`
	Applied int64  `json:"applied"` // last seq of the peer applied here
}

func (n *Node) shareDir() string { return filepath.Join(n.cfg.ShareDir, "rt") }

func writeAtomic(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// PublishShare writes this laptop's new changes, its LAN addresses and how far
// it has applied the peer's changes to the shared folder, and prunes what the
// peer has acknowledged.
func (n *Node) PublishShare() error {
	if n.cfg.ShareDir == "" {
		return nil
	}
	dir := n.shareDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	raw, _ := json.Marshal(addrFile{n.cfg.Node, LocalURLs(n.cfg.Listen), time.Now()})
	if err := writeAtomic(filepath.Join(dir, "addr-"+n.cfg.Node+".json"), raw); err != nil {
		return err
	}
	return n.Engine(func(e *rt.DB) error {
		peerApplied, _ := e.LastSeq(n.cfg.Peer)
		raw, _ := json.Marshal(ackFile{n.cfg.Node, peerApplied})
		if err := writeAtomic(filepath.Join(dir, "ack-"+n.cfg.Node+".json"), raw); err != nil {
			return err
		}
		shared, _ := e.GetMeta("share_seq")
		from, _ := strconv.ParseInt(shared, 10, 64)
		for i := 0; i < 1000; i++ {
			b, err := e.ExtractSettled(from, n.cfg.PageSize, n.cfg.SettleMs)
			if err != nil {
				return err
			}
			if b.To <= from {
				break
			}
			body, _ := json.Marshal(b)
			seg, _ := json.Marshal(segFile{n.mac("seg", string(body)), body})
			name := fmt.Sprintf("seg-%s-%012d-%012d.json", n.cfg.Node, b.From, b.To)
			if err := writeAtomic(filepath.Join(dir, name), seg); err != nil {
				return err
			}
			from = b.To
			if err := e.SetMeta("share_seq", strconv.FormatInt(from, 10)); err != nil {
				return err
			}
		}
		// What the peer has applied (by LAN ack or its ack file) can go.
		acked := int64(0)
		if v, _ := e.GetMeta("ack." + n.cfg.Peer); v != "" {
			acked, _ = strconv.ParseInt(v, 10, 64)
		}
		var af ackFile
		if raw, err := os.ReadFile(filepath.Join(dir, "ack-"+n.cfg.Peer+".json")); err == nil && json.Unmarshal(raw, &af) == nil && af.Applied > acked {
			acked = af.Applied
		}
		for _, s := range listSegs(dir, n.cfg.Node) {
			if s.to <= acked {
				os.Remove(filepath.Join(dir, s.name))
			}
		}
		if _, err := e.Prune(acked, int64(7*24*time.Hour/time.Millisecond)); err != nil {
			return err
		}
		return nil
	})
}

type segRef struct {
	name     string
	from, to int64
}

func listSegs(dir, node string) []segRef {
	ents, _ := os.ReadDir(dir)
	var out []segRef
	prefix := "seg-" + node + "-"
	for _, e := range ents {
		nm := e.Name()
		if !strings.HasPrefix(nm, prefix) || !strings.HasSuffix(nm, ".json") {
			continue
		}
		parts := strings.Split(strings.TrimSuffix(strings.TrimPrefix(nm, prefix), ".json"), "-")
		if len(parts) != 2 {
			continue
		}
		f, err1 := strconv.ParseInt(parts[0], 10, 64)
		t, err2 := strconv.ParseInt(parts[1], 10, 64)
		if err1 == nil && err2 == nil {
			out = append(out, segRef{nm, f, t})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].from < out[j].from })
	return out
}

// ReadShare applies the peer's segment files from the shared folder, in order.
func (n *Node) ReadShare() (int, error) {
	dir := n.shareDir()
	total := 0
	for _, s := range listSegs(dir, n.cfg.Peer) {
		var last int64
		n.Engine(func(e *rt.DB) error { var err error; last, err = e.LastSeq(n.cfg.Peer); return err })
		if s.to <= last {
			continue
		}
		if s.from > last+1 {
			return total, fmt.Errorf("shared folder is missing %s's changes %d..%d (not synced yet?)", n.cfg.Peer, last+1, s.from-1)
		}
		raw, err := os.ReadFile(filepath.Join(dir, s.name))
		if err != nil {
			return total, err
		}
		var sf segFile
		if err := json.Unmarshal(raw, &sf); err != nil {
			return total, fmt.Errorf("%s: %w", s.name, err)
		}
		if !hmac.Equal([]byte(n.mac("seg", string(sf.Batch))), []byte(sf.Sig)) {
			return total, fmt.Errorf("%s: signature does not match", s.name)
		}
		var b rt.Batch
		if err := json.Unmarshal(sf.Batch, &b); err != nil {
			return total, err
		}
		a, err := n.apply(&b)
		total += a
		if err != nil {
			return total, err
		}
	}
	return total, nil
}

// ---------------------------------------------------------------- lifecycle

// Tick turns the capture triggers off when Aronium has closed, and back on once
// it has run StableSec seconds with an unchanged Migration count.
func (n *Node) Tick() error {
	// An Aronium installer migrates the database on Aronium's next start, so the
	// triggers must be off while one runs, even if Aronium itself shows up.
	running := n.AroniumRunning() && !n.UpdaterRunning()
	if n.killed {
		return nil
	}
	return n.Engine(func(e *rt.DB) error {
		on := e.TriggersOn()
		n.setStatus(func(s *Status) { s.TriggersOn = on })
		if !running {
			n.startSeen = time.Time{}
			if on {
				n.log.Printf("Aronium closed: removing triggers (snapshot taken)")
				if err := e.RemoveTriggers(); err != nil {
					return err
				}
				n.setStatus(func(s *Status) { s.TriggersOn = false })
			}
			return nil
		}
		if on {
			return nil
		}
		mig, err := e.MigrationCount()
		if err != nil {
			return err
		}
		if n.startSeen.IsZero() || mig != n.startMig {
			n.startSeen, n.startMig = time.Now(), mig
			return nil
		}
		if time.Since(n.startSeen) < time.Duration(n.cfg.StableSec)*time.Second {
			return nil
		}
		caught, err := e.InstallTriggers()
		if err != nil {
			return err
		}
		n.log.Printf("Aronium running: triggers on (%d changes caught up)", caught)
		n.setStatus(func(s *Status) { s.TriggersOn = true })
		return nil
	})
}

// Run serves the peer and loops: lifecycle, pull, shared-folder publish.
func (n *Node) Run(ctx context.Context) error {
	srv := &http.Server{Addr: n.cfg.Listen, Handler: n.Handler(), ReadHeaderTimeout: 10 * time.Second}
	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			n.log.Printf("listen %s: %v", n.cfg.Listen, err)
		}
	}()
	defer srv.Close()
	tick := time.NewTicker(time.Duration(n.cfg.PollMs) * time.Millisecond)
	defer tick.Stop()
	for {
		n.Step(ctx)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-tick.C:
		}
	}
}

// LocalURLs lists http://<ipv4>:<port> for this machine's LAN addresses.
func LocalURLs(listen string) []string {
	_, port, err := net.SplitHostPort(listen)
	if err != nil {
		port = "47800"
	}
	var out []string
	ifs, _ := net.Interfaces()
	for _, i := range ifs {
		if i.Flags&net.FlagUp == 0 || i.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, _ := i.Addrs()
		for _, a := range addrs {
			if ipn, ok := a.(*net.IPNet); ok && ipn.IP.To4() != nil && !ipn.IP.IsLinkLocalUnicast() {
				out = append(out, "http://"+net.JoinHostPort(ipn.IP.String(), port))
			}
		}
	}
	return out
}
