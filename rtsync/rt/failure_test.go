package rt

import (
	"errors"
	"path/filepath"
	"testing"
)

// The office deletes a customer while the till is selling to them. Neither
// side may stall, and the sale must land on both.
func TestCustomerDeletedWhileTillSellsToThem(t *testing.T) {
	a, b := newPair(t, newSeedFile(t))
	mustExec(t, b.aro, "INSERT INTO Customer(Name) VALUES('Gone Soon')")
	syncBoth(t, a, b)
	var custA, custB int64
	a.aro.QueryRow("SELECT Id FROM Customer WHERE Name='Gone Soon'").Scan(&custA)
	b.aro.QueryRow("SELECT Id FROM Customer WHERE Name='Gone Soon'").Scan(&custB)
	mustExec(t, b.aro, "DELETE FROM Customer WHERE Id=?", custB)
	a.sell(t, "26-200-000001", custA, 1, line{"Nail 2in", 1, 10})
	syncBoth(t, a, b) // must not error
	if n := count(t, b.aro, "SELECT count(*) FROM Document WHERE Number='26-200-000001'"); n != 1 {
		t.Fatal("the till's sale did not reach the office")
	}
	if n := count(t, b.aro, "SELECT count(*) FROM Document WHERE Number='26-200-000001' AND CustomerId IS NULL"); n != 1 {
		t.Fatal("office copy of the sale should have no customer")
	}
	if n := count(t, a.aro, "SELECT IsEnabled FROM Customer WHERE Id=?", custA); n != 0 {
		t.Fatal("customer still enabled on the till")
	}
	if n := count(t, a.aro, "SELECT CustomerId FROM Document WHERE Number='26-200-000001'"); n != custA {
		t.Fatal("till's own sale lost its customer")
	}
	if c, _ := b.eng.Conflicts(10); len(c) == 0 {
		t.Fatal("no conflict recorded")
	}
	// Later changes still flow.
	a.sell(t, "26-200-000002", 1, 1, line{"Nail 2in", 1, 10})
	syncBoth(t, a, b)
	if n := count(t, b.aro, "SELECT count(*) FROM Document"); n != 2 {
		t.Fatalf("office has %d documents, want 2", n)
	}
}

// Both laptops create the row a unique index allows only once.
func TestSameUniqueRowOnBothLaptopsMerges(t *testing.T) {
	a, b := newPair(t, newSeedFile(t))
	mustExec(t, a.aro, "INSERT INTO StockControl(ProductId,ReorderPoint) VALUES(1,5)")
	mustExec(t, b.aro, "INSERT INTO StockControl(ProductId,ReorderPoint) VALUES(1,8)")
	syncBoth(t, a, b)
	for _, l := range []*laptop{a, b} {
		if n := count(t, l.aro, "SELECT count(*) FROM StockControl WHERE ProductId=1"); n != 1 {
			t.Fatalf("%s has %d StockControl rows for product 1", l.name, n)
		}
	}
	ra := count(t, a.aro, "SELECT CAST(ReorderPoint AS INTEGER) FROM StockControl")
	rb := count(t, b.aro, "SELECT CAST(ReorderPoint AS INTEGER) FROM StockControl")
	if ra != rb {
		t.Fatalf("reorder point differs: A %d, B %d", ra, rb)
	}
}

// A delete the receiving laptop can't do (rows still use it) is kept, not stuck.
func TestDeleteBlockedByForeignKeyIsKept(t *testing.T) {
	a, b := newPair(t, newSeedFile(t))
	mustExec(t, a.aro, "INSERT INTO ProductGroup(Name) VALUES('Paint')")
	syncBoth(t, a, b)
	var gb int64
	b.aro.QueryRow("SELECT Id FROM ProductGroup WHERE Name='Paint'").Scan(&gb)
	mustExec(t, b.aro, "UPDATE Product SET ProductGroupId=? WHERE Id=1", gb)
	mustExec(t, a.aro, "DELETE FROM ProductGroup WHERE Name='Paint'")
	syncBoth(t, a, b) // must not error
	syncBoth(t, a, b)
	if n := count(t, b.aro, "SELECT count(*) FROM ProductGroup WHERE Name='Paint'"); n != 1 {
		t.Fatal("office lost a group its products still use")
	}
	if n := count(t, a.aro, "SELECT count(*) FROM Product WHERE Id=1 AND ProductGroupId IS NULL"); n != 1 {
		t.Fatal("till should keep product 1 without the deleted group")
	}
}

// A change that can never apply is reported and can be set aside.
func TestStuckChangeCanBeSetAside(t *testing.T) {
	a, b := newPair(t, newSeedFile(t))
	b.sell(t, "26-200-500001", 1, 1, line{"Nail 2in", 1, 10})
	bt, err := b.eng.Extract(0, 1000)
	if err != nil {
		t.Fatal(err)
	}
	bad := "B:999999"
	var badSeq int64
	for i := range bt.Changes {
		if bt.Changes[i].Table == "DocumentItem" {
			bt.Changes[i].Vals["DocumentId"] = Value{G: &bad}
			badSeq = bt.Changes[i].Seq
		}
	}
	_, err = a.eng.Apply(bt)
	var ae *ApplyError
	if !errors.As(err, &ae) || ae.Seq != badSeq {
		t.Fatalf("want ApplyError at seq %d, got %v", badSeq, err)
	}
	if n := count(t, a.aro, "SELECT count(*) FROM Document"); n != 0 {
		t.Fatal("failed batch was partly applied")
	}
	a.eng.SetAside(ae.Origin, ae.Seq)
	if _, err := a.eng.Apply(bt); err != nil {
		t.Fatal(err)
	}
	if n := count(t, a.aro, "SELECT count(*) FROM Document"); n != 1 {
		t.Fatal("rest of the batch not applied after setting the bad change aside")
	}
	if c, _ := a.eng.Conflicts(5); len(c) == 0 {
		t.Fatal("set-aside change not recorded")
	}
}

// Writes between seeding and the first trigger install must still travel.
func TestWritesBeforeFirstInstallAreCaught(t *testing.T) {
	seed := newSeedFile(t)
	mk := func(name string) *laptop {
		p := filepath.Join(t.TempDir(), name+".db")
		copyFile(t, seed, p)
		e, err := Open(p)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := e.Seed(name); err != nil {
			t.Fatal(err)
		}
		l := &laptop{name: name, path: p, eng: e, aro: rawOpen(t, p)}
		t.Cleanup(func() { l.aro.Close(); l.eng.Close() })
		return l
	}
	a, b := mk("A"), mk("B")
	a.sell(t, "26-200-000001", 1, 1, line{"Cement", 1, 260}) // Aronium opened before the sidecar
	for _, l := range []*laptop{a, b} {
		if _, err := l.eng.InstallTriggers(); err != nil {
			t.Fatal(err)
		}
	}
	syncBoth(t, a, b)
	checkSame(t, a, b)
	if n := count(t, b.aro, "SELECT count(*) FROM Document"); n != 1 {
		t.Fatal("sale made before the first trigger install never reached the office")
	}
}
