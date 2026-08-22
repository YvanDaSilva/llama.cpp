# testing-20260820 — merged PRs & patches

Custom branch for the homelab AMD Vulkan cluster (neptune + jupiter + saturn,
distributed RPC, Qwen3.8-27B hybrid + MTP/DFlash2/DSpark spec decoding).

## Base
- ggml-org/llama.cpp main, resynced via the fork master at **2100e5926** (2026-08-22)
- Fork master kept in sync: `git push origin upstream/master:master` (fast-forward)
- Branch head: **65547b0c3** (merge of upstream main into the custom work)

## Upstream PRs merged (unmerged upstream at the time)

| PR | Title | Why it was merged |
|---|---|---|
| **#26617** | llama: forward-telescoping rollback engine for recurrent models | Correct rollback for Qwen3.8's 48 Gated DeltaNet layers (hybrid) |
| **#26933** | ggml-rpc: fix out-of-bounds read/write in GET_ROWS/SET_ROWS | RPC safety — we run a 3-node RPC split |
| **#26291** | rpc: parallelize cached tensor hashing during model load | Faster model loads over RPC |
| **#25666** | vulkan: treat a speculative-decode step as decode, not a batch | Disables MMVQ on AMD spec-decode — our draft-mtp path |
| **#27210** | spec: adaptive MTP draft depth (`draft-mtp-adaptive`) | Spec throughput; controller climbs from a floor depth |
| **#27173** | speculative: draft perf + chain MTP steps in one graph + rollback bugfix | ~+10% t/s, deeper drafts; conflict with #27210 in speculative.cpp resolved (keep both) |
| **#27342** | spec: DFlash2 support (block-diffusion sidecar) | The Qwen3.8 DFlash2 sidecar path |
| **#18626** | rpc: implement event and async backend APIs (rgerganov, `rpc-async`) | Pipeline-parallel input processing — the upstream rework that supersedes #24675. Per-endpoint command queue + RPC events; the `RPC_CMD_GET_ALLOC_SIZE` response cache is what unlocks the pipeline overlap. Conflicts resolved: kept our boot-retry loop (H2), took the async dispatcher (H3/H4), union of the caps (events + mmap) |

## Our own patches (beyond the merged PRs)

| Commit | Change |
|---|---|
| `97b427ee` | **IPv4+IPv6 RPC transport**: `socket_t::connect`/`create_server` rewritten with `getaddrinfo(AF_UNSPEC)` + result iteration; server sets `IPV6_V6ONLY=0` (dual-stack). Before: `gethostbyname`/`inet_addr` were IPv4-only |
| `1651c08e` | **Bracket IPv6 endpoints**: `[::]:50052` form + bracket-aware `parse_endpoint` (v6 hosts otherwise produced the broken `:::50052`) |
| `d3539e11` | **RPC boot retry**: `get_socket` retries connect+HELLO up to `GGML_RPC_RETRY` (default 6) with `GGML_RPC_RETRY_DELAY_MS` pauses — workers not up at boot no longer leave the server degraded forever |
| `0faf124c` | **Per-attempt connect timeout**: non-blocking connect + `poll(2)` up to `GGML_RPC_CONNECT_TIMEOUT_MS` (default 3000) — unreachable peers fail fast instead of the ~2 min kernel SYN timeout (which multiplied with the retry loop) |
| `58d71c43` | Include fix (`fcntl.h`/`poll.h`) for the non-blocking connect path |

## Deferred / explicitly NOT merged
- **#22970** vulkan K-quant matmul transpose — 4 conflicts vs main, open since May; candidate for a future conflict-resolution pass
- **#25362** AMD NonTemporal weight-load hints — merges clean, not yet pulled
- **#25051** Vulkan tensor-parallel — experimental, intra-node only; our distributed setup uses RPC layer split
- **#22569** paged KV — large draft, `mergeable:false`; tracked for the long-context memory unlock
- **#27140 / #27368** — CUDA-only, wrong backend
