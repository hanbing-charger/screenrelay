package main

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"embed"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const version = "0.3.0"

//go:embed ui/index.html ui/style.css ui/app.js
var dashboard embed.FS

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

func run() error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	folder := flag.String("folder", filepath.Join(home, "ScreenRelay"), "directory for received captures")
	listen := flag.String("listen", "0.0.0.0:8765", "address for phone uploads")
	noOpen := flag.Bool("no-open", false, "do not open the dashboard in the browser")
	maxMiB := flag.Int64("max-mib", 2048, "maximum size of one upload, in MiB")
	cert := flag.String("tls-cert", "", "optional certificate PEM for the phone endpoint")
	key := flag.String("tls-key", "", "optional private key PEM for the phone endpoint")
	flag.Parse()

	if *maxMiB < 1 || *maxMiB > 65536 {
		return errors.New("-max-mib must be between 1 and 65536")
	}
	scheme := "http"
	var certificate tls.Certificate
	if *cert != "" || *key != "" {
		certificate, err = tls.LoadX509KeyPair(*cert, *key)
		if err != nil {
			return fmt.Errorf("load TLS certificate and key: %w", err)
		}
		scheme = "https"
	}

	if _, _, err := net.SplitHostPort(*listen); err != nil {
		return fmt.Errorf("invalid -listen: %w", err)
	}
	receiver, err := net.Listen("tcp4", *listen)
	if err != nil {
		return fmt.Errorf("start phone receiver: %w", err)
	}
	defer receiver.Close()

	store, err := loadStore(*folder)
	if err != nil {
		return fmt.Errorf("open receive folder: %w", err)
	}
	configDir, err := os.UserConfigDir()
	if err != nil {
		return fmt.Errorf("locate receiver configuration: %w", err)
	}
	configDir = filepath.Join(configDir, "ScreenRelay")
	if err := os.MkdirAll(configDir, 0o700); err != nil {
		return fmt.Errorf("open receiver configuration: %w", err)
	}
	token, err := pairingToken(configDir)
	if err != nil {
		return fmt.Errorf("load pairing code: %w", err)
	}
	pairings, err := loadPairings(filepath.Join(configDir, "paired-devices.json"))
	if err != nil {
		return fmt.Errorf("load paired devices: %w", err)
	}

	local, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return fmt.Errorf("start local dashboard: %w", err)
	}
	defer local.Close()

	service := &relay{
		store: store, token: token, pairings: pairings, maxBytes: *maxMiB << 20,
		uploads: make(chan struct{}, 4), scheme: scheme,
		listening: receiver.Addr().(*net.TCPAddr), dashboardHost: local.Addr().String(),
	}
	uploadServer := &http.Server{
		Handler: service.phoneAPI(), ReadHeaderTimeout: 8 * time.Second,
		ReadTimeout: uploadDuration, WriteTimeout: uploadDuration + time.Minute,
		IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16 << 10,
	}
	adminServer := &http.Server{
		Handler: service.dashboardAPI(), ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16 << 10,
	}
	if scheme == "https" {
		receiver = tls.NewListener(receiver, &tls.Config{
			MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{certificate},
		})
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	failures := make(chan error, 2)
	go func() { failures <- uploadServer.Serve(receiver) }()
	go func() { failures <- adminServer.Serve(local) }()

	dashboardURL := "http://" + service.dashboardHost
	fmt.Printf("截屏快传 %s\n电脑控制台  %s\n保存目录  %s\n", version, dashboardURL, store.root)
	for _, address := range advertiseAddresses(service.listening, scheme) {
		fmt.Println("手机端地址  " + address)
	}
	fmt.Println("配对二维码与手动配对码在控制台网页。按 Ctrl+C 可停止接收。")
	if !*noOpen {
		if err := openDesktop(dashboardURL, false); err != nil {
			log.Printf("无法自动打开浏览器，请手动打开上面的电脑控制台地址。 %v", err)
		}
	}

	select {
	case err := <-failures:
		return err
	case <-ctx.Done():
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	go adminServer.Shutdown(shutdown)
	if err := uploadServer.Shutdown(shutdown); err != nil {
		uploadServer.Close()
	}
	return adminServer.Close()
}

func pairingToken(dir string) (string, error) {
	path := filepath.Join(dir, "pairing-token")
	token, err := os.ReadFile(path)
	if err == nil {
		text := strings.TrimSpace(string(token))
		decoded, decodeErr := base64.RawURLEncoding.DecodeString(text)
		if decodeErr != nil || len(decoded) != 32 {
			return "", errors.New("invalid pairing-token file: " + path)
		}
		return text, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	text := newPairingSecret()
	if err := writeNewFile(path, []byte(text+"\n")); err != nil {
		if errors.Is(err, os.ErrExist) {
			return pairingToken(dir)
		}
		return "", err
	}
	return text, nil
}

func randBytes(size int) []byte {
	bytes := make([]byte, size)
	rand.Read(bytes)
	return bytes
}

func advertiseAddresses(listening *net.TCPAddr, scheme string) []string {
	port := strconv.Itoa(listening.Port)
	urlFor := func(ip net.IP) string { return scheme + "://" + net.JoinHostPort(ip.String(), port) }
	addresses := []string{}
	if listening.IP != nil && !listening.IP.IsUnspecified() {
		if !listening.IP.IsLoopback() {
			addresses = append(addresses, urlFor(listening.IP))
		}
		return addresses
	}
	interfaces, _ := net.Interfaces()
	var other []string
	for _, nic := range interfaces {
		if nic.Flags&net.FlagUp == 0 || nic.Flags&net.FlagLoopback != 0 {
			continue
		}
		networkAddresses, _ := nic.Addrs()
		for _, address := range networkAddresses {
			ip, _, err := net.ParseCIDR(address.String())
			if err != nil || ip.To4() == nil || !ip.IsGlobalUnicast() {
				continue
			}
			if ip.IsPrivate() {
				addresses = append(addresses, urlFor(ip))
			} else {
				other = append(other, urlFor(ip))
			}
		}
	}
	slices.Sort(addresses)
	slices.Sort(other)
	return slices.Compact(append(addresses, other...))
}

func openDesktop(target string, folder bool) error {
	var command *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		command = exec.Command("open", target)
	case "windows":
		if folder {
			command = exec.Command("explorer.exe", target)
		} else {
			command = exec.Command("rundll32.exe", "url.dll,FileProtocolHandler", target)
		}
	default:
		command = exec.Command("xdg-open", target)
	}
	if err := command.Start(); err != nil {
		return err
	}
	go command.Wait()
	return nil
}
