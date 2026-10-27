package main

import (
	"encoding/json"
	"net/netip"
	"time"

	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

// leanConnectionMetadataIPC 是 IPC getConnections 出口的元数据白名单。
//
// UI 只消费这些字段（lib/models/common.dart 的 Metadata、连接列表与详情、
// 搜索过滤、FCM 卡片）：network/sourceIP/destinationIP/端口/host/uid/process/
// processPath/remoteDestination/geoip/ASN/specialProxy/specialRules/dnsMode。
// 内核 Metadata 里的 type/inboundIP/inboundPort/inboundName/inboundUser/
// rematchName/sniffHost/dscp 没有读取方，原先每秒随全量快照序列化一遍，
// 是大连接数下 payload 与分配的主要来源。HTTP /connections 路由不走本类型。
type leanConnectionMetadataIPC struct {
	NetWork          string   `json:"network,omitempty"`
	SourceIP         string   `json:"sourceIP,omitempty"`
	DestinationIP    string   `json:"destinationIP,omitempty"`
	SourceGeoIP      []string `json:"sourceGeoIP,omitempty"`
	DestinationGeoIP []string `json:"destinationGeoIP,omitempty"`
	SourceIPASN      string   `json:"sourceIPASN,omitempty"`
	DestinationIPASN string   `json:"destinationIPASN,omitempty"`
	// 端口沿用旧输出的字符串形态（Metadata 的 `,string` 标签），UI 侧
	// 直接按 String 读取。
	SourcePort      uint16 `json:"sourcePort,string,omitempty"`
	DestinationPort uint16 `json:"destinationPort,string,omitempty"`
	Host            string `json:"host,omitempty"`
	// DNSMode 恒输出：UI 以「非 null」决定是否展示 DNS Mode 行，
	// 与改前的全量快照保持一致。
	DNSMode      C.DNSMode `json:"dnsMode"`
	Uid          uint32    `json:"uid,omitempty"`
	Process      string    `json:"process,omitempty"`
	ProcessPath  string    `json:"processPath,omitempty"`
	SpecialProxy string    `json:"specialProxy,omitempty"`
	SpecialRules string    `json:"specialRules,omitempty"`
	RemoteDst    string    `json:"remoteDestination,omitempty"`
}

// leanConnectionIPC 是单条连接的 IPC 形态。
//
// 去掉了 providerChains：Dart 侧 TrackerInfo 没有该字段，反序列化后即丢弃。
type leanConnectionIPC struct {
	ID            string                    `json:"id"`
	Metadata      leanConnectionMetadataIPC `json:"metadata"`
	UploadTotal   int64                     `json:"upload"`
	DownloadTotal int64                     `json:"download"`
	Start         time.Time                 `json:"start"`
	Chain         C.Chain                   `json:"chains"`
	Rule          string                    `json:"rule"`
	RulePayload   string                    `json:"rulePayload"`
}

func ipString(ip netip.Addr) string {
	if !ip.IsValid() {
		return ""
	}
	return ip.String()
}

func leanConnection(info *statistic.TrackerInfo) leanConnectionIPC {
	chains := info.Chain
	if chains == nil {
		// Dart 侧按 List<String> 解析 chains，null 会直接抛错。
		chains = C.Chain{}
	}
	lean := leanConnectionIPC{
		ID:            info.UUID.String(),
		UploadTotal:   info.UploadTotal.Load(),
		DownloadTotal: info.DownloadTotal.Load(),
		Start:         info.Start,
		Chain:         chains,
		Rule:          info.Rule,
		RulePayload:   info.RulePayload,
	}

	meta := info.Metadata
	if meta == nil {
		return lean
	}
	lean.Metadata = leanConnectionMetadataIPC{
		NetWork:          meta.NetWork.String(),
		SourceIP:         ipString(meta.SrcIP),
		DestinationIP:    ipString(meta.DstIP),
		SourceGeoIP:      meta.SrcGeoIP,
		DestinationGeoIP: meta.DstGeoIP,
		SourceIPASN:      meta.SrcIPASN,
		DestinationIPASN: meta.DstIPASN,
		SourcePort:       meta.SrcPort,
		DestinationPort:  meta.DstPort,
		Host:             meta.Host,
		DNSMode:          meta.DNSMode,
		Uid:              meta.Uid,
		Process:          meta.Process,
		ProcessPath:      meta.ProcessPath,
		SpecialProxy:     meta.SpecialProxy,
		SpecialRules:     meta.SpecialRules,
		RemoteDst:        meta.RemoteDst,
	}
	return lean
}

// leanConnections 把内核连接表转成瘦身形态。
func leanConnections(connections []statistic.TrackerInfo) []leanConnectionIPC {
	out := make([]leanConnectionIPC, 0, len(connections))
	for i := range connections {
		out = append(out, leanConnection(&connections[i]))
	}
	return out
}

// marshalConnectionsIPC 把连接表转成 IPC 瘦身 JSON。
//
// 出口只保留 connections 数组：downloadTotal/uploadTotal/memory 在 Dart 侧
// 没有读取方（lib/clash/core.dart 只取 connections），而 memory 需要一次
// runtime.ReadMemStats。
func marshalConnectionsIPC(connections []statistic.TrackerInfo) ([]byte, error) {
	return json.Marshal(struct {
		Connections []leanConnectionIPC `json:"connections"`
	}{
		Connections: leanConnections(connections),
	})
}
