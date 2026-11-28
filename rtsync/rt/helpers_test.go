package rt

import (
	"database/sql"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

// newSeedFile builds a small Aronium 1.52 database from the committed schema
// with made-up reference rows (no real data).
func newSeedFile(t *testing.T) string {
	t.Helper()
	schema, err := os.ReadFile(filepath.Join("..", "testdata", "schema-1.52.sql"))
	if err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(t.TempDir(), "seed.db")
	db := rawOpen(t, p)
	defer db.Close()
	mustExec(t, db, string(schema))
	mustExec(t, db, `
INSERT INTO Warehouse(Id,Name) VALUES(1,'Main');
INSERT INTO User(Id,FirstName,Password,AccessLevel) VALUES(1,'Test','x',9);
INSERT INTO DocumentCategory(Id,Name) VALUES(1,'Purchase'),(2,'Sales'),(3,'Inventory'),(4,'Loss');
INSERT INTO DocumentType(Id,Name,Code,DocumentCategoryId,WarehouseId,StockDirection) VALUES
 (1,'Purchase','100',1,1,1),(2,'Sales','200',2,1,2),(3,'Inventory Count','300',3,1,1),(4,'Refund','220',2,1,1);
INSERT INTO PaymentType(Id,Name) VALUES(1,'Cash'),(2,'GCash');
INSERT INTO Country(Id,Name) VALUES(1,'Philippines');
INSERT INTO Customer(Id,Name) VALUES(1,'Walk-in');
INSERT INTO Product(Id,Name,Code,Price) VALUES(1,'Nail 2in','N2',10),(2,'Rebar 10mm','R10',154),(3,'Cement','C1',260);
INSERT INTO Stock(ProductId,WarehouseId,Quantity) VALUES(1,1,100),(2,1,50),(3,1,20);
INSERT INTO Counter(Name,Value) VALUES('Document.200.2026',0);
`)
	return p
}

func rawOpen(t *testing.T, p string) *sql.DB {
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

func mustExec(t *testing.T, db *sql.DB, q string, args ...any) sql.Result {
	t.Helper()
	r, err := db.Exec(q, args...)
	if err != nil {
		t.Fatalf("%v\n%s", err, q)
	}
	return r
}

func copyFile(t *testing.T, src, dst string) {
	t.Helper()
	in, err := os.Open(src)
	if err != nil {
		t.Fatal(err)
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.Copy(out, in); err != nil {
		t.Fatal(err)
	}
	out.Close()
}

// laptop is one side of a two-laptop test: the engine and an "Aronium"
// connection that writes the way Aronium does.
type laptop struct {
	name string
	path string
	eng  *DB
	aro  *sql.DB
	sent int64 // last own seq sent to the peer
}

func newPair(t *testing.T, seed string) (*laptop, *laptop) {
	t.Helper()
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
		if _, err := e.InstallTriggers(); err != nil {
			t.Fatal(err)
		}
		l := &laptop{name: name, path: p, eng: e, aro: rawOpen(t, p)}
		t.Cleanup(func() { l.aro.Close(); l.eng.Close() })
		return l
	}
	return mk("A"), mk("B")
}

// sync sends everything new from `from` to `to`.
func sync(t *testing.T, from, to *laptop) int {
	t.Helper()
	b, err := from.eng.Extract(from.sent, 100000)
	if err != nil {
		t.Fatalf("extract %s: %v", from.name, err)
	}
	n, err := to.eng.Apply(b)
	if err != nil {
		t.Fatalf("apply %s->%s: %v", from.name, to.name, err)
	}
	from.sent = b.To
	return n
}

func syncBoth(t *testing.T, a, b *laptop) {
	sync(t, a, b)
	sync(t, b, a)
}

type line struct {
	product string
	qty     float64
	price   float64
}

// byID names a product by Id ("#123") instead of by name.
func byID(id int64, qty, price float64) line { return line{fmt.Sprintf("#%d", id), qty, price} }

// private is set by the real-data test so failures never print shop data.
var private bool

// sell writes a sale the way Aronium 1.52 does (statements taken from
// Aronium.Storage.Local.dll and Aronium.Pos.Stock.Local.dll).
func (l *laptop) sell(t *testing.T, number string, customer int64, pay int64, lines ...line) int64 {
	t.Helper()
	tx, err := l.aro.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback() // no-op after Commit; frees the file if the test fails
	now := time.Now().Format("2006-01-02 15:04:05.0000000")
	day := time.Now().Format("2006-01-02") + " 00:00:00"
	var total float64
	for _, ln := range lines {
		total += ln.qty * ln.price
	}
	r, err := tx.Exec(`INSERT INTO Document (Number, UserId, CustomerId, OrderNumber, Date, DueDate, StockDate, Total, DateCreated, DateUpdated, DocumentTypeId, WarehouseId, Discount, DiscountType, DiscountApplyRule, PaidStatus)
		VALUES (?,1,?,?,?,?,?,?,?,?,2,1,0,0,0,2)`, number, customer, "T", day, day, now, total, now, now)
	if err != nil {
		t.Fatal(err)
	}
	docID, _ := r.LastInsertId()
	for _, ln := range lines {
		var pid int64
		if _, err := fmt.Sscanf(ln.product, "#%d", &pid); err != nil {
			if err := tx.QueryRow("SELECT Id FROM Product WHERE Name=?", ln.product).Scan(&pid); err != nil {
				t.Fatalf("product %s: %v", ln.product, err)
			}
		}
		if _, err := tx.Exec(`INSERT INTO DocumentItem (DocumentId, ProductId, Quantity, ExpectedQuantity, Discount, DiscountType, DiscountApplyRule, PriceBeforeTax, PriceBeforeTaxAfterDiscount, Price, PriceAfterDiscount, Total, ProductCost, TotalAfterDocumentDiscount)
			VALUES (?,?,?,0,0,0,0,?,?,?,?,?,0,?)`, docID, pid, ln.qty, ln.price, ln.price, ln.price, ln.price, ln.qty*ln.price, ln.qty*ln.price); err != nil {
			t.Fatal(err)
		}
		r, err := tx.Exec("UPDATE Stock SET Quantity = Quantity + ? WHERE ProductId = ? AND WarehouseId = ?", -ln.qty, pid, 1)
		if err != nil {
			t.Fatal(err)
		}
		if n, _ := r.RowsAffected(); n == 0 {
			tx.Exec("INSERT INTO Stock (ProductId, WarehouseId, Quantity) VALUES (?,1,?)", pid, -ln.qty)
		}
	}
	if _, err := tx.Exec(`INSERT INTO Payment (DocumentId, PaymentTypeId, Amount, RoundingAdjustment, Date, UserId, DateCreated) VALUES (?,?,?,0,?,1,?)`,
		docID, pay, total, day, now); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec("INSERT OR REPLACE INTO Counter (Name, Value) VALUES ('Document.200.2026', COALESCE((SELECT Value FROM Counter WHERE Name='Document.200.2026'),0)+1)"); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	return docID
}

// endOfDay does what Aronium's "Close register" does to the database.
func (l *laptop) endOfDay(t *testing.T) {
	t.Helper()
	tx, _ := l.aro.Begin()
	defer tx.Rollback()
	var from, to int64
	tx.QueryRow("SELECT IFNULL(MAX(ToDocumentId),0)+1 FROM ZReport").Scan(&from)
	tx.QueryRow("SELECT IFNULL(MAX(Id),0) FROM Document WHERE Id > (SELECT IFNULL(MAX(ToDocumentId),0) FROM ZReport)").Scan(&to)
	r, err := tx.Exec("INSERT INTO ZReport (Number, FromDocumentId, ToDocumentId, DateCreated) VALUES ((SELECT IFNULL(MAX(Number),0)+1 FROM ZReport),?,?,?)", from, to, time.Now().Format(time.RFC3339))
	if err != nil {
		t.Fatal(err)
	}
	zid, _ := r.LastInsertId()
	tx.Exec("UPDATE Payment SET ZReportId = ? WHERE ZReportId IS NULL", zid)
	tx.Exec("UPDATE Document SET IsClockedOut=1 WHERE IsClockedOut=0 AND UserId IN (1)")
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
}

// digest is a laptop-independent view of the business data: Ids differ
// between laptops, so rows are described by receipt number and product name.
func digest(t *testing.T, db *sql.DB) string {
	t.Helper()
	var out []string
	q := func(prefix, s string) {
		rows, err := db.Query(s)
		if err != nil {
			t.Fatal(err)
		}
		cols, _ := rows.Columns()
		for rows.Next() {
			vals := make([]any, len(cols))
			ptr := make([]any, len(cols))
			for i := range vals {
				ptr[i] = &vals[i]
			}
			rows.Scan(ptr...)
			parts := make([]string, len(vals))
			for i, v := range vals {
				if b, ok := v.([]byte); ok {
					v = string(b)
				}
				parts[i] = fmt.Sprint(v)
			}
			out = append(out, prefix+strings.Join(parts, "|"))
		}
		rows.Close()
	}
	q("doc ", `SELECT D.Number, D.Total, D.Date, C.Name, D.OrderNumber, D.PaidStatus FROM Document D LEFT JOIN Customer C ON C.Id=D.CustomerId`)
	q("item ", `SELECT D.Number, P.Name, I.Quantity, I.Price, I.Total FROM DocumentItem I JOIN Document D ON D.Id=I.DocumentId JOIN Product P ON P.Id=I.ProductId`)
	q("pay ", `SELECT D.Number, T.Name, P.Amount FROM Payment P JOIN Document D ON D.Id=P.DocumentId JOIN PaymentType T ON T.Id=P.PaymentTypeId`)
	q("stock ", `SELECT P.Name, ROUND(SUM(S.Quantity),6) FROM Stock S JOIN Product P ON P.Id=S.ProductId GROUP BY P.Name`)
	q("prod ", `SELECT Name, Code, Price, IsEnabled FROM Product`)
	q("cust ", `SELECT Name, IFNULL(Email,''), IFNULL(PhoneNumber,'') FROM Customer`)
	sort.Strings(out)
	return strings.Join(out, "\n")
}

func checkSame(t *testing.T, a, b *laptop) {
	t.Helper()
	da, db := digest(t, a.aro), digest(t, b.aro)
	if da != db {
		if private {
			// Real shop data: report only how many lines of each kind differ.
			la, lb := map[string]bool{}, map[string]bool{}
			for _, s := range strings.Split(da, "\n") {
				la[s] = true
			}
			for _, s := range strings.Split(db, "\n") {
				lb[s] = true
			}
			kinds := map[string]int{}
			for s := range la {
				if !lb[s] {
					kinds["A-only "+strings.SplitN(s, " ", 2)[0]]++
				}
			}
			for s := range lb {
				if !la[s] {
					kinds["B-only "+strings.SplitN(s, " ", 2)[0]]++
				}
			}
			t.Fatalf("laptops differ (counts only, real data): %v", kinds)
		}
		t.Fatalf("laptops differ:\n--- A ---\n%s\n--- B ---\n%s", da, db)
	}
	for _, l := range []*laptop{a, b} {
		var ok string
		l.aro.QueryRow("PRAGMA integrity_check").Scan(&ok)
		if ok != "ok" {
			t.Fatalf("%s integrity: %s", l.name, ok)
		}
		rows, _ := l.aro.Query("PRAGMA foreign_key_check")
		if rows.Next() {
			var tbl string
			var rid sql.NullInt64
			var parent string
			var fk int
			rows.Scan(&tbl, &rid, &parent, &fk)
			rows.Close()
			t.Fatalf("%s foreign key broken: %s row %v -> %s", l.name, tbl, rid.Int64, parent)
		}
		rows.Close()
	}
}

func count(t *testing.T, db *sql.DB, q string, args ...any) int64 {
	t.Helper()
	var n int64
	if err := db.QueryRow(q, args...).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}
