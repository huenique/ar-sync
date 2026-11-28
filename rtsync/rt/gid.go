package rt

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// Global ids:
//   KindID    "seed:<Id>" for rows that existed at seeding, else "<node>:<Id>"
//             with the Id the row had on the laptop that created it.
//   KindFKKey the key columns' parent gids joined with "|".
//   KindStock "<product gid>|<warehouse gid>".
// _rt_map holds rows this laptop received from the peer: gid -> local Id.

func (d *DB) seedMax(tbl string) (int64, error) { return d.metaInt("seed_max." + tbl) }

// gidOf turns a local Id into a global id.
func (d *DB) gidOf(tbl string, lid int64) (string, error) {
	var g string
	err := d.one("SELECT gid FROM _rt_map WHERE tbl=? AND lid=?", tbl, lid).Scan(&g)
	if err == nil {
		return g, nil
	}
	if err != sql.ErrNoRows {
		return "", err
	}
	sm, err := d.seedMax(tbl)
	if err != nil {
		return "", err
	}
	if lid <= sm {
		return "seed:" + strconv.FormatInt(lid, 10), nil
	}
	n, err := d.Node()
	if err != nil {
		return "", err
	}
	return n + ":" + strconv.FormatInt(lid, 10), nil
}

// resolve turns a global id into a local Id. ok=false when this laptop has no
// such row (never received, or the peer's insert hasn't arrived yet).
func (d *DB) resolve(tbl, gid string) (int64, bool, error) {
	origin, oid, err := splitGID(gid)
	if err != nil {
		return 0, false, err
	}
	n, err := d.Node()
	if err != nil {
		return 0, false, err
	}
	if origin == "seed" || origin == n {
		return oid, true, nil
	}
	var lid int64
	err = d.one("SELECT lid FROM _rt_map WHERE tbl=? AND gid=?", tbl, gid).Scan(&lid)
	if err == sql.ErrNoRows {
		return 0, false, nil
	}
	return lid, err == nil, err
}

func splitGID(g string) (string, int64, error) {
	i := strings.LastIndexByte(g, ':')
	if i <= 0 {
		return "", 0, fmt.Errorf("bad global id %q", g)
	}
	n, err := strconv.ParseInt(g[i+1:], 10, 64)
	if err != nil {
		return "", 0, fmt.Errorf("bad global id %q", g)
	}
	return g[:i], n, nil
}

// keyGID builds the global id of a KindFKKey or KindStock row from the local
// key values logged by the trigger ("12|3").
func (d *DB) keyGID(ti *tableInfo, keyv string) (string, error) {
	cols := ti.Spec.KeyCols
	if ti.Spec.Kind == KindStock {
		cols = []string{"ProductId", "WarehouseId"}
	}
	parts := strings.Split(keyv, "|")
	if len(parts) != len(cols) {
		return "", fmt.Errorf("%s: key %q does not match %v", ti.Spec.Name, keyv, cols)
	}
	out := make([]string, len(parts))
	for i, p := range parts {
		lid, err := strconv.ParseInt(p, 10, 64)
		if err != nil {
			return "", fmt.Errorf("%s: key %q: %w", ti.Spec.Name, keyv, err)
		}
		parent := ti.FKMap[cols[i]]
		if ti.Spec.Kind == KindStock {
			parent = map[string]string{"ProductId": "Product", "WarehouseId": "Warehouse"}[cols[i]]
		}
		if out[i], err = d.gidOf(parent, lid); err != nil {
			return "", err
		}
	}
	return strings.Join(out, "|"), nil
}

// resolveKey turns a key gid back into local key values. ok=false if a parent
// is missing here.
func (d *DB) resolveKey(ti *tableInfo, gid string) ([]int64, bool, error) {
	cols := ti.Spec.KeyCols
	parents := make([]string, 0, 2)
	if ti.Spec.Kind == KindStock {
		cols = []string{"ProductId", "WarehouseId"}
		parents = []string{"Product", "Warehouse"}
	} else {
		for _, c := range cols {
			parents = append(parents, ti.FKMap[c])
		}
	}
	parts := strings.Split(gid, "|")
	if len(parts) != len(cols) {
		return nil, false, fmt.Errorf("%s: bad key gid %q", ti.Spec.Name, gid)
	}
	out := make([]int64, len(parts))
	for i, p := range parts {
		lid, ok, err := d.resolve(parents[i], p)
		if err != nil || !ok {
			return nil, ok, err
		}
		out[i] = lid
	}
	return out, true, nil
}

// Seed marks this database as the common starting point for sync and names
// this laptop. Both laptops must be seeded from byte-identical copies; the
// seed tag lets them check that.
func (d *DB) Seed(node string) (string, error) {
	if node == "" || node == "seed" || strings.ContainsAny(node, ":|") {
		return "", fmt.Errorf("bad node name %q", node)
	}
	if err := d.ensureMeta(); err != nil {
		return "", err
	}
	if old, ok, _ := d.getMeta("node"); ok {
		return "", fmt.Errorf("already seeded as %q", old)
	}
	if err := d.begin(false); err != nil {
		return "", err
	}
	var parts []string
	for _, sp := range Replicated {
		ti := d.sch[sp.Name]
		if ti == nil || sp.Kind != KindID {
			continue
		}
		var mx, seq sql.NullInt64
		if err := d.one("SELECT max(Id) FROM " + qi(sp.Name)).Scan(&mx); err != nil {
			d.rollback()
			return "", err
		}
		d.one("SELECT seq FROM sqlite_sequence WHERE name=?", sp.Name).Scan(&seq)
		m := mx.Int64
		if seq.Int64 > m {
			m = seq.Int64
		}
		if err := d.setMeta("seed_max."+sp.Name, strconv.FormatInt(m, 10)); err != nil {
			d.rollback()
			return "", err
		}
		parts = append(parts, sp.Name+"="+strconv.FormatInt(m, 10))
	}
	sort.Strings(parts)
	sum := sha256.Sum256([]byte(strings.Join(parts, ";")))
	tag := hex.EncodeToString(sum[:8])
	for k, v := range map[string]string{"node": node, "seed_tag": tag, "hlc": "0"} {
		if err := d.setMeta(k, v); err != nil {
			d.rollback()
			return "", err
		}
	}
	// Snapshot now, so anything Aronium writes before the triggers first go on
	// is caught up by InstallTriggers.
	if err := d.takeSnapshot(); err != nil {
		d.rollback()
		return "", err
	}
	return tag, d.commit()
}
