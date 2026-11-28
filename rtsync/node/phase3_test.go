package node

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/huenique/ar-sync/rtsync/rt"
)

type notices struct{ got []string }

func (c *notices) fn(kind, text string, buttons ...string) { c.got = append(c.got, kind) }
func (c *notices) count(kind string) int {
	n := 0
	for _, k := range c.got {
		if k == kind {
			n++
		}
	}
	return n
}

// clock is a movable time for the reminder rules.
type clock struct{ t time.Time }

func (c *clock) now() time.Time { return c.t }

func TestTillToastAndRestartFlow(t *testing.T) {
	a, b := pair(t, "")
	var seen notices
	clk := &clock{time.Date(2026, 11, 30, 10, 0, 0, 0, time.Local)}
	a.n.Notify, a.n.Now = seen.fn, clk.now
	aroStart := clk.t.Add(-2 * time.Hour) // Aronium has been open since 08:00
	a.n.AroniumStarted = func() (time.Time, bool) { return aroStart, true }
	restarts := 0
	a.n.RestartAronium = func() error { restarts++; return nil }
	ctx := context.Background()

	// A sale from the office does not ask the till to restart.
	sale(t, b.aro, "B1", 1, 1)
	settle()
	a.n.Step(ctx)
	if seen.count("prices") != 0 {
		t.Fatal("restart toast for a sale")
	}
	// A price edit does, once; a second edit soon after doesn't toast again.
	execSQL(t, b.aro, "UPDATE Product SET Price=11 WHERE Id=1")
	settle()
	a.n.Step(ctx)
	execSQL(t, b.aro, "UPDATE Product SET Price=12 WHERE Id=1")
	settle()
	a.n.Step(ctx)
	if seen.count("prices") != 1 || !a.n.Status().RestartDue {
		t.Fatalf("prices toasts=%d restartDue=%v", seen.count("prices"), a.n.Status().RestartDue)
	}
	// During the day the till is never restarted by itself.
	if restarts != 0 {
		t.Fatal("till restarted by itself during shop hours")
	}
	// "Later" holds the reminder for an hour.
	later := filepath.Join(t.TempDir(), "later.flag")
	a.n.cfg.LaterFile = later
	os.WriteFile(later, nil, 0o644)
	os.Chtimes(later, clk.t, clk.t)
	clk.t = clk.t.Add(70 * time.Minute)
	os.Chtimes(later, clk.t.Add(-10*time.Minute), clk.t.Add(-10*time.Minute))
	a.n.Step(ctx)
	if seen.count("prices") != 1 {
		t.Fatal("reminded although Later was clicked 10 minutes ago")
	}
	clk.t = clk.t.Add(time.Hour)
	a.n.Step(ctx)
	if seen.count("prices") != 2 {
		t.Fatalf("no reminder an hour after Later (toasts=%d)", seen.count("prices"))
	}
	// Cashier restarts Aronium: the pending restart clears.
	aroStart = clk.t
	clk.t = clk.t.Add(time.Minute)
	a.n.Step(ctx)
	if a.n.Status().RestartDue {
		t.Fatal("restart still due after Aronium restarted")
	}
}

func TestTillRestartsItselfBeforeOpening(t *testing.T) {
	a, b := pair(t, "")
	clk := &clock{time.Date(2026, 11, 30, 18, 30, 0, 0, time.Local)}
	a.n.Now = clk.now
	opened := clk.t.Add(-10 * time.Hour) // Aronium opened 08:30 and was never closed
	a.n.AroniumStarted = func() (time.Time, bool) { return opened, true }
	restarts := 0
	a.n.RestartAronium = func() error { restarts++; return nil }
	execSQL(t, b.aro, "UPDATE Product SET Price=99 WHERE Id=2") // office edits after closing
	settle()
	a.n.Step(context.Background())
	if restarts != 0 {
		t.Fatal("restarted at 18:30")
	}
	clk.t = time.Date(2026, 12, 1, 7, 40, 0, 0, time.Local) // left open overnight
	a.n.Step(context.Background())
	if restarts != 1 {
		t.Fatalf("restarts before opening = %d, want 1", restarts)
	}
}

func TestOfficeEndOfDayWarned(t *testing.T) {
	a, b := pair(t, "")
	var seen notices
	b.n.Notify = seen.fn
	ctx := context.Background()
	b.n.Step(ctx) // learns the current Z
	execSQL(t, b.aro, "INSERT INTO ZReport(Number,FromDocumentId,ToDocumentId) VALUES(1,0,0)")
	b.n.Step(ctx)
	if seen.count("endofday") != 1 {
		t.Fatalf("office End of day warnings = %d, want 1", seen.count("endofday"))
	}
	if n := scalar(t, a.aro, "SELECT count(*) FROM ZReport"); n != "0" {
		t.Fatal("the office's Z report reached the till")
	}
}

func TestVersionMismatchPausesThenResumes(t *testing.T) {
	a, b := pair(t, "")
	var seen notices
	a.n.Notify = seen.fn
	ctx := context.Background()
	// Aronium on the office laptop updates: a new column appears there.
	execSQL(t, b.aro, "ALTER TABLE Product ADD COLUMN NewThing TEXT")
	b.n.Engine(func(e *rt.DB) error { _, err := e.InstallTriggers(); return err })
	sale(t, b.aro, "B1", 1, 1)
	settle()
	a.n.Step(ctx)
	if a.n.Status().Paused == "" || seen.count("paused") != 1 {
		t.Fatalf("not paused: status=%+v notices=%v", a.n.Status(), seen.got)
	}
	if n := scalar(t, a.aro, "SELECT count(*) FROM Document"); n != "0" {
		t.Fatal("applied changes across Aronium versions")
	}
	// The till updates too: sync resumes and catches up.
	execSQL(t, a.aro, "ALTER TABLE Product ADD COLUMN NewThing TEXT")
	a.n.Engine(func(e *rt.DB) error { _, err := e.InstallTriggers(); return err })
	a.n.Step(ctx)
	if a.n.Status().Paused != "" {
		t.Fatalf("still paused: %+v", a.n.Status())
	}
	if n := scalar(t, a.aro, "SELECT count(*) FROM Document"); n != "1" {
		t.Fatalf("till has %s documents after resuming, want 1", n)
	}
}

func TestUpdaterTurnsTriggersOff(t *testing.T) {
	a, _ := pair(t, "")
	upd := true
	a.n.UpdaterRunning = func() bool { return upd }
	a.n.Tick()
	if a.n.Status().TriggersOn {
		t.Fatal("triggers on while an Aronium installer runs")
	}
	upd = false
	a.n.Tick()
	a.n.Tick()
	if !a.n.Status().TriggersOn {
		t.Fatal("triggers not back after the installer finished")
	}
}

func TestKillSwitch(t *testing.T) {
	share := t.TempDir()
	a, b := pair(t, share)
	ctx := context.Background()
	sale(t, b.aro, "B-last", 1, 1)
	settle()
	os.MkdirAll(filepath.Join(share, "rt"), 0o755)
	os.WriteFile(filepath.Join(share, "rt", "KILL"), nil, 0o644)
	a.n.Step(ctx) // final exchange, then off
	if !a.n.Status().Killed {
		t.Fatal("not killed")
	}
	if n := scalar(t, a.aro, "SELECT count(*) FROM Document WHERE Number='B-last'"); n != "1" {
		t.Fatal("final exchange did not bring the office's last sale")
	}
	if n := scalar(t, a.aro, `SELECT count(*) FROM sqlite_master WHERE name LIKE '\_rt\_%' ESCAPE '\'`); n != "0" {
		t.Fatalf("%s sync tables/triggers left in pos.db", n)
	}
	// Further steps do nothing and never bring triggers back.
	a.n.Step(ctx)
	if n := scalar(t, a.aro, `SELECT count(*) FROM sqlite_master WHERE type='trigger'`); n != "0" {
		t.Fatal("triggers came back after kill")
	}
}
