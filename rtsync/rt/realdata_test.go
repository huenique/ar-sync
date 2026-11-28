package rt

import (
	"fmt"
	"os"
	"testing"
	"time"
)

// TestRealShopCopy runs the two-laptop scenario on a copy of a real Aronium 1.52
// database. Opt-in: set RTSYNC_FIXTURE to the path of such a copy (never
// committed; it holds customer data). Failures print counts, never rows.
func TestRealShopCopy(t *testing.T) {
	fx := os.Getenv("RTSYNC_FIXTURE")
	if fx == "" {
		t.Skip("RTSYNC_FIXTURE not set")
	}
	private = true
	defer func() { private = false }()

	t0 := time.Now()
	a, b := newPair(t, fx)
	t.Logf("seed + install triggers on both: %v", time.Since(t0).Round(time.Millisecond))

	// Pick real enabled products with stock (by Id; nothing printed).
	rows, err := a.aro.Query("SELECT P.Id, P.Price FROM Product P JOIN Stock S ON S.ProductId=P.Id WHERE P.IsEnabled=1 AND P.Price>0 ORDER BY P.Id LIMIT 30")
	if err != nil {
		t.Fatal(err)
	}
	type prod struct {
		id    int64
		price float64
	}
	var ps []prod
	for rows.Next() {
		var p prod
		rows.Scan(&p.id, &p.price)
		ps = append(ps, p)
	}
	rows.Close()
	if len(ps) < 10 {
		t.Fatalf("only %d usable products", len(ps))
	}

	// Office: a new product and customer, a price edit, an inventory count, a sale.
	mustExec(t, b.aro, "INSERT INTO Product(Name,Code,Price) VALUES('ZZ RT TEST','ZZRT',99)")
	mustExec(t, b.aro, "INSERT INTO Customer(Name) VALUES('ZZ RT CUSTOMER')")
	mustExec(t, b.aro, "UPDATE Product SET Price=Price+5 WHERE Id=?", ps[0].id)
	mustExec(t, b.aro, "UPDATE Stock SET Quantity=123 WHERE ProductId=?", ps[1].id)
	var cust int64
	b.aro.QueryRow("SELECT Id FROM Customer WHERE Name='ZZ RT CUSTOMER'").Scan(&cust)
	b.sell(t, "26-200-500001", cust, 1, line{"ZZ RT TEST", 2, 99}, byID(ps[2].id, 1, ps[2].price))

	// Till: twenty sales over real products, then End of day.
	for i := 0; i < 20; i++ {
		p1, p2 := ps[i%len(ps)], ps[(i*7+3)%len(ps)]
		a.sell(t, fmt.Sprintf("26-200-%06d", i+1), 1, 1, byID(p1.id, 1, p1.price), byID(p2.id, 2, p2.price))
	}
	a.endOfDay(t)

	t1 := time.Now()
	syncBoth(t, a, b)
	t.Logf("exchange: %v", time.Since(t1).Round(time.Millisecond))
	checkSame(t, a, b)

	// The till now sells the office's new product to the office's new customer.
	var pA, cA int64
	a.aro.QueryRow("SELECT Id FROM Product WHERE Code='ZZRT'").Scan(&pA)
	a.aro.QueryRow("SELECT Id FROM Customer WHERE Name='ZZ RT CUSTOMER'").Scan(&cA)
	if pA == 0 || cA == 0 {
		t.Fatal("office product or customer missing on the till")
	}
	a.sell(t, "26-200-000021", cA, 1, byID(pA, 1, 99))

	// Triggers off and on, as around an Aronium restart, with a sale in the gap.
	t2 := time.Now()
	if err := a.eng.RemoveTriggers(); err != nil {
		t.Fatal(err)
	}
	t.Logf("remove triggers + snapshot: %v", time.Since(t2).Round(time.Millisecond))
	a.sell(t, "26-200-000022", 1, 1, byID(ps[5].id, 1, ps[5].price))
	t3 := time.Now()
	caught, err := a.eng.InstallTriggers()
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("install triggers + catch-up (%d changes): %v", caught, time.Since(t3).Round(time.Millisecond))

	syncBoth(t, a, b)
	checkSame(t, a, b)
	if n := count(t, b.aro, "SELECT count(*) FROM Document WHERE Number LIKE '26-200-%'"); n != 23 {
		t.Fatalf("office has %d new receipts, want 23", n)
	}
}
