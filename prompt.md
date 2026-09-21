# Setup prompt — read this first

You are an AI coding assistant helping someone set up this repo on their own machine, right after they cloned it. This file is your runbook. Don't skip steps or guess at hardware — detect it, then reason from what you actually found.

The goal by the end: a working `.env` with `MODEL_FILE` pointing at a real `.gguf` file that fits this person's hardware well, plus `NGL`/`N_CPU_MOE`/`CONTEXT_SIZE`/`THREADS`/`LLM_CPUSET` set sensibly — not copy-pasted defaults.

## Step 1 — detect the hardware

Run `./scripts/detect-hardware.sh` and read its actual output before doing anything else — don't re-derive the detection commands yourself; the script exists precisely so this step is a fixed, tested check instead of something reinvented slightly differently on every run. It also regenerates `portal/docs/hardware.html` (viewable at `https://<your-domain>/docs/hardware.html` once the stack is up) with the same numbers, so re-run it after any hardware change.

Note down: GPU model + total VRAM, CPU core count and topology (the script reports P-core/E-core split directly via sysfs when the chip is hybrid — Intel 12th-gen+ desktop parts, most laptop chips — no need to cross-check spec pages), and total RAM. If the script reports no NVIDIA GPU or `nvidia-container-toolkit` isn't registered, stop and tell the user plainly — this stack requires an NVIDIA GPU (see README "Requirements"); it does not support CPU-only or non-NVIDIA GPU inference.

## Step 2 — decide: dense or MoE

This is the real fork in the road, and it hinges on VRAM headroom, not personal preference.

**If the GPU has enough VRAM to hold an entire model of the size/quality you want, plus the KV-cache context, with a couple GB to spare** — pick a **dense** model. Dense models generally have better quality per parameter than MoE at a given size, and if it fully fits on GPU there's no CPU-offload penalty to worry about at all: `NGL=99`, `N_CPU_MOE` doesn't apply. This is the simple, fast path. Roughly: 12GB+ VRAM comfortably fits a good dense model in the 7-14B range at Q4-Q5 quantization with real context room; 24GB+ opens up 32B-class dense models.

**If VRAM is tight relative to the model quality you want** — pick a **Mixture-of-Experts (MoE)** model instead, and lean on `N_CPU_MOE` to offload expert layers to system RAM. This is the whole reason `N_CPU_MOE` exists (see README "Swapping the model"): a MoE model only activates a handful of its experts per token (e.g. 8 of 128), so most of its weights sit idle on any given forward pass — offloading those idle experts to CPU/RAM costs far less than it would for a dense model, where *every* weight gets touched every token regardless.

This isn't theoretical — it's this project's own founding lesson, one real measured case (not a universal default — your own numbers will differ): on an RTX 3080 10GB, a dense 32B model maxed out at ~2 tok/s — unusable — while a same-scale MoE model (30B total, ~3B active, `N_CPU_MOE=36`) hit 27-51 tok/s on the *identical hardware*, depending on CPU governor/thread-placement tuning (see README.md "Tuning" and `scripts/tune-system.sh` for that governor/tuning piece). Same GPU, same VRAM budget — the dense-vs-MoE architecture choice alone was the difference between usable and not. Don't dismiss MoE as "worse" just because fewer parameters are active — for constrained VRAM it's usually the better trade, not a compromise.

**If VRAM is very limited (under ~8GB) or absent** — temper expectations. A small dense model (3-8B, Q4) fully on GPU, or a heavily CPU-offloaded MoE model, both work but won't be fast. Say so plainly rather than overselling it.

**VRAM capacity isn't the whole story — memory bandwidth is what actually limits token generation.** A GPU with more VRAM but less bandwidth can be *worse* for TG than one with less VRAM but more bandwidth. Real illustration, measured on this project's own reference hardware: a 16GB card at ~288 GB/s bandwidth is measurably *slower* for token generation than a 10GB card at 760 GB/s, despite the extra VRAM — "more VRAM, less bandwidth" is one of the most common bad trade-offs people make choosing a GPU for local inference. `detect-hardware.sh` can't get this from `nvidia-smi` (there's no runtime-queryable field for it) — you already know it, or can estimate it closely, from the GPU name the script reports. Match it against your own knowledge of that card's spec sheet rather than treating bandwidth as unknown just because the script didn't report it; only fall back to asking the user to check if you're genuinely unsure (an unfamiliar or very new card).

## Step 3 — pick an actual model file

Once you know dense-vs-MoE and roughly what size class fits:
- Point the user at quantized GGUF builds from a reputable source (Hugging Face — look for `bartowski` or `unsloth` quantizations of whatever base model they're after; both are well-regarded, actively maintained GGUF converters as of this writing, but verify the model card is recent and matches the architecture you're targeting rather than assuming these names are still the right ones by the time you're reading this).
- Match quantization to VRAM: Q4_K_M is a reasonable default balance of quality/size; go higher (Q5/Q6) if VRAM allows, lower (Q3/Q4_0) only if genuinely constrained — quality drops off noticeably below Q4.
- Confirm the file the user picks actually matches the dense/MoE call from Step 2 — check the model card, don't assume from the name alone.

## Step 4 — write `.env`

```bash
cp .env.example .env
```

Then set, based on what you found:
- **`MODEL_FILE`** — the `.gguf` filename, already placed in `models/`
- **`NGL=99`** — almost always correct as-is (llama.cpp clamps to the model's real layer count)
- **`N_CPU_MOE`** — `0` for dense models (no-op) or if the MoE model fully fits on GPU anyway. For a MoE model that needs CPU offload: rule of thumb from README "Swapping the model" — expert tensors are typically ~90%+ of a MoE model's file size, so (file size in GB) ÷ (total expert layers, check the model card) ≈ GB per layer; pick a value that leaves ~1-2GB VRAM headroom above what fits
- **`CONTEXT_SIZE`** — bigger costs more VRAM regardless of how much context a given request actually uses; don't set it far beyond what the user will realistically need
- **`THREADS`** — matters most for the CPU-offloaded portion of a hybrid setup; on a hybrid P-core/E-core CPU, don't assume more threads or "the fast cores" is automatically better without the user actually measuring (`scripts/benchmark.sh`) — see README "Tuning"
- **`LLM_CPUSET`** — leave empty unless you have a specific, measured reason to pin cores (see the same "Tuning" section — it's a real lever but not a default-on one)
- **`DOMAIN`** — `localhost` is fine to start; see README "Custom domain + HTTPS" if they want real TLS on their LAN

## Step 5 — bring it up and sanity-check

```bash
./scripts/stack-up.sh
```

Then actually verify generation works and report real numbers back to the user (tokens/sec, whether it felt CPU-bound) rather than declaring success just because the container started — `docs/api.md` has a working curl example. Prefer `scripts/benchmark.sh` (measures real prompt-processing/token-generation tok/s, VRAM, GPU clocks — see its own header comment for usage) over an ad hoc single request, and save the JSON output into `benchmarks/` so the numbers are comparable if the user tries a different model or `N_CPU_MOE` value later.

## Don't

- Don't pick a model size based on "what's popular" instead of what was actually measured against this hardware.
- Don't set `N_CPU_MOE` or `LLM_CPUSET` by guessing — either compute them from real numbers (file size, layer count, VRAM free) or leave them at the safe defaults and say so.
- Don't claim a setup is fast or slow without having actually run it.
