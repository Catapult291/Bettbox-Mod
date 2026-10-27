package main

import (
	"encoding/json"
	"fmt"
	"net/netip"
	"testing"
	"time"

	"github.com/metacubex/mihomo/common/atomic"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"

	"github.com/gofrs/uuid/v5"
)

// 改前基线：statistic.Snapshot 全量 json.Marshal —— 即 handleGetConnections
// 改动前的 IPC 出口形态（downloadTotal/uploadTotal/memory + 全量连接，
// 每连接含 providerChains 与 metadata 全字段）。改后本文件追加
// count / lean 对照子基准。运行：
//
//	CGO_ENABLED=0 go test -tags=with_gvisor -bench=BenchmarkConnections -benchtime=2s -run=^$ .

// benchConnectionsSnapshot 构造 n 条连接的全量快照，字段形态贴近真实流量：
// 域名 + IP 双栈、geoip、进程路径、双层 chain、rule payload。
func benchConnectionsSnapshot(n int) *statistic.Snapshot {
	conns := make([]statistic.TrackerInfo, 0, n)
	for i := 0; i < n; i++ {
		u, err := uuid.NewV4()
		if err != nil {
			panic(err)
		}
		meta := &C.Metadata{
			NetWork:      C.TCP,
			Type:         C.SOCKS5,
			SrcIP:        netip.MustParseAddr("192.168.1.23"),
			DstIP:        netip.MustParseAddr("142.250.72.14"),
			SrcGeoIP:     []string{"LAN"},
			DstGeoIP:     []string{"US", "US-CA"},
			SrcIPASN:     "AS4134",
			DstIPASN:     "AS15169",
			SrcPort:      uint16(40000 + i%20000),
			DstPort:      443,
			InIP:         netip.MustParseAddr("127.0.0.1"),
			InPort:       7890,
			InName:       "mixed",
			Host:         fmt.Sprintf("cdn-%04d.example.com", i),
			DNSMode:      C.DNSNormal,
			Uid:          1000,
			Process:      "chrome.exe",
			ProcessPath:  `C:\Program Files\Google\Chrome\Application\chrome.exe`,
			RemoteDst:    "142.250.72.14:443",
			SniffHost:    fmt.Sprintf("sniff-%04d.example.com", i),
			RematchName:  "auto",
			SpecialRules: "",
			SpecialProxy: "",
		}
		conns = append(conns, statistic.TrackerInfo{
			UUID:          u,
			Metadata:      meta,
			UploadTotal:   atomic.NewInt64(int64(1024 + i)),
			DownloadTotal: atomic.NewInt64(int64(4096 + i)),
			Start:         time.Now().Add(-time.Duration(i) * time.Second),
			Chain:         C.Chain{"AUTO", "HK-01"},
			ProviderChain: C.Chain{"provider-sub-1", "node-a"},
			Rule:          "DomainSuffix",
			RulePayload:   "example.com",
		})
	}
	return &statistic.Snapshot{
		DownloadTotal: 1 << 30,
		UploadTotal:   1 << 28,
		Connections:   conns,
		Memory:        128 << 20,
	}
}

func benchConnectionsFull(b *testing.B, n int) {
	snapshot := benchConnectionsSnapshot(n)

	// 先量 payload，不计入 b.N。
	data, err := json.Marshal(snapshot)
	if err != nil {
		b.Fatalf("marshal snapshot: %v", err)
	}
	b.ReportMetric(float64(len(data)), "full_bytes")
	b.ReportMetric(float64(len(data))/float64(n), "full_bytes_per_conn")

	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_, _ = json.Marshal(snapshot)
	}
}

func BenchmarkConnectionsFull_100(b *testing.B)  { benchConnectionsFull(b, 100) }
func BenchmarkConnectionsFull_500(b *testing.B)  { benchConnectionsFull(b, 500) }
func BenchmarkConnectionsFull_1000(b *testing.B) { benchConnectionsFull(b, 1000) }

// 改后：handleGetConnections 的出口形态 = Manager.Connections() + 白名单序列化。
// count 走 Manager.Count()，不物化连接表。
//
// LeanMarshal 只量瘦身形态的序列化，用来和上面的 Full（同样只量序列化）对齐；
// LeanHandler 量真实的「收集 + 序列化」，与 FullHandler 同口径。
func benchConnectionsLeanMarshal(b *testing.B, n int) {
	lean := leanConnections(benchConnectionsSnapshot(n).Connections)

	data, err := json.Marshal(lean)
	if err != nil {
		b.Fatalf("marshal lean connections: %v", err)
	}
	b.ReportAllocs()
	b.ResetTimer()
	b.ReportMetric(float64(len(data)), "lean_bytes")
	b.ReportMetric(float64(len(data))/float64(n), "lean_bytes_per_conn")

	for i := 0; i < b.N; i++ {
		_, _ = json.Marshal(lean)
	}
}

func benchConnectionsFullHandler(b *testing.B, n int) {
	m := newFakeManager(n)

	data, err := json.Marshal(m.Snapshot())
	if err != nil {
		b.Fatalf("marshal snapshot: %v", err)
	}
	b.ReportAllocs()
	b.ResetTimer()
	b.ReportMetric(float64(len(data)), "full_bytes")
	b.ReportMetric(float64(len(data))/float64(n), "full_bytes_per_conn")

	for i := 0; i < b.N; i++ {
		_, _ = json.Marshal(m.Snapshot())
	}
}

func benchConnectionsLeanHandler(b *testing.B, n int) {
	m := newFakeManager(n)

	data, err := marshalConnectionsIPC(m.Connections())
	if err != nil {
		b.Fatalf("marshal lean connections: %v", err)
	}
	b.ReportAllocs()
	b.ResetTimer()
	b.ReportMetric(float64(len(data)), "lean_bytes")
	b.ReportMetric(float64(len(data))/float64(n), "lean_bytes_per_conn")

	for i := 0; i < b.N; i++ {
		_, _ = marshalConnectionsIPC(m.Connections())
	}
}

func benchConnectionsCount(b *testing.B, n int) {
	m := newFakeManager(n)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = m.Count()
	}
}

func BenchmarkConnectionsLean_100(b *testing.B)         { benchConnectionsLeanMarshal(b, 100) }
func BenchmarkConnectionsLean_500(b *testing.B)         { benchConnectionsLeanMarshal(b, 500) }
func BenchmarkConnectionsLean_1000(b *testing.B)        { benchConnectionsLeanMarshal(b, 1000) }
func BenchmarkConnectionsFullHandler_100(b *testing.B)  { benchConnectionsFullHandler(b, 100) }
func BenchmarkConnectionsFullHandler_1000(b *testing.B) { benchConnectionsFullHandler(b, 1000) }
func BenchmarkConnectionsLeanHandler_100(b *testing.B)  { benchConnectionsLeanHandler(b, 100) }
func BenchmarkConnectionsLeanHandler_1000(b *testing.B) { benchConnectionsLeanHandler(b, 1000) }
func BenchmarkConnectionsCount_100(b *testing.B)        { benchConnectionsCount(b, 100) }
func BenchmarkConnectionsCount_1000(b *testing.B)       { benchConnectionsCount(b, 1000) }
