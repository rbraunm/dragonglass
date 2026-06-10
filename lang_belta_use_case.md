# Lang Belta — Use Case Spec

**Author:** Randy + Claude  
**Date:** June 10, 2026  
**Status:** Proposed / scoping  
**Target hardware:** V100-PCIe-32GB (planned Phase 6 GPU)

---

## Overview

Build a self-hosted model that is *exceptional* — not merely passable — at **Lang Belta**, the
Belter Creole conlang from *The Expanse* (created by linguist Nick Farmer). It runs inside the
existing dragonglass stack and serves as a non-coding use case for it: a hard, low-resource
language task that exercises RAG, local inference, and the benchmark discipline already
established in this repo.

This is a knowledge pack + system prompt + eval harness served through Ollama / Open WebUI.
The eval harness mirrors the `benchmark-results/` pattern: a use case is only "done" when a
scoreboard says so.

---

## Why this is hard (data reality)

- **Low-resource conlang.** Farmer created ~1,000–2,000 attested words. The grammar is small
  but fully documented and rule-governed (definiteness agreement, aspect/mood markers, SVO
  order, head-before-modifier, zero copula, proximal/distal demonstratives, question particle
  `ke`).
- **Base-model knowledge is thin.** General LLMs zero-shot into low-resource languages range
  from mediocre to unusable. The lift here comes from putting the rules and lexicon *in
  context*, not from the model's latent knowledge.
- **The bar to clear is low; "exceptional" is wide open.** Existing tools (LingoJam,
  anythingtranslate, xlatorhub) are word-substitution toys or thin GPT wrappers. They treat
  Lang Belta as relexified English and break the grammar — definiteness agreement, aspect
  marking, zero copula. None are good. There is no purpose-built model.

---

## Strategy: RAG-first, fine-tune only if the eval demands it

The language is small *and* rule-governed, so the full verified lexicon plus the complete
grammar fit comfortably in a frontier-class context window. Highest quality for lowest effort
is therefore **context engineering** — lexicon lookup + explicit grammar rules + few-shot on
real attested sentences — over the strongest local model that fits.

A LoRA fine-tune only earns its place *later*, if benchmarks show the base model can't carry
register/style from context alone. Training first would fight a parallel-data shortage we
don't need to fight (see Corpus). RAG-first is the call.

---

## Hardware floor

Context engineering only works if the underlying model is smart enough to *apply* grammar
rules it reads in context. A 7B on the workstation 2080 Ti (11 GB) will mangle agreement and
aspect no matter how good the prompt is. Realistic floor is **~30B–70B-quant**, which means
the **V100-PCIe-32GB**. Plan this use case around the V100, not the 2080 Ti — this lines up
with the Phase 6 GPU target already on the roadmap.

---

## Corpus

Two artifacts, both built before any model work:

1. **Knowledge pack**
   - Lexicon: the Lexica community spreadsheet, cleaned into a structured table. This is
     **canonical** — it is the surviving capture of Farmer's primary material, much of which
     was tweeted and is now dead links. Cross-check against the Wiktionary appendix and the
     Fandom word/phrase categories.
   - Grammar: encoded as explicit rules — definiteness agreement (`da X da Y`), aspect/mood
     markers, SVO order, head-before-modifier, zero copula, proximal/distal, `ke` questions,
     and gap-handling (below).

2. **Eval set**
   - Held-out attested Belta↔English pairs, scored **both directions** on grammar correctness
     and lexical accuracy. Without this scoreboard "exceptional" is unfalsifiable.

### Sources and hygiene

- **Keystone parallel data — Fandom "Belter dialogue" page.** Fans transcribed essentially
  every Belter line from the show in scene context with English meaning attached, flagging
  uncertain transcriptions with `?`. This is the human alignment we need. It is *not* clean
  pairs — it's prose scene-transcript format, some lines have no explicit gloss, and it needs
  real extraction + alignment to become a dataset. (The show was deliberately built to work
  *without* subtitles, so there is no official English gloss to mine — the mapping is fan
  labor.)
- **Lexicon:** Lexica spreadsheet (canonical); Wiktionary appendix + Fandom categories as
  cross-check.
- **Grammar:** Fandom grammar page; Linguifex.
- **Curated pairs:** phrasebooks / Memrise course / cheat sheets — smaller, higher quality.
- **QUARANTINE — the novels.** Book Belter is the older, incomplete, relexified-English
  register; Daniel Abraham (half of "James S.A. Corey") explicitly told learners to focus on
  the *show* version. **Zero book text** in training, eval, or RAG — no authority, not even a
  tiebreaker. Any valid book-origin word was absorbed into the Lexica sheet long ago.

### Realistic yield

Dialogue wiki (hundreds of lines) + curated pairs (smaller) → low thousands of clean pairs at
the absolute most. This is fine-tune-thin, which is exactly why the strategy stays RAG-first.

---

## Principles

- **Fail loud on lexical gaps.** Thousands of English concepts have no canonical Belter word.
  The system must handle gaps the way fluent speakers do — compounding, circumlocution,
  documented borrowing patterns — and **flag** any coined vocabulary ("no attested word;
  coined from X + Y") rather than silently inventing it. No silent fallbacks.
- **Measure, don't assume.** The eval harness is the first artifact, not an afterthought.
- **Register target:** the show / Farmer Ceres dialect. Everything else is out of scope.

---

## Next step

**Corpus inventory.** Pull each source and report actual counts — lexicon size, dialogue-wiki
line yield, curated pair count — so we size the corpus before designing the pack. Some sources
fetch cleanly (Fandom pages, Wiktionary appendix); the Lexica Google Sheet and a couple of the
cheat sheets are behind dynamic/auth walls and need a manual export.

---

## Open decisions

- **Model choice:** which 30B–70B quant fits the V100-32GB at acceptable tok/s.
- **Serving path:** system prompt + Open WebUI RAG doc-upload vs. a dedicated Ollama Modelfile
  with embedded system prompt vs. external orchestration.
- **Eval scoring:** automatic metrics (chrF++/BLEU are weak on a corpus this small) vs.
  rubric-based grammar-feature scoring (human or LLM-judge).
