package main

import (
	"encoding/json"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	C "github.com/metacubex/mihomo/constant"
)

// leanProxyIPC 是 IPC getProxies 出口的瘦身形态。
//
// UI 构组链路（lib/clash/core.dart → buildProxiesGroupsRaw → Group.fromJson）
// 只消费 name/type/now；分组另需 all/hidden/icon/testUrl。history/extra/alive
// 与 udp/xudp/tfo/mptcp/smux/interface/routing-mark/provider-name/dialer-proxy
// 在 UI 侧无读取方，原先经 Proxy.MarshalJSON 双重序列化整包回传，是大订阅
// getProxies 的主要 payload 与 CPU 开销来源。HTTP /proxies 路由不走本类型。
type leanProxyIPC struct {
	Name string `json:"name"`
	Type string `json:"type"`
	Now  string `json:"now,omitempty"`
	// All 是分组成员名列表；叶子节点恒空，用 omitempty 省掉。
	All []string `json:"all,omitempty"`
	// Hidden / Icon / TestUrl 仅分组有意义。
	Hidden  bool   `json:"hidden,omitempty"`
	Icon    string `json:"icon,omitempty"`
	TestUrl string `json:"testUrl,omitempty"`
}

// marshalProxiesIPC 把内核代理表转成 IPC 瘦身形态。
//
// 分组走各自 adapter 的 MarshalJSON（只含 now/all/hidden/icon/testUrl 等
// 组字段，无 history/extra），再注入 name；叶子直接取 Name()/Type()，
// 不再经 Proxy.MarshalJSON 的 unmarshal→map→remarshal。
func marshalProxiesIPC(proxies map[string]C.Proxy) (map[string]leanProxyIPC, error) {
	out := make(map[string]leanProxyIPC, len(proxies))
	for name, p := range proxies {
		lean := leanProxyIPC{Name: name, Type: p.Type().String()}

		// 分组：Selector / URLTest / Fallback / LoadBalance 的内层
		// MarshalJSON 已回传组字段；用类型断言取出，避免整包 proxy JSON。
		if ap, ok := p.(*adapter.Proxy); ok {
			switch ap.ProxyAdapter.(type) {
			case *outboundgroup.Selector, *outboundgroup.URLTest,
				*outboundgroup.Fallback, *outboundgroup.LoadBalance:
				// 内层 MarshalJSON 只含组字段（type/now/all/hidden/icon/testUrl/...），
				// 没有 name——name 由外层 Proxy.MarshalJSON 注入。这里补上。
				inner, err := ap.ProxyAdapter.MarshalJSON()
				if err != nil {
					return nil, err
				}
				var groupFields struct {
					Now     string   `json:"now"`
					All     []string `json:"all"`
					Hidden  bool     `json:"hidden"`
					Icon    string   `json:"icon"`
					TestUrl string   `json:"testUrl"`
				}
				if err := json.Unmarshal(inner, &groupFields); err != nil {
					return nil, err
				}
				lean.Now = groupFields.Now
				lean.All = groupFields.All
				lean.Hidden = groupFields.Hidden
				lean.Icon = groupFields.Icon
				lean.TestUrl = groupFields.TestUrl
			}
		}

		out[name] = lean
	}
	return out, nil
}

// leanProviderProxyIPC 是 provider 列表里单个节点的瘦身形态。
//
// 构组时只用 name 把 provider 节点并入 allProxies（见 buildProxiesGroupsRaw），
// 类型供 Proxy.fromJson 物化 Group.all 用；其余字段无消费方。
type leanProviderProxyIPC struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

func leanProviderProxies(proxies []C.Proxy) []leanProviderProxyIPC {
	if len(proxies) == 0 {
		return nil
	}
	out := make([]leanProviderProxyIPC, 0, len(proxies))
	for _, p := range proxies {
		out = append(out, leanProviderProxyIPC{
			Name: p.Name(),
			Type: p.Type().String(),
		})
	}
	return out
}

// providerIPC 是 getExternalProviders 出口的瘦身形态。
//
// 与 ExternalProvider 相比，Proxies 从 []C.Proxy（每个再走一遍
// Proxy.MarshalJSON 双重序列化）换成 leanProviderProxyIPC。
type providerIPC struct {
	Name             string                 `json:"name"`
	Type             string                 `json:"type"`
	VehicleType      string                 `json:"vehicle-type"`
	Count            int                    `json:"count"`
	Path             string                 `json:"path"`
	UpdateAt         json.RawMessage        `json:"update-at"`
	SubscriptionInfo *json.RawMessage       `json:"subscription-info"`
	Proxies          []leanProviderProxyIPC `json:"proxies"`
}

func marshalProvidersIPC(eps []ExternalProvider) ([]providerIPC, error) {
	out := make([]providerIPC, 0, len(eps))
	for _, ep := range eps {
		updateAt, err := json.Marshal(ep.UpdateAt)
		if err != nil {
			return nil, err
		}
		var subInfo *json.RawMessage
		if ep.SubscriptionInfo != nil {
			raw, err := json.Marshal(ep.SubscriptionInfo)
			if err != nil {
				return nil, err
			}
			rm := json.RawMessage(raw)
			subInfo = &rm
		}
		out = append(out, providerIPC{
			Name:             ep.Name,
			Type:             ep.Type,
			VehicleType:      ep.VehicleType,
			Count:            ep.Count,
			Path:             ep.Path,
			UpdateAt:         updateAt,
			SubscriptionInfo: subInfo,
			Proxies:          leanProviderProxies(ep.Proxies),
		})
	}
	return out, nil
}
