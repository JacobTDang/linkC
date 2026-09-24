# Board palettes: AI agents, computer architecture, and connection styles

Jacob, after the diagram engine shipped: "I want to look into other things I could add to the
diagram, like stuff for agents, like nodes for LangGraph, tools, context, MCP services. Also … computer
architecture, like multiplexer, buses, component blocks like ALU etc."

He approved the mockups (`.superpowers/brainstorm/42945-1790255802/content/palettes.html`), and chose
all three pieces: the AI-agents palette, the computer-architecture palette, and connection styles.

Everything stays one Board: agents set `"kind"`, and the shape follows. Layout, routing and labels are
unchanged, because every new shape draws inside the same 176 × 84 footprint.

## 1 · New kinds

`ComponentKind` gains the kinds below, and `ComponentKind.groups` lists them in three named groups for
the toolbar:
- **System:** the existing seven kinds.
- **AI agents:** the 12 kinds in the first table.
- **Hardware:** the 10 kinds in the second table.

A kind linkC doesn't know is still kept verbatim and drawn as a service.

**AI agents:**

| kind | Shape (from the mockup) | Sub-line default |
|---|---|---|
| `agent` | A card with a sparkle glyph and an accent outline. | AGENT NODE |
| `model` | A card with a dashed inner border; the model's logo, or a chip glyph. | MODEL |
| `tool` | A card with clipped corners and a wrench glyph. | TOOL |
| `mcp` | A hexagon with a green outline; the service's logo, or a plug glyph. | MCP SERVER |
| `router` | A diamond with a gold outline; the name is centred. | ROUTER |
| `start` | A green-tinted pill; the name is centred. | — |
| `end` | A red-tinted pill; the name is centred. | — |
| `vector-store` | A cylinder with a dot grid. | VECTOR STORE |
| `memory` | A cylinder with a history glyph. | MEMORY |
| `prompt` | A document with a folded corner. | PROMPT · CONTEXT |
| `state` | A folder-tab card with a brace glyph and a violet outline. | STATE |
| `human` | A capsule card with a person glyph and a gold outline. | HUMAN IN THE LOOP |

**Hardware:**

| kind | Shape (from the mockup) | Sub-line default |
|---|---|---|
| `alu` | The notched ALU trapezoid; the name is centred. | — |
| `mux` / `demux` | A tall trapezoid (the wide side is the inputs for a mux, the outputs for a demux), with "sel" under it. | — |
| `register` | A rectangle with a clock notch on its bottom edge. | REGISTER |
| `ram` | A tall rectangle with memory-cell lines. | MEMORY |
| `control` | An ellipse with a gold outline; the name is in italics. | CONTROL UNIT |
| `adder` | A circle with a plus sign, and the name under it. | — |
| `decoder` | A trapezoid, the reverse of the mux. | — |
| `clock` | A small rounded square with a square-wave glyph, and the name under it. | — |
| `bus` | A thick horizontal bar, and the name above it. | — |

**What "sub-line default" means.** It is the text after `KIND ·` when a component has no `tech` and no
`reached_by`. Where the table shows —, the shape carries its name in or under the drawing and has no
sub-line.

**Insets.** Each new shape has per-kind side insets, as the existing shapes do, so arrow ends, the
running dot, handles and the change glow all sit on the drawn outline.

**The toolbar.** The Component menu shows three sections, System, AI agents and Hardware, each with
its kinds.

## 2 · Connection styles

An arrow gains a style:

| style | Drawn as | Meaning |
|---|---|---|
| `plain` (the default) | As today. | |
| `conditional` | Dashed gold, with a gold arrowhead and gold label text. | A branch an agent may take. The label is the branch ("done", "tool calls"). |
| `control` | Dashed gold, the same look. | A hardware control signal ("ALUSrc"). |
| `bus` | 2.6 pt thick, with a slash mark near the source carrying the bit width. | A multi-bit data path. |

**In the file.** A component's `uses` maps each target either to a label string (a plain arrow, exactly
as today) or to an object:

```json
"uses": {
  "tools": { "label": "tool calls", "style": "conditional" },
  "alu":   { "style": "bus", "bits": 32 },
  "db":    "reads"
}
```

- A plain arrow is always written as a string, so existing files and their diffs are unchanged.
- The object form is written only when the style isn't `plain`.
- `bits` is only valid with `bus` and must be 1–4096.
- An unknown style is refused with a reason.

**In code.** `BoardComponent.uses` becomes `[String: BoardArrow]`, where
`BoardArrow { label: String; style: BoardArrowStyle; bits: Int? }`. `BoardArrow` is
`ExpressibleByStringLiteral`, so plain arrows read naturally in code and tests.

Everything that reads or writes arrows carries the style with the arrow:
- decode and encode;
- `BoardMerge` (an arrow merges as one value);
- `BoardEdit`'s rename and delete;
- `BoardReport`, which appends `(conditional)`, `(control)` or `(bus, 32-bit)`;
- the router and labels, which only read labels.

**The default rule.** A new arrow from a `router` defaults to `conditional`, and one from a `control`
unit defaults to `control`. This holds whether it's drawn with the Arrow tool or added by
`linkc_edit_board`'s `connect` without a `style`. An explicit style always wins.

**For agents.**
- `connect` takes `"style"` (plain, conditional, control, bus) and `"bits"`.
- Connecting an existing arrow again replaces its label and style.
- `linkc_get_board` shows the object form.
- The tool description names the styles and the default rule.

**On the Board.** The arrow's label editor gains a compact style picker (plain / conditional / control
/ bus). With bus selected, it shows a bits field. The choice is one edit and one undo step.

**Drawing.**
- **Conditional and control arrows** use `Theme.boardConditional` (gold), dashed 5/4, with their pill
  text in gold.
- **A bus** draws 2.6 pt in the kind-neutral bus colour, with the slash mark and bit width about 30 pt
  after its first segment starts, never inside a box. With no label, the bus shows no pill.
- **Focus and hover** highlight styled arrows in the accent colour, as today.

## 3 · AI brand logos

`BoardTech` adds these ids, from `@lobehub/icons-static-svg` 1.95.1 (MIT, © LobeHub, the same source
as the agent logos). The colour variant is used where one exists, arcs are normalised as before, and
each logo is sized to 24 × 24.

| id | aliases | display name |
|---|---|---|
| `openai` | gpt, chatgpt | OpenAI |
| `anthropic` | | Anthropic |
| `gemini` | google-ai | Gemini |
| `mistral` | | Mistral |
| `meta` | llama | Meta |
| `deepseek` | | DeepSeek |
| `ollama` | | Ollama |
| `huggingface` | hf | Hugging Face |
| `langchain` | | LangChain |
| `langgraph` | | LangGraph |
| `llamaindex` | | LlamaIndex |
| `crewai` | crew | CrewAI |
| `groq` | | Groq |
| `perplexity` | | Perplexity |
| `cohere` | | Cohere |
| `qwen` | | Qwen |
| `xai` | grok | xAI |
| `mcp` | | MCP |
| `openrouter` | | OpenRouter |
| `vertexai` | vertex | Vertex AI |
| `bedrock` | | Bedrock |
| `azure` | | Azure |

`claude` keeps resolving to the Claude agent logo, so a `model` named or teched `claude` shows it.

The licence note joins the generated file's header. That file, `BoardTechLogos.swift`, already
documents its generator. Add the lobe source to the plan's generator step.

## 4 · Testing (LinkCKit, TDD)

- **`BoardMapTests`:**
  - a plain arrow is written as a string;
  - a styled arrow round-trips as an object;
  - `bits` is valid only with `bus` and within range;
  - an unknown style is refused;
  - a v1 file still decodes.
- **`BoardEditTests`:**
  - `connect` with a style and bits;
  - reconnecting replaces the label and style;
  - the default rule for `router` and `control` sources, and an explicit style overriding it;
  - rename and delete carry styled arrows;
  - bad style or bits values are refused with the step's number.
- **`BoardModelTests`:** the Board's `addArrow` applies the default rule, and `setArrowStyle` is one
  undo step.
- **`BoardMergeTests`:** an arrow's style merges as one value.
- **`BoardReportTests`:** styles appear in the report.
- **`BoardTechTests`:** the 22 new ids load as 24 × 24 SVGs, their aliases resolve, and the total count
  is 69.
- **`ComponentKindTests`:** the three groups cover every known kind exactly once, and the new kinds are
  known.

These are checked by hand in the app:
- all 22 new shapes at 25%, 100% and 200% zoom;
- arrows meeting their outlines;
- the grouped Component menu;
- the style picker;
- how conditional, control and bus arrows are drawn;
- the LangGraph and datapath examples from the mockup, built by an agent with `linkc_edit_board`.

## Out of scope

- Per-edge colours beyond the four styles.
- Ports: named inputs and outputs on a MUX or ALU.
- Top-to-bottom layout.
- Different footprint sizes per kind.
