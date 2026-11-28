package node

import (
	"context"
	"database/sql"
	"fmt"
	"io"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/huenique/ar-sync/rtsync/rt"
)

const testKey = "00112233445566778899aabbccddeeff"

func seedFile(t *testing.T) string {
	t.Helper()
	schema, err := os.ReadFile(filepath.Join("..", "testdata", "schema-1.52.sql"))
	if err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(t.TempDir(), "seed.db")
	db := open(t, p)
	defer db.Close()
	execSQL(t, db, string(schema))
	execSQL(t, db, `
INSERT INTO Warehouse(Id,Name) VALUES(1,'Main');
INSERT INTO User(Id,FirstName,Password,AccessLevel) VALUES(1,'Test','x',9);
INSERT INTO DocumentCategory(Id,Name) VALUES(2,'Sales');
INSERT INTO DocumentType(Id,Name,Code,DocumentCategoryId,WarehouseId,StockDirection) VALUES(2,'Sales','200',2,1,2);
INSERT INTO PaymentType(Id,Name) VALUES(1,'Cash');
INSERT INTO Customer(Id,Name) VALUES(1,'Walk-in');
INSERT INTO Product(Id,Name,Code,Price) VALUES(1,'Nail','N',10),(2,'Rebar','R',154);
INSERT INTO Stock(ProductId,WarehouseId,Quantity) VALUES(1,1,1000),(2,1,1000);`)
	return p
}

func open(t *testing.T, p string) *sql.DB {
	t.Helper()
	q := url.Values{}
	q.Add("_pragma", "busy_timeout(5000)")
	q.Add("_pragma", "foreign_keys(1)")
	db, err := sql.Open("sqlite", "file:"+p+"?"+q.Encode())
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	return db
}

func execSQL(t *testing.T, db *sql.DB, q string, args ...any) {
	t.Helper()
	if _, err := db.Exec(q, args...); err != nil {
		t.Fatalf("%v\n%s", err, q)
	}
}

type side struct {
	n   *Node
	aro *sql.DB
	srv *httptest.Server
}

// pair builds two seeded laptops A and B with their own servers. A shared
// folder is used when share != "".
func pair(t *testing.T, share string) (*side, *side) {
	t.Helper()
	seed := seedFile(t)
	mk := func(name, peer string) *side {
		p := filepath.Join(t.TempDir(), name+".db")
		raw, _ := os.ReadFile(seed)
		os.WriteFile(p, raw, 0o644)
		e, err := rt.Open(p)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := e.Seed(name); err != nil {
			t.Fatal(err)
		}
		if _, err := e.InstallTriggers(); err != nil {
			t.Fatal(err)
		}
		e.Close()
		n, err := New(Config{Node: name, Peer: peer, DBPath: p, Key: testKey, ShareDir: share, SettleMs: 1, PageSize: 50, StableSec: 0}, nil)
		if err != nil {
			t.Fatal(err)
		}
		n.AroniumRunning = func() bool { return true }
		n.cfg.StableSec = 0 // New() turns 0 into the 15 s default
		n.UpdaterRunning = func() bool { return false }
		n.Notify = nil
		n.cfg.Role = map[string]string{"A": "till", "B": "office"}[name]
		s := &side{n: n, aro: open(t, p), srv: httptest.NewServer(n.Handler())}
		t.Cleanup(func() { s.srv.Close(); s.aro.Close(); n.Close() })
		return s
	}
	a, b := mk("A", "B"), mk("B", "A")
	a.n.cfg.PeerURLs = []string{b.srv.URL}
	b.n.cfg.PeerURLs = []string{a.srv.URL}
	return a, b
}

var seq int

func sale(t *testing.T, db *sql.DB, number string, pid int64, qty float64) {
	t.Helper()
	seq++
	tx, _ := db.Begin()
	defer tx.Rollback()
	day := time.Now().Format("2006-01-02") + " 00:00:00"
	r, err := tx.Exec(`INSERT INTO Document (Number,UserId,CustomerId,Date,StockDate,Total,DocumentTypeId,WarehouseId) VALUES (?,1,1,?,?,?,2,1)`, number, day, day, qty*10)
	if err != nil {
		t.Fatal(err)
	}
	id, _ := r.LastInsertId()
	if _, err := tx.Exec(`INSERT INTO DocumentItem (DocumentId,ProductId,Quantity,Price,Total) VALUES (?,?,?,10,?)`, id, pid, qty, qty*10); err != nil {
		t.Fatal(err)
	}
	tx.Exec(`INSERT INTO Payment (DocumentId,PaymentTypeId,Amount,Date,UserId,DateCreated) VALUES (?,1,?,?,1,?)`, id, qty*10, day, day)
	tx.Exec("UPDATE Stock SET Quantity = Quantity + ? WHERE ProductId=? AND WarehouseId=1", -qty, pid)
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
}

func scalar(t *testing.T, db *sql.DB, q string) string {
	t.Helper()
	var v any
	if err := db.QueryRow(q).Scan(&v); err != nil {
		t.Fatal(err)
	}
	if b, ok := v.([]byte); ok {
		return string(b)
	}
	return fmt.Sprint(v)
}

// state summarizes the business data the same way on both laptops.
func state(t *testing.T, db *sql.DB) string {
	return scalar(t, db, `SELECT (SELECT group_concat(Number, ',') FROM (SELECT Number FROM Document ORDER BY Number))
		|| ' / ' || (SELECT group_concat(q, ',') FROM (SELECT P.Name || '=' || S.Quantity q FROM Stock S JOIN Product P ON P.Id=S.ProductId ORDER BY P.Name))
		|| ' / ' || (SELECT group_concat(x, ',') FROM (SELECT Name || ':' || Price x FROM Product ORDER BY Name))`)
}

func settle() { time.Sleep(5 * time.Millisecond) }

func TestLANBothWays(t *testing.T) {
	a, b := pair(t, "")
	sale(t, a.aro, "A1", 1, 2)
	sale(t, b.aro, "B1", 2, 3)
	execSQL(t, b.aro, "UPDATE Product SET Price=160 WHERE Id=2")
	settle()
	ctx := context.Background()
	if n, via, err := b.n.PullOnce(ctx); err != nil || via != "lan" || n == 0 {
		t.Fatalf("B pull: n=%d via=%s err=%v", n, via, err)
	}
	if n, via, err := a.n.PullOnce(ctx); err != nil || via != "lan" || n == 0 {
		t.Fatalf("A pull: n=%d via=%s err=%v", n, via, err)
	}
	if sa, sb := state(t, a.aro), state(t, b.aro); sa != sb {
		t.Fatalf("differ:\nA %s\nB %s", sa, sb)
	}
	// Nothing new: a second pull applies nothing and still succeeds.
	if n, _, err := a.n.PullOnce(ctx); err != nil || n != 0 {
		t.Fatalf("idle pull: n=%d err=%v", n, err)
	}
}

func TestWrongKeyRejected(t *testing.T) {
	a, b := pair(t, "")
	b.n.cfg.Key = "ffffffffffffffffffffffffffffffff"
	sale(t, a.aro, "A1", 1, 1)
	settle()
	_, _, err := b.n.PullOnce(context.Background())
	if err == nil {
		t.Fatal("pull with the wrong key succeeded")
	}
	if got := scalar(t, b.aro, "SELECT count(*) FROM Document"); got != "0" {
		t.Fatalf("B received %s documents with a wrong key", got)
	}
}

func TestSettleHoldsFreshChanges(t *testing.T) {
	a, b := pair(t, "")
	a.n.cfg.SettleMs = 60000
	sale(t, a.aro, "A1", 1, 1)
	if n, _, err := b.n.PullOnce(context.Background()); err != nil || n != 0 {
		t.Fatalf("fresh change sent before settling: n=%d err=%v", n, err)
	}
}

func TestSharedFolderFallbackAndPrune(t *testing.T) {
	share := t.TempDir()
	a, b := pair(t, share)
	a.n.cfg.PeerURLs = []string{"http://127.0.0.1:1"} // LAN down
	b.n.cfg.PeerURLs = []string{"http://127.0.0.1:1"}
	for i := 0; i < 120; i++ { // more than one page per segment
		sale(t, a.aro, fmt.Sprintf("A%03d", i), 1, 1)
	}
	settle()
	if err := a.n.PublishShare(); err != nil {
		t.Fatal(err)
	}
	if segs := listSegs(filepath.Join(share, "rt"), "A"); len(segs) < 2 {
		t.Fatalf("want several segments, got %d", len(segs))
	}
	n, via, err := b.n.PullOnce(context.Background())
	if err != nil || via != "share" || n == 0 {
		t.Fatalf("B pull: n=%d via=%s err=%v", n, via, err)
	}
	if sa, sb := state(t, a.aro), state(t, b.aro); sa != sb {
		t.Fatalf("differ:\nA %s\nB %s", sa, sb)
	}
	// B tells A how far it got; A then deletes those segments and log rows.
	if err := b.n.PublishShare(); err != nil {
		t.Fatal(err)
	}
	if err := a.n.PublishShare(); err != nil {
		t.Fatal(err)
	}
	if segs := listSegs(filepath.Join(share, "rt"), "A"); len(segs) != 0 {
		t.Fatalf("%d acknowledged segments left", len(segs))
	}
	// A tampered segment is refused.
	sale(t, a.aro, "A-late", 1, 1)
	settle()
	a.n.PublishShare()
	segs := listSegs(filepath.Join(share, "rt"), "A")
	p := filepath.Join(share, "rt", segs[0].name)
	raw, _ := os.ReadFile(p)
	os.WriteFile(p, append(raw[:len(raw)-3], []byte("x}}")...), 0o644)
	if _, _, err := b.n.PullOnce(context.Background()); err == nil {
		t.Fatal("tampered segment accepted")
	}
}

func TestPartitionThenReconnectInPages(t *testing.T) {
	a, b := pair(t, "")
	urlA, urlB := a.n.cfg.PeerURLs, b.n.cfg.PeerURLs
	a.n.cfg.PeerURLs, b.n.cfg.PeerURLs = []string{"http://127.0.0.1:1"}, []string{"http://127.0.0.1:1"}
	for i := 0; i < 60; i++ {
		sale(t, a.aro, fmt.Sprintf("A%02d", i), 1, 1)
		sale(t, b.aro, fmt.Sprintf("B%02d", i), 1, 2)
		if i%15 == 0 {
			execSQL(t, a.aro, "UPDATE Product SET Price=Price+1 WHERE Id=1")
			execSQL(t, b.aro, "UPDATE Product SET Price=Price+2 WHERE Id=2")
		}
	}
	if _, _, err := b.n.PullOnce(context.Background()); err == nil {
		t.Fatal("pull succeeded with the LAN down and no shared folder")
	}
	a.n.cfg.PeerURLs, b.n.cfg.PeerURLs = urlA, urlB
	settle()
	for _, s := range []*side{a, b, a} {
		if _, _, err := s.n.PullOnce(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	if sa, sb := state(t, a.aro), state(t, b.aro); sa != sb {
		t.Fatalf("differ:\nA %s\nB %s", sa, sb)
	}
	if got := scalar(t, a.aro, "SELECT Quantity FROM Stock WHERE ProductId=1"); got != "820" {
		t.Fatalf("nail stock %s, want 820 (1000 - 60 - 120)", got)
	}
}

func TestLifecycleAroundAroniumRestart(t *testing.T) {
	a, b := pair(t, "")
	running := true
	a.n.AroniumRunning = func() bool { return running }
	running = false // Aronium closes
	if err := a.n.Tick(); err != nil {
		t.Fatal(err)
	}
	if a.n.Status().TriggersOn {
		t.Fatal("triggers still on after Aronium closed")
	}
	sale(t, b.aro, "B1", 1, 1)
	settle()
	if _, via, _ := a.n.PullOnce(context.Background()); via != "deferred" {
		t.Fatalf("applied while triggers were off (via %s)", via)
	}
	running = true // Aronium starts and writes during startup
	sale(t, a.aro, "A-startup", 2, 1)
	a.n.Tick() // first sighting: wait for a stable Migration count
	if a.n.Status().TriggersOn {
		t.Fatal("triggers on before Aronium settled")
	}
	a.n.Tick()
	if !a.n.Status().TriggersOn {
		t.Fatal("triggers not back on")
	}
	settle()
	ctx := context.Background()
	if _, _, err := a.n.PullOnce(ctx); err != nil {
		t.Fatal(err)
	}
	if _, _, err := b.n.PullOnce(ctx); err != nil {
		t.Fatal(err)
	}
	if sa, sb := state(t, a.aro), state(t, b.aro); sa != sb {
		t.Fatalf("differ:\nA %s\nB %s", sa, sb)
	}
}

var _ = io.Discard
