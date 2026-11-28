package rt

import (
	"context"
	"database/sql"
	"fmt"
	"net/url"
	"strconv"
	"strings"

	_ "modernc.org/sqlite"
)

// DB is one laptop's pos.db with the sync tables in it.
type DB struct {
	Path string
	sql  *sql.DB
	conn *sql.Conn
	ctx  context.Context
	sch  map[string]*tableInfo
}

type fkInfo struct{ Col, Parent string }

type tableInfo struct {
	Spec    *TableSpec
	Cols    []string // all columns in table order
	PK      []string
	FKs     []fkInfo // FK columns that point at replicated tables
	FKMap   map[string]string
	HasCol  map[string]bool
	HasDate bool // has DateUpdated
}

// Open opens pos.db with foreign keys on (as Aronium does) and a 5 s busy
// timeout, on a single connection so BEGIN IMMEDIATE and the echo flag share it.
func Open(path string) (*DB, error) {
	q := url.Values{}
	q.Add("_pragma", "busy_timeout(5000)")
	q.Add("_pragma", "foreign_keys(1)")
	dsn := "file:" + path + "?" + q.Encode()
	s, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	s.SetMaxOpenConns(1)
	ctx := context.Background()
	c, err := s.Conn(ctx)
	if err != nil {
		s.Close()
		return nil, err
	}
	d := &DB{Path: path, sql: s, conn: c, ctx: ctx}
	if err := d.loadSchema(); err != nil {
		d.Close()
		return nil, err
	}
	return d, nil
}

// Close releases the connection.
func (d *DB) Close() error {
	if d.conn != nil {
		d.conn.Close()
	}
	return d.sql.Close()
}

func (d *DB) exec(q string, args ...any) (sql.Result, error) {
	return d.conn.ExecContext(d.ctx, q, args...)
}

func (d *DB) query(q string, args ...any) (*sql.Rows, error) {
	return d.conn.QueryContext(d.ctx, q, args...)
}

func (d *DB) one(q string, args ...any) *sql.Row {
	return d.conn.QueryRowContext(d.ctx, q, args...)
}

func qi(name string) string { return "[" + strings.ReplaceAll(name, "]", "]]") + "]" }

func (d *DB) loadSchema() error {
	d.sch = map[string]*tableInfo{}
	for i := range Replicated {
		sp := &Replicated[i]
		ti := &tableInfo{Spec: sp, FKMap: map[string]string{}, HasCol: map[string]bool{}}
		rows, err := d.query("SELECT name, pk FROM pragma_table_info(?) ORDER BY cid", sp.Name)
		if err != nil {
			return err
		}
		type pkc struct {
			n string
			k int
		}
		var pks []pkc
		for rows.Next() {
			var n string
			var pk int
			if err := rows.Scan(&n, &pk); err != nil {
				rows.Close()
				return err
			}
			ti.Cols = append(ti.Cols, n)
			ti.HasCol[n] = true
			if pk > 0 {
				pks = append(pks, pkc{n, pk})
			}
		}
		rows.Close()
		if len(ti.Cols) == 0 {
			continue // table absent in this Aronium version
		}
		for k := 1; k <= len(pks); k++ {
			for _, p := range pks {
				if p.k == k {
					ti.PK = append(ti.PK, p.n)
				}
			}
		}
		ti.HasDate = ti.HasCol["DateUpdated"]
		frows, err := d.query(`SELECT "from", "table" FROM pragma_foreign_key_list(?)`, sp.Name)
		if err != nil {
			return err
		}
		for frows.Next() {
			var col, parent string
			if err := frows.Scan(&col, &parent); err != nil {
				frows.Close()
				return err
			}
			if _, dup := ti.FKMap[col]; dup {
				continue
			}
			if SpecByName(parent) == nil || sp.isLocalCol(col) {
				continue // FK into a local table (ZReport) or a local column
			}
			ti.FKMap[col] = parent
			ti.FKs = append(ti.FKs, fkInfo{col, parent})
		}
		frows.Close()
		d.sch[sp.Name] = ti
	}
	return nil
}

// syncCols are the columns of a table that travel: everything except the
// integer Id of a KindID table and local-only columns.
func (ti *tableInfo) syncCols() []string {
	var out []string
	for _, c := range ti.Cols {
		if ti.Spec.Kind == KindID && c == "Id" {
			continue
		}
		if ti.Spec.isLocalCol(c) {
			continue
		}
		out = append(out, c)
	}
	return out
}

const metaDDL = `
CREATE TABLE IF NOT EXISTS _rt_meta(k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE IF NOT EXISTS _rt_log(seq INTEGER PRIMARY KEY AUTOINCREMENT, tbl TEXT NOT NULL, op TEXT NOT NULL,
  rid INTEGER, keyv TEXT, cols TEXT, delta REAL, wall INTEGER NOT NULL, hlc INTEGER);
CREATE TABLE IF NOT EXISTS _rt_ctx(a INTEGER);
CREATE TABLE IF NOT EXISTS _rt_map(tbl TEXT NOT NULL, gid TEXT NOT NULL, lid INTEGER NOT NULL,
  PRIMARY KEY(tbl, gid), UNIQUE(tbl, lid));
CREATE TABLE IF NOT EXISTS _rt_ver(tbl TEXT NOT NULL, gid TEXT NOT NULL, col TEXT NOT NULL, hlc INTEGER NOT NULL, node TEXT NOT NULL,
  PRIMARY KEY(tbl, gid, col));
CREATE TABLE IF NOT EXISTS _rt_tomb(tbl TEXT NOT NULL, gid TEXT NOT NULL, hlc INTEGER NOT NULL, node TEXT NOT NULL,
  PRIMARY KEY(tbl, gid));
CREATE TABLE IF NOT EXISTS _rt_peer(origin TEXT PRIMARY KEY, last_seq INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS _rt_snapids(tbl TEXT NOT NULL, id INTEGER NOT NULL, PRIMARY KEY(tbl, id)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS _rt_snapstock(pid INTEGER NOT NULL, wid INTEGER NOT NULL, qty REAL NOT NULL, PRIMARY KEY(pid, wid));
CREATE TABLE IF NOT EXISTS _rt_conflict(at INTEGER NOT NULL, tbl TEXT, gid TEXT, note TEXT);
`

func (d *DB) ensureMeta() error {
	_, err := d.exec(metaDDL)
	return err
}

func (d *DB) getMeta(k string) (string, bool, error) {
	var v sql.NullString
	err := d.one("SELECT v FROM _rt_meta WHERE k=?", k).Scan(&v)
	if err == sql.ErrNoRows {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return v.String, true, nil
}

func (d *DB) setMeta(k, v string) error {
	_, err := d.exec("INSERT INTO _rt_meta(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", k, v)
	return err
}

func (d *DB) metaInt(k string) (int64, error) {
	v, ok, err := d.getMeta(k)
	if err != nil || !ok || v == "" {
		return 0, err
	}
	return strconv.ParseInt(v, 10, 64)
}

// Node is this laptop's name in global ids.
func (d *DB) Node() (string, error) {
	n, ok, err := d.getMeta("node")
	if err != nil {
		return "", err
	}
	if !ok {
		return "", fmt.Errorf("database is not seeded for real-time sync")
	}
	return n, nil
}

// begin starts a write transaction that peers' changes and stamping run in.
// echo=true sets the flag the triggers check, so applied rows are not logged.
func (d *DB) begin(echo bool) error {
	if _, err := d.exec("BEGIN IMMEDIATE"); err != nil {
		return err
	}
	if echo {
		if _, err := d.exec("INSERT INTO _rt_ctx(a) VALUES(1)"); err != nil {
			d.exec("ROLLBACK")
			return err
		}
	}
	return nil
}

func (d *DB) commit() error {
	if _, err := d.exec("DELETE FROM _rt_ctx"); err != nil {
		d.exec("ROLLBACK")
		return err
	}
	_, err := d.exec("COMMIT")
	return err
}

func (d *DB) rollback() { d.exec("ROLLBACK") }
