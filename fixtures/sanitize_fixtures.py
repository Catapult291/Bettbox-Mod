#!/usr/bin/env python3
"""把本机真实的 Bettbox 数据脱敏成仓库内的测试 fixture。

用法（在仓库根执行）：

    python fixtures/sanitize_fixtures.py \
        --profile "%APPDATA%/Catapult291/Bettbox/profiles/<id>.yaml" \
        --running "%APPDATA%/Catapult291/Bettbox/config.yaml" \
        --prefs   "%APPDATA%/Catapult291/Bettbox/shared_preferences.json" \
        --out fixtures

输入是用户机器上的真实数据，输出是可直接入库的脱敏 fixture。脱敏规则：

* `server` / `servername` / `sni` / `host`：换成 `node<N>.example.com`（同一原始值映射到同一假值）。
* `password` / `uuid` / `url` / `token` / `secret` / `path` / `username` / 各类 key：
  形状保持替换（字母数字变 `X`，保留 `-` `:` `/` `=` 等标点），长度与类型不变。
* 全文域名抹除：先从代理 `server` 与订阅 `url` 里收集真实主机名（及其末两级域名），
  再把它们在任何字符串（规则、节点名、脚本正文……）里的出现替换成 `example.com`
  —— 否则规则里会出现机场自己的域名。
* 顶层 `hosts`：整体换成固定的示例映射。
* 订阅流量信息（`upload` / `download` / `total` / `expire`，含首字母大写变体）：归零。
* 提供商/配置名（`RENAME` 表）：换成通用名，脚本正文里也一并替换。
* 其余（规则结构、分组名、节点地区名、端口、DNS、主题等）保持原样。

脚本本身入库，便于复核与重跑；输入数据不入库。
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

import yaml

# 提供商标识等换成通用名；脚本正文里也会做同样的字符串替换，保持一致。
RENAME = {
    "Neverlose": "fixture-a",
    "MESL": "fixture-b",
}

DOMAIN_KEYS = {"server", "servername", "sni", "host"}
SECRET_KEYS = {
    "password",
    "uuid",
    "private-key",
    "public-key",
    "pre-shared-key",
    "psk",
    "obfs-password",
    "auth",
    "auth-str",
    "auth_str",
    "token",
    "secret",
    "url",
    "path",
    "ws-path",
    "grpc-service-name",
    "username",
    "ageSecretKey",
    "age-secret-key",
}
TRAFFIC_KEYS = {"upload", "download", "total", "expire", "Upload", "Download", "Total", "Expire"}
FIXED_HOSTS = {"example.com": ["203.0.113.10"]}
REPLACEMENT_DOMAIN = "example.com"


class Sanitizer:
    def __init__(self) -> None:
        self._domains: dict[str, str] = {}
        self._redact_domains: set[str] = set()

    def collect(self, node) -> None:
        """收集需要在全文中一并抹掉的真实域名（代理服务器与订阅地址的主机）。"""
        if isinstance(node, dict):
            for key, value in node.items():
                if key in DOMAIN_KEYS and isinstance(value, str) and value:
                    self._add_host(value)
                elif key == "url" and isinstance(value, str):
                    self._add_host(self._host_of(value))
                self.collect(value)
        elif isinstance(node, list):
            for item in node:
                self.collect(item)

    def clean(self, node, key: str | None = None):
        if isinstance(node, dict):
            if key == "hosts":
                return dict(FIXED_HOSTS)
            return {k: self.clean(v, k) for k, v in node.items()}
        if isinstance(node, list):
            return [self.clean(item, key) for item in node]
        if isinstance(node, str):
            return self._clean_str(node, key)
        if isinstance(node, (int, float)) and key in TRAFFIC_KEYS:
            return 0
        return node

    def clean_text(self, value: str) -> str:
        """处理不在结构遍历里的自由文本（如脚本正文）。"""
        return self._redact_domain_hits(self._rename(value))

    def _clean_str(self, value: str, key: str | None) -> str:
        if key in DOMAIN_KEYS:
            return self._fake_domain(value) if value else value
        if key in SECRET_KEYS:
            return re.sub(r"[A-Za-z0-9]", "X", value)
        return self.clean_text(value)

    def _add_host(self, host: str | None) -> None:
        if not host:
            return
        host = host.lower().strip()
        if not re.fullmatch(r"[a-z0-9.-]+", host):
            return
        if re.fullmatch(r"[0-9.]+", host):
            return
        self._redact_domains.add(host)
        parts = host.split(".")
        if len(parts) > 2:
            self._redact_domains.add(".".join(parts[-2:]))

    @staticmethod
    def _host_of(url: str) -> str | None:
        match = re.match(r"[a-z][a-z0-9+.-]*://([^/?#]+)", url, re.IGNORECASE)
        if not match:
            return None
        return match.group(1).split("@")[-1].split(":")[0]

    def _redact_domain_hits(self, value: str) -> str:
        for domain in sorted(self._redact_domains, key=len, reverse=True):
            if domain in value:
                value = value.replace(domain, REPLACEMENT_DOMAIN)
        return value

    def _rename(self, value: str) -> str:
        for original, replacement in RENAME.items():
            value = value.replace(original, replacement)
        return value

    def _fake_domain(self, value: str) -> str:
        if value not in self._domains:
            self._domains[value] = f"node{len(self._domains) + 1}.example.com"
        return self._domains[value]


def write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {path} ({path.stat().st_size} bytes)")


def load_yaml(path: str):
    return yaml.safe_load(Path(path).read_text(encoding="utf-8"))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", action="append", default=[], help="真实 profile YAML（可多次）")
    parser.add_argument("--running", help="运行中的 config.yaml")
    parser.add_argument("--prefs", help="shared_preferences.json")
    parser.add_argument("--out", default="fixtures", help="输出目录")
    args = parser.parse_args()

    out = Path(args.out)
    sanitizer = Sanitizer()

    profiles = [(path, load_yaml(path)) for path in args.profile]
    running = load_yaml(args.running) if args.running else None
    config = None
    if args.prefs:
        prefs = json.loads(Path(args.prefs).read_text(encoding="utf-8"))
        config = json.loads(prefs["flutter.config"])

    # 先收集真实域名，再统一脱敏，保证规则/脚本里出现的机场域名也被抹掉。
    for _, raw in profiles:
        sanitizer.collect(raw)
    if running is not None:
        sanitizer.collect(running)
    if config is not None:
        sanitizer.collect(config)

    for index, (_, raw) in enumerate(profiles):
        write_json(out / "config" / f"profile-{chr(ord('a') + index)}.json", sanitizer.clean(raw))

    if running is not None:
        write_json(out / "config" / "running-config.json", sanitizer.clean(running))

    if config is not None:
        write_json(out / "config" / "app-config.json", sanitizer.clean(config))
        for script in config.get("scriptProps", {}).get("scripts", []):
            label = re.sub(
                r"[^A-Za-z0-9_-]", "_", script.get("label") or script.get("id", "script")
            )
            text = sanitizer.clean_text(script.get("content", ""))
            path = out / "scripts" / f"{label}.js"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text if text.endswith("\n") else text + "\n", encoding="utf-8")
            print(f"wrote {path} ({path.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
