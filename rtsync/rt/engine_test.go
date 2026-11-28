package rt

import (
	"encoding/json"
	"errors"
	"testing"
	"time"
)

func TestTriggersLogAroniumSale(t *testing.T) {
	a, _ := newPair(t, newSeedFile(t))
	a.sell(t, "26-200-000001", 1, 1, line{"Nail 2in", 3, 10})
	got := map[string]int64{}
	rows, _ := a.aro.Query("SELECT tbl||'/'||op, count(*) FROM _rt_log GROUP BY 1")
	for rows.Next() {
		var k string
		var n int64
		rows.Scan(&k, &n)
		got[k] = n
	}
	rows.Close()
	want := map[string]int64{"Document/I": 1, "DocumentItem/I": 1, "Payment/I": 1, "Stock/S": 1}
	if len(got) != len(want) {
		t.Fatalf("log = %v, want %v", got, want)
	}
	for k, v := range want {
		if got[k] != v {
			t.Fatalf("log = %v, want %v", got, want)
		}
	}
	var d float64
	a.aro.QueryRow("SELECT delta FROM _rt_log WHERE tbl='Stock'").Scan(&d)
	if d != -3 {
		t.Fatalf("stock delta = %v, want -3", d)
	}
}

func TestLocalOnlyTablesAndColumnsNotLogged(t *testing.T) {
	a, _ := newPair(t, newSeedFile(t))
	a.sell(t, "26-200-000001", 1, 1, line{"Nail 2in", 1, 10})
	before := count(t, a.aro, "SELECT count(*) FROM _rt_log")
	a.endOfDay(t) // ZReport insert, Payment.ZReportId, Document.IsClockedOut
	mustExec(t, a.aro, "INSERT OR REPLACE INTO ApplicationProperty(Name,Value) VALUES('X','1')")
	if after := count(t, a.aro, "SELECT count(*) FROM _rt_log"); after != before {
		t.Fatalf("end of day logged %d rows; Z report state must stay local", after-before)
	}
}

func TestTwoWaySalesWithCollidingIds(t *testing.T) {
	a, b := newPair(t, newSeedFile(t))
	idA := a.sell(t, "26-200-000001", 1, 1, line{"Nail 2in", 2, 10}, line{"Cement", 1, 260})
	idB := b.sell(t, "26-200-500001", 1, 2, line{"Rebar 10mm", 4, 154})
	if idA != idB {
		t.Fatalf("test expects colliding Ids, got %d and %d", idA, idB)
	}
	a.sell(t, "26-200-000002", 1, 1, line{"Rebar 10mm", 1, 154})
	syncBoth(t, a, b)
	checkSame(t, a, b)
	if n := count(t, a.aro, "SELECT count(*) FROM Document"); n != 3 {
		t.Fatalf("A has %d documents, want 3", n)
	}
	if q := count(t, b.aro, "SELECT CAST(Quantity AS INTEGER) FROM Stock WHERE ProductId=2"); q != 45 {
		t.Fatalf("B rebar stock %d, want 45", q)
	}
	// Echo suppression: applying wrote nothing to the receiver's own log.
	if n := count(t, b.aro, "SELECT count(*) FROM _rt_log WHERE tbl='Document'"); n != 1 {
		t.Fatalf("B logged %d documents, want only its own 1", n)
	}
}

func TestApplyIsIdempotentAndDetectsGaps(t *testing.T) {
	a, b := newPair(t, newSeedFile(t))
	a.sell(t, "26-200-000001", 1, 1, line{"Nail 2in", 1, 10})
	b1, _ := a.eng.Extract(0, 1000)
	if _, err := b.eng.Apply(b1); err != nil {
		t.Fatal(err)
	}
	if n, err := b.eng.Apply(b1); err != nil || n != 0 {
		t.Fatalf("second apply: n=%d err=%v", n, err)
	}
	// JSON round trip, as the transport will send it.
	raw, _ := json.Marshal(b1)
	var again Batch
	json.Unmarshal(raw, &again)
	if n, err := b.eng.Apply(&again); err != nil || n != 0 {
		t.Fatalf("apply after JSON: n=%d err=%v", n, err)
	}
	a.sell(t, "26-200-000002", 1, 1, line{"Nail 2in", 1, 10})
	a.sell(t, "26-200-000003", 1, 1, line{"Nail 2in", 1, 10})
	full, _ := a.eng.Extract(b1.To, 1000)
	late, _ := a.eng.Extract(full.To-1, 1000) // skips earlier rows
	if _, err := b.eng.Apply(late); !errors.Is(err, ErrGap) {
		t.Fatalf("want ErrGap, got %v", err)
	}
	// Overlapping resend is fine.
	overlap, _ := a.eng.Extract(0, 1000)
	if _, err := b.eng.Apply(overlap); err != nil {
		t.Fatal(err)
	}
	a.sent = overlap.To
	checkSame(t, a, b)
	if n := count(t, b.aro, "SELECT count(*) FROM Document"); n != 3 {
		t.Fatalf("B has %d documents, want 3", n)
	}
}

func TestMismatchedSeedRejected(t *testing.T) {
	a, b := newPair(t, newSeedFile(t))
	a.sell(t, "26-200-000001", 1, 1, line{"Nail 2in", 1, 10})
	bt, _ := a.eng.Extract(0, 100)
	bt.SeedTag = "other"
	if _, err := b.eng.Apply(bt); !errors.Is(err, ErrMismatch) {
		t.Fatalf("want ErrMismatch, got %v", err)
	}
}

func TestOfficeCreatesProductAndCustomerThenTillUsesThem(t *testing.T) {
	a, b := newPair(t, newSeedFile(t))
	// Both laptops create rows with the same new Ids.
	mustExec(t, b.aro, "INSERT INTO Product(Name,Code,Price) VALUES('Paint 1L','P1',350)")
	mustExec(t, b.aro, "INSERT INTO Customer(Name,Email) VALUES('Builder Co','x@example.test')")
	mustExec(t, a.aro, "INSERT INTO Product(Name,Code,Price) VALUES('Tape','T1',40)")
	var custB int64
	b.aro.QueryRow("SELECT Id FROM Customer WHERE Name='Builder Co'").Scan(&custB)
	b.sell(t, "26-200-500001", custB, 1, line{"Paint 1L", 2, 350})
	syncBoth(t, a, b)
	checkSame(t, a, b)
	// The till sells the office's product to the office's customer.
	var custA int64
	a.aro.QueryRow("SELECT Id FROM Customer WHERE Name='Builder Co'").Scan(&custA)
	a.sell(t, "26-200-000001", custA, 1, line{"Paint 1L", 1, 350}, line{"Tape", 1, 40})
	// And the till edits the office-made product.
	time.Sleep(5 * time.Millisecond)
	mustExec(t, a.aro, "UPDATE Product SET Price=375, DateUpdated='x' WHERE Name='Paint 1L'")
	syncBoth(t, a, b)
	checkSame(t, a, b)
	if p := count(t, b.aro, "SELECT CAST(Price AS INTEGER) FROM Product WHERE Name='Paint 1L'"); p != 375 {
		t.Fatalf("office sees price %d, want 375", p)
	}
}

func TestLastWriterWinsPerColumn(t *testing.T) {
	a, b := newPair(t, newSeedFile(t))
	// Different columns of the same product at the same time: both edits survive.
	mustExec(t, a.aro, "UPDATE Product SET Price=12 WHERE Id=1")
	mustExec(t, b.aro, "UPDATE Product SET Name='Nail 2 inch' WHERE Id=1")
	// Same column: the later edit wins on both laptops.
	mustExec(t, a.aro, "UPDATE Product SET Code='OLD' WHERE Id=2")
	time.Sleep(10 * time.Millisecond)
	mustExec(t, b.aro, "UPDATE Product SET Code='NEW' WHERE Id=2")
	sync(t, b, a) // newer edit arrives first...
	sync(t, a, b) // ...older one second: must not overwrite
	checkSame(t, a, b)
	var name, code string
	var price float64
	a.aro.QueryRow("SELECT Name, Price FROM Product WHERE Id=1").Scan(&name, &price)
	a.aro.QueryRow("SELECT Code FROM Product WHERE Id=2").Scan(&code)
	if name != "Nail 2 inch" || price != 12 || code != "NEW" {
		t.Fatalf("got name=%q price=%v code=%q", name, price, code)
	}
}

func TestDeletesAndTombstones(t *testing.T) {
	a, b := newPair(t, newSeedFile(t))
	id := a.sell(t, "26-200-000001", 1, 1, line{"Nail 2in", 1, 10})
	a.sell(t, "26-200-000002", 1, 1, line{"Cement", 1, 260})
	syncBoth(t, a, b)
	// The office voids the till's first receipt (cascade removes lines and payment).
	var bid int64
	b.aro.QueryRow("SELECT Id FROM Document WHERE Number='26-200-000001'").Scan(&bid)
	mustExec(t, b.aro, "DELETE FROM Document WHERE Id=?", bid)
	// Meanwhile the till edits that receipt's note: delete still wins.
	mustExec(t, a.aro, "UPDATE Document SET Note='late edit' WHERE Id=?", id)
	syncBoth(t, a, b)
	checkSame(t, a, b)
	if n := count(t, a.aro, "SELECT count(*) FROM Document WHERE Number='26-200-000001'"); n != 0 {
		t.Fatal("deleted receipt came back on the till")
	}
	// A deleted product is disabled on the other laptop, not removed.
	mustExec(t, a.aro, "DELETE FROM Stock WHERE ProductId=3")
	mustExec(t, a.aro, "DELETE FROM DocumentItem WHERE ProductId=3")
	mustExec(t, a.aro, "DELETE FROM Product WHERE Id=3")
	sync(t, a, b)
	if n := count(t, b.aro, "SELECT IsEnabled FROM Product WHERE Id=3"); n != 0 {
		t.Fatal("product not disabled on the office laptop")
	}
}

func TestStockDeltasCommute(t *testing.T) {
	a, b := newPair(t, newSeedFile(t))
	for i := 0; i < 5; i++ {
		a.sell(t, "A"+string(rune('0'+i)), 1, 1, line{"Cement", 1, 260})
		b.sell(t, "B"+string(rune('0'+i)), 1, 1, line{"Cement", 2, 260})
	}
	// Inventory count on the office: absolute write, logged as a delta.
	mustExec(t, b.aro, "UPDATE Stock SET Quantity = 30 WHERE ProductId=3")
	syncBoth(t, a, b)
	checkSame(t, a, b)
	if q := count(t, a.aro, "SELECT CAST(Quantity AS INTEGER) FROM Stock WHERE ProductId=3"); q != 25 {
		t.Fatalf("till cement stock %d, want 25 (count 30 minus the till's 5 sold meanwhile)", q)
	}
}

func TestCatchUpAfterTriggersWereOff(t *testing.T) {
	a, b := newPair(t, newSeedFile(t))
	a.sell(t, "26-200-000001", 1, 1, line{"Nail 2in", 1, 10})
	if err := a.eng.RemoveTriggers(); err != nil {
		t.Fatal(err)
	}
	// Aronium writes while the triggers are off (e.g. during its startup).
	a.sell(t, "26-200-000002", 1, 1, line{"Cement", 2, 260})
	mustExec(t, a.aro, "UPDATE Product SET Price=11 WHERE Id=1")
	mustExec(t, a.aro, "INSERT INTO Customer(Name) VALUES('Gap customer')")
	if n := count(t, a.aro, "SELECT count(*) FROM _rt_log WHERE seq > 4"); n != 0 {
		t.Fatal("triggers still logging")
	}
	caught, err := a.eng.InstallTriggers()
	if err != nil {
		t.Fatal(err)
	}
	if caught < 5 {
		t.Fatalf("catch-up found %d changes, want at least 5", caught)
	}
	syncBoth(t, a, b)
	checkSame(t, a, b)
	if n, _ := a.eng.TriggersInstalled(); n == 0 {
		t.Fatal("triggers not back")
	}
}

func TestOfflineForHoursThenCatchUp(t *testing.T) {
	a, b := newPair(t, newSeedFile(t))
	for i := 0; i < 40; i++ {
		a.sell(t, "A-"+time.Now().Format("150405.000000"), 1, 1, line{"Nail 2in", 1, 10})
		if i%10 == 0 {
			mustExec(t, b.aro, "UPDATE Product SET Price=Price+1 WHERE Id=2")
			b.sell(t, "B-"+time.Now().Format("150405.000000"), 1, 2, line{"Rebar 10mm", 1, 154})
		}
	}
	// Send in small batches, as after a long partition.
	for {
		bt, err := a.eng.Extract(a.sent, 7)
		if err != nil {
			t.Fatal(err)
		}
		if bt.To == a.sent {
			break
		}
		if _, err := b.eng.Apply(bt); err != nil {
			t.Fatal(err)
		}
		a.sent = bt.To
	}
	sync(t, b, a)
	checkSame(t, a, b)
}
