package node

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/huenique/ar-sync/rtsync/rt"
)

// catalogTables are cached by Aronium's selling screen until it restarts.
// Only product and price caching was observed (check V2); customers and
// payment types are not on this list until that is tested.
var catalogTables = map[string]bool{
	"Product": true, "Barcode": true, "ProductGroup": true, "PriceList": true, "PriceListItem": true,
	"ProductTax": true, "Tax": true, "Promotion": true, "PromotionItem": true,
}

const (
	msgPrices    = "Prices/products updated from the office - restart Aronium when no customer is waiting."
	msgOfficeZ   = "End of day belongs on the till. This Z report stays on this laptop; the till's End of day still counts these sales."
	msgPaused    = "Real-time sync is paused: the two laptops run different Aronium versions. Update Aronium on both laptops."
	msgKilled    = "Real-time sync is off on this laptop. Ask the owner before selling here."
	retoastEvery = time.Hour
)

// Step is one pass of the sidecar loop.
func (n *Node) Step(ctx context.Context) {
	if n.checkKill() {
		return
	}
	if err := n.Tick(); err != nil {
		n.log.Printf("lifecycle: %v", err)
	}
	if n.selfRewound() {
		n.setStatus(func(s *Status) { s.Paused = "this laptop's database was restored from an older copy" })
		n.toast("rewound", msgRewound, retoastEvery)
		return
	}
	if _, via, err := n.PullOnce(ctx); err != nil {
		n.log.Printf("pull (%s): %v", via, err)
		switch {
		case errors.Is(err, rt.ErrMismatch):
			n.setStatus(func(s *Status) { s.Paused = "Aronium versions differ" })
			n.toast("paused", msgPaused, retoastEvery)
		case errors.Is(err, ErrRewound):
			n.setStatus(func(s *Status) { s.Paused = "the other laptop's database was restored from an older copy" })
			n.toast("rewound", msgRewound, retoastEvery)
		}
	} else if !n.draining() {
		n.setStatus(func(s *Status) { s.Paused = "" })
	}
	if n.cfg.Role == "till" {
		n.checkRestart()
	} else {
		n.checkOfficeZ()
	}
	if n.Now().Sub(n.lastShare) > time.Minute {
		if err := n.PublishShare(); err != nil {
			n.log.Printf("shared folder: %v", err)
		}
		n.lastShare = n.Now()
	}
}

// toast shows a notice at most once per `every` for its kind.
func (n *Node) toast(kind, text string, every time.Duration, buttons ...string) bool {
	if last, ok := n.lastToast[kind]; ok && n.Now().Sub(last) < every {
		return false
	}
	n.lastToast[kind] = n.Now()
	n.log.Printf("notice [%s] %s", kind, text)
	if n.Notify != nil {
		n.Notify(kind, text, buttons...)
	}
	return true
}

func (n *Node) notifyArgs(kind, text string, buttons []string) *exec.Cmd {
	args := append([]string{}, n.cfg.NotifyCmd[1:]...)
	args = append(args, "-Kind", kind, "-Text", text)
	if len(buttons) > 0 {
		args = append(args, "-Buttons", strings.Join(buttons, ","))
	}
	return exec.Command(n.cfg.NotifyCmd[0], args...)
}

func (n *Node) runNotify(kind, text string, buttons ...string) {
	if len(n.cfg.NotifyCmd) == 0 {
		return
	}
	if err := n.notifyArgs(kind, text, buttons).Start(); err != nil {
		n.log.Printf("notify: %v", err)
	}
}

func (n *Node) runNotifyErr(kind, text string) error {
	if len(n.cfg.NotifyCmd) == 0 {
		return errors.New("no notify command configured")
	}
	out, err := n.notifyArgs(kind, text, nil).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// ---------------------------------------------------------------- till: restart after catalog changes

func (n *Node) catalogChanged(tables map[string]int) {
	if n.cfg.Role != "till" {
		return
	}
	hit := false
	for t := range tables {
		if catalogTables[t] {
			hit = true
		}
	}
	if !hit {
		return
	}
	n.Engine(func(e *rt.DB) error {
		if v, _ := e.GetMeta("restart_pending"); v == "" {
			return e.SetMeta("restart_pending", strconv.FormatInt(n.Now().UnixMilli(), 10))
		}
		return nil
	})
	n.setStatus(func(s *Status) { s.RestartDue = true })
	if !n.laterClicked() {
		n.toast("prices", msgPrices, 15*time.Minute, "restart-aronium", "restart-later")
	}
}

func (n *Node) laterClicked() bool {
	if n.cfg.LaterFile == "" {
		return false
	}
	st, err := os.Stat(n.cfg.LaterFile)
	return err == nil && n.Now().Sub(st.ModTime()) < retoastEvery
}

// checkRestart clears the pending restart once Aronium has started after the
// change, restarts it by itself before opening hour, and otherwise reminds.
func (n *Node) checkRestart() {
	var since int64
	n.Engine(func(e *rt.DB) error {
		v, _ := e.GetMeta("restart_pending")
		since, _ = strconv.ParseInt(v, 10, 64)
		return nil
	})
	if since == 0 {
		n.setStatus(func(s *Status) { s.RestartDue = false })
		return
	}
	pendingAt := time.UnixMilli(since)
	started, running := n.AroniumStarted()
	if running && started.After(pendingAt) {
		n.Engine(func(e *rt.DB) error { return e.SetMeta("restart_pending", "") })
		n.setStatus(func(s *Status) { s.RestartDue = false })
		n.log.Printf("Aronium restarted since the office's changes: selling screen is current")
		return
	}
	n.setStatus(func(s *Status) { s.RestartDue = true })
	if !running {
		return // it loads fresh data when it next opens
	}
	if n.Now().Hour() < n.cfg.OpenHour {
		if last, ok := n.lastToast["auto-restart"]; ok && n.Now().Sub(last) < 10*time.Minute {
			return
		}
		n.lastToast["auto-restart"] = n.Now()
		n.log.Printf("before opening: restarting Aronium to load the office's changes")
		if err := n.RestartAronium(); err != nil {
			n.log.Printf("restart: %v", err)
		}
		return
	}
	if !n.laterClicked() {
		n.toast("prices", msgPrices, retoastEvery, "restart-aronium", "restart-later")
	}
}

// ---------------------------------------------------------------- office: End of day guard

func (n *Node) checkOfficeZ() {
	var warn bool
	n.Engine(func(e *rt.DB) error {
		mx, err := e.MaxLocalID("ZReport")
		if err != nil {
			return err
		}
		seen, _ := e.GetMeta("z_seen")
		if seen == "" {
			return e.SetMeta("z_seen", strconv.FormatInt(mx, 10))
		}
		if s, _ := strconv.ParseInt(seen, 10, 64); mx > s {
			warn = true
			return e.SetMeta("z_seen", strconv.FormatInt(mx, 10))
		}
		return nil
	})
	if warn {
		delete(n.lastToast, "endofday")
		n.toast("endofday", msgOfficeZ, 0)
	}
}

// ---------------------------------------------------------------- kill switch

// KillFiles are the files that turn real-time sync off: KILL in the shared
// folder (both laptops) or next to this laptop's database.
func (n *Node) KillFiles() []string { return KillPaths(n.cfg) }

// KillPaths: [this laptop's kill file, the shared one (if a shared folder is set)].
func KillPaths(c Config) []string {
	out := []string{filepath.Join(filepath.Dir(c.DBPath), "rtsync.KILL")}
	if c.ShareDir != "" {
		out = append(out, filepath.Join(c.ShareDir, "rt", "KILL"))
	}
	return out
}
