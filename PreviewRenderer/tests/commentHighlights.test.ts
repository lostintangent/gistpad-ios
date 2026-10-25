import { describe, expect, test } from "bun:test";
import type { Root } from "hast";
import {
  CommentHighlightController, idleHighlight, type CommentThreadActivation,
} from "../src/commentHighlights";
import type { RenderRequest } from "../src/protocol";

const request: RenderRequest = {
  version: 1, documentID: "comments-fixture",
  generation: "18446744073709551615", markdown: "A native note",
};
function fixture(text = request.markdown) {
  const events: CommentThreadActivation[] = [];
  const controller = new CommentHighlightController(request, (event) => events.push(event));
  const tree: Root = { type: "root", children: [{ type: "text", value: text }] };
  controller.catalogPlugin()(tree);
  return { controller, events, tree };
}
function state(highlights = [{
  segment: 0, start: 2, end: 8, commentIDs: ["9223372036854775807"],
}]) {
  return {
    version: request.version, documentID: request.documentID, generation: request.generation,
    selectedCommentID: null, showsInlineComments: true, allowsInteraction: true, accent: "#FACC15", highlights,
  };
}

describe("native comment annotations", () => {
  test("catalog preserves individual text nodes in document order and excludes code and SVG", () => {
    const { controller } = fixture();
    const tree: Root = {
      type: "root", children: [{
        type: "element", tagName: "p", properties: {}, children: [
          { type: "text", value: "Before " },
          { type: "element", tagName: "strong", properties: {}, children: [{ type: "text", value: "native" }] },
          { type: "text", value: " after" },
          { type: "element", tagName: "code", properties: {}, children: [{ type: "text", value: "inline" }] },
        ],
      }, ...["pre", "svg"].map((tagName) => ({
        type: "element" as const, tagName, properties: {},
        children: [{ type: "text" as const, value: "excluded" }],
      }))],
    };
    const fresh = new CommentHighlightController(request, () => {});
    fresh.catalogPlugin()(tree);
    expect(fresh.catalog().segments).toEqual(["Before ", "native", " after"]);
    expect(controller.catalog().generation).toBe(request.generation);
  });

  test("catalog and native IDs retain full precision without exposing a mutable catalog", () => {
    const { controller } = fixture();
    const catalog = controller.catalog();
    catalog.segments[0] = "not the note";
    expect(controller.catalog().segments).toEqual(["A native note"]);
    controller.setHighlights(state());
    expect(controller.snapshot().highlights[0]!.commentIDs).toEqual(["9223372036854775807"]);
    controller.setHighlights(state([{ segment: 0, start: 2, end: 8, commentIDs: ["-9223372036854775808"] }]));
    expect(controller.snapshot().highlights[0]!.commentIDs).toEqual(["-9223372036854775808"]);
  });

  test("table whitespace stays a text node instead of becoming invalid span children", () => {
    const tree: Root = {
      type: "root", children: [{
        type: "element", tagName: "table", properties: {}, children: [
          { type: "text", value: "\n" },
          { type: "element", tagName: "tbody", properties: {}, children: [{
            type: "element", tagName: "tr", properties: {}, children: [{
              type: "element", tagName: "td", properties: {}, children: [{ type: "text", value: "native" }],
            }],
          }] },
        ],
      }],
    };
    const controller = new CommentHighlightController(request, () => {});
    controller.catalogPlugin()(tree);
    const table = tree.children[0]!;
    expect(table.type === "element" && table.children[0]!.type).toBe("text");
    expect(controller.catalog().segments).toEqual(["\n", "native"]);
  });

  test("activation sends a small verified range rather than an unbounded overlap ID list", () => {
    const { controller, events } = fixture();
    const input = state();
    input.highlights[0]!.commentIDs = Array.from({ length: 1_000 }, (_, index) => String(index + 1));
    controller.setHighlights(input);
    controller.open(controller.snapshot().highlights[0]!);
    expect(events).toEqual([{
      version: 1, documentID: request.documentID, generation: request.generation,
      type: "commentActivate", segment: 0, start: 2, end: 8,
    }]);
    expect(JSON.stringify(events[0]).length).toBeLessThan(256);
  });

  test("noninteractive annotations cannot emit activations", () => {
    const { controller, events } = fixture();
    controller.setHighlights({ ...state(), allowsInteraction: false });
    controller.open(controller.snapshot().highlights[0]!);
    expect(events).toEqual([]);
  });

  test("explicit reveal revisions retain UInt64 precision and reject invalid requests", () => {
    const { controller } = fixture();
    controller.setHighlights({ ...state(), selectedCommentID: "9223372036854775807",
      revealRevision: "18446744073709551615" });
    expect(controller.snapshot().revealRevision).toBe("18446744073709551615");
    for (const revealRevision of [null, 1, "-1", "01", "18446744073709551616"]) {
      expect(() => controller.setHighlights({ ...state(), revealRevision })).toThrow(TypeError);
    }
  });

  test("state updates preserve overlaps, selected-only visibility and exact source text", () => {
    const { controller } = fixture();
    const value = {
      ...state([
        { segment: 0, start: 2, end: 8, commentIDs: ["10", "20"] },
        { segment: 0, start: 8, end: 13, commentIDs: ["20"] },
      ]),
      selectedCommentID: "20", showsInlineComments: false,
    };
    let changes = 0;
    const unsubscribe = controller.subscribe(() => changes++);
    controller.setHighlights(value);
    value.highlights[0]!.commentIDs.length = 0;
    expect(controller.snapshot().highlights[0]!.commentIDs).toEqual(["10", "20"]);
    expect(controller.snapshot().showsInlineComments).toBe(false);
    expect(controller.catalog().segments[0]).toBe(request.markdown);
    expect(changes).toBe(1);
    unsubscribe();
    controller.setHighlights(state());
    expect(changes).toBe(1);
  });

  test("rejects stale identities, malformed IDs and unverified or overlapping ranges", () => {
    const { controller } = fixture();
    for (const invalid of [
      { ...state(), documentID: "another-note" },
      { ...state(), generation: "0" },
      { ...state(), accent: "var(--injected)" },
      state([{ segment: 1, start: 2, end: 8, commentIDs: ["1"] }]),
      state([{ segment: 0, start: -1, end: 8, commentIDs: ["1"] }]),
      state([{ segment: 0, start: 2, end: 100, commentIDs: ["1"] }]),
      state([{ segment: 0, start: 2, end: 8, commentIDs: ["-0"] }]),
      state([{ segment: 0, start: 2, end: 8, commentIDs: ["01"] }]),
      state([{ segment: 0, start: 2, end: 8, commentIDs: ["9223372036854775808"] }]),
      state([{ segment: 0, start: 2, end: 8, commentIDs: ["-9223372036854775809"] }]),
      state([{ segment: 0, start: 2, end: 8, commentIDs: ["1", "1"] }]),
      state([
        { segment: 0, start: 2, end: 8, commentIDs: ["1"] },
        { segment: 0, start: 7, end: 13, commentIDs: ["2"] },
      ]),
    ]) expect(() => controller.setHighlights(invalid)).toThrow(TypeError);
  });

  test("UTF-16 offsets never split a surrogate pair or normalize selected text", () => {
    const { controller } = fixture("🫧 native note");
    controller.setHighlights(state([{ segment: 0, start: 3, end: 9, commentIDs: ["1"] }]));
    expect(controller.catalog().segments[0]!.slice(3, 9)).toBe("native");
    expect(() => controller.setHighlights(
      state([{ segment: 0, start: 1, end: 9, commentIDs: ["1"] }]),
    )).toThrow(TypeError);
  });

  test("backgrounds start at half accent and preserve existing body, link and alpha-ink contrast", () => {
    expect(idleHighlight([250, 204, 21], [255, 255, 255], { rgb: [0, 0, 0], alpha: 1 }, 4.5))
      .toBe("rgb(253,230,138)");
    const dark = idleHighlight([250, 204, 21], [0, 0, 0], { rgb: [255, 255, 255], alpha: 1 }, 7);
    expect(dark).not.toBe("rgb(125,102,11)");
    expect(idleHighlight([250, 204, 21], [255, 255, 255], { rgb: [0, 122, 255], alpha: 1 }, 4.5))
      .toBe("rgb(255,255,255)");
    expect(idleHighlight([250, 204, 21], [255, 255, 255], { rgb: [60, 60, 67], alpha: 0.6 }, 7))
      .toBe("rgb(255,255,255)");
  });
});
