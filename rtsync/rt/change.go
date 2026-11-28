package rt

import (
	"database/sql"
	"fmt"
	"strings"
)

// Value is one column value. Exactly one field is set; G marks a foreign key
// carried as a global id. Typed fields keep blobs, integers and text apart
// through JSON.
type Value struct {
	Null bool     `json:"n,omitempty"`
	I    *int64   `json:"i,omitempty"`
	F    *float64 `json:"f,omitempty"`
	S    *string  `json:"s,omitempty"`
	B    []byte   `json:"b,omitempty"`
	G    *string  `json:"g,omitempty"`
}

func valueOf(v any) Value {
	switch x := v.(type) {
	case nil:
		return Value{Null: true}
	case int64:
		return Value{I: &x}
	case float64:
		return Value{F: &x}
	case string:
		return Value{S: &x}
	case []byte:
		if x == nil {
			x = []byte{}
		}
		return Value{B: x}
	case bool:
		var i int64
		if x {
			i = 1
		}
		return Value{I: &i}
	}
	s := fmt.Sprint(v)
	return Value{S: &s}
}

func (v Value) raw() any {
	switch {
	case v.I != nil:
		return *v.I
	case v.F != nil:
		return *v.F
	case v.S != nil:
		return *v.S
	case v.B != nil:
		return v.B
	}
	return nil
}

// Change is one logged change, ready to send.
type Change struct {
	Seq   int64            `json:"seq"`
	HLC   int64            `json:"hlc"`
	Table string           `json:"t"`
	Op    string           `json:"op"` // I insert, U update, D delete, S stock delta
	GID   string           `json:"gid"`
	Vals  map[string]Value `json:"v,omitempty"`
	Delta float64          `json:"d,omitempty"`
}

// Batch is a run of one laptop's changes, seq From..To inclusive. To can be
// past the last Change when trailing log rows had nothing to send.
type Batch struct {
	Origin  string   `json:"origin"`
	SeedTag string   `json:"seed"`
	Schema  string   `json:"schema"`
	From    int64    `json:"from"`
	To      int64    `json:"to"`
	MaxHLC  int64    `json:"maxhlc"`
	Changes []Change `json:"changes"`
}

// hlc layout: wall milliseconds << 12 | counter.
const hlcShift = 12

func cmpVer(h1 int64, n1 string, h2 int64, n2 string) int {
	switch {
	case h1 < h2:
		return -1
	case h1 > h2:
		return 1
	}
	return strings.Compare(n1, n2)
}

// stamp gives every new local log row a hybrid logical clock value and records
// the column versions and tombstones of this laptop's own edits. Runs inside
// the caller's transaction, before any peer change is compared against them.
func (d *DB) stamp() error {
	node, err := d.Node()
	if err != nil {
		return err
	}
	last, err := d.metaInt("hlc")
	if err != nil {
		return err
	}
	type row struct {
		seq, wall int64
		tbl, op   string
		rid       sql.NullInt64
		keyv      sql.NullString
		cols      sql.NullString
	}
	rows, err := d.query("SELECT seq,tbl,op,rid,keyv,cols,wall FROM _rt_log WHERE hlc IS NULL ORDER BY seq")
	if err != nil {
		return err
	}
	var todo []row
	for rows.Next() {
		var r row
		if err := rows.Scan(&r.seq, &r.tbl, &r.op, &r.rid, &r.keyv, &r.cols, &r.wall); err != nil {
			rows.Close()
			return err
		}
		todo = append(todo, r)
	}
	rows.Close()
	for _, r := range todo {
		h := r.wall << hlcShift
		if h <= last {
			h = last + 1
		}
		last = h
		if _, err := d.exec("UPDATE _rt_log SET hlc=? WHERE seq=?", h, r.seq); err != nil {
			return err
		}
		ti := d.sch[r.tbl]
		if ti == nil || r.op == "S" {
			continue
		}
		gid, err := d.logGID(ti, r.rid.Int64, r.keyv.String)
		if err != nil {
			return err
		}
		switch r.op {
		case "I":
			for _, c := range ti.syncCols() {
				if err := d.putVer(r.tbl, gid, c, h, node); err != nil {
					return err
				}
			}
		case "U":
			for _, c := range strings.Split(strings.TrimSuffix(r.cols.String, ","), ",") {
				if c == "" {
					continue
				}
				if err := d.putVer(r.tbl, gid, c, h, node); err != nil {
					return err
				}
			}
		case "D":
			if _, err := d.exec(`INSERT INTO _rt_tomb(tbl,gid,hlc,node) VALUES(?,?,?,?)
				ON CONFLICT(tbl,gid) DO UPDATE SET hlc=excluded.hlc, node=excluded.node WHERE excluded.hlc > _rt_tomb.hlc`,
				r.tbl, gid, h, node); err != nil {
				return err
			}
		}
	}
	return d.setMeta("hlc", fmt.Sprint(last))
}

func (d *DB) logGID(ti *tableInfo, rid int64, keyv string) (string, error) {
	if ti.Spec.Kind == KindID {
		return d.gidOf(ti.Spec.Name, rid)
	}
	return d.keyGID(ti, keyv)
}

// putVer records (hlc,node) as the column's version if it is newer.
func (d *DB) putVer(tbl, gid, col string, h int64, node string) error {
	_, err := d.exec(`INSERT INTO _rt_ver(tbl,gid,col,hlc,node) VALUES(?,?,?,?,?)
		ON CONFLICT(tbl,gid,col) DO UPDATE SET hlc=excluded.hlc, node=excluded.node
		WHERE excluded.hlc > _rt_ver.hlc OR (excluded.hlc = _rt_ver.hlc AND excluded.node > _rt_ver.node)`,
		tbl, gid, col, h, node)
	return err
}

func (d *DB) getVer(tbl, gid, col string) (int64, string, error) {
	var h int64
	var n string
	err := d.one("SELECT hlc,node FROM _rt_ver WHERE tbl=? AND gid=? AND col=?", tbl, gid, col).Scan(&h, &n)
	if err == sql.ErrNoRows {
		return 0, "", nil
	}
	return h, n, err
}
