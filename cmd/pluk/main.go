package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/kubestellar/pluk/pkg/classify"
	"github.com/kubestellar/pluk/pkg/events"
)

const defaultRunDir = "/var/run/pluk"
const defaultConfigDir = "/etc/pluk"

func main() {
	// Multi-call binary: detect if called as pluk-publish, pluk-subscribe, pluk-send
	base := filepath.Base(os.Args[0])
	switch base {
	case "pluk-publish":
		cmdPublish(os.Args[1:])
		return
	case "pluk-subscribe":
		cmdSubscribe(os.Args[1:])
		return
	case "pluk-send":
		cmdSend(os.Args[1:])
		return
	}

	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}

	switch os.Args[1] {
	case "publish":
		cmdPublish(os.Args[2:])
	case "subscribe":
		cmdSubscribe(os.Args[2:])
	case "send":
		cmdSend(os.Args[2:])
	case "version":
		fmt.Println("pluk 2.0.0 (go)")
	default:
		usage()
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "Usage: pluk <command> [options]")
	fmt.Fprintln(os.Stderr, "Commands: publish, subscribe, send, version")
}

func runDir() string {
	if d := os.Getenv("PLUK_RUN_DIR"); d != "" {
		return d
	}
	return defaultRunDir
}

func configDir() string {
	if d := os.Getenv("PLUK_CONFIG_DIR"); d != "" {
		return d
	}
	return defaultConfigDir
}

func patternsDir() string {
	if d := os.Getenv("PLUK_PATTERNS_DIR"); d != "" {
		return d
	}
	return filepath.Join(configDir(), "patterns.d")
}

func ensureDirs() {
	os.MkdirAll(filepath.Join(runDir(), "logs"), 0o1777)
	os.MkdirAll(filepath.Join(runDir(), "commands"), 0o1777)
}

// --- publish ---

func cmdPublish(args []string) {
	session := ""
	cli := "claude"
	pane := "0"
	noRaw := false

	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--session":
			i++
			if i < len(args) {
				session = args[i]
			}
		case "--cli":
			i++
			if i < len(args) {
				cli = args[i]
			}
		case "--pane":
			i++
			if i < len(args) {
				pane = args[i]
			}
		case "--no-raw":
			noRaw = true
		}
	}

	if session == "" {
		fmt.Fprintln(os.Stderr, "error: --session is required")
		os.Exit(1)
	}

	ensureDirs()

	logFile := filepath.Join(runDir(), "logs", session+".jsonl")
	f, err := os.OpenFile(logFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o666)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: cannot open log file: %s\n", err)
		os.Exit(1)
	}
	defer f.Close()

	patterns, err := classify.LoadPatterns(patternsDir(), cli)
	if err != nil {
		fmt.Fprintf(os.Stderr, "pluk: warning: no pattern file for cli=%s (%s)\n", cli, err)
		patterns = &classify.Patterns{CLI: cli}
	} else {
		fmt.Fprintf(os.Stderr, "pluk: loaded patterns for %s\n", cli)
	}

	classifier := classify.New(patterns, session, pane, "pipe-pane")
	source := "pipe-pane"
	_ = source

	fmt.Fprintf(os.Stderr, "pluk: publisher started: session=%s pane=%s cli=%s\n", session, pane, cli)

	scanner := bufio.NewScanner(os.Stdin)
	const maxLineSize = 64 * 1024
	scanner.Buffer(make([]byte, maxLineSize), maxLineSize)

	for scanner.Scan() {
		raw := scanner.Text()
		clean := classify.StripANSI(raw)
		if clean == "" {
			continue
		}

		// Classify the line
		if classified := classifier.Classify(clean); classified != nil {
			fmt.Fprintln(f, classified.JSON())
		}

		// Also emit raw_output unless suppressed
		if !noRaw {
			rawEvent := classifier.RawOutput(clean)
			fmt.Fprintln(f, rawEvent.JSON())
		}
	}
}

// --- subscribe ---

func cmdSubscribe(args []string) {
	session := ""
	filter := ""

	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		session = args[0]
		args = args[1:]
	}

	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--session":
			i++
			if i < len(args) {
				session = args[i]
			}
		case "--filter":
			i++
			if i < len(args) {
				filter = args[i]
			}
		}
	}

	if session == "" {
		fmt.Fprintln(os.Stderr, "error: session name is required")
		os.Exit(1)
	}

	logFile := filepath.Join(runDir(), "logs", session+".jsonl")

	// Wait for file to exist (timeout after 60s)
	const maxWaitSeconds = 60
	waited := 0
	fmt.Fprintf(os.Stderr, "pluk: waiting for %s ...\n", logFile)
	for {
		if _, err := os.Stat(logFile); err == nil {
			break
		}
		if waited >= maxWaitSeconds {
			fmt.Fprintf(os.Stderr, "pluk: timeout waiting for log file %s (waited %ds)\n", logFile, maxWaitSeconds)
			os.Exit(1)
		}
		time.Sleep(1 * time.Second)
		waited++
	}

	f, err := os.Open(logFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %s\n", err)
		os.Exit(1)
	}
	defer f.Close()

	// Seek to end for tail behavior
	f.Seek(0, io.SeekEnd)

	filterTypes := make(map[string]bool)
	if filter != "" {
		for _, t := range strings.Split(filter, ",") {
			filterTypes[strings.TrimSpace(t)] = true
		}
	}

	reader := bufio.NewReader(f)
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			// EOF — wait and retry (tail -f behavior)
			time.Sleep(500 * time.Millisecond)
			if _, statErr := f.Stat(); statErr != nil {
				return
			}
			continue
		}
		line = strings.TrimRight(line, "\n")
		if line == "" {
			continue
		}
		if len(filterTypes) > 0 {
			var e events.Event
			if json.Unmarshal([]byte(line), &e) == nil {
				if !filterTypes[e.Type] {
					continue
				}
			}
		}
		fmt.Println(line)
	}
}

// --- send ---

func cmdSend(args []string) {
	session := ""
	text := ""
	key := ""
	enter := false

	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--session":
			i++
			if i < len(args) {
				session = args[i]
			}
		case "--text":
			i++
			if i < len(args) {
				text = args[i]
			}
		case "--key":
			i++
			if i < len(args) {
				key = args[i]
			}
		case "--enter":
			enter = true
		}
	}

	if session == "" {
		fmt.Fprintln(os.Stderr, "error: --session is required")
		os.Exit(1)
	}

	if text == "" && key == "" && !enter {
		fmt.Fprintln(os.Stderr, "error: --text, --key, or --enter is required")
		os.Exit(1)
	}

	// Use tmux send-keys directly
	tmuxArgs := []string{"send-keys", "-t", session}

	if text != "" {
		tmuxArgs = append(tmuxArgs, "-l", text)
		if enter {
			tmuxArgs = append(tmuxArgs, "Enter")
		}
	} else if key != "" {
		tmuxArgs = append(tmuxArgs, key)
	} else if enter {
		tmuxArgs = append(tmuxArgs, "Enter")
	}

	// Find the right tmux socket
	socketArgs := findTmuxSocket(session)
	fullArgs := append(socketArgs, tmuxArgs...)

	cmd := exec.Command("tmux", fullArgs...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "error: tmux send-keys failed: %s\n", err)
		os.Exit(1)
	}

	// Log the command_received event
	ensureDirs()
	logFile := filepath.Join(runDir(), "logs", session+".jsonl")
	f, err := os.OpenFile(logFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o666)
	if err == nil {
		defer f.Close()
		classifier := classify.New(nil, session, "0", "cmd")
		e := classifier.CommandReceived(text, "pluk-send")
		fmt.Fprintln(f, e.JSON())
	}
}

func findTmuxSocket(session string) []string {
	// Check if a socket with the session name exists under /tmp/tmux-*
	matches, _ := filepath.Glob("/tmp/tmux-*/" + session)
	if len(matches) > 0 {
		return []string{"-L", session}
	}
	return nil
}
