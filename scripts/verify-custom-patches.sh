#!/usr/bin/env bash
# Check that the fork patches survived a resync with upstream/master.
#
# Every line below is a grep count taken on the t3-full tip e93db8b54, before
# the merge. A lower count means a conflict resolution dropped part of a patch.
# A higher count means our lines merged with upstream code, so read that file.
#
# usage: scripts/verify-custom-patches.sh

set -u

total=0
bad=()

check() {
    local file=$1
    local regex=$2
    local want=$3
    local label=$4

    total=$((total + 1))

    if [[ ! -f $file ]]; then
        printf 'FAIL  %-46s missing file %s\n' "$label" "$file"
        bad+=("$label: file $file does not exist")
        return
    fi

    local got
    got=$(grep -cE -- "$regex" "$file")

    if [[ $got -eq $want ]]; then
        printf 'ok    %-46s %-34s %s\n' "$label" "$file" "$got"
    else
        printf 'FAIL  %-46s %-34s want %s, got %s  (pattern: %s)\n' "$label" "$file" "$want" "$got" "$regex"
        bad+=("$label: $file has $got match(es) of '$regex', expected $want")
    fi
}

# build files
check src/CMakeLists.txt       'llama-rollback-telescope\.cpp'   1 'telescope engine in libllama'
check src/CMakeLists.txt       'llama-moecache\.cpp'             1 'expert cache in libllama'
check tests/CMakeLists.txt     'test-speculative-adaptive\.cpp'  1 'adaptive MTP test built'

# ggml rpc
check ggml/src/ggml-rpc/transport.cpp  'getaddrinfo'                2 'IPv4+IPv6 transport'
check ggml/src/ggml-rpc/transport.cpp  'IPV6_V6ONLY'                1 'dual-stack server socket'
check ggml/src/ggml-rpc/transport.cpp  'GGML_RPC_CONNECT_TIMEOUT_MS' 1 'per-attempt connect timeout'
check ggml/src/ggml-rpc/ggml-rpc.cpp   'GGML_RPC_RETRY'             4 'worker boot retry'
check ggml/src/ggml-rpc/ggml-rpc.cpp   'RPC_CMD_GET_ALLOC_SIZE'     3 'alloc size response cache'
check ggml/src/ggml-rpc/ggml-rpc.cpp   'malformed (SET|GET)_ROWS'   2 'graph bounds validation'
check tools/rpc/rpc-server.cpp         'host\.find'                 1 'bracketed IPv6 endpoint'
check src/llama-model-loader.cpp       'ggml_rpc_load_threads'      2 'parallel cache hashing'

# ggml vulkan
check ggml/src/ggml-vulkan/ggml-vulkan.cpp 'is_k_quant'             9 'AMD k-quant gate'
check ggml/src/ggml-vulkan/ggml-vulkan.cpp 'k >= 4096'              1 'k-quant k threshold'
check ggml/src/ggml-vulkan/ggml-vulkan.cpp 'MMVQ_MAX_DECODE_LIKE_N' 2 'spec step counts as decode'

# ggml alloc / backend / cuda
check ggml/src/ggml-alloc.c                'max_size'                            14 'view init after max_size split'
check ggml/src/ggml-alloc.c                'alloc_ctx_tensors_finalize_views'     2 'finalize pass'
check tests/test-alloc.cpp                 'test_view_init_after_max_size_split'  2 'max_size split regression test'
check ggml/include/ggml-backend.h          'prefetch_experts_slots'               1 'expert prefetch API'
check ggml/src/ggml-backend.cpp            'prefetch_experts_slots'               3 'expert prefetch impl'
check ggml/src/ggml-backend-meta.cpp       'fingerprint'                          5 'meta plan cache'
check ggml/src/ggml-cuda/allreduce.cu      'ggml_cuda_ar_kernel_slot'             4 'chunked allreduce'

# src
check src/llama-ext.h                  'llama_graph_reserve'                      2 'graph reserve API'
check src/llama-context.cpp            'LLAMA_SCHED_POOL|LLAMA_META_MIRROR_OUTPUT' 4 'sched pool + mirrored output'
check src/llama-model.cpp              'LLAMA_META_MIRROR_OUTPUT'                 2 'mirrored output head'
check src/llama-context.cpp            'const_cast'                               2 '-Wcast-qual fix'
check src/models/dflash.cpp            'DFLASH_SELECTOR'                          5 'DFlash2'
check src/models/qwen35.cpp            'build_attn_mha'                           1 'qwen35 MTP graph'
check src/models/delta-net-base.cpp    'snapshot'                                 4 'conv-state snapshot fix'
check src/llama-moecache.cpp           'llama_moe_cache'                          5 'expert cache engine'
check src/llama-rollback-telescope.cpp 'telescope'                               11 'telescope engine'
check src/llama-model-loader.cpp       'expert|EXPERT'                            7 'expert cache load hooks'

# common
check common/speculative.cpp          'pinned|mparams\.devices'                  6 'draft device pin'
check common/speculative.cpp          'no_kv_offload = false'                    1 'draft kv cache placement'
check common/speculative.cpp          'LLAMA_SPEC_CHAIN'                         3 'chained MTP draft'
check common/speculative.cpp          'common_speculative_adaptive'              3 'adaptive draft depth'
check common/speculative-adaptive.h   'common_speculative_adaptive'              1 'adaptive controller'
check common/common.h                 'COMMON_SPECULATIVE_TYPE_DRAFT_MTP_ADAPTIVE' 2 'adaptive type'
check common/common.h                 'prefetch_experts_slots'                   1 'expert prefetch param'
check common/arg.cpp                  'prefetch-experts-slots'                   1 'expert prefetch arg'
check common/fit.cpp                  'dmds_extra\[0\]\.mb\.model'                1 'fit draft reserve'
check tests/test-arg-parser.cpp       'no_kv_offload'                            2 'draft kv placement test'

# tools/server
check tools/server/server-context.cpp 'fallback reserve'                         2 'draft reserve scope'
check tools/server/server-context.cpp 'fit_params_target\[main_idx\]'             1 'reserve on main device'
check tools/server/server-context.cpp 'SLOT_CKPT_MAGIC'                          3 'slot checkpoints'
check tools/server/tests/unit/test_slot_save.py 'checkpoint'                     2 'slot checkpoint test'

# tests
check tests/test-speculative-adaptive.cpp 'adaptive'                             9 'adaptive draft test'
check tests/test_telescope.cpp            'telescope'                           10 'telescope test'

# reverted on purpose (ac8c1c538): must not come back
check src/llama-kv-cache.h 'llama_kv_cache_evict_stats'                          0 'kv eviction telemetry stays reverted'

if [[ ${#bad[@]} -gt 0 ]]; then
    printf '\n%d of %d custom markers FAILED:\n' "${#bad[@]}" "$total"
    for m in "${bad[@]}"; do
        printf '  - %s\n' "$m"
    done
    printf '\nDo not commit until every failure is explained.\n'
    exit 1
fi

printf '\nall %d custom markers present\n' "$total"
