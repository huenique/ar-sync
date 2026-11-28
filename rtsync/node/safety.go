package node

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/huenique/ar-sync/rtsync/rt"
)

// ErrRewound: one laptop's pos.db is older than what the other already
// received from it (restored from a backup). Sequence numbers would repeat and
// the peer would skip real changes as duplicates, so sync stops.
var ErrRewound = errors.New("database restored from an older copy: seed both laptops again")

const (
	msgDrainClose = "Real-time sync is being turned off. Close Aronium on both laptops when no customer is waiting."
	msgRewound    = "Real-time sync stopped: a laptop's database was restored from an older copy. Call the owner (both laptops need seeding again)."
	msgStuck      = "A change from the other laptop could not be applied and was set aside. Call the owner."
)

// selfHello describes this laptop for the peer.
func (n *Node) selfHello() hello {
	if n.final != nil {
		return *n.final
	}
	var h hello
	n.Engine(func(e *rt.DB) error { h = n.helloLocked(e); return nil })
	return h
}

// helloLocked: caller holds the engine.
func (n *Node) helloLocked(e *rt.DB) hello {
	max, _ := e.LogMaxSeq()
	return hello{Node: n.cfg.Node, Seed: e.SeedTag(), Schema: e.SchemaTag(), MaxSeq: max,
		Aronium: n.AroniumRunning(), Draining: n.draining()}
}

// notePeer records the peer's state and checks it hasn't gone back in time.
func (n *Node) notePeer(h hello) error {
	if h.Node != n.cfg.Peer {
		return fmt.Errorf("answered as %q, expected %q", h.Node, n.cfg.Peer)
	}
	n.peer = h
	if h.Killed {
		return nil
	}
	var last int64
	n.Engine(func(e *rt.DB) error { var err error; last, err = e.LastSeq(n.cfg.Peer); return err })
	if h.MaxSeq < last {
		return ErrRewound
	}
	return nil
}

// selfRewound: the peer has acknowledged more of this laptop's changes than
// this pos.db ever made, so this file was restored from an older copy.
func (n *Node) selfRewound() bool {
	rewound := false
	n.Engine(func(e *rt.DB) error {
		max, err := e.LogMaxSeq()
		if err != nil {
			return err
		}
		var ack int64
		if v, _ := e.GetMeta("ack." + n.cfg.Peer); v != "" {
			ack, _ = strconv.ParseInt(v, 10, 64)
		}
		if pa := n.peerAppliedFromShare(); pa > ack {
			ack = pa
		}
		rewound = ack > max
		return nil
	})
	return rewound
}

// checkStuck sets a peer change aside when the same one keeps failing.
func (n *Node) checkStuck(err error) {
	var ae *rt.ApplyError
	if !errors.As(err, &ae) {
		if err == nil {
			n.stuckSeq = 0
		}
		return
	}
	if ae.Seq != n.stuckSeq {
		n.stuckSeq, n.stuckFrom = ae.Seq, n.Now()
		return
	}
	if n.Now().Sub(n.stuckFrom) < time.Duration(n.cfg.StuckSec)*time.Second {
		return
	}
	n.log.Printf("setting aside %s seq %d after %v of failures: %v", ae.Origin, ae.Seq, n.Now().Sub(n.stuckFrom).Round(time.Second), ae.Err)
	n.Engine(func(e *rt.DB) error { e.SetAside(ae.Origin, ae.Seq); return nil })
	n.stuckSeq = 0
	delete(n.lastToast, "stuck")
	n.toast("stuck", msgStuck, 0)
}

func (n *Node) draining() bool {
	for _, f := range n.KillFiles() {
		if fileExists(f) {
			return true
		}
	}
	return false
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

// checkKill drains and then removes real-time sync when a kill file exists.
// It keeps syncing until Aronium is closed on both laptops and each has
// applied everything the other made; only then does it take the triggers and
// _rt_ tables out of pos.db, so nothing is lost and ar-sync's one-writer copies
// are clean. Coming back means seeding both laptops again.
func (n *Node) checkKill() bool {
	if n.killed {
		return true
	}
	if !n.draining() {
		return false
	}
	n.setStatus(func(s *Status) { s.Paused = "turning real-time sync off" })
	if n.AroniumRunning() {
		n.toast("draining", msgDrainClose, 15*time.Minute)
		return false // keep syncing normally meanwhile
	}
	ready, why := n.drained()
	if !ready {
		n.log.Printf("kill switch: waiting (%s)", why)
		return false
	}
	var h hello
	err := n.Engine(func(e *rt.DB) error {
		h = n.helloLocked(e)
		return e.Uninstall()
	})
	if err != nil {
		n.log.Printf("uninstall: %v", err)
		return false
	}
	h.Killed, h.Draining, h.Aronium = true, false, false
	n.final = &h
	n.killed = true
	if n.cfg.ShareDir != "" {
		// Leave the final state in the shared folder for a peer without LAN.
		raw, _ := json.Marshal(ackFile{Node: n.cfg.Node, Applied: n.peer.MaxSeq, Hello: h})
		writeAtomic(filepath.Join(n.shareDir(), "ack-"+n.cfg.Node+".json"), raw)
	}
	n.setStatus(func(s *Status) { s.Killed = true; s.TriggersOn = false; s.Paused = "" })
	n.log.Printf("kill switch: real-time sync removed after a full exchange")
	if n.cfg.Role == "office" && n.Notify != nil {
		// ar-sync's viewing-laptop check must not count the synced sales as local ones.
		n.Notify("rebaseline", "")
	}
	n.toast("killed", msgKilled, 0)
	return true
}

// drained: Aronium closed on the peer too, the peer has applied all of this
// laptop's changes, and this laptop has applied all of the peer's.
func (n *Node) drained() (bool, string) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if _, via, err := n.PullOnce(ctx); err != nil {
		return false, fmt.Sprintf("exchange via %s: %v", via, err)
	}
	if err := n.PublishShare(); err != nil {
		return false, "shared folder: " + err.Error()
	}
	p := n.peer
	if p.Node == "" {
		return false, "no word from the other laptop yet"
	}
	if p.Aronium && !p.Killed {
		return false, "Aronium still open on the other laptop"
	}
	var mine, acked, applied int64
	n.Engine(func(e *rt.DB) error {
		mine, _ = e.LogMaxSeq()
		applied, _ = e.LastSeq(n.cfg.Peer)
		v, _ := e.GetMeta("ack." + n.cfg.Peer)
		acked, _ = strconv.ParseInt(v, 10, 64)
		return nil
	})
	if pa := n.peerAppliedFromShare(); pa > acked {
		acked = pa
	}
	if acked < mine {
		return false, fmt.Sprintf("other laptop has applied %d of this laptop's %d changes", acked, mine)
	}
	if applied < p.MaxSeq {
		return false, fmt.Sprintf("applied %d of the other laptop's %d changes", applied, p.MaxSeq)
	}
	return true, ""
}

func (n *Node) peerAppliedFromShare() int64 {
	if n.cfg.ShareDir == "" {
		return 0
	}
	var af ackFile
	raw, err := os.ReadFile(filepath.Join(n.shareDir(), "ack-"+n.cfg.Peer+".json"))
	if err != nil || json.Unmarshal(raw, &af) != nil {
		return 0
	}
	return af.Applied
}
