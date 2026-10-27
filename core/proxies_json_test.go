package main

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	C "github.com/metacubex/mihomo/constant"
)

func leanLeaf(name string) C.Proxy {
	return adapter.NewProxy(outbound.NewBase(outbound.BaseOption{
		Name: name,
		Type: C.Shadowsocks,
		UDP:  true,
	}))
}

func TestMarshalProxiesIPC_LeafHasNameTypeOnly(t *testing.T) {
	in := map[string]C.Proxy{
		"node-a": leanLeaf("node-a"),
	}
	out, err := marshalProxiesIPC(in)
	if err != nil {
		t.Fatalf("marshalProxiesIPC: %v", err)
	}
	got, ok := out["node-a"]
	if !ok {
		t.Fatal("missing node-a")
	}
	if got.Name != "node-a" || got.Type != "Shadowsocks" {
		t.Fatalf("unexpected leaf: %+v", got)
	}
	if got.All != nil || got.Now != "" || got.Hidden || got.Icon != "" || got.TestUrl != "" {
		t.Fatalf("leaf should not carry group fields: %+v", got)
	}
}

func TestMarshalProxiesIPC_Empty(t *testing.T) {
	out, err := marshalProxiesIPC(map[string]C.Proxy{})
	if err != nil {
		t.Fatalf("marshalProxiesIPC empty: %v", err)
	}
	if len(out) != 0 {
		t.Fatalf("expected empty map, got %d", len(out))
	}
}

func TestMarshalProxiesIPC_OmitsHistoryExtraAlive(t *testing.T) {
	in := map[string]C.Proxy{"node-a": leanLeaf("node-a")}
	out, err := marshalProxiesIPC(in)
	if err != nil {
		t.Fatalf("marshalProxiesIPC: %v", err)
	}
	raw, err := json.Marshal(out)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	s := string(raw)
	for _, banned := range []string{"history", "extra", "alive", "provider-name", "routing-mark"} {
		if strings.Contains(s, banned) {
			t.Fatalf("lean payload must not contain %q: %s", banned, s)
		}
	}
}

func TestLeanProviderProxies_NameAndTypeOnly(t *testing.T) {
	in := []C.Proxy{leanLeaf("n1"), leanLeaf("n2")}
	out := leanProviderProxies(in)
	if len(out) != 2 {
		t.Fatalf("want 2, got %d", len(out))
	}
	raw, err := json.Marshal(out)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	s := string(raw)
	if !strings.Contains(s, `"name":"n1"`) || !strings.Contains(s, `"type":"Shadowsocks"`) {
		t.Fatalf("missing name/type: %s", s)
	}
	for _, banned := range []string{"history", "extra", "alive", "udp"} {
		if strings.Contains(s, banned) {
			t.Fatalf("lean provider proxy must not contain %q: %s", banned, s)
		}
	}
}

func TestLeanProviderProxies_Nil(t *testing.T) {
	if leanProviderProxies(nil) != nil {
		t.Fatal("nil in should be nil out")
	}
}

func TestMarshalProvidersIPC_PreservesMeta(t *testing.T) {
	eps := []ExternalProvider{{
		Name:        "airport-a",
		Type:        "Proxy",
		VehicleType: "HTTP",
		Count:       2,
		Path:        "/tmp/a.yaml",
		Proxies:     []C.Proxy{leanLeaf("n1"), leanLeaf("n2")},
	}}
	out, err := marshalProvidersIPC(eps)
	if err != nil {
		t.Fatalf("marshalProvidersIPC: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("want 1 provider, got %d", len(out))
	}
	p := out[0]
	if p.Name != "airport-a" || p.Count != 2 || len(p.Proxies) != 2 {
		t.Fatalf("meta mismatch: %+v", p)
	}
	raw, err := json.Marshal(out)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	if strings.Contains(string(raw), "history") {
		t.Fatalf("provider payload must not contain history: %s", raw)
	}
}
