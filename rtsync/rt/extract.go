package rt

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"fmt"
	"strings"
)

// SchemaTag fingerprints the synced tables' columns. Both laptops must agree
// before they exchange changes (an Aronium update on one side changes it).
func (d *DB) SchemaTag() string {
	var b strings.Builder
	for _, sp := range Replicated {
		if ti := d.sch[sp.Name]; ti != nil {
			b.WriteString(sp.Name + "(" + strings.Join(ti.Cols, ",") + ");")
		}
	}
	s := sha256.Sum256([]byte(b.String()))
	return hex.EncodeToString(s[:8])
}

// Extract stamps new local changes and returns those after seq `since`, at
// most `limit` log rows. Rows deleted since they were logged are skipped (the
// delete itself follows).
func (d *DB) Extract(since int64, limit int) (*Batch, error) {
	node, err := d.Node()
	if err != nil {
		return nil, err
	}
	tag, _, _ := d.getMeta("seed_tag")
	if err := d.begin(false); err != nil {
		return nil, err
	}
	if err := d.stamp(); err != nil {
		d.rollback()
		return nil, err
	}
	if err := d.commit(); err != nil {
		return nil, err
	}
	b := &Batch{Origin: node, SeedTag: tag, Schema: d.SchemaTag(), From: since + 1, To: since}
	rows, err := d.query("SELECT seq,tbl,op,rid,keyv,cols,delta,hlc FROM _rt_log WHERE seq>? AND hlc IS NOT NULL ORDER BY seq LIMIT ?", since, limit)
	if err != nil {
		return nil, err
	}
	type lr struct {
		seq, hlc int64
		tbl, op  string
		rid      sql.NullInt64
		keyv     sql.NullString
		cols     sql.NullString
		delta    sql.NullFloat64
	}
	var lrs []lr
	for rows.Next() {
		var r lr
		if err := rows.Scan(&r.seq, &r.tbl, &r.op, &r.rid, &r.keyv, &r.cols, &r.delta, &r.hlc); err != nil {
			rows.Close()
			return nil, err
		}
		lrs = append(lrs, r)
	}
	rows.Close()
	for _, r := range lrs {
		b.To = r.seq
		if r.hlc > b.MaxHLC {
			b.MaxHLC = r.hlc
		}
		ti := d.sch[r.tbl]
		if ti == nil {
			continue
		}
		c := Change{Seq: r.seq, HLC: r.hlc, Table: r.tbl, Op: r.op}
		switch r.op {
		case "S":
			if c.GID, err = d.keyGID(ti, r.keyv.String); err != nil {
				return nil, err
			}
			c.Delta = r.delta.Float64
			if c.Delta == 0 {
				continue
			}
		case "D":
			if c.GID, err = d.logGID(ti, r.rid.Int64, r.keyv.String); err != nil {
				return nil, err
			}
		case "I", "U":
			if c.GID, err = d.logGID(ti, r.rid.Int64, r.keyv.String); err != nil {
				return nil, err
			}
			cols := ti.syncCols()
			if r.op == "U" {
				cols = nil
				for _, x := range strings.Split(strings.TrimSuffix(r.cols.String, ","), ",") {
					if x != "" && ti.HasCol[x] && !ti.Spec.isLocalCol(x) {
						cols = append(cols, x)
					}
				}
			}
			vals, found, err := d.readRow(ti, r.rid.Int64, cols)
			if err != nil {
				return nil, err
			}
			if !found || len(vals) == 0 {
				continue
			}
			c.Vals = vals
		default:
			return nil, fmt.Errorf("log %d: unknown op %q", r.seq, r.op)
		}
		b.Changes = append(b.Changes, c)
	}
	return b, nil
}

// readRow reads columns of one row by rowid, with foreign keys as global ids.
func (d *DB) readRow(ti *tableInfo, rowid int64, cols []string) (map[string]Value, bool, error) {
	if len(cols) == 0 {
		return nil, true, nil
	}
	sel := make([]string, len(cols))
	for i, c := range cols {
		sel[i] = qi(c)
	}
	rows, err := d.query("SELECT "+strings.Join(sel, ",")+" FROM "+qi(ti.Spec.Name)+" WHERE rowid=?", rowid)
	if err != nil {
		return nil, false, err
	}
	defer rows.Close()
	if !rows.Next() {
		return nil, false, rows.Err()
	}
	raw := make([]any, len(cols))
	ptr := make([]any, len(cols))
	for i := range raw {
		ptr[i] = &raw[i]
	}
	if err := rows.Scan(ptr...); err != nil {
		return nil, false, err
	}
	rows.Close()
	out := make(map[string]Value, len(cols))
	for i, c := range cols {
		if parent, isFK := ti.FKMap[c]; isFK && raw[i] != nil {
			lid, ok := toInt(raw[i])
			if !ok {
				return nil, false, fmt.Errorf("%s.%s: non-integer key %v", ti.Spec.Name, c, raw[i])
			}
			g, err := d.gidOf(parent, lid)
			if err != nil {
				return nil, false, err
			}
			out[c] = Value{G: &g}
			continue
		}
		out[c] = valueOf(raw[i])
	}
	return out, true, nil
}

func toInt(v any) (int64, bool) {
	switch x := v.(type) {
	case int64:
		return x, true
	case float64:
		return int64(x), x == float64(int64(x))
	}
	return 0, false
}
