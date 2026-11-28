package rt

import (
	"database/sql"
	"fmt"
	"strings"
	"time"
)

// Triggers are on only while Aronium runs. They come off when Aronium exits
// (an Aronium update migrates the schema on its next start: DROP COLUMN fails
// on a column a trigger names, and a table rebuild silently drops triggers),
// and go back on once Aronium has finished starting. Whatever Aronium wrote
// in between is found by comparing with a snapshot taken at removal.

// bigTables are only checked for new and removed rows in the catch-up, not
// edits: copying them would double the file, and Aronium's own writes in the
// seconds before triggers return do not edit old sales.
var bigTables = map[string]bool{"Document": true, "DocumentItem": true, "Payment": true}

func snapTable(t string) string { return "_rt_snaprow_" + t }

// RemoveTriggers snapshots the synced tables and drops the triggers.
func (d *DB) RemoveTriggers() error {
	if _, err := d.Node(); err != nil {
		return err
	}
	if err := d.begin(false); err != nil {
		return err
	}
	if err := d.takeSnapshot(); err != nil {
		d.rollback()
		return err
	}
	if err := d.dropTriggers(); err != nil {
		d.rollback()
		return err
	}
	if err := d.setMeta("triggers", "off"); err != nil {
		d.rollback()
		return err
	}
	return d.commit()
}

func (d *DB) takeSnapshot() error {
	if err := d.clearSnapshot(); err != nil {
		return err
	}
	for _, sp := range Replicated {
		ti := d.sch[sp.Name]
		if ti == nil {
			continue
		}
		switch {
		case sp.Kind == KindStock:
			if _, err := d.exec("INSERT INTO _rt_snapstock(pid,wid,qty) SELECT ProductId,WarehouseId,SUM(Quantity) FROM Stock GROUP BY ProductId,WarehouseId"); err != nil {
				return err
			}
		case bigTables[sp.Name]:
			if _, err := d.exec("INSERT INTO _rt_snapids(tbl,id) SELECT ?, rowid FROM "+qi(sp.Name), sp.Name); err != nil {
				return err
			}
		default:
			if _, err := d.exec("CREATE TABLE " + qi(snapTable(sp.Name)) + " AS SELECT rowid AS _rid, * FROM " + qi(sp.Name)); err != nil {
				return err
			}
		}
	}
	return d.setMeta("snapshot", "1")
}

func (d *DB) clearSnapshot() error {
	if _, err := d.exec("DELETE FROM _rt_snapids; DELETE FROM _rt_snapstock;"); err != nil {
		return err
	}
	for _, sp := range Replicated {
		if _, err := d.exec("DROP TABLE IF EXISTS " + qi(snapTable(sp.Name))); err != nil {
			return err
		}
	}
	return d.setMeta("snapshot", "0")
}

// InstallTriggers logs what changed since the snapshot (if any), then creates
// the triggers. Safe to call while Aronium is open.
func (d *DB) InstallTriggers() (caught int, err error) {
	if _, err := d.Node(); err != nil {
		return 0, err
	}
	if err := d.loadSchema(); err != nil { // Aronium may have migrated since Open
		return 0, err
	}
	if err := d.begin(false); err != nil {
		return 0, err
	}
	defer func() {
		if err != nil {
			d.rollback()
		}
	}()
	if snap, _, _ := d.getMeta("snapshot"); snap == "1" {
		if caught, err = d.catchUp(); err != nil {
			return 0, err
		}
		if err = d.clearSnapshot(); err != nil {
			return 0, err
		}
	}
	if err = d.dropTriggers(); err != nil {
		return 0, err
	}
	if err = d.createTriggers(); err != nil {
		return 0, err
	}
	if err = d.setMeta("triggers", "on"); err != nil {
		return 0, err
	}
	return caught, d.commit()
}

func (d *DB) synth(tbl, op string, rid int64, keyv, cols any, delta any) error {
	_, err := d.exec("INSERT INTO _rt_log(tbl,op,rid,keyv,cols,delta,wall) VALUES(?,?,?,?,?,?,?)",
		tbl, op, rid, keyv, cols, delta, time.Now().UnixMilli())
	return err
}

func (ti *tableInfo) keySelect(prefix string) string {
	if ti.Spec.Kind != KindFKKey {
		return "NULL"
	}
	parts := make([]string, len(ti.Spec.KeyCols))
	for i, c := range ti.Spec.KeyCols {
		parts[i] = fmt.Sprintf("IFNULL(%s%s,'')", prefix, qi(c))
	}
	return strings.Join(parts, " || '|' || ")
}

func (d *DB) catchUp() (int, error) {
	n := 0
	type hit struct {
		rid  int64
		keyv any
	}
	collect := func(q string, args ...any) ([]hit, error) {
		rows, err := d.query(q, args...)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		var out []hit
		for rows.Next() {
			var h hit
			if err := rows.Scan(&h.rid, &h.keyv); err != nil {
				return nil, err
			}
			out = append(out, h)
		}
		return out, rows.Err()
	}
	for _, sp := range Replicated {
		ti := d.sch[sp.Name]
		if ti == nil {
			continue
		}
		t := qi(sp.Name)
		switch {
		case sp.Kind == KindStock:
			rows, err := d.query(`SELECT k.pid, k.wid, IFNULL(c.q,0) - IFNULL(s.qty,0) FROM
				(SELECT ProductId pid, WarehouseId wid FROM Stock UNION SELECT pid, wid FROM _rt_snapstock) k
				LEFT JOIN (SELECT ProductId, WarehouseId, SUM(Quantity) q FROM Stock GROUP BY 1,2) c ON c.ProductId=k.pid AND c.WarehouseId=k.wid
				LEFT JOIN _rt_snapstock s ON s.pid=k.pid AND s.wid=k.wid
				WHERE IFNULL(c.q,0) <> IFNULL(s.qty,0)`)
			if err != nil {
				return n, err
			}
			type sd struct {
				p, w int64
				dq   float64
			}
			var sds []sd
			for rows.Next() {
				var x sd
				rows.Scan(&x.p, &x.w, &x.dq)
				sds = append(sds, x)
			}
			rows.Close()
			for _, x := range sds {
				if err := d.synth("Stock", "S", 0, fmt.Sprintf("%d|%d", x.p, x.w), nil, x.dq); err != nil {
					return n, err
				}
				n++
			}
		case bigTables[sp.Name]:
			added, err := collect("SELECT rowid, NULL FROM "+t+" WHERE rowid NOT IN (SELECT id FROM _rt_snapids WHERE tbl=?)", sp.Name)
			if err != nil {
				return n, err
			}
			gone, err := collect("SELECT id, NULL FROM _rt_snapids WHERE tbl=? AND id NOT IN (SELECT rowid FROM "+t+")", sp.Name)
			if err != nil {
				return n, err
			}
			for _, h := range added {
				if err := d.synth(sp.Name, "I", h.rid, nil, nil, nil); err != nil {
					return n, err
				}
				n++
			}
			for _, h := range gone {
				if err := d.synth(sp.Name, "D", h.rid, nil, nil, nil); err != nil {
					return n, err
				}
				n++
			}
		default:
			s := qi(snapTable(sp.Name))
			added, err := collect("SELECT rowid, " + ti.keySelect("") + " FROM " + t + " WHERE rowid NOT IN (SELECT _rid FROM " + s + ")")
			if err != nil {
				return n, err
			}
			gone, err := collect("SELECT _rid, " + ti.keySelect("") + " FROM " + s + " WHERE _rid NOT IN (SELECT rowid FROM " + t + ")")
			if err != nil {
				return n, err
			}
			cols := make([]string, len(ti.Cols))
			for i, c := range ti.Cols {
				cols[i] = qi(c)
			}
			cl := strings.Join(cols, ",")
			changed, err := collect("SELECT x._rid, NULL FROM (SELECT rowid AS _rid, " + cl + " FROM " + t + " EXCEPT SELECT _rid, " + cl + " FROM " + s + ") x WHERE x._rid IN (SELECT _rid FROM " + s + ")")
			if err != nil {
				return n, err
			}
			for _, h := range added {
				if err := d.synth(sp.Name, "I", h.rid, h.keyv, nil, nil); err != nil {
					return n, err
				}
				n++
			}
			for _, h := range gone {
				if err := d.synth(sp.Name, "D", h.rid, h.keyv, nil, nil); err != nil {
					return n, err
				}
				n++
			}
			all := strings.Join(ti.syncCols(), ",") + ","
			for _, h := range changed {
				var keyv any
				if sp.Kind == KindFKKey {
					d.one("SELECT "+ti.keySelect("")+" FROM "+t+" WHERE rowid=?", h.rid).Scan(&keyv)
				}
				if err := d.synth(sp.Name, "U", h.rid, keyv, all, nil); err != nil {
					return n, err
				}
				n++
			}
		}
	}
	return n, nil
}

// TriggersOn reports whether the triggers are installed (per the engine's own record).
func (d *DB) TriggersOn() bool {
	v, _, _ := d.getMeta("triggers")
	return v == "on"
}

// Prune deletes this laptop's log rows the peer has applied (seq <= acked)
// and that are older than keepMs. Returns rows removed.
func (d *DB) Prune(acked int64, keepMs int64) (int64, error) {
	r, err := d.exec("DELETE FROM _rt_log WHERE seq <= ? AND hlc IS NOT NULL AND wall < ?", acked, time.Now().UnixMilli()-keepMs)
	if err != nil {
		return 0, err
	}
	return r.RowsAffected()
}

// MigrationCount is Aronium's applied migration count; it changes when an
// Aronium update migrates the database.
func (d *DB) MigrationCount() (int64, error) {
	var n int64
	err := d.one("SELECT count(*) FROM Migration").Scan(&n)
	return n, err
}

// MaxLocalID is the highest Id in a table (0 if empty); used for local-only
// tables such as ZReport.
func (d *DB) MaxLocalID(tbl string) (int64, error) {
	var n sql.NullInt64
	err := d.one("SELECT max(Id) FROM " + qi(tbl)).Scan(&n)
	return n.Int64, err
}

// Uninstall removes the triggers and every _rt_ table: pos.db goes back to
// plain Aronium. Used by the kill switch before one-writer sync resumes.
func (d *DB) Uninstall() error {
	if err := d.begin(false); err != nil {
		return err
	}
	if err := d.dropTriggers(); err != nil {
		d.rollback()
		return err
	}
	rows, err := d.query(`SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '\_rt\_%' ESCAPE '\'`)
	if err != nil {
		d.rollback()
		return err
	}
	var names []string
	for rows.Next() {
		var s string
		rows.Scan(&s)
		names = append(names, s)
	}
	rows.Close()
	for _, t := range names {
		if _, err := d.exec("DROP TABLE " + qi(t)); err != nil {
			d.rollback()
			return err
		}
	}
	_, err = d.exec("COMMIT")
	return err
}
