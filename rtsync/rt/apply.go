package rt

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// ErrGap means a batch starts past the next seq this laptop expects from that
// peer; the sender must resend from LastSeq(origin)+1.
var ErrGap = errors.New("batch skips changes: resend from the last applied seq")

// ErrMismatch means the peer was seeded from a different copy or runs a
// different Aronium schema; nothing is applied.
var ErrMismatch = errors.New("peer seed or schema does not match")

// errMissingParent: a change refers to a row this laptop doesn't have and
// hasn't deleted. The whole batch rolls back and is retried later.
type errMissingParent struct{ tbl, gid string }

func (e errMissingParent) Error() string {
	return fmt.Sprintf("missing parent %s %s", e.tbl, e.gid)
}

// LastSeq is the last seq applied from a peer (0 if none).
func (d *DB) LastSeq(origin string) (int64, error) {
	var n int64
	err := d.one("SELECT last_seq FROM _rt_peer WHERE origin=?", origin).Scan(&n)
	if err == sql.ErrNoRows {
		return 0, nil
	}
	return n, err
}

// Apply writes a peer's batch in one short BEGIN IMMEDIATE transaction with the
// echo flag set, so the triggers don't log it again. It is idempotent: changes
// at or below the peer's last applied seq are skipped.
func (d *DB) Apply(b *Batch) (applied int, err error) {
	node, err := d.Node()
	if err != nil {
		return 0, err
	}
	tag, _, _ := d.getMeta("seed_tag")
	if b.SeedTag != tag || b.Schema != d.SchemaTag() {
		return 0, ErrMismatch
	}
	if b.Origin == node {
		return 0, fmt.Errorf("batch is from this laptop (%s)", node)
	}
	if err := d.begin(true); err != nil {
		return 0, err
	}
	defer func() {
		if err != nil {
			d.rollback()
		}
	}()
	if err = d.stamp(); err != nil {
		return 0, err
	}
	last, err := d.LastSeq(b.Origin)
	if err != nil {
		return 0, err
	}
	if b.To <= last {
		return 0, d.commit()
	}
	if b.From > last+1 {
		err = ErrGap
		return 0, err
	}
	for i := range b.Changes {
		c := &b.Changes[i]
		if c.Seq <= last {
			continue
		}
		if err = d.applyOne(b.Origin, c); err != nil {
			return applied, fmt.Errorf("seq %d %s %s %s: %w", c.Seq, c.Op, c.Table, c.GID, err)
		}
		applied++
	}
	if _, err = d.exec(`INSERT INTO _rt_peer(origin,last_seq) VALUES(?,?)
		ON CONFLICT(origin) DO UPDATE SET last_seq=excluded.last_seq`, b.Origin, b.To); err != nil {
		return applied, err
	}
	// Hybrid clock: never fall behind what the peer has seen.
	h, err := d.metaInt("hlc")
	if err != nil {
		return applied, err
	}
	if b.MaxHLC > h {
		if err = d.setMeta("hlc", fmt.Sprint(b.MaxHLC)); err != nil {
			return applied, err
		}
	}
	err = d.commit()
	return applied, err
}

func (d *DB) tombstoned(tbl, gid string) (bool, error) {
	var n int
	err := d.one("SELECT count(*) FROM _rt_tomb WHERE tbl=? AND gid=?", tbl, gid).Scan(&n)
	return n > 0, err
}

func (d *DB) conflict(tbl, gid, note string) {
	d.exec("INSERT INTO _rt_conflict(at,tbl,gid,note) VALUES(?,?,?,?)", time.Now().Unix(), tbl, gid, note)
}

func (d *DB) applyOne(origin string, c *Change) error {
	ti := d.sch[c.Table]
	if ti == nil {
		return fmt.Errorf("table %s does not sync here", c.Table)
	}
	switch c.Op {
	case "S":
		return d.applyStock(ti, c)
	case "D":
		return d.applyDelete(ti, origin, c)
	case "I", "U":
		if dead, err := d.tombstoned(c.Table, c.GID); err != nil || dead {
			return err
		}
		where, found, err := d.locate(ti, c.GID)
		if err != nil {
			return err
		}
		if found {
			return d.applyUpdate(ti, origin, c, where)
		}
		if c.Op == "U" {
			return nil // row gone here (deleted locally, or never received): nothing to edit
		}
		return d.applyInsert(ti, origin, c)
	}
	return fmt.Errorf("unknown op %q", c.Op)
}

// rowRef identifies a local row for UPDATE/DELETE.
type rowRef struct {
	sql  string
	args []any
}

// locate finds the local row for a gid. found=false when it doesn't exist here.
func (d *DB) locate(ti *tableInfo, gid string) (rowRef, bool, error) {
	var ref rowRef
	if ti.Spec.Kind == KindID {
		lid, ok, err := d.resolve(ti.Spec.Name, gid)
		if err != nil || !ok {
			return ref, false, err
		}
		ref = rowRef{"Id=?", []any{lid}}
	} else {
		keys, ok, err := d.resolveKey(ti, gid)
		if err != nil || !ok {
			return ref, false, err
		}
		var w []string
		var a []any
		for i, k := range ti.Spec.KeyCols {
			w = append(w, qi(k)+"=?")
			a = append(a, keys[i])
		}
		ref = rowRef{strings.Join(w, " AND "), a}
	}
	var n int
	if err := d.one("SELECT count(*) FROM "+qi(ti.Spec.Name)+" WHERE "+ref.sql, ref.args...).Scan(&n); err != nil {
		return ref, false, err
	}
	return ref, n > 0, nil
}

// localValue converts a sent value to what this laptop stores, mapping
// foreign keys. skip=true: the parent was deleted here, drop the change.
func (d *DB) localValue(ti *tableInfo, col string, v Value) (any, bool, error) {
	if v.G == nil {
		return v.raw(), false, nil
	}
	parent := ti.FKMap[col]
	if parent == "" {
		return nil, false, fmt.Errorf("%s.%s is not a synced foreign key here", ti.Spec.Name, col)
	}
	lid, ok, err := d.resolve(parent, *v.G)
	if err != nil {
		return nil, false, err
	}
	if ok {
		var n int
		if err := d.one("SELECT count(*) FROM "+qi(parent)+" WHERE Id=?", lid).Scan(&n); err != nil {
			return nil, false, err
		}
		ok = n > 0
	}
	if !ok {
		dead, err := d.tombstoned(parent, *v.G)
		if err != nil {
			return nil, false, err
		}
		if dead {
			return nil, true, nil
		}
		return nil, false, errMissingParent{parent, *v.G}
	}
	return lid, false, nil
}

func (d *DB) applyInsert(ti *tableInfo, origin string, c *Change) error {
	var cols, marks []string
	var args []any
	for _, col := range ti.syncCols() {
		v, present := c.Vals[col]
		if !present {
			continue
		}
		lv, skip, err := d.localValue(ti, col, v)
		if err != nil {
			return err
		}
		if skip {
			// A parent was deleted here: this row can't exist. Remember it as deleted.
			_, err := d.exec("INSERT OR IGNORE INTO _rt_tomb(tbl,gid,hlc,node) VALUES(?,?,?,?)", c.Table, c.GID, c.HLC, origin)
			return err
		}
		cols = append(cols, qi(col))
		marks = append(marks, "?")
		args = append(args, lv)
	}
	if _, err := d.exec("INSERT INTO "+qi(ti.Spec.Name)+" ("+strings.Join(cols, ",")+") VALUES ("+strings.Join(marks, ",")+")", args...); err != nil {
		return err
	}
	if ti.Spec.Kind == KindID {
		var lid int64
		if err := d.one("SELECT last_insert_rowid()").Scan(&lid); err != nil {
			return err
		}
		if _, err := d.exec("INSERT INTO _rt_map(tbl,gid,lid) VALUES(?,?,?)", c.Table, c.GID, lid); err != nil {
			return err
		}
	}
	for col := range c.Vals {
		if err := d.putVer(c.Table, c.GID, col, c.HLC, origin); err != nil {
			return err
		}
	}
	return nil
}

// applyUpdate sets each column whose sent version beats the local one.
func (d *DB) applyUpdate(ti *tableInfo, origin string, c *Change, where rowRef) error {
	var sets []string
	var args []any
	for col, v := range c.Vals {
		if !ti.HasCol[col] || ti.Spec.isLocalCol(col) || (ti.Spec.Kind == KindID && col == "Id") {
			continue
		}
		h, n, err := d.getVer(c.Table, c.GID, col)
		if err != nil {
			return err
		}
		if cmpVer(c.HLC, origin, h, n) <= 0 {
			continue // the local value is newer: last writer wins
		}
		lv, skip, err := d.localValue(ti, col, v)
		if err != nil {
			return err
		}
		if skip {
			continue
		}
		sets = append(sets, qi(col)+"=?")
		args = append(args, lv)
		if err := d.putVer(c.Table, c.GID, col, c.HLC, origin); err != nil {
			return err
		}
	}
	if len(sets) == 0 {
		return nil
	}
	args = append(args, where.args...)
	_, err := d.exec("UPDATE "+qi(ti.Spec.Name)+" SET "+strings.Join(sets, ",")+" WHERE "+where.sql, args...)
	return err
}

func (d *DB) applyDelete(ti *tableInfo, origin string, c *Change) error {
	if _, err := d.exec(`INSERT INTO _rt_tomb(tbl,gid,hlc,node) VALUES(?,?,?,?)
		ON CONFLICT(tbl,gid) DO UPDATE SET hlc=excluded.hlc, node=excluded.node WHERE excluded.hlc > _rt_tomb.hlc`,
		c.Table, c.GID, c.HLC, origin); err != nil {
		return err
	}
	where, found, err := d.locate(ti, c.GID)
	if err != nil || !found {
		return err
	}
	// Delete wins over edits; note it when this laptop edited the row later.
	var newer int
	d.one("SELECT count(*) FROM _rt_ver WHERE tbl=? AND gid=? AND hlc>?", c.Table, c.GID, c.HLC).Scan(&newer)
	if newer > 0 {
		d.conflict(c.Table, c.GID, "deleted on "+origin+" after a later edit here; delete kept")
	}
	if ti.Spec.SoftDelete && ti.HasCol["IsEnabled"] {
		_, err = d.exec("UPDATE "+qi(ti.Spec.Name)+" SET IsEnabled=0 WHERE "+where.sql, where.args...)
		return err
	}
	_, err = d.exec("DELETE FROM "+qi(ti.Spec.Name)+" WHERE "+where.sql, where.args...)
	return err
}

func (d *DB) applyStock(ti *tableInfo, c *Change) error {
	keys, ok, err := d.resolveKey(ti, c.GID)
	if err != nil {
		return err
	}
	if !ok {
		// Product deleted here (or never arrived): a delta for it has nowhere to go.
		parts := strings.SplitN(c.GID, "|", 2)
		if dead, _ := d.tombstoned("Product", parts[0]); dead {
			return nil
		}
		return errMissingParent{"Product", parts[0]}
	}
	res, err := d.exec("UPDATE Stock SET Quantity = Quantity + ? WHERE ProductId=? AND WarehouseId=?", c.Delta, keys[0], keys[1])
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		_, err = d.exec("INSERT INTO Stock(ProductId,WarehouseId,Quantity) VALUES(?,?,?)", keys[0], keys[1], c.Delta)
	}
	return err
}
