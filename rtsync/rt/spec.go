// Package rt is the real-time two-way sync engine for Aronium Lite's pos.db.
//
// It records every change Aronium makes (SQLite triggers into _rt_log), turns
// those records into Changes keyed by global ids, and applies a peer's Changes
// into the live database with Ids remapped, per-column last-writer-wins for
// edits, delete tombstones, and stock as summed deltas.
package rt

// Kind says how a table's rows are identified across laptops.
type Kind int

const (
	// KindID tables have an INTEGER Id primary key. A row's global id is
	// "seed:<Id>" for rows present at seeding, or "<node>:<Id>" for rows a
	// laptop created afterwards.
	KindID Kind = iota
	// KindFKKey tables have a primary key made only of foreign keys
	// (ProductTax, DocumentItemTax, DocumentItemExpirationDate). Their global id
	// is built from the parents' global ids.
	KindFKKey
	// KindStock is the Stock table: rows are keyed by (ProductId, WarehouseId)
	// and only Quantity deltas travel.
	KindStock
)

// TableSpec describes one replicated table.
type TableSpec struct {
	Name string
	Kind Kind
	// KeyCols are the primary key columns of a KindFKKey table.
	KeyCols []string
	// LocalCols never travel: they hold per-till state (Z report membership).
	LocalCols []string
	// SoftDelete: a delete from the peer becomes IsEnabled=0 here. Used for
	// Product: Aronium's selling screen caches the product list until restart,
	// and a hard delete would make the cached product fail at the counter.
	SoftDelete bool
}

// Replicated lists every table that syncs, parents before children.
// Anything not listed is local to each laptop: Counter, ZReport, StartingCash,
// ApplicationProperty, Migration, printers and print stations, SecurityKey,
// PosOrder/PosOrderItem/PosVoid, FloorPlan*, FiscalItem, Company, Template,
// DocumentCategory, DocumentType.
var Replicated = []TableSpec{
	{Name: "User", Kind: KindID},
	{Name: "Country", Kind: KindID},
	{Name: "Currency", Kind: KindID},
	{Name: "Warehouse", Kind: KindID},
	{Name: "Tax", Kind: KindID},
	{Name: "PaymentType", Kind: KindID},
	{Name: "VoidReason", Kind: KindID},
	{Name: "ProductGroup", Kind: KindID},
	{Name: "PriceList", Kind: KindID},
	{Name: "Product", Kind: KindID, SoftDelete: true},
	{Name: "Barcode", Kind: KindID},
	{Name: "ProductTax", Kind: KindFKKey, KeyCols: []string{"ProductId", "TaxId"}},
	{Name: "ProductComment", Kind: KindID},
	{Name: "PriceListItem", Kind: KindID},
	{Name: "Promotion", Kind: KindID},
	{Name: "PromotionItem", Kind: KindID},
	{Name: "Customer", Kind: KindID},
	{Name: "CustomerDiscount", Kind: KindID},
	{Name: "LoyaltyCard", Kind: KindID},
	{Name: "StockControl", Kind: KindID},
	{Name: "Document", Kind: KindID, LocalCols: []string{"IsClockedOut"}},
	{Name: "DocumentItem", Kind: KindID},
	{Name: "DocumentItemTax", Kind: KindFKKey, KeyCols: []string{"DocumentItemId", "TaxId"}},
	{Name: "DocumentItemExpirationDate", Kind: KindFKKey, KeyCols: []string{"DocumentItemId"}},
	{Name: "Payment", Kind: KindID, LocalCols: []string{"ZReportId"}},
	{Name: "Stock", Kind: KindStock},
}

// SpecByName returns the spec for a table, or nil if it does not sync.
func SpecByName(name string) *TableSpec {
	for i := range Replicated {
		if Replicated[i].Name == name {
			return &Replicated[i]
		}
	}
	return nil
}

func (s *TableSpec) isLocalCol(c string) bool {
	for _, l := range s.LocalCols {
		if l == c {
			return true
		}
	}
	return false
}
