package rt

import (
	"fmt"
	"strings"
)

// Triggers use only core SQL (no JSON or custom functions): a failing trigger
// would abort Aronium's own sale. They skip when _rt_ctx has a row, which only
// the sync engine's own transaction ever sets.

const wallExpr = `CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)`
const echoGuard = `NOT EXISTS (SELECT 1 FROM _rt_ctx)`

func trigName(table, op string) string { return "_rt_" + table + "_" + op }

func keyExpr(ref string, cols []string) string {
	parts := make([]string, len(cols))
	for i, c := range cols {
		parts[i] = fmt.Sprintf("IFNULL(%s.%s,'')", ref, qi(c))
	}
	return strings.Join(parts, " || '|' || ")
}

func (ti *tableInfo) triggerSQL() []string {
	t := ti.Spec.Name
	var out []string
	add := func(op, when, body string) {
		w := echoGuard
		if when != "" {
			w += " AND (" + when + ")"
		}
		out = append(out, fmt.Sprintf("CREATE TRIGGER %s AFTER %s ON %s WHEN %s BEGIN %s; END",
			qi(trigName(t, op[:1])), op, qi(t), w, body))
	}
	ins := func(op, rid, keyv, cols, delta string) string {
		return fmt.Sprintf("INSERT INTO _rt_log(tbl,op,rid,keyv,cols,delta,wall) VALUES('%s','%s',%s,%s,%s,%s,%s)",
			t, op, rid, keyv, cols, delta, wallExpr)
	}
	switch ti.Spec.Kind {
	case KindStock:
		k := func(ref string) string { return keyExpr(ref, []string{"ProductId", "WarehouseId"}) }
		add("INSERT", "", ins("S", "NEW.rowid", k("NEW"), "NULL", "NEW.Quantity"))
		add("UPDATE", "OLD.Quantity IS NOT NEW.Quantity OR OLD.ProductId IS NOT NEW.ProductId OR OLD.WarehouseId IS NOT NEW.WarehouseId",
			ins("S", "NEW.rowid", k("NEW"), "NULL", "NEW.Quantity - OLD.Quantity"))
		add("DELETE", "", ins("S", "OLD.rowid", k("OLD"), "NULL", "-OLD.Quantity"))
		return out
	}
	sc := ti.syncCols()
	var changed, any []string
	for _, c := range sc {
		changed = append(changed, fmt.Sprintf("(CASE WHEN OLD.%s IS NOT NEW.%s THEN '%s,' ELSE '' END)", qi(c), qi(c), c))
		any = append(any, fmt.Sprintf("OLD.%s IS NOT NEW.%s", qi(c), qi(c)))
	}
	keyNew, keyOld := "NULL", "NULL"
	if ti.Spec.Kind == KindFKKey {
		keyNew, keyOld = keyExpr("NEW", ti.Spec.KeyCols), keyExpr("OLD", ti.Spec.KeyCols)
	}
	add("INSERT", "", ins("I", "NEW.rowid", keyNew, "NULL", "NULL"))
	if len(sc) > 0 {
		add("UPDATE", strings.Join(any, " OR "), ins("U", "NEW.rowid", keyNew, strings.Join(changed, " || "), "NULL"))
	}
	add("DELETE", "", ins("D", "OLD.rowid", keyOld, "NULL", "NULL"))
	return out
}

// TriggersInstalled counts this engine's triggers in the database.
func (d *DB) TriggersInstalled() (int, error) {
	var n int
	err := d.one(`SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name LIKE '\_rt\_%' ESCAPE '\'`).Scan(&n)
	return n, err
}

func (d *DB) dropTriggers() error {
	rows, err := d.query(`SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE '\_rt\_%' ESCAPE '\'`)
	if err != nil {
		return err
	}
	var names []string
	for rows.Next() {
		var n string
		rows.Scan(&n)
		names = append(names, n)
	}
	rows.Close()
	for _, n := range names {
		if _, err := d.exec("DROP TRIGGER IF EXISTS " + qi(n)); err != nil {
			return err
		}
	}
	return nil
}

func (d *DB) createTriggers() error {
	for _, sp := range Replicated {
		ti := d.sch[sp.Name]
		if ti == nil {
			continue
		}
		for _, s := range ti.triggerSQL() {
			if _, err := d.exec(s); err != nil {
				return fmt.Errorf("trigger on %s: %w", sp.Name, err)
			}
		}
	}
	return nil
}
