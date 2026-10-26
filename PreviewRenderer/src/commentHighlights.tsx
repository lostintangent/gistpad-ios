import { useEffect, useLayoutEffect, useRef, useSyncExternalStore, type ReactNode } from "react";
import { flushSync } from "react-dom";
import type { Element as HASTElement, Root } from "hast";
import { isUInt64String, type RenderRequest } from "./protocol";
import { contrastRatio, type RGB } from "./appearance";

type Identity = Pick<RenderRequest, "version" | "documentID" | "generation">;
export interface CommentThreadActivation extends Identity {
  type: "commentActivate";
  segment: number;
  start: number;
  end: number;
}
interface Highlight {
  segment: number;
  start: number;
  end: number;
  commentIDs: string[];
}
interface HighlightState extends Identity {
  highlights: Highlight[];
  selectedCommentID: string | null;
  revealRevision: string;
  showsInlineComments: boolean;
  allowsInteraction: boolean;
  accent: string;
}

function isCommentID(value: unknown): value is string {
  return typeof value === "string" && /^(0|-?[1-9]\d{0,18})$/.test(value) &&
    BigInt(value) >= -9_223_372_036_854_775_808n &&
    BigInt(value) <= 9_223_372_036_854_775_807n;
}

export class CommentHighlightController {
  private segments: string[] | undefined;
  private nodes = new WeakMap<HASTElement, number>();
  private listeners = new Set<() => void>();
  private state: HighlightState;

  constructor(
    private readonly request: RenderRequest,
    private readonly activate: (message: CommentThreadActivation) => void,
  ) {
    this.state = {
      ...this.identity(), highlights: [], selectedCommentID: null, revealRevision: "0",
      showsInlineComments: true, allowsInteraction: false, accent: "#0EA5E9",
    };
  }

  private identity(): Identity {
    return {
      version: this.request.version, documentID: this.request.documentID,
      generation: this.request.generation,
    };
  }

  readonly subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  };
  readonly snapshot = () => this.state;

  readonly catalogPlugin = () => (tree: Root) => {
    const segments: string[] = [];
    this.nodes = new WeakMap();
    const stack: { parent: Root | HASTElement; index: number }[] = [{ parent: tree, index: 0 }];
    while (stack.length > 0) {
      const frame = stack[stack.length - 1]!;
      const index = frame.index++;
      const node = frame.parent.children[index];
      if (!node) {
        stack.pop();
      } else if (node.type === "text") {
        const segment = segments.length;
        segments.push(node.value);
        if (!node.value.trim()) continue;
        const span: HASTElement = { type: "element", tagName: "span", properties: {}, children: [node] };
        this.nodes.set(span, segment);
        frame.parent.children[index] = span;
      } else if (node.type === "element" && !["pre", "code", "svg"].includes(node.tagName)) {
        stack.push({ parent: node, index: 0 });
      }
    }
    if (this.segments && (this.segments.length !== segments.length ||
        this.segments.some((text, index) => text !== segments[index]))) {
      throw new Error("The rendered quote catalog changed without a document generation.");
    }
    this.segments = segments;
  };

  segment(node: HASTElement | undefined): number | undefined {
    return node && this.nodes.get(node);
  }

  catalog() {
    if (!this.segments) throw new Error("The preview has not finished rendering.");
    return { ...this.identity(), segments: this.segments.slice() };
  }

  selection() {
    if (!this.segments) throw new Error("The preview has not finished rendering.");
    const selection = window.getSelection();
    const article = document.querySelector("article");
    const belongs = (node: Node | null) => node && article &&
      (article.contains(node) || node.contains(article));
    const quote = selection && selection.rangeCount === 1 && !selection.isCollapsed &&
      belongs(selection.anchorNode) && belongs(selection.focusNode)
      ? selection.toString() : null;
    return { ...this.identity(), quote };
  }

  setHighlights(value: unknown) {
    if (!value || typeof value !== "object" || !this.segments) {
      throw new TypeError("Invalid comment highlights");
    }
    const data = value as Partial<HighlightState>;
    const revealRevision = data.revealRevision === undefined ? "0" : data.revealRevision;
    if (data.version !== this.request.version || data.documentID !== this.request.documentID ||
        data.generation !== this.request.generation ||
        !isUInt64String(revealRevision) ||
        typeof data.showsInlineComments !== "boolean" ||
        typeof data.allowsInteraction !== "boolean" ||
        typeof data.accent !== "string" || !/^#[0-9a-f]{6}$/i.test(data.accent) ||
        (data.selectedCommentID !== null && !isCommentID(data.selectedCommentID)) ||
        !Array.isArray(data.highlights) || data.highlights.length > 20_000) {
      throw new TypeError("Invalid comment highlight state");
    }
    let previous: Highlight | undefined;
    for (const highlight of data.highlights) {
      if (!highlight || !Number.isSafeInteger(highlight.segment) ||
          !Number.isSafeInteger(highlight.start) || !Number.isSafeInteger(highlight.end) ||
          highlight.segment < 0 || highlight.segment >= this.segments.length ||
          highlight.start < 0 || highlight.end <= highlight.start ||
          highlight.end > this.segments[highlight.segment]!.length ||
          !Array.isArray(highlight.commentIDs) || highlight.commentIDs.length === 0 ||
          highlight.commentIDs.length > 20_000 || !highlight.commentIDs.every(isCommentID) ||
          new Set(highlight.commentIDs).size !== highlight.commentIDs.length ||
          !isTextBoundary(this.segments[highlight.segment]!, highlight.start) ||
          !isTextBoundary(this.segments[highlight.segment]!, highlight.end) ||
          (previous && (highlight.segment < previous.segment ||
            (highlight.segment === previous.segment && highlight.start < previous.end)))) {
        throw new TypeError("Invalid comment highlight range");
      }
      previous = highlight;
    }
    const restoreSelection = preserveRenderedSelection();
    this.state = {
      ...this.identity(),
      selectedCommentID: data.selectedCommentID,
      revealRevision,
      showsInlineComments: data.showsInlineComments,
      allowsInteraction: data.allowsInteraction,
      accent: data.accent,
      highlights: data.highlights.map((highlight) => ({
        ...highlight, commentIDs: highlight.commentIDs.slice(),
      })),
    };
    if (typeof document === "undefined") {
      this.listeners.forEach((listener) => listener());
    } else {
      flushSync(() => this.listeners.forEach((listener) => listener()));
    }
    restoreSelection?.();
  }

  open(highlight: Highlight) {
    if (!this.state.allowsInteraction || !this.state.highlights.includes(highlight)) return;
    this.activate({
      ...this.identity(), type: "commentActivate",
      segment: highlight.segment, start: highlight.start, end: highlight.end,
    });
  }
}

function isTextBoundary(text: string, offset: number): boolean {
  if (offset === 0 || offset === text.length) return true;
  const previous = text.charCodeAt(offset - 1), next = text.charCodeAt(offset);
  return !(previous >= 0xD800 && previous <= 0xDBFF && next >= 0xDC00 && next <= 0xDFFF);
}

export function CommentText({ controller, segment, text }: {
  controller: CommentHighlightController; segment: number; text: string;
}) {
  const state = useSyncExternalStore(controller.subscribe, controller.snapshot, controller.snapshot);
  const highlights = state.highlights.filter((highlight) => highlight.segment === segment);
  let cursor = 0;
  const children: ReactNode[] = [];
  let selectedRun: ReactNode[] | undefined;
  for (const highlight of highlights) {
    const before = text.slice(cursor, highlight.start);
    const quote = text.slice(highlight.start, highlight.end);
    cursor = highlight.end;
    const selected = highlight.commentIDs.includes(state.selectedCommentID ?? "");
    if (before || !selected) selectedRun = undefined;
    children.push(before);
    const fragment = state.showsInlineComments || selected
      ? <CommentFragment key={highlight.start} controller={controller} highlight={highlight}
        state={state} selected={selected}>{quote}</CommentFragment>
      : quote;
    if (selected) {
      if (!selectedRun) {
        selectedRun = [];
        children.push(<span key={`selected-${highlight.start}`} className="comment-selected-run" data-comment-run="">
          {selectedRun}
        </span>);
      }
      selectedRun.push(fragment);
    } else {
      children.push(fragment);
    }
  }
  return <span className="comment-text" data-comment-segment={segment}>{children}{text.slice(cursor)}</span>;
}

function preserveRenderedSelection(): (() => void) | undefined {
  if (typeof window === "undefined") return;
  const selection = window.getSelection();
  if (!selection || selection.isCollapsed || !selection.anchorNode || !selection.focusNode) return;
  function endpoint(node: Node, offset: number) {
    const element = node instanceof Element ? node : node.parentElement;
    const wrapper = element?.closest(".comment-text[data-comment-segment]");
    if (!wrapper) return { node, offset, wrapper: undefined };
    const range = document.createRange();
    range.selectNodeContents(wrapper);
    range.setEnd(node, offset);
    return { node, offset: range.toString().length, wrapper };
  }
  const original = {
    anchor: selection.anchorNode, anchorOffset: selection.anchorOffset,
    focus: selection.focusNode, focusOffset: selection.focusOffset,
  };
  const anchor = endpoint(selection.anchorNode, selection.anchorOffset);
  const focus = endpoint(selection.focusNode, selection.focusOffset);
  function resolve(saved: ReturnType<typeof endpoint>): { node: Node; offset: number } | undefined {
    if (!saved.wrapper) return saved.node.isConnected ? saved : undefined;
    if (!saved.wrapper.isConnected) return;
    const walker = document.createTreeWalker(saved.wrapper, NodeFilter.SHOW_TEXT);
    let remaining = saved.offset;
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const length = node.textContent?.length ?? 0;
      if (remaining <= length) return { node, offset: remaining };
      remaining -= length;
    }
  }
  return () => {
    if (selection.anchorNode === original.anchor && selection.anchorOffset === original.anchorOffset &&
        selection.focusNode === original.focus && selection.focusOffset === original.focusOffset) return;
    const start = resolve(anchor), end = resolve(focus);
    if (start && end) selection.setBaseAndExtent(start.node, start.offset, end.node, end.offset);
  };
}

function CommentFragment({ controller, highlight, state, selected, children }: {
  controller: CommentHighlightController; highlight: Highlight; state: HighlightState;
  selected: boolean; children: string;
}) {
  const ref = useRef<HTMLSpanElement>(null);
  useLayoutEffect(() => {
    const element = ref.current!;
    const update = () => {
      const parent = element.parentElement!;
      const ink = parseColor(getComputedStyle(parent).color);
      const layers: RGBA[] = [];
      for (let ancestor: Element | null = parent; ancestor; ancestor = ancestor.parentElement) {
        layers.push(parseColor(getComputedStyle(ancestor).backgroundColor));
      }
      let page: RGB = [255, 255, 255];
      for (const layer of layers.reverse()) page = mix(page, layer.rgb, layer.alpha);
      const accent = parseHex(state.accent);
      const target = document.documentElement.dataset.contrast === "increased" ? 7 : 4.5;
      element.style.setProperty("--comment-idle", idleHighlight(accent, page, ink, target));
    };
    update();
    window.addEventListener("gistpad-preview-appearance", update);
    return () => window.removeEventListener("gistpad-preview-appearance", update);
  }, [state.accent]);
  useEffect(() => {
    if (!selected) return;
    const first = state.highlights.find((span) => span.commentIDs.includes(state.selectedCommentID!));
    if (first !== highlight) return;
    for (let ancestor = ref.current?.parentElement; ancestor; ancestor = ancestor.parentElement) {
      if (ancestor instanceof HTMLDetailsElement) ancestor.open = true;
      if (ancestor.classList.contains("spoiler")) ancestor.dispatchEvent(new Event("gistpad-reveal-comment"));
    }
    if (window.webkit?.messageHandlers?.gistpadComments) return;
    const frame = requestAnimationFrame(() => {
      ref.current?.scrollIntoView({
        block: "center",
        behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "instant" : "smooth",
      });
    });
    return () => cancelAnimationFrame(frame);
  }, [selected, state.selectedCommentID, state.revealRevision]);
  return <span ref={ref} className={`comment-highlight${selected ? " comment-selected" : ""}`}
    data-comment-ids={highlight.commentIDs.join(" ")}
    role={state.allowsInteraction ? "button" : undefined} tabIndex={state.allowsInteraction ? 0 : undefined}
    aria-label={state.allowsInteraction ? children : undefined}
    aria-description={state.allowsInteraction
      ? `${selected ? "Selected comment. " : ""}${highlight.commentIDs.length > 1 ? "Choose comment thread" : "View comment"}`
      : undefined}
    aria-haspopup={state.allowsInteraction && highlight.commentIDs.length > 1 ? "dialog" : undefined}
    aria-current={selected ? "true" : undefined}
    onClick={state.allowsInteraction ? (event) => {
      event.preventDefault();
      event.stopPropagation();
      controller.open(highlight);
    } : undefined}
    onKeyDown={state.allowsInteraction ? (event) => {
      if (event.key !== "Enter" && event.key !== " ") return;
      event.preventDefault();
      event.stopPropagation();
      controller.open(highlight);
    } : undefined}>{children}</span>;
}

interface RGBA { rgb: RGB; alpha: number }
function mix(page: RGB, color: RGB, amount: number): RGB {
  return page.map((value, index) => value * (1 - amount) + color[index]! * amount) as RGB;
}
function parseHex(value: string): RGB {
  return [1, 3, 5].map((start) => parseInt(value.slice(start, start + 2), 16)) as RGB;
}
function parseColor(value: string): RGBA {
  const match = /^rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)(?:,\s*([\d.]+))?\)$/.exec(value);
  if (!match) throw new Error(`Unsupported computed comment color: ${value}`);
  return { rgb: [Number(match[1]), Number(match[2]), Number(match[3])], alpha: Number(match[4] ?? 1) };
}
export function idleHighlight(accent: RGB, page: RGB, ink: RGBA, target: number): string {
  const minimum = Math.min(target, contrastRatio(mix(page, ink.rgb, ink.alpha), page));
  for (let step = 0; step <= 128; step++) {
    const candidate = mix(page, accent, 0.5 - step / 256).map(Math.round) as RGB;
    if (contrastRatio(mix(candidate, ink.rgb, ink.alpha), candidate) + 0.000_001 >= minimum) {
      return `rgb(${candidate.join(",")})`;
    }
  }
  throw new Error("The comment background could not preserve its original text contrast.");
}
