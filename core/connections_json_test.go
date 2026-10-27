package main

import (
	"encoding/json"
	"sort"
	"strings"
	"testing"

	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

// fakeConnectionTracker 让测试与基准可以直接往零值 Manager 里塞连接，
// 不需要真实隧道。
type fakeConnectionTracker struct {
	info *statistic.TrackerInfo
}

func (f *fakeConnectionTracker) ID() string                    { return f.info.UUID.String() }
func (f *fakeConnectionTracker) Close() error                  { return nil }
func (f *fakeConnectionTracker) Info() *statistic.TrackerInfo  { return f.info }
func (f *fakeConnectionTracker) Chains() C.Chain               { return f.info.Chain }
func (f *fakeConnectionTracker) ProviderChains() C.Chain       { return f.info.ProviderChain }
func (f *fakeConnectionTracker) AppendToChains(C.ProxyAdapter) {}
func (f *fakeConnectionTracker) RemoteDestination() string {
	if f.info.Metadata == nil {
		return ""
	}
	return f.info.Metadata.RemoteDst
}

func newFakeManager(n int) *statistic.Manager {
	m := &statistic.Manager{}
	conns := benchConnectionsSnapshot(n).Connections
	for i := range conns {
		m.Join(&fakeConnectionTracker{info: &conns[i]})
	}
	return m
}

func TestMarshalConnectionsIPC_Whitelist(t *testing.T) {
	snapshot := benchConnectionsSnapshot(1)
	// 基准形态里这两项为空，这里补上以覆盖白名单里的全部字段。
	snapshot.Connections[0].Metadata.SpecialRules = "SPECIAL"
	snapshot.Connections[0].Metadata.SpecialProxy = "PROXY"

	raw, err := marshalConnectionsIPC(snapshot.Connections)
	if err != nil {
		t.Fatalf("marshalConnectionsIPC: %v", err)
	}

	var decoded struct {
		Connections []map[string]json.RawMessage `json:"connections"`
	}
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("json.Unmarshal: %v", err)
	}
	if len(decoded.Connections) != 1 {
		t.Fatalf("want 1 connection, got %d", len(decoded.Connections))
	}

	connKeys := sortedKeys(decoded.Connections[0])
	wantConnKeys := []string{"chains", "download", "id", "metadata", "rule", "rulePayload", "start", "upload"}
	if !equalStrings(connKeys, wantConnKeys) {
		t.Fatalf("connection keys = %v, want %v", connKeys, wantConnKeys)
	}

	var meta map[string]json.RawMessage
	if err := json.Unmarshal(decoded.Connections[0]["metadata"], &meta); err != nil {
		t.Fatalf("decode metadata: %v", err)
	}
	metaKeys := sortedKeys(meta)
	wantMetaKeys := []string{
		"destinationGeoIP", "destinationIP", "destinationIPASN", "destinationPort",
		"dnsMode", "host", "network", "process", "processPath", "remoteDestination",
		"sourceGeoIP", "sourceIP", "sourceIPASN", "sourcePort", "specialProxy",
		"specialRules", "uid",
	}
	if !equalStrings(metaKeys, wantMetaKeys) {
		t.Fatalf("metadata keys = %v, want %v", metaKeys, wantMetaKeys)
	}

	// 端口保持旧输出的字符串形态，UI 侧按 String 读取。
	var port string
	if err := json.Unmarshal(meta["sourcePort"], &port); err != nil {
		t.Fatalf("sourcePort should be a string: %v", err)
	}
	if port != "40000" {
		t.Fatalf("sourcePort = %q, want 40000", port)
	}

	var dnsMode string
	if err := json.Unmarshal(meta["dnsMode"], &dnsMode); err != nil {
		t.Fatalf("dnsMode should be a string: %v", err)
	}
	if dnsMode != "normal" {
		t.Fatalf("dnsMode = %q, want normal", dnsMode)
	}
}

func TestMarshalConnectionsIPC_OmitsHeavyFields(t *testing.T) {
	raw, err := marshalConnectionsIPC(benchConnectionsSnapshot(2).Connections)
	if err != nil {
		t.Fatalf("marshalConnectionsIPC: %v", err)
	}
	s := string(raw)
	for _, banned := range []string{
		"providerChains", "sniffHost", "rematchName", "inboundIP",
		"inboundPort", "inboundName", "inboundUser", "dscp",
		`"type":"SOCKS5"`, "downloadTotal", "uploadTotal", "memory",
	} {
		if strings.Contains(s, banned) {
			t.Fatalf("lean payload must not contain %q: %s", banned, s)
		}
	}
}

func TestMarshalConnectionsIPC_Empty(t *testing.T) {
	raw, err := marshalConnectionsIPC(nil)
	if err != nil {
		t.Fatalf("marshalConnectionsIPC: %v", err)
	}
	if string(raw) != `{"connections":[]}` {
		t.Fatalf("empty payload = %s", raw)
	}
}

func TestMarshalConnectionsIPC_NilChainsBecomeEmptyList(t *testing.T) {
	snapshot := benchConnectionsSnapshot(1)
	snapshot.Connections[0].Chain = nil

	raw, err := marshalConnectionsIPC(snapshot.Connections)
	if err != nil {
		t.Fatalf("marshalConnectionsIPC: %v", err)
	}
	if !strings.Contains(string(raw), `"chains":[]`) {
		t.Fatalf("nil chains must marshal as []: %s", raw)
	}
}

func TestManagerCountTracksJoinAndLeave(t *testing.T) {
	m := newFakeManager(3)
	if got := m.Count(); got != 3 {
		t.Fatalf("Count = %d, want 3", got)
	}

	first := m.Connections()[0]
	m.Leave(&fakeConnectionTracker{info: &first})
	if got := m.Count(); got != 2 {
		t.Fatalf("Count after leave = %d, want 2", got)
	}
}

func TestManagerConnectionsMatchesSnapshotShape(t *testing.T) {
	m := newFakeManager(4)
	conns := m.Connections()
	if len(conns) != 4 {
		t.Fatalf("Connections len = %d, want 4", len(conns))
	}
	for _, c := range conns {
		if c.Metadata == nil || c.UUID.String() == "" {
			t.Fatalf("incomplete connection info: %+v", c)
		}
	}
}

func sortedKeys(m map[string]json.RawMessage) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
