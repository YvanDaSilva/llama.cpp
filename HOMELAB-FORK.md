# HOMELAB-FORK.md - fork notes for the homelab cluster

Documentation of why this fork exists, what it carries on top of upstream,
which branch our infrastructure pins, and what must be re-applied on every
upstream merge. Written 2026-10-02. No build impact (the fork is consumed as a
nix source with `flake = false`, so extra markdown is ignored).

## Why this fork exists

The cluster runs three hosts with AMD GPUs (Vulkan backend) and splits a single
model across them with llama.cpp's RPC layer split. On top of that we use
speculative decoding (MTP and DFlash2) over that RPC split, and very long
contexts (up to 1M with the KV cache in host RAM).

Several upstream PRs we depend on were unmerged, and some of them are
CUDA-first and never exercised the RPC backend. This fork carries those PRs
plus a small set of our own patches. Fork commits are authored with the
`homelab-builder <homelab-builder@localhost>` identity.

## Branches

| branch | head | date | what it is |
|---|---|---|---|
| `master` | 4d19b28769 | 2026-08-26 | plain upstream mirror snapshot, no custom work |
| `testing-20260820` | 9e7b3e7cf9 | 2026-08-31 | first testing line (early custom patches) |
| `testing-rebase` | 1f846f8405 | 2026-08-26 | rebase line, head is the fit-reserve patch |
| `testing-t3` | e93db8b548 | 2026-09-09 | **the line the cluster pins and builds** |

`t3-full` is **not** a branch. It appears only inside the message of merge
commit `b4fd44c` ("Merge remote-tracking branch 'upstream/master' into
t3-full"), which was the local working branch used for that upstream merge and
was then pushed as `testing-t3`.

## What our infrastructure pins

- nix flake input `llama-cpp-fork`:
  `git+https://github.com/YvanDaSilva/llama.cpp?ref=testing-t3&rev=e93db8b54844707fa6ccc2a281961cfbf23fe1ca`
  with `flake = false`. `flake.lock` records `locked.ref = "testing-t3"`, the
  same rev, revCount 10893.
- The package is built as `pkgs.llama-cpp.override { src = inputs.llama-cpp-fork, ... }`
  in `cfgs/services/local-ai.nix`, with the same Vulkan and RPC flags as the
  nixpkgs build, plus a postInstall that symlinks `llama-cli` to `llama`,
  installs `include/llama.h`, and renames `bin/ggml-rpc-server` to
  `bin/llama-rpc-server`. The package version stays numeric because it feeds
  the `LLAMA_BUILD_NUMBER` integer literal.
- Every host in the cluster, plus the orbitd-supervised llama service, inherits
  this package. There is no per-host override.
- The GitHub URL and the rev pin are deliberate. Remote builders fetch the
  source over the network, and an unpinned ref hits the GitHub API rate limit.

## Upstream PRs carried (cherry-picked 2026-08-20)

| PR | what it fixes |
|---|---|
| 26617 | rollback telescope for recurrent models (new files only) |
| 26933 | RPC GET_ROWS out-of-bounds fix |
| 26291 | RPC parallel tensor hashing |
| 25666 | vulkan: MMVQ off for AMD speculative decode |
| 27210 | adaptive MTP depth |
| 27173 | draft performance +10% (conflict in `common/speculative.cpp`, resolved by keeping both blocks) |
| 27342 | DFlash2 support |

Deliberately skipped: 27140 and 27368 (CUDA only), 22970 (vulkan K-quant
matmul, unmergeable), 25051 (vulkan tensor parallelism, experimental and
intra-node only, we keep the RPC layer split), 22569 (paged KV draft), 21097
(closed), 22140 (the yarn context cap, closed as not planned, so the
override-kv workaround stands).

## Our own patches

These are maintained by hand and must be re-checked after every upstream merge.

1. **RPC transport IPv6 and dual-stack** - `ggml/src/ggml-rpc/transport.cpp`.
   `connect()` now uses `getaddrinfo` with `AF_UNSPEC` and iterates results,
   where it previously used `AF_INET` plus `gethostbyname`. `create_server()`
   uses `getaddrinfo` with `AI_PASSIVE` and sets `IPV6_V6ONLY` to 0 so one
   listener accepts IPv4 and IPv6. Reason: mDNS resolves IPv6 first here, and
   the old v4-only resolver could not use the ULA addresses.
2. **Bracketed IPv6 endpoints** - `ggml/src/ggml-rpc/ggml-rpc.cpp`,
   `parse_endpoint()`. Accepts the bracket form such as
   `[fd1b:178:2::17]:50052` in addition to plain `host:port`. Reason: the RPC
   server built `:::50052` from host `::`, the naive split on the first colon
   produced an empty host, and rpc-server exited into a systemd restart loop.
3. **RPC connect retry at boot** - `ggml/src/ggml-rpc/ggml-rpc.cpp`,
   `rpc_dispatcher::start()`. Env knobs `GGML_RPC_RETRY` (max attempts, default
   6) and `GGML_RPC_RETRY_DELAY_MS` (default 2000 ms). Reason: workers come up
   after the server at boot, and a single failed connect left the server
   degraded forever with no reconnect path. This covers connect time only. A
   worker that dies mid-inference still aborts the process, see open items.
4. **Draft model pinned to the main device** - `common/speculative.cpp`. The
   external draft (DFlash2, Eagle3, MTP) was split across all fit devices
   including the RPC workers, and its first graph dispatch aborted with
   "Remote RPC server crashed or returned malformed response". The fix fills a
   2-element NULL-terminated array and assigns it to
   `llama_model_params.devices`, so only the target model is split across the
   workers and the draft stays local. The array must outlive the model load, so
   it lives in branch scope. History: the first attempt patched
   `llama_context_params.devices`, which does not exist, and was corrected the
   same day.
5. **Fit fallback for the draft** - `common/fit.cpp`, `add_extra_memory()`.
   Upstream catches a failed measure of the extra model and fits the main model
   alone. Our dflash and dspark architectures cannot produce a standalone
   context (they require `ctx_other`), so the measure always fails, the main
   model filled the card, and the pinned draft ran out of memory. The fix
   reserves the draft file size plus a 1 GiB margin on the main device when the
   measure fails.

## Deliberate upstream revert

`ac8c1c5` (2026-09-09) reverts upstream `cdfe700` "llama : add KV eviction
telemetry, validation hardening, and a 15-case test suite". That removes the
streaming eviction sink and recent-window plumbing, the telemetry structs, the
`llama_model_attn_cache_evict_size` helper, and `tests/test-kv-evict.cpp`,
roughly 1500 lines.

**The reason for this revert is not recorded anywhere.** It is a known
documentation gap. Whatever the cause, the revert must be re-applied after
every upstream merge, otherwise the removed code returns and the behavior of
the KV cache changes silently.

## Rebase lineage, and why old commit ids are not ancestors

`testing-t3` is a rebuilt line. The GitHub compare API reports
`0d1078370...e93db8b` as diverged (319 ahead, 37 behind) and
`1f846f8...e93db8b` as diverged (257 ahead, 42 behind). Older custom commits
such as the draft pin `0d1078370` and the fit reserve `1f846f8` are therefore
**not ancestors** of the pinned rev. That is expected after a rebuilt history
and does not mean the changes are missing.

The changes were verified at the pinned rev by reading the files rather than by
ancestry:

| patch | file | marker to grep |
|---|---|---|
| draft pin | `common/speculative.cpp` | `mparams.devices = pinned` |
| RPC retry | `ggml/src/ggml-rpc/ggml-rpc.cpp` | `GGML_RPC_RETRY` |
| fit reserve | `common/fit.cpp` | `reserving its file size` (comment says "fork (testing-rebase)") |
| IPv6 transport | `ggml/src/ggml-rpc/transport.cpp` | `IPV6_V6ONLY` and `AF_UNSPEC` |
| bracket endpoints | `ggml/src/ggml-rpc/ggml-rpc.cpp` | `bracketed IPv6` |

## Resync procedure when upstream drifts

1. Branch from `testing-t3` for the merge (the previous merge used the name
   `t3-full`).
2. `git fetch upstream` and merge `upstream/master`.
3. Expect work in these areas: the ggml-backend-meta split-axis change, the
   `is_dsv4` and `mirror_output` paths used by dflash and dspark, the
   server-context fit refactor, `common/speculative.cpp` (keep both blocks),
   and the KV eviction revert.
4. Re-apply any of the five patches the merge dropped, using the markers above
   to check.
5. Re-apply the eviction revert.
6. Build for Vulkan and RPC, deploy the server first and the workers second,
   then verify the three-host layer split.
7. Bump the nix pin in both `flake.nix` and `flake.lock`, keeping the GitHub URL
   and the rev.
8. Record the outcome in this file, including the real reason for the eviction
   revert if we recover it.

## Open items and upstream work we are waiting on

- **RPC mid-run reconnect.** A worker dropping during inference still aborts the
  process through `RPC_STATUS_ASSERT`. Our planned phase 2 (mark the worker
  dead, reconnect, re-register tensors, where the server dedupes re-uploads
  with its tensor hash cache) is not implemented. Upstream has an RPC overhaul
  open, 18626.
- **KV in host RAM with MTP.** `--no-kv-offload` puts the KV cache in host RAM,
  but with MTP the draft KV is copied to VRAM on every draft step, which costs
  roughly 30 percent throughput. The upstream fix, PR 28117, is still open, so
  KV in RAM is used with plain models only.
- **Paged KV.** Does not exist upstream and not in this fork. Earlier attempts
  were closed (14070, 17579, 20026, 22569).
- **Flash-Next at very long context.** With the YaRN recipe the model loads at
  800k, but the HIP decoder runs out of memory because weights plus workspace
  exceed a fragmented 80 GB card. The comfortable single-card context is much
  lower.
- Upstream `3e08552` "Common : Fix for kv draft cache placement" (2026-08-31)
  is already in `testing-t3` through the merge, and it addresses part of the
  same draft placement problem that patch 4 works around.

## Measured behavior of this build

| model and setup | coherent context | speed |
|---|---|---|
| 27B dense, KV in VRAM | 524288 (ceiling) | 19.8 to 26.8 t/s |
| 27B dense, KV in host RAM | 1000000 | 7.25 t/s decode, about 70 t/s prompt |
| DavidAU MTP with draft-mtp | 524288 (draft accept 0.90) | 50 t/s at small context |
| 7B instruct 1M, q8_0 | 1000000 | 65 t/s |
| Ornith-1.5-35B-A3B | 262144 native | 74.6 t/s |
| 27B distributed over three hosts | coherent | 22.1 t/s at small context |
| 7B instruct 1M, q4_0 | incoherent (1 of 6 cases) | decode speed identical to q8_0 |

The q4_0 case is the reason coherence checks are part of our probe harness.
Decode speed alone does not detect it.

A 300K context needle test retrieved 3 of 3 needles at 300,062 tokens, past the
262144 boundary that used to crash on the stale fork base.

## Harness note

The cluster exercises this build with `orbitctl ai eval`, which runs isolated
throwaway eval cells, a coherency battery, and JSONL baselines. That harness
does not modify the source in this repository.
