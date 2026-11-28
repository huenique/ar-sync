// Command arsync-rt is the real-time sync sidecar for Aronium Lite.
//
//	arsync-rt seed   -db pos.db -node A      mark a database as the common start
//	arsync-rt run    -config rt.json         run the sidecar
//	arsync-rt status -config rt.json         print sync state as JSON
//	arsync-rt kill   -config rt.json [-both] turn real-time sync off (one-writer sync resumes)
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/signal"
	"path/filepath"

	"github.com/huenique/ar-sync/rtsync/node"
	"github.com/huenique/ar-sync/rtsync/rt"
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	var err error
	switch os.Args[1] {
	case "seed":
		err = seed(os.Args[2:])
	case "run":
		err = run(os.Args[2:])
	case "status":
		err = status(os.Args[2:])
	case "kill":
		err = kill(os.Args[2:])
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "arsync-rt:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: arsync-rt seed -db PATH -node NAME | run -config FILE | status -config FILE | kill -config FILE [-both]")
	os.Exit(2)
}

func seed(args []string) error {
	fs := flag.NewFlagSet("seed", flag.ExitOnError)
	db := fs.String("db", "", "pos.db")
	name := fs.String("node", "", "this laptop's node name (A or B)")
	fs.Parse(args)
	e, err := rt.Open(*db)
	if err != nil {
		return err
	}
	defer e.Close()
	tag, err := e.Seed(*name)
	if err != nil {
		return err
	}
	fmt.Println("seeded", *name, "seed tag", tag)
	return nil
}

func loadConfig(path string) (node.Config, error) {
	var c node.Config
	raw, err := os.ReadFile(path)
	if err != nil {
		return c, err
	}
	return c, json.Unmarshal(raw, &c)
}

func run(args []string) error {
	fs := flag.NewFlagSet("run", flag.ExitOnError)
	cfgPath := fs.String("config", "", "config file")
	logPath := fs.String("log", "", "log file (default stderr)")
	fs.Parse(args)
	cfg, err := loadConfig(*cfgPath)
	if err != nil {
		return err
	}
	var w io.Writer = os.Stderr
	if *logPath != "" {
		f, err := os.OpenFile(*logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
		if err != nil {
			return err
		}
		defer f.Close()
		w = f
	}
	lg := log.New(w, cfg.Node+" ", log.LstdFlags)
	n, err := node.New(cfg, lg)
	if err != nil {
		return err
	}
	defer n.Close()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	lg.Printf("started; listening on %s; peer %s at %v", cfg.Listen, cfg.Peer, cfg.PeerURLs)
	err = n.Run(ctx)
	if err == context.Canceled {
		return nil
	}
	return err
}

func status(args []string) error {
	fs := flag.NewFlagSet("status", flag.ExitOnError)
	cfgPath := fs.String("config", "", "config file")
	fs.Parse(args)
	cfg, err := loadConfig(*cfgPath)
	if err != nil {
		return err
	}
	e, err := rt.Open(cfg.DBPath)
	if err != nil {
		return err
	}
	defer e.Close()
	last, _ := e.LastSeq(cfg.Peer)
	ack, _ := e.GetMeta("ack." + cfg.Peer)
	out := map[string]any{"node": cfg.Node, "seed": e.SeedTag(), "schema": e.SchemaTag(),
		"triggersOn": e.TriggersOn(), "appliedFromPeer": last, "peerAcked": ack}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(out)
}

// kill drops a kill file. The running sidecar does one last exchange, removes
// its triggers and tables from pos.db, and stays idle. With -both, the file goes
// in the shared folder and both laptops stop.
func kill(args []string) error {
	fs := flag.NewFlagSet("kill", flag.ExitOnError)
	cfgPath := fs.String("config", "", "config file")
	both := fs.Bool("both", false, "stop both laptops (shared-folder kill file)")
	fs.Parse(args)
	cfg, err := loadConfig(*cfgPath)
	if err != nil {
		return err
	}
	files := node.KillPaths(cfg)
	target := files[0]
	if *both {
		if len(files) < 2 {
			return fmt.Errorf("no shared folder configured")
		}
		target = files[1]
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
	}
	if err := os.WriteFile(target, []byte("real-time sync turned off\n"), 0o644); err != nil {
		return err
	}
	fmt.Println("kill file written:", target)
	return nil
}
